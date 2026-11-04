// kekkai-relay：在结界外运行，替一个软件接住从结界外拖进来或粘贴进来的文件。
// 用法：kekkai-relay <套接字路径> <App 路径> <结界状态文件夹> <传输文件夹> [必定隔离的路径…]
// 软件里的注入库读拖放板（请求以 D 开头）或粘贴时读剪贴板（以 P 开头）时连上套接字；这里不信请求里的任何内容，自己读：
//   - 拖放：拖动开始时（按住鼠标、拖放板内容变化）指针下的窗口不属于结界中的软件，
//     请求时指针下的窗口和发请求的进程都属于这个软件；
//   - 粘贴：剪贴板谁都能写，无法确认来源，所以每次由这里弹出系统提示请用户确认，软件点不到这个提示。
// 必定隔离的路径（如 ~/.ssh）一律不复制。
// 处理就是把文件复制（APFS 上是克隆，几乎不占空间）进传输文件夹下的隐藏文件夹，去掉下载来源、标签等附加信息，
// 回答“原来的写法<TAB>副本的写法”，注入库据此把软件读到的路径换成副本。软件始终碰不到原文件，也看不到原路径。
#import <AppKit/AppKit.h>
#import <CoreGraphics/CoreGraphics.h>
#include <copyfile.h>
#include <libproc.h>
#include <sys/socket.h>
#include <sys/un.h>
#include <sys/xattr.h>

static NSString *appPath, *stateDir, *dropDir, *appName;
static NSArray<NSString *> *never;  // 必定隔离的路径（已解析符号链接）
static NSInteger pasteCount = -1;  // 用户已答复过的剪贴板序号，同一次粘贴软件会读好几遍，不重复询问
static NSString *pasteAnswer;      // 那次的回答，拒绝时为空串
static NSInteger okCount = -1;  // 从结界外开始的那次拖动的拖放板序号

static NSString *pathOf(pid_t pid) {
    char b[PROC_PIDPATHINFO_MAXSIZE];
    return proc_pidpath(pid, b, sizeof b) > 0 ? @(b) : nil;
}

// 指针下最上层的窗口属于哪个进程，跳过拖动的图像和指针，以及系统组件浮在普通窗口上面的透明层
// （实测拖动期间通知中心盖着整个屏幕）；桌面上的图标也算（属于访达）
static pid_t ownerAtPointer(void) {
    CGEventRef e = CGEventCreate(NULL);
    CGPoint p = CGEventGetLocation(e);
    CFRelease(e);
    int drag = CGWindowLevelForKey(kCGDraggingWindowLevelKey), cursor = CGWindowLevelForKey(kCGCursorWindowLevelKey);
    NSArray *list = CFBridgingRelease(CGWindowListCopyWindowInfo(kCGWindowListOptionOnScreenOnly, kCGNullWindowID));
    for (NSDictionary *w in list) {
        int layer = [w[(id)kCGWindowLayer] intValue];
        if (layer == drag || layer == cursor || [w[(id)kCGWindowAlpha] doubleValue] == 0) continue;
        pid_t pid = [w[(id)kCGWindowOwnerPID] intValue];
        if (layer > 0 && [pathOf(pid) hasPrefix:@"/System/"]) continue;
        CGRect r;
        if (CGRectMakeWithDictionaryRepresentation((CFDictionaryRef)w[(id)kCGWindowBounds], &r) && CGRectContainsPoint(r, p))
            return pid;
    }
    return 0;
}

// 软件本身，或它拉起的、在它结界文件夹里的程序（如 QQ 7.0.3 的 versions/<版本>/QQUpdate.app）
static NSString *spacePath;
static BOOL inApp(pid_t pid) {
    NSString *p = pathOf(pid);
    return p && ([p hasPrefix:[appPath stringByAppendingString:@"/"]] || (spacePath && [p hasPrefix:spacePath]));
}

// 结界中各软件的主程序（run 时记在 <id>.binary）
static BOOL inKekkai(pid_t pid) {
    NSString *p = pathOf(pid);
    if (!p || inApp(pid)) return p != nil;
    for (NSString *f in [NSFileManager.defaultManager contentsOfDirectoryAtPath:stateDir error:nil]) {
        if (![f hasSuffix:@".binary"]) continue;
        NSString *bin = [NSString stringWithContentsOfFile:[stateDir stringByAppendingPathComponent:f] encoding:NSUTF8StringEncoding error:nil];
        NSString *bundle = [bin componentsSeparatedByString:@"/Contents/MacOS/"].firstObject;
        if (bundle.length && [p hasPrefix:[bundle stringByAppendingString:@"/"]]) return YES;
    }
    return NO;
}

static BOOL appRunning(void) {
    pid_t pids[4096];
    int n = proc_listallpids(pids, sizeof pids);
    for (int i = 0; i < n; i++) if (inApp(pids[i])) return YES;
    return NO;
}

