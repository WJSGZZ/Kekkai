// 注入结界里运行的软件，替系统回答会认出你的问题：
// 假用户：问“我是谁、家在哪”时答 user 和结界文件夹，系统那边的查询照旧被挡。
// 假设备：序列号、硬件 UUID、网卡地址、电脑名换成结界给这个软件的一套，机型、系统版本这类不唯一的不改。
// 软件开新进程时常把环境变量整个换掉，这里把注入和这些设置补回去，子进程也拿到同样的答案。
#include <CoreFoundation/CoreFoundation.h>
#include <IOKit/IOKitLib.h>
#include <SystemConfiguration/SystemConfiguration.h>
#include <ifaddrs.h>
#include <net/if_dl.h>
#include <sys/sysctl.h>
#include <sys/utsname.h>
#include <pwd.h>
#include <spawn.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>
#include <errno.h>

#define INTERPOSE(mine, theirs) \
    __attribute__((used)) static struct { const void *a, *b; } _i_##theirs \
    __attribute__((section("__DATA,__interpose"))) = { (const void *)(mine), (const void *)(theirs) };

static const char *carry[] = {"HOME", "DYLD_INSERT_LIBRARIES", "KEKKAI_HOME", "KEKKAI_LAT", "KEKKAI_LON",
                              "KEKKAI_SERIAL", "KEKKAI_UUID", "KEKKAI_NAME", "KEKKAI_SEED", NULL};
static char *saved[sizeof carry / sizeof *carry];  // 启动时记下的 "名字=值"
static char *home, *serial, *uuid, *name, *seed;
static struct passwd fake;

__attribute__((constructor)) static void setup(void) {
    for (int i = 0; carry[i]; i++) {
        const char *v = getenv(carry[i]);
        if (!v) continue;
        size_t n = strlen(carry[i]) + strlen(v) + 2;
        saved[i] = malloc(n);
        strcpy(saved[i], carry[i]); strcat(saved[i], "="); strcat(saved[i], v);
    }
    const char *v;
    if ((v = getenv("KEKKAI_SERIAL"))) serial = strdup(v);
    if ((v = getenv("KEKKAI_UUID"))) uuid = strdup(v);
    if ((v = getenv("KEKKAI_NAME"))) name = strdup(v);
    if ((v = getenv("KEKKAI_SEED"))) seed = strdup(v);
    const char *h = getenv("KEKKAI_HOME");
    if (!h) return;
    home = strdup(h);
    fake = (struct passwd){.pw_name = "user", .pw_passwd = "*", .pw_uid = getuid(), .pw_gid = getgid(),
                           .pw_gecos = "User", .pw_dir = home, .pw_shell = "/bin/zsh", .pw_class = ""};
}

static int mine(uid_t uid) { return home && uid == getuid(); }

static struct passwd *my_getpwuid(uid_t uid) { return mine(uid) ? &fake : getpwuid(uid); }

static struct passwd *my_getpwnam(const char *name) {
    return home && name && !strcmp(name, "user") ? &fake : getpwnam(name);
}

// 把假用户写进调用方给的缓冲区
static int fill(struct passwd *pwd, char *buf, size_t len, struct passwd **result) {
    const char *f[] = {fake.pw_name, fake.pw_passwd, fake.pw_gecos, fake.pw_dir, fake.pw_shell, fake.pw_class};
    char *out[6];
    size_t used = 0;
    for (int i = 0; i < 6; i++) {
        size_t n = strlen(f[i]) + 1;
        if (used + n > len) { *result = NULL; return ERANGE; }
        out[i] = memcpy(buf + used, f[i], n);
        used += n;
    }
    *pwd = fake;
    pwd->pw_name = out[0]; pwd->pw_passwd = out[1]; pwd->pw_gecos = out[2];
    pwd->pw_dir = out[3]; pwd->pw_shell = out[4]; pwd->pw_class = out[5];
    *result = pwd;
    return 0;
}

