// 注入结界里运行的软件，替系统回答会认出你的问题：
// 假用户：问“我是谁、家在哪”时答 user 和结界文件夹，系统那边的查询照旧被挡。
// 假设备：序列号、硬件 UUID、网卡地址、电脑名换成结界给这个软件的一套，机型、系统版本这类不唯一的不改。
// 软件开新进程时常把环境变量整个换掉，这里把注入和这些设置补回去，子进程也拿到同样的答案。
// 端口：它开的 TCP 端口挪进结界分给它的那组，沙盒只许它连这组，所以连得上自己的、连不上别人的。
// 剪贴板：可以写；读内容只在你按 ⌘V 或点“粘贴”后的一会儿放行。
// 进程：别的程序一律“没有这个进程”，列表里只有它自己，像一台什么都没开的 Mac。
// 局域网：连不上局域网里的设备，也搜不到 Bonjour 服务；DNS 和系统代理照常。
// 语言：首选语言和地区换成常见的组合（如简体中文、中国），不留第二语言。
#include <CoreFoundation/CoreFoundation.h>
#include <IOKit/IOKitLib.h>
#include <SystemConfiguration/SystemConfiguration.h>
#include <DiskArbitration/DiskArbitration.h>
#include <CoreGraphics/CoreGraphics.h>
#include <ColorSync/ColorSync.h>
#include <ifaddrs.h>
#include <net/if_dl.h>
#include <sys/sysctl.h>
#include <net/route.h>
#include <sys/utsname.h>
#include <pwd.h>
#include <spawn.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>
#include <errno.h>
#include <libproc.h>
#include <dlfcn.h>
#include <time.h>
#include <objc/runtime.h>
#include <objc/message.h>
#include <ctype.h>
#include <fcntl.h>
#include <stdio.h>
#include <netinet/in.h>
#include <arpa/inet.h>
#include <sys/socket.h>
#include <dns_sd.h>
#include <Network/Network.h>

#define INTERPOSE(mine, theirs) \
    __attribute__((used)) static struct { const void *a, *b; } _i_##theirs \
    __attribute__((section("__DATA,__interpose"))) = { (const void *)(mine), (const void *)(theirs) };

static const char *carry[] = {"HOME", "DYLD_INSERT_LIBRARIES", "KEKKAI_HOME", "KEKKAI_LAT", "KEKKAI_LON",
                              "KEKKAI_SERIAL", "KEKKAI_UUID", "KEKKAI_NAME", "KEKKAI_SEED",
                              "KEKKAI_PORTS", "KEKKAI_PORTMAP", "KEKKAI_PASTE", "KEKKAI_PROCS",
                              "KEKKAI_NOLAN", "KEKKAI_LANG", "KEKKAI_LOCALE", NULL};
static char *saved[sizeof carry / sizeof *carry];  // 启动时记下的 "名字=值"
static char *home, *serial, *uuid, *name, *seed, *portmap;
static int pstart, pcount;  // 分给它的端口：pstart 起 pcount 个
static int hide_procs, no_lan;
static struct passwd fake;

// ---- 剪贴板 ----

static double paste_until;  // 这个时刻之前读剪贴板放行
static CFStringRef general;  // 通用剪贴板的名字；拖放用的是另一块，不管

static double now_s(void) {
    struct timespec t;
    clock_gettime(CLOCK_MONOTONIC, &t);
    return t.tv_sec + t.tv_nsec / 1e9;
}

static int may_read(id pb) {
    if (now_s() < paste_until || !general) return 1;
    CFTypeRef n = ((id (*)(id, SEL))objc_msgSend)(pb, sel_registerName("name"));
    return !n || !CFEqual(n, general);
}

static int text_is(id s, const char *want) {
    char b[64];
    return s && CFStringGetCString((CFStringRef)s, b, sizeof b, kCFStringEncodingUTF8) && !strcmp(b, want);
}

static int text_has(id s, const char *part) {
    char b[256];
    return s && CFStringGetCString((CFStringRef)s, b, sizeof b, kCFStringEncodingUTF8) && strstr(b, part);
}

static IMP orig_data, orig_string, orig_plist, orig_objects, orig_items, orig_file, orig_wrapper, orig_event, orig_action;

static id g_data(id self, SEL s, id type) { return may_read(self) ? ((id (*)(id, SEL, id))orig_data)(self, s, type) : nil; }
static id g_string(id self, SEL s, id type) { return may_read(self) ? ((id (*)(id, SEL, id))orig_string)(self, s, type) : nil; }
static id g_plist(id self, SEL s, id type) { return may_read(self) ? ((id (*)(id, SEL, id))orig_plist)(self, s, type) : nil; }
static id g_objects(id self, SEL s, id cls, id opt) {
    return may_read(self) ? ((id (*)(id, SEL, id, id))orig_objects)(self, s, cls, opt) : nil;
}
static id g_items(id self, SEL s) { return may_read(self) ? ((id (*)(id, SEL))orig_items)(self, s) : nil; }
static id g_file(id self, SEL s, id type, id path) {
    return may_read(self) ? ((id (*)(id, SEL, id, id))orig_file)(self, s, type, path) : nil;
}
static id g_wrapper(id self, SEL s) { return may_read(self) ? ((id (*)(id, SEL))orig_wrapper)(self, s) : nil; }