// 去掉下载来源、标签等扩展属性，只留隔离标记（门禁要用）
static void strip(NSString *path) {
    NSMutableArray *all = [NSMutableArray arrayWithObject:path];
    for (NSString *sub in [NSFileManager.defaultManager enumeratorAtPath:path]) [all addObject:[path stringByAppendingPathComponent:sub]];
    for (NSString *p in all) {
        const char *f = p.fileSystemRepresentation;
        char names[16384];
        ssize_t n = listxattr(f, names, sizeof names, XATTR_NOFOLLOW);
        for (char *x = names; n > 0 && x < names + n; x += strlen(x) + 1)
            if (strcmp(x, "com.apple.quarantine")) removexattr(f, x, XATTR_NOFOLLOW);
    }
}

// 一周前的副本删掉；软件发送或保存时通常已另存一份
static void prune(void) {
    NSFileManager *fm = NSFileManager.defaultManager;
    for (NSString *d in [fm contentsOfDirectoryAtPath:dropDir error:nil]) {
        NSString *p = [dropDir stringByAppendingPathComponent:d];
        NSDate *m = [fm attributesOfItemAtPath:p error:nil].fileModificationDate;
        if (m && -m.timeIntervalSinceNow > 7 * 86400) [fm removeItemAtPath:p error:nil];
    }
}

static BOOL isNever(NSString *path) {
    NSString *real = path.stringByResolvingSymlinksInPath;
    for (NSString *n in never)
        if ([real isEqualToString:n] || [real hasPrefix:[n stringByAppendingString:@"/"]]) return YES;
    return NO;
}

// 剪贴板或拖放板上的文件：每项原来的网址写法和对应路径；读不出、名字里有分隔符或在必定隔离的路径里的跳过
static NSArray<NSArray<NSString *> *> *filesOn(NSPasteboard *pb) {
    NSMutableArray *out = [NSMutableArray array];
    for (NSPasteboardItem *item in pb.pasteboardItems) {
        NSString *raw = [item stringForType:NSPasteboardTypeFileURL];  // 访达给的常是 file:///.file/id=… 这种引用写法
        NSString *src = [NSURL URLWithString:raw].filePathURL.path;
        if (!src || [raw rangeOfCharacterFromSet:NSCharacterSet.newlineCharacterSet].length || [src containsString:@"\t"] ||
            [src containsString:@"\n"] || isNever(src)) continue;
        [out addObject:@[raw, src]];
    }
    return out;
}

// 复制进传输文件夹，返回给注入库的对照表
static NSString *relay(NSArray<NSArray<NSString *> *> *files, NSInteger count, NSString *kind) {
    NSDateFormatter *f = [NSDateFormatter new];
    f.dateFormat = @"yyyyMMdd-HHmmss";
    NSString *dir = [dropDir stringByAppendingPathComponent:[NSString stringWithFormat:@"%@-%@%ld", [f stringFromDate:NSDate.date], kind, (long)count]];
    NSMutableString *out = [NSMutableString string];
    int i = 0;
    for (NSArray<NSString *> *file in files) {
        NSString *raw = file[0], *src = file[1];
        // 每个文件一层编号文件夹，同名文件互不覆盖，文件名保持原样
        NSString *sub = [dir stringByAppendingPathComponent:[NSString stringWithFormat:@"%d", ++i]];
        NSString *dst = [sub stringByAppendingPathComponent:src.lastPathComponent];
        [NSFileManager.defaultManager createDirectoryAtPath:sub withIntermediateDirectories:YES attributes:nil error:nil];
        if (copyfile(src.fileSystemRepresentation, dst.fileSystemRepresentation, NULL, COPYFILE_ALL | COPYFILE_RECURSIVE | COPYFILE_CLONE)) continue;
        strip(dst);
        BOOL isDir = NO;
        [NSFileManager.defaultManager fileExistsAtPath:dst isDirectory:&isDir];
        NSString *to = [NSURL fileURLWithPath:dst isDirectory:isDir].absoluteString;
        // 网址写法在前：路径是它的一部分，先换整串
        [out appendFormat:@"%@\t%@\n", raw, to];
        [out appendFormat:@"%@\t%@\n", [NSURL fileURLWithPath:src isDirectory:isDir].absoluteString, to];
        [out appendFormat:@"%@\t%@\n", src, dst];
    }
    return out;
}

static NSString *t(NSString *zh, NSString *en) {
    return [NSLocale.preferredLanguages.firstObject hasPrefix:@"zh"] ? zh : en;
}