static int my_getpwuid_r(uid_t uid, struct passwd *pwd, char *buf, size_t len, struct passwd **result) {
    return mine(uid) ? fill(pwd, buf, len, result) : getpwuid_r(uid, pwd, buf, len, result);
}

static int my_getpwnam_r(const char *name, struct passwd *pwd, char *buf, size_t len, struct passwd **result) {
    return home && name && !strcmp(name, "user") ? fill(pwd, buf, len, result) : getpwnam_r(name, pwd, buf, len, result);
}

static char *my_getlogin(void) { return home ? "user" : getlogin(); }

// 新进程的环境里缺哪项就补上；已有的不动
static char **patch(char *const envp[]) {
    size_t n = 0;
    while (envp && envp[n]) n++;
    char **out = malloc((n + sizeof carry / sizeof *carry + 1) * sizeof *out);
    memcpy(out, envp, n * sizeof *out);
    size_t m = n;
    for (int i = 0; carry[i]; i++) {
        if (!saved[i]) continue;
        size_t k = strlen(carry[i]);
        int has = 0;
        for (size_t j = 0; j < n && !has; j++) has = !strncmp(envp[j], carry[i], k) && envp[j][k] == '=';
        if (!has) out[m++] = saved[i];
    }
    out[m] = NULL;
    return out;
}

static int my_execve(const char *path, char *const argv[], char *const envp[]) {
    return execve(path, argv, patch(envp));
}

static int my_posix_spawn(pid_t *pid, const char *path, const posix_spawn_file_actions_t *fa,
                          const posix_spawnattr_t *attr, char *const argv[], char *const envp[]) {
    char **e = patch(envp);
    int r = posix_spawn(pid, path, fa, attr, argv, e);
    free(e);
    return r;
}

static int my_posix_spawnp(pid_t *pid, const char *file, const posix_spawn_file_actions_t *fa,
                           const posix_spawnattr_t *attr, char *const argv[], char *const envp[]) {
    char **e = patch(envp);
    int r = posix_spawnp(pid, file, fa, attr, argv, e);
    free(e);
    return r;
}

INTERPOSE(my_getpwuid, getpwuid)
INTERPOSE(my_getpwnam, getpwnam)
INTERPOSE(my_getpwuid_r, getpwuid_r)
INTERPOSE(my_getpwnam_r, getpwnam_r)
INTERPOSE(my_getlogin, getlogin)
INTERPOSE(my_execve, execve)
INTERPOSE(my_posix_spawn, posix_spawn)
INTERPOSE(my_posix_spawnp, posix_spawnp)

// ---- 假设备 ----

// 网卡地址：前三字节是厂商号，保留（看起来仍是苹果的网卡）；后三字节按这个软件的种子换掉，每块网卡各不相同
static void fake_mac(unsigned char *mac) {
    uint32_t h = 2166136261u;
    for (const char *c = seed; *c; c++) h = (h ^ (unsigned char)*c) * 16777619u;
    for (int i = 0; i < 6; i++) h = (h ^ mac[i]) * 16777619u;
    mac[3] = h >> 16; mac[4] = h >> 8; mac[5] = h;
}

static CFStringRef str(const char *s) { return CFStringCreateWithCString(NULL, s, kCFStringEncodingUTF8); }

// 设备树里的序列号是定长、补零的字节
static CFDataRef padded(const char *s, CFDataRef orig) {
    CFIndex n = orig ? CFDataGetLength(orig) : 32, k = strlen(s);
    UInt8 *b = calloc(n, 1);
    memcpy(b, s, k < n ? k : n);
    CFDataRef d = CFDataCreate(NULL, b, n);
    free(b);
    return d;
}

static int is(CFStringRef key, const char *s) {
    char buf[64];
    return key && CFStringGetCString(key, buf, sizeof buf, kCFStringEncodingUTF8) && !strcmp(buf, s);
}