// ⌘V：按键先经过 sendEvent:，菜单的快捷键也在这之后才处理
static void g_event(id self, SEL s, id e) {
    unsigned long type = ((unsigned long (*)(id, SEL))objc_msgSend)(e, sel_registerName("type"));
    if (type == 10) {  // 按下键
        unsigned long flags = ((unsigned long (*)(id, SEL))objc_msgSend)(e, sel_registerName("modifierFlags"));
        id chars = ((id (*)(id, SEL))objc_msgSend)(e, sel_registerName("charactersIgnoringModifiers"));
        if ((flags & (1ul << 20)) && (text_is(chars, "v") || text_is(chars, "V"))) paste_until = now_s() + 1.5;
    }
    ((void (*)(id, SEL, id))orig_event)(self, s, e);
}

// 点菜单或右键菜单里的“粘贴”：动作名是 paste 开头的，或者菜单项是 ⌘V、叫“粘贴”
static BOOL g_action(id self, SEL s, SEL action, id to, id from) {
    const char *a = action ? sel_getName(action) : "";
    int paste = !strncmp(a, "paste", 5);
    if (!paste && from && objc_getClass("NSMenuItem") &&
        ((BOOL (*)(id, SEL, Class))objc_msgSend)(from, sel_registerName("isKindOfClass:"), objc_getClass("NSMenuItem"))) {
        id key = ((id (*)(id, SEL))objc_msgSend)(from, sel_registerName("keyEquivalent"));
        unsigned long mask = ((unsigned long (*)(id, SEL))objc_msgSend)(from, sel_registerName("keyEquivalentModifierMask"));
        id title = ((id (*)(id, SEL))objc_msgSend)(from, sel_registerName("title"));
        paste = (text_is(key, "v") && (mask & (1ul << 20))) || text_has(title, "粘贴") || text_has(title, "Paste");
    }
    if (paste) paste_until = now_s() + 1.5;
    return ((BOOL (*)(id, SEL, SEL, id, id))orig_action)(self, s, action, to, from);
}

static void hook(const char *cls, const char *sel, IMP mine, IMP *orig) {
    Class c = objc_getClass(cls);
    Method m = c ? class_getInstanceMethod(c, sel_registerName(sel)) : NULL;
    if (m) *orig = method_setImplementation(m, mine);
}

static void guard_clipboard(void) {
    if (!objc_getClass("NSPasteboard") || !objc_getClass("NSApplication")) return;  // 没有界面的进程碰不到剪贴板
    id *g = dlsym(RTLD_DEFAULT, "NSPasteboardNameGeneral");
    general = g && *g ? CFRetain((CFTypeRef)*g) : NULL;
    hook("NSPasteboard", "dataForType:", (IMP)g_data, &orig_data);
    hook("NSPasteboard", "stringForType:", (IMP)g_string, &orig_string);
    hook("NSPasteboard", "propertyListForType:", (IMP)g_plist, &orig_plist);
    hook("NSPasteboard", "readObjectsForClasses:options:", (IMP)g_objects, &orig_objects);
    hook("NSPasteboard", "pasteboardItems", (IMP)g_items, &orig_items);
    hook("NSPasteboard", "readFileContentsType:toFile:", (IMP)g_file, &orig_file);
    hook("NSPasteboard", "readFileWrapper", (IMP)g_wrapper, &orig_wrapper);
    hook("NSApplication", "sendEvent:", (IMP)g_event, &orig_event);
    hook("NSApplication", "sendAction:to:from:", (IMP)g_action, &orig_action);
}

static void hide_apps(void);

static void find_proxies(void);
static void set_language(const char *lang, const char *locale);

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
    if ((v = getenv("KEKKAI_PORTS")) && sscanf(v, "%d:%d", &pstart, &pcount) != 2) pcount = 0;
    if ((v = getenv("KEKKAI_PORTMAP"))) portmap = strdup(v);
    if (getenv("KEKKAI_PASTE")) guard_clipboard();
    hide_procs = getenv("KEKKAI_PROCS") != NULL;
    if (hide_procs) hide_apps();
    if ((no_lan = getenv("KEKKAI_NOLAN") != NULL)) find_proxies();
    if (getenv("KEKKAI_LANG") && getenv("KEKKAI_LOCALE")) set_language(getenv("KEKKAI_LANG"), getenv("KEKKAI_LOCALE"));
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

// ---- 端口 ----

static int ours(int port) { return port >= pstart && port < pstart + pcount; }

static int port_of(const struct sockaddr *a) {
    return ntohs(a->sa_family == AF_INET ? ((struct sockaddr_in *)a)->sin_port : ((struct sockaddr_in6 *)a)->sin6_port);
}

static void set_port(struct sockaddr *a, int port) {
    if (a->sa_family == AF_INET) ((struct sockaddr_in *)a)->sin_port = htons(port);
    else ((struct sockaddr_in6 *)a)->sin6_port = htons(port);
}

static int inet(const struct sockaddr *a, socklen_t len) {
    return a && ((a->sa_family == AF_INET && len >= sizeof(struct sockaddr_in)) ||
                 (a->sa_family == AF_INET6 && len >= sizeof(struct sockaddr_in6)));
}

static int loopback(const struct sockaddr *a) {
    if (a->sa_family == AF_INET) return (ntohl(((struct sockaddr_in *)a)->sin_addr.s_addr) >> 24) == 127;
    const struct in6_addr *x = &((struct sockaddr_in6 *)a)->sin6_addr;
    return IN6_IS_ADDR_LOOPBACK(x) || (IN6_IS_ADDR_V4MAPPED(x) && x->s6_addr[12] == 127);
}

