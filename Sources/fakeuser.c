// 假用户：注入结界里运行的软件，它问“我是谁、家在哪”时答 user 和结界文件夹，不去问系统。
// 系统那边的查询照旧被挡，真实用户名只有结界知道。
// 软件开新进程时常把环境变量整个换掉，这里把注入和 HOME 补回去，子进程也拿到同样的答案。
#include <pwd.h>
#include <spawn.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>
#include <errno.h>

#define INTERPOSE(mine, theirs) \
    __attribute__((used)) static struct { const void *a, *b; } _i_##theirs \
    __attribute__((section("__DATA,__interpose"))) = { (const void *)(mine), (const void *)(theirs) };

static const char *carry[] = {"HOME", "DYLD_INSERT_LIBRARIES", "KEKKAI_HOME", "KEKKAI_LAT", "KEKKAI_LON", NULL};
static char *saved[sizeof carry / sizeof *carry];  // 启动时记下的 "名字=值"
static char *home;
static struct passwd fake;

__attribute__((constructor)) static void setup(void) {
    for (int i = 0; carry[i]; i++) {
        const char *v = getenv(carry[i]);
        if (!v) continue;
        size_t n = strlen(carry[i]) + strlen(v) + 2;
        saved[i] = malloc(n);
        strcpy(saved[i], carry[i]); strcat(saved[i], "="); strcat(saved[i], v);
    }
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