// 有假值就返回新对象（调用方负责释放），否则 NULL
static CFTypeRef replacement(CFStringRef key, CFTypeRef orig) {
    if (serial && is(key, "IOPlatformSerialNumber")) return str(serial);
    if (uuid && is(key, "IOPlatformUUID")) return str(uuid);
    if (serial && (is(key, "serial-number") || is(key, "mlb-serial-number")))
        return padded(serial, orig && CFGetTypeID(orig) == CFDataGetTypeID() ? orig : NULL);
    if (seed && is(key, "IOMACAddress") && orig && CFGetTypeID(orig) == CFDataGetTypeID() && CFDataGetLength(orig) == 6) {
        UInt8 mac[6];
        CFDataGetBytes(orig, CFRangeMake(0, 6), mac);
        fake_mac(mac);
        return CFDataCreate(NULL, mac, 6);
    }
    return NULL;
}

static int sensitive(CFStringRef key) {
    return is(key, "IOPlatformSerialNumber") || is(key, "IOPlatformUUID") || is(key, "serial-number") ||
           is(key, "mlb-serial-number") || is(key, "IOMACAddress");
}

static CFTypeRef my_IORegistryEntryCreateCFProperty(io_registry_entry_t e, CFStringRef key, CFAllocatorRef a, IOOptionBits o) {
    CFTypeRef v = IORegistryEntryCreateCFProperty(e, key, a, o);
    if (!sensitive(key)) return v;
    CFTypeRef r = replacement(key, v);
    if (v) CFRelease(v);
    return r;  // 没有假值就当没有这一项
}

static CFTypeRef my_IORegistryEntrySearchCFProperty(io_registry_entry_t e, const io_name_t plane, CFStringRef key,
                                                    CFAllocatorRef a, IOOptionBits o) {
    CFTypeRef v = IORegistryEntrySearchCFProperty(e, plane, key, a, o);
    if (!sensitive(key)) return v;
    CFTypeRef r = replacement(key, v);
    if (v) CFRelease(v);
    return r;
}

static void scrub(const void *key, const void *value, void *dict) {
    if (CFGetTypeID(key) != CFStringGetTypeID() || !sensitive(key)) return;
    CFTypeRef r = replacement(key, value);
    if (r) { CFDictionarySetValue(dict, key, r); CFRelease(r); }
    else CFDictionaryRemoveValue(dict, key);
}

static kern_return_t my_IORegistryEntryCreateCFProperties(io_registry_entry_t e, CFMutableDictionaryRef *props,
                                                          CFAllocatorRef a, IOOptionBits o) {
    kern_return_t kr = IORegistryEntryCreateCFProperties(e, props, a, o);
    if (kr == KERN_SUCCESS && props && *props) {
        CFDictionaryRef copy = CFDictionaryCreateCopy(NULL, *props);  // 遍历时不能改原字典
        CFDictionaryApplyFunction(copy, scrub, *props);
        CFRelease(copy);
        // 结界规则把真值挡掉后整本字典里就没有这几项，补上假的
        if (IOObjectConformsTo(e, "IOPlatformExpertDevice")) {
            const char *keys[] = {"IOPlatformSerialNumber", "IOPlatformUUID", NULL};
            for (int i = 0; keys[i]; i++) {
                CFStringRef k = str(keys[i]);
                CFTypeRef r = CFDictionaryContainsKey(*props, k) ? NULL : replacement(k, NULL);
                if (r) { CFDictionarySetValue(*props, k, r); CFRelease(r); }
                CFRelease(k);
            }
        }
    }
    return kr;
}

static int my_gethostuuid(uuid_t id, const struct timespec *wait) {
    if (!uuid) return gethostuuid(id, wait);
    unsigned v[16];
    if (sscanf(uuid, "%2x%2x%2x%2x-%2x%2x-%2x%2x-%2x%2x-%2x%2x%2x%2x%2x%2x", &v[0], &v[1], &v[2], &v[3], &v[4], &v[5],
               &v[6], &v[7], &v[8], &v[9], &v[10], &v[11], &v[12], &v[13], &v[14], &v[15]) != 16)
        return gethostuuid(id, wait);
    for (int i = 0; i < 16; i++) id[i] = v[i];
    return 0;
}