// 记录文件每行“原端口 实际端口”，后写的算数；各进程共用
static int mapped(int port) {
    int fd = portmap ? open(portmap, O_RDONLY) : -1, found = 0;
    if (fd < 0) return 0;
    char buf[8192];
    ssize_t n = read(fd, buf, sizeof buf - 1);
    close(fd);
    if (n <= 0) return 0;
    buf[n] = 0;
    for (char *line = buf; line && *line; line = strchr(line, '\n'), line = line ? line + 1 : NULL) {
        int from, to;
        if (sscanf(line, "%d %d", &from, &to) == 2 && from == port) found = to;
    }
    return found;
}

static void remember(int from, int to) {
    int fd = portmap ? open(portmap, O_WRONLY | O_APPEND | O_CREAT, 0600) : -1;
    if (fd < 0) return;
    char line[32];
    write(fd, line, snprintf(line, sizeof line, "%d %d\n", from, to));
    close(fd);
}

static int my_bind(int fd, const struct sockaddr *addr, socklen_t len) {
    int type = 0;
    socklen_t tl = sizeof type;
    if (!pcount || !inet(addr, len) || getsockopt(fd, SOL_SOCKET, SO_TYPE, &type, &tl) || type != SOCK_STREAM ||
        ours(port_of(addr)))
        return bind(fd, addr, len);
    struct sockaddr_storage a;
    memcpy(&a, addr, len);
    int want = port_of(addr), before = want ? mapped(want) : 0;
    if (before) {  // 已经挪过：只用原来那个，占着就照实说占着（别的进程靠这个判断自己是不是第二个）
        set_port((struct sockaddr *)&a, before);
        return bind(fd, (struct sockaddr *)&a, len);
    }
    for (int i = 0; i < pcount; i++) {
        int port = pstart + (want + i) % pcount;
        set_port((struct sockaddr *)&a, port);
        if (bind(fd, (struct sockaddr *)&a, len) == 0) {
            if (want) remember(want, port);
            return 0;
        }
        if (errno != EADDRINUSE) return -1;
    }
    errno = EADDRINUSE;
    return -1;
}

static int to_port(int fd, const struct sockaddr *addr, socklen_t len) {
    int to;
    if (!pcount || !inet(addr, len) || !loopback(addr) || ours(port_of(addr)) || !(to = mapped(port_of(addr))))
        return connect(fd, addr, len);
    struct sockaddr_storage a;
    memcpy(&a, addr, len);
    set_port((struct sockaddr *)&a, to);
    return connect(fd, (struct sockaddr *)&a, len);
}

INTERPOSE(my_bind, bind)

// ---- 局域网 ----

static struct sockaddr_storage proxies[8];  // 系统代理设在局域网里时照常放行
static int nproxies;

static int private4(uint32_t a) {
    return (a >> 24) == 10 || (a >> 20) == 0xAC1 || (a >> 16) == 0xC0A8 || (a >> 16) == 0xA9FE ||
           (a >> 28) == 0xE || a == 0xFFFFFFFF;  // 私有、链路本地、组播、广播
}

static int same_host(const struct sockaddr *a, const struct sockaddr *b) {
    if (a->sa_family != b->sa_family || port_of(a) != port_of(b)) return 0;
    if (a->sa_family == AF_INET)
        return ((struct sockaddr_in *)a)->sin_addr.s_addr == ((struct sockaddr_in *)b)->sin_addr.s_addr;
    return !memcmp(&((struct sockaddr_in6 *)a)->sin6_addr, &((struct sockaddr_in6 *)b)->sin6_addr, 16);
}

static int lan(const struct sockaddr *a, socklen_t len) {
    if (!no_lan || !inet(a, len) || port_of(a) == 53) return 0;
    int hit;
    if (a->sa_family == AF_INET) hit = private4(ntohl(((struct sockaddr_in *)a)->sin_addr.s_addr));
    else {
        const struct in6_addr *x = &((struct sockaddr_in6 *)a)->sin6_addr;
        hit = IN6_IS_ADDR_LINKLOCAL(x) || IN6_IS_ADDR_MULTICAST(x) || (x->s6_addr[0] & 0xFE) == 0xFC ||
              (IN6_IS_ADDR_V4MAPPED(x) && private4(ntohl(*(uint32_t *)&x->s6_addr[12])));
    }
    for (int i = 0; hit && i < nproxies; i++)
        if (same_host(a, (struct sockaddr *)&proxies[i])) hit = 0;
    return hit;
}