// 系统提示由 UserNotificationCenter 显示，不在软件的进程里，软件无法替用户点按
static BOOL confirmPaste(NSArray<NSArray<NSString *> *> *files) {
    NSMutableArray *names = [NSMutableArray array];
    for (NSArray<NSString *> *file in files) [names addObject:file[1].lastPathComponent];
    NSString *list = [names componentsJoinedByString:@"\n"];
    NSString *head = files.count == 1 ? [NSString stringWithFormat:t(@"将“%@”粘贴到“%@”？", @"Paste “%@” into “%@”?"), names[0], appName]
                                      : [NSString stringWithFormat:t(@"将 %lu 个文件粘贴到“%@”？", @"Paste %lu files into “%@”?"), (unsigned long)files.count, appName];
    NSString *body = [NSString stringWithFormat:t(@"结界将复制以下文件并交给该 App，原文件及其位置对 App 不可见。\n\n%@\n\n位于：%@",
                                                    @"Kekkai will give the app copies of these files; the originals and their location stay hidden.\n\n%@\n\nFrom: %@"),
                      list, [files[0][1] stringByDeletingLastPathComponent]];
    CFOptionFlags r = kCFUserNotificationAlternateResponse;
    CFUserNotificationDisplayAlert(120, kCFUserNotificationCautionAlertLevel, NULL, NULL, NULL, (__bridge CFStringRef)head, (__bridge CFStringRef)body,
                                   (__bridge CFStringRef)t(@"粘贴", @"Paste"), (__bridge CFStringRef)t(@"取消", @"Cancel"), NULL, &r);
    return (r & 3) == kCFUserNotificationDefaultResponse;
}

static void answer(int fd) {
    char kind = 0;
    if (read(fd, &kind, 1) != 1) return;
    pid_t peer = 0;
    socklen_t len = sizeof peer;
    getsockopt(fd, SOL_LOCAL, LOCAL_PEERPID, &peer, &len);
    if (!inApp(peer)) return;
    NSString *out = @"";
    if (kind == 'D') {
        NSPasteboard *pb = [NSPasteboard pasteboardWithName:NSPasteboardNameDrag];
        if (pb.changeCount != okCount || !inApp(ownerAtPointer())) return;
        out = relay(filesOn(pb), pb.changeCount, @"");
    } else if (kind == 'P') {
        NSPasteboard *pb = NSPasteboard.generalPasteboard;
        NSInteger c = pb.changeCount;
        if (c == pasteCount) out = pasteAnswer;
        else {
            NSArray *files = filesOn(pb);
            if (!files.count) return;  // 不是文件，或都在必定隔离的路径里：不问
            out = confirmPaste(files) && pb.changeCount == c ? relay(files, c, @"p") : @"";
            pasteCount = c;
            pasteAnswer = out;
        }
    }
    const char *s = out.UTF8String;
    for (size_t done = 0, n = strlen(s); done < n;) {
        ssize_t w = write(fd, s + done, n - done);
        if (w <= 0) break;
        done += w;
    }
}

int main(int argc, char **argv) {
    @autoreleasepool {
        if (argc < 5) return 2;
        appPath = @(argv[2]);
        const char *sp = getenv("KEKKAI_SPACE");
        if (sp && *sp) spacePath = [@(sp) stringByAppendingString:@"/"];
        appName = [NSFileManager.defaultManager displayNameAtPath:appPath].stringByDeletingPathExtension;
        NSMutableArray *n = [NSMutableArray array];
        for (int i = 5; i < argc; i++) [n addObject:@(argv[i]).stringByResolvingSymlinksInPath];
        never = n;
        stateDir = @(argv[3]);
        dropDir = [@(argv[4]) stringByAppendingPathComponent:@".kekkai-drop"];
        prune();
        int srv = socket(AF_UNIX, SOCK_STREAM, 0);
        struct sockaddr_un a = {.sun_family = AF_UNIX};
        if (strlen(argv[1]) >= sizeof a.sun_path) return 2;
        strcpy(a.sun_path, argv[1]);
        unlink(argv[1]);
        if (bind(srv, (struct sockaddr *)&a, sizeof a) || listen(srv, 4)) return 1;
        chmod(argv[1], 0600);
        NSPasteboard *pb = [NSPasteboard pasteboardWithName:NSPasteboardNameDrag];
        NSInteger seen = pb.changeCount;
        int idle = 0;
        for (;;) {
            @autoreleasepool {
                // 按住鼠标时看拖放板有没有换内容：换了就是一次新的拖动，记下它从哪里开始
                if (CGEventSourceButtonState(kCGEventSourceStateCombinedSessionState, kCGMouseButtonLeft)) {
                    NSInteger c = pb.changeCount;
                    if (c != seen) {
                        seen = c;
                        pid_t from = ownerAtPointer();
                        okCount = from && !inKekkai(from) ? c : -1;
                    }
                }
                fd_set r;
                FD_ZERO(&r);
                FD_SET(srv, &r);
                struct timeval tv = {0, 50000};
                if (select(srv + 1, &r, NULL, NULL, &tv) > 0) {
                    int fd = accept(srv, NULL, NULL);
                    if (fd >= 0) { answer(fd); close(fd); }
                }
                // 软件退出后跟着退出；刚启动时它可能还没起来
                if (++idle % 100 == 0 && idle > 600 && !appRunning()) break;
            }
        }
        unlink(argv[1]);
    }
    return 0;
}