static int my_getifaddrs(struct ifaddrs **list) {
    int r = getifaddrs(list);
    if (r == 0 && seed)
        for (struct ifaddrs *i = *list; i; i = i->ifa_next)
            if (i->ifa_addr && i->ifa_addr->sa_family == AF_LINK) {
                struct sockaddr_dl *d = (struct sockaddr_dl *)i->ifa_addr;
                unsigned char *m = (unsigned char *)LLADDR(d);
                // 新版系统这里本来就只给 02:00:00:00:00:00 这样的占位，不用改
                if (d->sdl_alen == 6 && (m[1] | m[2] | m[3] | m[4] | m[5])) fake_mac(m);
            }
    return r;
}

// 主机名：电脑名去掉空格加 .local，和系统默认的样子一致
static void hostname(char *out, size_t n) {
    char h[256];
    size_t j = 0;
    for (const char *c = name; *c && j < sizeof h - 7; c++) h[j++] = *c == ' ' ? '-' : *c;
    strcpy(h + j, ".local");
    strlcpy(out, h, n);
}

static int my_gethostname(char *out, size_t n) {
    if (!name) return gethostname(out, n);
    hostname(out, n);
    return 0;
}

static int my_uname(struct utsname *u) {
    int r = uname(u);
    if (r == 0 && name) hostname(u->nodename, sizeof u->nodename);
    return r;
}

static int fill_hostname(void *old, size_t *oldlen) {
    char h[256];
    hostname(h, sizeof h);
    size_t n = strlen(h) + 1;
    if (old && *oldlen < n) { errno = ENOMEM; return -1; }
    if (old) memcpy(old, h, n);
    *oldlen = n;
    return 0;
}

static int my_sysctl(int *mib, u_int len, void *old, size_t *oldlen, void *new, size_t newlen) {
    if (name && len == 2 && mib[0] == CTL_KERN && mib[1] == KERN_HOSTNAME && !new && oldlen) return fill_hostname(old, oldlen);
    return sysctl(mib, len, old, oldlen, new, newlen);
}

static int my_sysctlbyname(const char *n, void *old, size_t *oldlen, void *new, size_t newlen) {
    if (name && n && !strcmp(n, "kern.hostname") && !new && oldlen) return fill_hostname(old, oldlen);
    return sysctlbyname(n, old, oldlen, new, newlen);
}

static CFStringRef my_SCDynamicStoreCopyComputerName(SCDynamicStoreRef store, CFStringEncoding *enc) {
    if (!name) return SCDynamicStoreCopyComputerName(store, enc);
    if (enc) *enc = kCFStringEncodingUTF8;
    return str(name);
}

static CFStringRef my_SCDynamicStoreCopyLocalHostName(SCDynamicStoreRef store) {
    if (!name) return SCDynamicStoreCopyLocalHostName(store);
    char h[256];
    hostname(h, sizeof h);
    h[strlen(h) - 6] = 0;  // 去掉 .local
    return str(h);
}

INTERPOSE(my_IORegistryEntryCreateCFProperty, IORegistryEntryCreateCFProperty)
INTERPOSE(my_IORegistryEntrySearchCFProperty, IORegistryEntrySearchCFProperty)
INTERPOSE(my_IORegistryEntryCreateCFProperties, IORegistryEntryCreateCFProperties)
INTERPOSE(my_gethostuuid, gethostuuid)
INTERPOSE(my_getifaddrs, getifaddrs)
INTERPOSE(my_gethostname, gethostname)
INTERPOSE(my_uname, uname)
INTERPOSE(my_sysctl, sysctl)
INTERPOSE(my_sysctlbyname, sysctlbyname)
INTERPOSE(my_SCDynamicStoreCopyComputerName, SCDynamicStoreCopyComputerName)
INTERPOSE(my_SCDynamicStoreCopyLocalHostName, SCDynamicStoreCopyLocalHostName)