static void find_proxies(void) {
    CFDictionaryRef d = SCDynamicStoreCopyProxies(NULL);
    if (!d) return;
    CFStringRef keys[][2] = {{kSCPropNetProxiesHTTPProxy, kSCPropNetProxiesHTTPPort},
                             {kSCPropNetProxiesHTTPSProxy, kSCPropNetProxiesHTTPSPort},
                             {kSCPropNetProxiesSOCKSProxy, kSCPropNetProxiesSOCKSPort}};
    for (int i = 0; i < 3 && nproxies < 8; i++) {
        CFStringRef host = CFDictionaryGetValue(d, keys[i][0]);
        CFNumberRef port = CFDictionaryGetValue(d, keys[i][1]);
        char h[64];
        int p = 0;
        if (!host || CFGetTypeID(host) != CFStringGetTypeID() || !CFStringGetCString(host, h, sizeof h, kCFStringEncodingUTF8) ||
            !port || CFGetTypeID(port) != CFNumberGetTypeID() || !CFNumberGetValue(port, kCFNumberIntType, &p))
            continue;
        struct sockaddr_storage *s = &proxies[nproxies];
        struct sockaddr_in *v4 = (struct sockaddr_in *)s;
        struct sockaddr_in6 *v6 = (struct sockaddr_in6 *)s;
        if (inet_pton(AF_INET, h, &v4->sin_addr) == 1) v4->sin_family = AF_INET, v4->sin_port = htons(p), nproxies++;
        else if (inet_pton(AF_INET6, h, &v6->sin6_addr) == 1) v6->sin6_family = AF_INET6, v6->sin6_port = htons(p), nproxies++;
    }
    CFRelease(d);
}

static int my_connect(int fd, const struct sockaddr *addr, socklen_t len) {
    if (lan(addr, len)) return errno = EHOSTUNREACH, -1;
    return to_port(fd, addr, len);
}

static int my_connectx(int fd, const sa_endpoints_t *ep, sae_associd_t aid, unsigned int flags, const struct iovec *iov,
                       unsigned int iovcnt, size_t *len, sae_connid_t *cid) {
    if (ep && lan(ep->sae_dstaddr, ep->sae_dstaddrlen)) return errno = EHOSTUNREACH, -1;
    return connectx(fd, ep, aid, flags, iov, iovcnt, len, cid);
}

static ssize_t my_sendto(int fd, const void *buf, size_t n, int flags, const struct sockaddr *to, socklen_t len) {
    if (to && lan(to, len)) return errno = EHOSTUNREACH, -1;
    return sendto(fd, buf, n, flags, to, len);
}

static ssize_t my_sendmsg(int fd, const struct msghdr *m, int flags) {
    if (m && m->msg_name && lan(m->msg_name, m->msg_namelen)) return errno = EHOSTUNREACH, -1;
    return sendmsg(fd, m, flags);
}

// Bonjour：NSNetServiceBrowser 等经过这几个函数
static DNSServiceErrorType my_DNSServiceBrowse(DNSServiceRef *r, DNSServiceFlags f, uint32_t i, const char *type,
                                               const char *domain, DNSServiceBrowseReply cb, void *ctx) {
    return no_lan ? kDNSServiceErr_PolicyDenied : DNSServiceBrowse(r, f, i, type, domain, cb, ctx);
}

static DNSServiceErrorType my_DNSServiceResolve(DNSServiceRef *r, DNSServiceFlags f, uint32_t i, const char *name,
                                                const char *type, const char *domain, DNSServiceResolveReply cb, void *ctx) {
    return no_lan ? kDNSServiceErr_PolicyDenied : DNSServiceResolve(r, f, i, name, type, domain, cb, ctx);
}

static DNSServiceErrorType my_DNSServiceRegister(DNSServiceRef *r, DNSServiceFlags f, uint32_t i, const char *name,
                                                 const char *type, const char *domain, const char *host, uint16_t port,
                                                 uint16_t txtlen, const void *txt, DNSServiceRegisterReply cb, void *ctx) {
    return no_lan ? kDNSServiceErr_PolicyDenied
                  : DNSServiceRegister(r, f, i, name, type, domain, host, port, txtlen, txt, cb, ctx);
}

// Network 框架的浏览器不经上面几个函数，直接取消，软件收到“已取消”
static void my_nw_browser_start(nw_browser_t b) {
    if (no_lan) nw_browser_cancel(b);
    else nw_browser_start(b);
}

INTERPOSE(my_nw_browser_start, nw_browser_start)
INTERPOSE(my_connectx, connectx)
INTERPOSE(my_sendto, sendto)
INTERPOSE(my_sendmsg, sendmsg)
INTERPOSE(my_DNSServiceBrowse, DNSServiceBrowse)
INTERPOSE(my_DNSServiceResolve, DNSServiceResolve)
INTERPOSE(my_DNSServiceRegister, DNSServiceRegister)

// ---- 语言 ----

// 只改本进程的偏好设置：结界文件夹里偏好设置不经系统服务，不会写进真实的偏好设置。软件自己选过语言的不动
static void set_language(const char *lang, const char *locale) {
    CFPropertyListRef own = CFPreferencesCopyValue(CFSTR("AppleLanguages"), kCFPreferencesCurrentApplication,
                                                   kCFPreferencesCurrentUser, kCFPreferencesAnyHost);
    if (own) return CFRelease(own);
    CFStringRef l = CFStringCreateWithCString(NULL, lang, kCFStringEncodingUTF8);
    CFStringRef r = CFStringCreateWithCString(NULL, locale, kCFStringEncodingUTF8);
    CFArrayRef a = CFArrayCreate(NULL, (const void **)&l, 1, &kCFTypeArrayCallBacks);
    CFPreferencesSetAppValue(CFSTR("AppleLanguages"), a, kCFPreferencesCurrentApplication);
    CFPreferencesSetAppValue(CFSTR("AppleLocale"), r, kCFPreferencesCurrentApplication);
    CFRelease(a), CFRelease(l), CFRelease(r);
}

INTERPOSE(my_connect, connect)

// ---- 进程 ----

// 是它自己或它开的子进程
static int family(pid_t pid) {
    if (pid == getpid()) return 1;
    struct kinfo_proc k;
    size_t n = sizeof k;
    int mib[4] = {CTL_KERN, KERN_PROC, KERN_PROC_PID, pid};
    return !sysctl(mib, 4, &k, &n, NULL, 0) && n && k.kp_eproc.e_ppid == getpid();
}

static int my_proc_listpids(uint32_t type, uint32_t info, void *buf, int size) {
    if (!hide_procs) return proc_listpids(type, info, buf, size);
    if (!buf) return sizeof(pid_t);
    if (size < (int)sizeof(pid_t)) return 0;
    *(pid_t *)buf = getpid();
    return sizeof(pid_t);
}

static int my_proc_listallpids(void *buf, int size) {
    if (!hide_procs) return proc_listallpids(buf, size);
    if (buf && size >= (int)sizeof(pid_t)) *(pid_t *)buf = getpid();
    return 1;
}

// 查别人：系统沙盒答“没有权限”，换成“没有这个进程”
#define ALIEN(call) do { int r_ = (call); if (hide_procs && r_ <= 0 && errno == EPERM) errno = ESRCH; return r_; } while (0)
static int my_proc_pidinfo(int pid, int flavor, uint64_t arg, void *buf, int size) {
    if (hide_procs && !family(pid)) { errno = ESRCH; return 0; }
    ALIEN(proc_pidinfo(pid, flavor, arg, buf, size));
}
static int my_proc_pidpath(int pid, void *buf, uint32_t size) {
    if (hide_procs && !family(pid)) { errno = ESRCH; return 0; }
    ALIEN(proc_pidpath(pid, buf, size));
}
static int my_proc_name(int pid, void *buf, uint32_t size) {
    if (hide_procs && !family(pid)) { errno = ESRCH; return 0; }
    ALIEN(proc_name(pid, buf, size));
}

// sysctl 的进程表：整份列表只给它自己那一条；按编号查别人当作没有
static int proc_table(int *mib, u_int len) { return hide_procs && len >= 3 && mib[0] == CTL_KERN && mib[1] == KERN_PROC; }

static int fake_proc_table(int *mib, u_int len, void *old, size_t *oldlen) {
    if (len >= 4 && mib[2] == KERN_PROC_PID) {
        if (family(mib[3])) return sysctl(mib, len, old, oldlen, NULL, 0);
        *oldlen = 0;
        return 0;
    }
    if (mib[2] == KERN_PROC_ALL || mib[2] == KERN_PROC_UID || mib[2] == KERN_PROC_RUID || mib[2] == KERN_PROC_PGRP ||
        mib[2] == KERN_PROC_SESSION || mib[2] == KERN_PROC_TTY) {
        int self[4] = {CTL_KERN, KERN_PROC, KERN_PROC_PID, getpid()};
        return sysctl(self, 4, old, oldlen, NULL, 0);
    }
    return sysctl(mib, len, old, oldlen, NULL, 0);
}

INTERPOSE(my_proc_listpids, proc_listpids)
INTERPOSE(my_proc_listallpids, proc_listallpids)
INTERPOSE(my_proc_pidinfo, proc_pidinfo)
INTERPOSE(my_proc_pidpath, proc_pidpath)
INTERPOSE(my_proc_name, proc_name)

// 运行中的软件和窗口：来自启动服务和窗口服务器，沙盒挡不了（实测结界里能列出全部 113 个软件和各窗口的所属软件）。
// 只留它自己：同一进程、它开的子进程，或同一个软件 ID（多开、辅助程序）
static CFStringRef own_id(void) {
    static CFStringRef id;
    if (!id) {
        CFBundleRef b = CFBundleGetMainBundle();
        CFStringRef s = b ? CFBundleGetIdentifier(b) : NULL;
        id = s ? CFRetain(s) : CFSTR("");
    }
    return id;
}

static int own_app(id app) {
    pid_t pid = ((pid_t (*)(id, SEL))objc_msgSend)(app, sel_registerName("processIdentifier"));
    if (family(pid)) return 1;
    CFStringRef b = (CFStringRef)((id (*)(id, SEL))objc_msgSend)(app, sel_registerName("bundleIdentifier"));
    return b && CFStringGetLength(own_id()) && CFEqual(b, own_id());
}

static id autoreleased(CFTypeRef v) { return ((id (*)(id, SEL))objc_msgSend)((id)v, sel_registerName("autorelease")); }

static id only_own(id list) {
    CFMutableArrayRef out = CFArrayCreateMutable(NULL, 0, &kCFTypeArrayCallBacks);
    for (CFIndex i = 0, n = list ? CFArrayGetCount((CFArrayRef)list) : 0; i < n; i++) {
        id a = (id)CFArrayGetValueAtIndex((CFArrayRef)list, i);
        if (own_app(a)) CFArrayAppendValue(out, a);
    }
    return autoreleased(out);
}

static IMP orig_running, orig_with_id, orig_with_pid, orig_front, orig_menubar;
static id g_running(id self, SEL s) { return only_own(((id (*)(id, SEL))orig_running)(self, s)); }
static id g_with_id(id self, SEL s, id bid) { return only_own(((id (*)(id, SEL, id))orig_with_id)(self, s, bid)); }
static id g_with_pid(id self, SEL s, pid_t pid) {
    id a = ((id (*)(id, SEL, pid_t))orig_with_pid)(self, s, pid);
    return a && own_app(a) ? a : nil;
}
// 前台软件说明你此刻在用什么，不是它自己就答没有
static id g_front(id self, SEL s) {
    id a = ((id (*)(id, SEL))orig_front)(self, s);
    return a && own_app(a) ? a : nil;
}
static id g_menubar(id self, SEL s) {
    id a = ((id (*)(id, SEL))orig_menubar)(self, s);
    return a && own_app(a) ? a : nil;
}

static void hook_class(const char *cls, const char *sel, IMP mine, IMP *orig) {
    Class c = objc_getClass(cls);
    Method m = c ? class_getClassMethod(c, sel_registerName(sel)) : NULL;
    if (m) *orig = method_setImplementation(m, mine);
}

static void hide_apps(void) {
    if (!objc_getClass("NSWorkspace")) return;
    hook("NSWorkspace", "runningApplications", (IMP)g_running, &orig_running);
    hook("NSWorkspace", "frontmostApplication", (IMP)g_front, &orig_front);
    hook("NSWorkspace", "menuBarOwningApplication", (IMP)g_menubar, &orig_menubar);
    hook_class("NSRunningApplication", "runningApplicationsWithBundleIdentifier:", (IMP)g_with_id, &orig_with_id);
    hook_class("NSRunningApplication", "runningApplicationWithProcessIdentifier:", (IMP)g_with_pid, &orig_with_pid);
}

static int own_window(CFDictionaryRef w) {
    CFNumberRef n = CFDictionaryGetValue(w, kCGWindowOwnerPID);
    pid_t pid = 0;
    return n && CFNumberGetValue(n, kCFNumberIntType, &pid) && family(pid);
}

static CFArrayRef my_CGWindowListCopyWindowInfo(CGWindowListOption o, CGWindowID rel) {
    CFArrayRef all = CGWindowListCopyWindowInfo(o, rel);
    if (!hide_procs || !all) return all;
    CFMutableArrayRef out = CFArrayCreateMutable(NULL, 0, &kCFTypeArrayCallBacks);
    for (CFIndex i = 0, n = CFArrayGetCount(all); i < n; i++) {
        CFDictionaryRef w = CFArrayGetValueAtIndex(all, i);
        if (own_window(w)) CFArrayAppendValue(out, w);
    }
    CFRelease(all);
    return out;
}

// 只给编号的那一版：按编号再查一次所属进程
static CFArrayRef my_CGWindowListCreate(CGWindowListOption o, CGWindowID rel) {
    CFArrayRef ids = CGWindowListCreate(o, rel);
    if (!hide_procs || !ids) return ids;
    CFArrayRef info = CGWindowListCreateDescriptionFromArray(ids);
    CFMutableArrayRef out = CFArrayCreateMutable(NULL, 0, NULL);  // 元素是窗口编号，不是 CF 对象
    for (CFIndex i = 0, n = info ? CFArrayGetCount(info) : 0; i < n; i++) {
        CFDictionaryRef w = CFArrayGetValueAtIndex(info, i);
        CFNumberRef num = CFDictionaryGetValue(w, kCGWindowNumber);
        uint32_t wid;
        if (own_window(w) && num && CFNumberGetValue(num, kCFNumberSInt32Type, &wid)) CFArrayAppendValue(out, (const void *)(uintptr_t)wid);
    }
    if (info) CFRelease(info);
    CFRelease(ids);
    return out;
}

static CFArrayRef my_CGWindowListCreateDescriptionFromArray(CFArrayRef ids) {
    CFArrayRef all = CGWindowListCreateDescriptionFromArray(ids);
    if (!hide_procs || !all) return all;
    CFMutableArrayRef out = CFArrayCreateMutable(NULL, 0, &kCFTypeArrayCallBacks);
    for (CFIndex i = 0, n = CFArrayGetCount(all); i < n; i++) {
        CFDictionaryRef w = CFArrayGetValueAtIndex(all, i);
        if (own_window(w)) CFArrayAppendValue(out, w);
    }
    CFRelease(all);
    return out;
}

INTERPOSE(my_CGWindowListCopyWindowInfo, CGWindowListCopyWindowInfo)
INTERPOSE(my_CGWindowListCreate, CGWindowListCreate)
INTERPOSE(my_CGWindowListCreateDescriptionFromArray, CGWindowListCreateDescriptionFromArray)

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

// 其余能认出这台 Mac 的值（磁盘、电池、蓝牙、芯片、触控板等的序列号和 UUID）：按种子和原值换一个同样格式的，
// 同一个原值在这个软件里永远换成同一个，各软件之间不同
static const char *morphed[] = {"UUID", "VolGroupUUID", "SerialNumber", "Serial", "ECID", "ecid", "unique-chip-id",
                                "BD_ADDR", "local-mac-address", "mac-address", "USB Serial Number", "kUSBSerialNumberString", NULL};
// 里面夹着序列号的整块数据，直接当没有
static const char *dropped[] = {"BatteryData", "EDID", "IODisplayEDID", "IODisplayEDIDOriginal", "DisplayAttributes", NULL};

static int listed(CFStringRef key, const char **list) {
    for (int i = 0; list[i]; i++) if (is(key, list[i])) return 1;
    return 0;
}

static uint64_t mix(uint64_t h, const void *p, size_t n) {
    for (size_t i = 0; i < n; i++) h = (h ^ ((const unsigned char *)p)[i]) * 1099511628211ull;
    return h;
}

static uint64_t seeded(const void *p, size_t n) { return mix(mix(14695981039346656037ull, seed, strlen(seed)), p, n); }

// 打散：FNV 的低位只取决于输入的低位，逐位取值前要先打散
static uint64_t scramble(uint64_t x) {
    x += 0x9e3779b97f4a7c15ull;
    x = (x ^ (x >> 30)) * 0xbf58476d1ce4e5b9ull;
    x = (x ^ (x >> 27)) * 0x94d049bb133111ebull;
    return x ^ (x >> 31);
}

// 字符串逐位换：数字换数字，字母换字母，像十六进制的只用十六进制字符，大小写跟原值走，分隔符不动
static void morph_chars(char *s) {
    int hex = 1, lower = 0;
    for (char *c = s; *c; c++) {
        hex &= isxdigit((unsigned char)*c) || *c == '-' || *c == ':';
        lower |= islower((unsigned char)*c);
    }
    uint64_t h = seeded(s, strlen(s));
    for (size_t i = 0; s[i]; i++) {
        uint64_t r = scramble(h + i) >> 8;
        unsigned char c = s[i];
        if (hex && isxdigit(c)) s[i] = (lower ? "0123456789abcdef" : "0123456789ABCDEF")[r % 16];
        else if (isdigit(c)) s[i] = '0' + r % 10;
        else if (isupper(c)) s[i] = 'A' + r % 26;
        else if (islower(c)) s[i] = 'a' + r % 26;
    }
}

static CFTypeRef morph(CFTypeRef v) {
    if (!v || !seed) return NULL;
    CFTypeID t = CFGetTypeID(v);
    if (t == CFStringGetTypeID()) {
        char b[256];
        if (!CFStringGetCString(v, b, sizeof b, kCFStringEncodingUTF8)) return NULL;
        morph_chars(b);
        return str(b);
    }
    if (t == CFDataGetTypeID()) {
        CFIndex n = CFDataGetLength(v);
        UInt8 *b = malloc(n ? n : 1);
        CFDataGetBytes(v, CFRangeMake(0, n), b);
        if (n == 6) fake_mac(b);  // 网卡、蓝牙地址：和 getifaddrs 换的一致
        else {
            uint64_t h = seeded(b, n);
            for (CFIndex i = 0; i < n; i++) if (b[i]) b[i] = scramble(h + i) >> 24;
        }
        CFDataRef d = CFDataCreate(NULL, b, n);
        free(b);
        return d;
    }
    if (t == CFNumberGetTypeID()) {
        int64_t x = 0;
        CFNumberGetValue(v, kCFNumberSInt64Type, &x);
        if (!x) return CFRetain(v);
        uint64_t m = 1;  // 位数不变：int64 最多 19 位，m 最大 1e19，放得进 uint64
        for (uint64_t y = x < 0 ? -(uint64_t)x : (uint64_t)x; y; y /= 10) m *= 10;
        uint64_t low = m / 10, top = m > (uint64_t)INT64_MAX ? (uint64_t)INT64_MAX : m;
        int64_t r = (int64_t)(low + scramble(seeded(&x, sizeof x)) % (top - low));
        return CFNumberCreate(NULL, kCFNumberSInt64Type, &r);
    }
    return NULL;
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
    if (listed(key, morphed)) return morph(orig);
    return NULL;
}

static int sensitive(CFStringRef key) {
    return is(key, "IOPlatformSerialNumber") || is(key, "IOPlatformUUID") || is(key, "serial-number") ||
           is(key, "mlb-serial-number") || is(key, "IOMACAddress") || listed(key, morphed) || listed(key, dropped);
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

// 老接口按字节取属性：敏感的一律当没有（照格式换要知道类型，这个接口不给）
static kern_return_t my_IORegistryEntryGetProperty(io_registry_entry_t e, const io_name_t key, io_struct_inband_t buf, uint32_t *size) {
    CFStringRef k = str(key);
    int hide = seed && sensitive(k);
    CFRelease(k);
    return hide ? kIOReturnNotFound : IORegistryEntryGetProperty(e, key, buf, size);
}

// 磁盘服务给的分区、卷宗 UUID：和设备树里换的是同一套
static void morph_uuid(CFMutableDictionaryRef d, CFStringRef key) {
    CFUUIDRef u = CFDictionaryGetValue(d, key);
    if (!u || CFGetTypeID(u) != CFUUIDGetTypeID()) return;
    CFStringRef s = CFUUIDCreateString(NULL, u);
    CFStringRef m = morph(s);
    CFUUIDRef n = m ? CFUUIDCreateFromString(NULL, m) : NULL;
    if (n) { CFDictionarySetValue(d, key, n); CFRelease(n); }
    else CFDictionaryRemoveValue(d, key);
    CFRelease(s);
    if (m) CFRelease(m);
}

static CFDictionaryRef my_DADiskCopyDescription(DADiskRef disk) {
    CFDictionaryRef d = DADiskCopyDescription(disk);
    if (!d || !seed) return d;
    CFMutableDictionaryRef m = CFDictionaryCreateMutableCopy(NULL, 0, d);
    CFRelease(d);
    morph_uuid(m, kDADiskDescriptionVolumeUUIDKey);
    morph_uuid(m, kDADiskDescriptionMediaUUIDKey);
    CFDictionaryRemoveValue(m, kDADiskDescriptionDeviceGUIDKey);
    CFStringRef sn = CFStringCreateWithCString(NULL, "DADeviceSerialNumber", kCFStringEncodingUTF8);  // 外接盘有
    CFDictionaryRemoveValue(m, sn);
    CFRelease(sn);
    return m;
}

static uint32_t my_CGDisplaySerialNumber(CGDirectDisplayID d) {
    uint32_t v = CGDisplaySerialNumber(d);
    return v && seed ? (uint32_t)scramble(seeded(&v, sizeof v)) : v;
}

// 显示器 UUID 由厂商、型号、序列号算出，同样能认出这块屏
static CFUUIDRef my_CGDisplayCreateUUIDFromDisplayID(uint32_t d) {
    CFUUIDRef u = CGDisplayCreateUUIDFromDisplayID(d);
    if (!u || !seed) return u;
    CFStringRef s = CFUUIDCreateString(NULL, u);
    CFStringRef m = morph(s);
    CFRelease(u);
    CFRelease(s);
    u = m ? CFUUIDCreateFromString(NULL, m) : NULL;
    if (m) CFRelease(m);
    return u;
}

// 开机时间往前挪 0～6 小时、本次开机编号换掉：每次开机都变，各软件挪的量不同，对不上
static void fake_boottime(struct timeval *tv) {
    time_t real = tv->tv_sec;
    tv->tv_sec = real - (time_t)(scramble(seeded(&real, sizeof real)) % 21600);
}

static void fake_bootsession(char *s) { morph_chars(s); }

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

// 路由表里带硬件地址的条目（ARP、IPv6 邻居）：有路由器和局域网里别的设备的网卡地址，等于说出了你在哪个网络。
// 删掉这些条目，其余照给；要大小的那一次也照删后的算，前后对得上
static void drop_neighbors(void *buf, size_t *len) {
    char *p = buf, *end = p + *len, *out = p;
    while (p + sizeof(struct rt_msghdr) <= end) {
        struct rt_msghdr *m = (struct rt_msghdr *)p;
        size_t n = m->rtm_msglen;  // 先记下：往前挪会盖住这条的头
        if (!n || p + n > end) break;
        if (!(m->rtm_flags & RTF_LLINFO)) { memmove(out, p, n); out += n; }
        p += n;
    }
    *len = out - (char *)buf;
}

static int route_table(int *mib, u_int len) { return seed && len >= 6 && mib[0] == CTL_NET && mib[1] == PF_ROUTE; }

static int my_sysctl(int *mib, u_int len, void *old, size_t *oldlen, void *new, size_t newlen) {
    if (name && len == 2 && mib[0] == CTL_KERN && mib[1] == KERN_HOSTNAME && !new && oldlen) return fill_hostname(old, oldlen);
    if (proc_table(mib, len) && oldlen && !new) return fake_proc_table(mib, len, old, oldlen);
    if (route_table(mib, len) && oldlen && !new) {
        if (old) {
            int r = sysctl(mib, len, old, oldlen, NULL, 0);
            if (!r) drop_neighbors(old, oldlen);
            return r;
        }
        return sysctl(mib, len, NULL, oldlen, NULL, 0);  // 只问大小：给原大小，够装
    }
    int r = sysctl(mib, len, old, oldlen, new, newlen);
    if (!r && seed && len == 2 && mib[0] == CTL_KERN && mib[1] == KERN_BOOTTIME && old && oldlen && *oldlen >= sizeof(struct timeval))
        fake_boottime(old);
    return r;
}

static int my_sysctlbyname(const char *n, void *old, size_t *oldlen, void *new, size_t newlen) {
    if (name && n && !strcmp(n, "kern.hostname") && !new && oldlen) return fill_hostname(old, oldlen);
    int r = sysctlbyname(n, old, oldlen, new, newlen);
    if (!r && seed && n && old && oldlen) {
        if (!strcmp(n, "kern.boottime") && *oldlen >= sizeof(struct timeval)) fake_boottime(old);
        if (!strcmp(n, "kern.bootsessionuuid") && *oldlen) { ((char *)old)[*oldlen - 1] = 0; fake_bootsession(old); }
    }
    return r;
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
INTERPOSE(my_IORegistryEntryGetProperty, IORegistryEntryGetProperty)
INTERPOSE(my_DADiskCopyDescription, DADiskCopyDescription)
INTERPOSE(my_CGDisplaySerialNumber, CGDisplaySerialNumber)
INTERPOSE(my_CGDisplayCreateUUIDFromDisplayID, CGDisplayCreateUUIDFromDisplayID)
INTERPOSE(my_gethostuuid, gethostuuid)
INTERPOSE(my_getifaddrs, getifaddrs)
INTERPOSE(my_gethostname, gethostname)
INTERPOSE(my_uname, uname)
INTERPOSE(my_sysctl, sysctl)
INTERPOSE(my_sysctlbyname, sysctlbyname)
INTERPOSE(my_SCDynamicStoreCopyComputerName, SCDynamicStoreCopyComputerName)
INTERPOSE(my_SCDynamicStoreCopyLocalHostName, SCDynamicStoreCopyLocalHostName)
