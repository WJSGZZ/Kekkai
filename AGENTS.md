# 开发须知

给接手开发的人和 Agent。用户看的说明在 [README.zh-CN.md](README.zh-CN.md)（英文 [README.md](README.md)），这里只写改代码前要知道的事。

## 结构

| 位置 | 作用 |
|---|---|
| `Sources/cli.swift` → `kekkai` | 核心，Swift 写的命令行，编译成单个程序，不依赖系统 Python。生成 SBPL 沙盒规则、用 `sandbox-exec` 启动软件、管理每个软件的结界文件夹、读系统日志得出拦截记录、添加时试运行。界面只是调用它。签名信息用 Security 框架读，进程表用 libproc，代理端口用 SystemConfiguration；`launchctl`、`log show`、`codesign`、`cp -c`、`security` 仍调系统工具。`kekkai profile <App>` 打印将使用的沙盒规则而不启动，改规则后可用它核对 |
| `Sources/Kekkai.swift` | SwiftUI 界面，单文件。通过 `CLI.path` 调命令行，读 `list --json` 和 `blocked --json`。另有菜单栏图标（`MenuBarExtra`，`statusGlyph()` 按图标同一套 8 格网格画单色模板图，有 App 在结界中运行时门里的灯亮），列出 `inside` 的 App 和置顶但未运行的 App（`Store.pinned`，存在结界自己的 UserDefaults `pinned`，不进 settings.json）；关窗口后不退出，只剩菜单栏时每 15 秒刷新一次。“在‘应用程序’中创建入口”生成的入口（`kekkai launcher` 写的小 App）图标由 `launcherIcon()` 画：原图标右下角叠结界图标 |
| `Sources/inject.c` → `libkekkai.dylib` | 用 DYLD interpose 注入：假用户（`KEKKAI_HOME`），假设备（序列号、硬件 UUID、网卡地址、电脑名、型号，按软件的种子生成），并在 `execve`/`posix_spawn` 时把环境变量补给子进程 |
| `Sources/fakeloc.m` → `libfakeloc.dylib` | 虚拟定位，替换 CoreLocation 回调 |
| `rules/<软件 id>.json` | 个别软件的额外放行，越少越好 |
| `scripts/build.sh` | 编译出自带全部组件的 `build/Kekkai.app`：命令行、规则、两个注入库放在 `Contents/Resources/support/`，`build-id` 是它们的哈希 |
| `install.sh` | 开发用：构建后装进 `/Applications`（非管理员装进 `~/Applications`），并让聚焦重新收录。钥匙串里有 Apple Development 证书就自动用它签（`KEKKAI_SIGN`），签名要求不含指纹，完全磁盘访问权限等授权重新构建后仍有效；没有证书就临时签名，每次构建都要重新授权 |
| `scripts/make-dmg.sh` | 打安装映像 `build/Kekkai-<版本>.dmg`，拖到“应用程序”即装 |
| `Assets/` | 图标、安装映像背景的生成脚本、安装映像窗口布局 `dmg.DS_Store` |

运行时的位置：

- App 启动时 `Support.install()` 比对 `build-id`，不同就把 support 里的东西复制到 `~/Library/Application Support/Kekkai/bin/`，界面调用的是那里的 `kekkai`。所以改了命令行或规则，要重新构建 App，光改仓库不生效。
- 设置存在 `~/Library/Application Support/Kekkai/settings.json`，以软件 id 为键；`_added` 是已添加软件的路径表。
- 每个软件的结界文件夹在 `/Users/Shared/Kekkai.noindex/<软件 id>`（`.noindex` 让聚焦不收录；旧路径 `/Users/Shared/Kekkai` 会被 `migrateSpaces()` 迁移并留下符号链接）。注入库复制到其中的 `.lib/`。

## 关键机制

- **两种模式**（`effectiveMode()`）：`space` 结界文件夹（默认，HOME 指到它的文件夹，第一次运行复制原数据）和 `real` 原地运行（规则或设置里写 `"mode": "real"`，用于腾讯会议官网版这类用书签记数据位置、搬走就失效的软件）。
- **能不能注入**由 `injectable()` 判断：带 hardened runtime 或库校验、又没有放开它的权限的软件不能注入，只靠沙盒挡；大多数国外软件属于这类。设了 `clone`（界面“以可注入副本运行”）就和虚拟定位一样走 `localCopy()`：APFS 克隆后不带 `--options runtime` 临时重签，副本可注入。实测 Obsidian（480 MB）副本连启动只多占约 7 MB（codesign 只改签名所在的块）；系统权限要重新授权。`list` 里 `injectable` 按是否用副本算，`canClone` 表示原版不能注入。
- **自带苹果沙盒的软件**（QQ、微信、App Store 版）放 APFS 克隆副本，去掉沙盒权限后临时签名；副本数据不能用原容器，原因见 README。
- **读原容器要完全磁盘访问权限**：`~/Library/Containers/<id>` 受系统策略保护，结界 App 调起的 `cp` 被拒（日志 `System Policy: cp deny file-read-data`），实测不弹授权框；`copyFailed()` 把 EPERM 换成去设置里开“完全磁盘访问权限”的提示，界面给按钮。临时签名的签名要求就是 cdhash，每次构建都变，授权会失效（开关仍显示打开），所以 `install.sh` 改用开发证书签。从终端运行命令行时用的是终端的权限，所以开发时测不出来。
- **添加就是试运行**：`kekkai add` = `run` + `tune`（等 20 秒）。失败会说明原因，并清掉这次试运行新建的文件夹和设置。
- **设备身份**：每个软件一套，存在设置里；`new-identity` 重置。`commonRules` 同时用 `iokit-property` 挡住真实硬件号，除非设了 `keep_identity`。
- **端口配额**：“本机端口”关闭时，`portBlock()` 给每个软件分一组 32 个端口（20000–39999 里，各软件不重叠，启动前发现被别的程序占了就换一组，存在设置的 `ports`），沙盒只许它在本机连这组和系统代理端口。能注入的软件开 TCP 端口时，`inject.c` 的 `bind` 把端口挪进这组，挪过的记在 `TMPDIR/.kekkai-ports`，`connect` 连原端口时照着换；同一原端口再开时照实返回“已占用”。不能注入的软件只有沙盒这层，自己开的端口也连不上，要用就打开“本机端口”。
- 已核实的系统事实：macOS 上 `gethostuuid` 不经沙盒检查（XNU 里 `#if !defined(XNU_TARGET_OS_OSX)`），所以要靠注入改；SBPL 的 `(deny iokit-get-properties (iokit-property ...))` 有效；`network-bind`／`network-outbound` 能按单个端口放行，但端口写不了 0，也写不了范围；只按 `localhost` 限制，连本机局域网地址不算 localhost。
- **更多设备信息**：`DEVICE_IDS`（磁盘、分区、电池、蓝牙、芯片、触控板、键盘、显示器的序列号和 UUID）能注入时沙盒放行、`inject.c` 的 `morph()` 按种子换成同格式的值（同一原值在一个软件里总换成同一个）；不能注入时沙盒按属性名挡。开机时间、`kern.bootsessionuuid`、磁盘服务、显示器序列号和 UUID（`CGDisplayCreateUUIDFromDisplayID`）也一样处理（显示器的两项走窗口服务，不能注入时挡不住）。软件调起的系统程序（2026-11-03 实测修复）：注入库进不了系统程序，能注入时软件调起的 `ioreg`、`diskutil`、`ifconfig`、`scutil`、`hostname` 原本读得到真实的磁盘与外设序列号、分区 UUID、网卡地址、电脑名、主机名和开机信息（微信开发者工具实际会调 `ioreg`、`networksetup`）。现在 `commonRules` 用 `(process-attribute is-platform-binary)` 只对系统程序挡这些：`DEVICE_IDS`、`kern.bootsessionuuid`／`kern.boottime`／`kern.hostname`、网卡列表 sysctl（`net.routetable.0.*.3|6`）、磁盘服务和 configd、`/Library/Preferences/SystemConfiguration/preferences.plist`；软件自己的程序不是系统程序，照旧由注入库换值。实测系统程序读不到上述任何一项，`scutil --get ComputerName` 得“MacBook Air”；curl、ping、nslookup、`uname -m`、`sysctl hw.*`、`sw_vers` 正常，`hostname`、`uname -a` 报错。同时补进 `DEVICE_IDS` 与注入库名单：SSD 的 `Serial Number`、`NamespaceUUID`、雷雳 `Domain UUID`、`BootSessionUUID`、摄像头和红外投射器序列号、`AccessoryCertificateSerialNumber`，以及夹着序列号的整块字典 `Device Characteristics`、`Controller Characteristics`、`AdapterDetails`、`AppleRawAdapterDetails`（这几项原先对所有软件都没挡）。仍未处理：`ioreg` 里网络服务字典的 `uuid` 和 `CGSSessionUniqueSessionUUID`（键名随服务变，不能按名挡）。
- **网络位置**：路由表里带 `RTF_LLINFO` 的条目（ARP、IPv6 邻居）由注入库删掉；`arp`、`ndp`、`netstat`、`ipconfig`、`system_profiler` 在 `NO_EXEC` 里。Wi-Fi 名称和 BSSID 系统本身对没有定位权限的程序打码（实测 `<redacted>`）。不能注入的软件由沙盒挡 sysctl 名 `net.routetable.<协议>.<0|30>.<1|2|7>.*`（全部协议和 IPv6 的整表导出）；不能整组挡 `net.route`，网卡列表（操作码 3、6）同时供 `getifaddrs` 用，挡了就断网。IPv4 的 ARP 条目系统本就不给普通程序（实测 `arp -an` 有条目，普通进程用 sysctl 读到 0 条）。
- **钥匙串**：始终用结界文件夹里的独立钥匙串（`privateKeychain()`），不提供改用用户钥匙串的选项，用户钥匙串在结界文件夹之外；原地运行的软件整个挡住钥匙串服务。实测沙盒内对 `login.keychain-db` 列证书得 0 条（沙盒外 5 条）。
- **运行中的软件与窗口**：“其他进程信息”关闭且能注入时，`hide_apps()` 钩 `NSWorkspace runningApplications`／`frontmostApplication`／`menuBarOwningApplication` 和 `NSRunningApplication` 的两个类方法，`CGWindowListCopyWindowInfo` 等三个窗口列表函数按所属进程过滤，只留它自己、子进程和同一软件 ID。实测由 114 个软件、125 个窗口降到 1 个和 0 个。不能注入时沙盒挡不了（LaunchServices、窗口服务器是图形软件必需的）。
- **聚焦搜索**：沙盒挡 `com.apple.metadata.mds`；不挡时，禁止读 `/Applications` 也能搜出全部软件（实测 322 个）。规则可写 `allow_spotlight` 放开。
- **添加时先试副本**：不能注入、没有苹果沙盒、设置里没选过 `clone` 的软件，`add()` 先设 `clone` 试运行，起不来就删掉副本、改回原版再试。实测 Obsidian 以副本加入。
- **登录项与特权助手**：沙盒挡 `com.apple.xpc.smd`、`com.apple.backgroundtaskmanagement*`、`com.apple.authd`、`com.apple.security.authtrampoline`。不挡时沙盒内 `SMAppService` 注册登录项成功（实测），下次登录就在结界外运行；`SMJobSubmit` 本来就被 launchd 拒绝（实测错误码 4）。
- **结界外的组件**：`outsideParts()` 列出不是结界任务后代的同一软件进程（扩展、用副本时原版的进程、不在沙盒里的进程），以及 LaunchAgents／LaunchDaemons／PrivilegedHelperTools 里同厂商前缀的项目；界面在设置顶部提示。实测列出百度网盘的 `baiduNetdiskSync`。
- **原地运行的缺口**：`real` 模式家目录是真的，不设 `KEKKAI_HOME`，路径里的账户名可见。
- **带隔离标记的软件不用副本**：`quarantined()`；临时签名副本被门禁拒绝（实测 `ASP: Security policy would not allow process`，退出原因 OS_REASON_EXEC），不绕过门禁，所以 `add()` 不先试副本、`run()` 忽略 `clone`、界面不显示副本开关。
- **腾讯会议官网版实测（2026-11-03，3.47.2）**：清空旧数据后以结界文件夹模式能启动，不写真实资料库；但它通过 LaunchServices 查到 App Store 版（沙盒内查询软件 ID 能得到 VooV，未读其文件），每次启动都要求授权读取 App Store 版数据。不能注入、带隔离标记，结界无法隐藏这次查询。用户选择只留 App Store 版，官网版已移除；是否保持登录未测，规则仍为 `real`。系统的打开面板会把 `NSOSPLastRootDirectory` 写进真实的偏好设置。
- **传入文件**：拖放和粘贴给出的是原文件路径，结界外的文件对软件不存在，所以发不出去。不能直接拖入时（不能注入，或下一条的条件不满足），界面把文件复制进 `list` 给出的 `inbox`（结界文件夹里的 `Downloads`；原地运行的软件用 `Kekkai.noindex/.transfer/<id>`，规则只放行它自己这一个），再在访达中选中，由用户从那里拖入或在打开面板里选。复制在界面进程里做（拖放带着用户的授权，交给命令行的子进程可能触发文件夹权限提示），`stripOrigin()` 去掉除隔离标记以外的扩展属性（下载网址、标签等）；`com.apple.provenance` 受系统保护删不掉。剪贴板设为“禁止”时，从访达拖入也不行（拖放走同一个剪贴板服务），只能用打开面板。
- **直接拖入（中转）**：能注入、剪贴板不是“禁止”时，`run()` 用 launchd 起一个结界外的 `kekkai-relay`（`Sources/relay.m`，任务名 `<label>.relay`，软件退出后自己退出），套接字放在软件的 `TMPDIR`，路径经 `KEKKAI_RELAY` 传给注入库。注入库在软件读拖放板时连上去；中转程序不信请求内容，自己读拖放板，只在两项都成立时处理：拖动开始时（按住鼠标、拖放板序号变化）指针下的窗口不属于结界中的软件，请求时指针下的窗口和对端进程（`LOCAL_PEERPID`）都属于这个软件。处理是把每个文件 `copyfile`（克隆，跨磁盘就是真复制，大文件会慢）进 `inbox/.kekkai-drop/<时间>-<序号>/<n>/原名`，去掉隔离标记以外的扩展属性，答回“原写法<TAB>副本写法”（访达给的 `file:///.file/id=…` 引用网址、路径网址、路径各一行）。注入库把 NSPasteboard 和 NSPasteboardItem 读出的文字、网址、属性列表里的原写法换成副本；读不成文字的数据（二进制属性列表先解开再换）不给，因为可能带着原路径。实测（测试程序）：读到副本内容，八种类型里都没有账户名，下载来源属性已去掉；`com.apple.provenance` 删不掉，不含路径。副本一周后由中转程序删除。之前的做法是给原文件签只读令牌，弃用原因：软件看得到原路径（含账户名），和假用户矛盾。坑：`stringForType:` 内部会调 `dataForType:`，判断“是否中转过”时要防重入，否则栈溢出（实测）；找指针下的窗口要跳过 `/System/` 里程序在普通层之上的窗口，拖动期间通知中心在第 23 层盖着全屏（实测）。粘贴（请求以 `P` 开头，拖放为 `D`）：通用剪贴板谁都能写，来源无法确认，所以注入库只在 ⌘V／“粘贴”的窗口内请求，中转程序每次用 `CFUserNotificationDisplayAlert` 弹系统提示确认（由 UserNotificationCenter 显示，软件点不到），同一剪贴板序号只问一次、记住答复；确认期间不计入 1.5 秒读取窗口。必定隔离的路径（启动参数传入，解析符号链接后比对）拖放和粘贴都不复制、不询问。实测（测试程序）：自己写 `~/.ssh/known_hosts` 再调“粘贴”，不弹窗、无副本、读不到；伪造普通文件弹窗后取消，读不到；访达复制后确认，读到副本，各类型无账户名（图标、UTF-16 文字等二进制类型不给）。
- **程序坞角标**：能注入的软件带 `KEKKAI_BADGE`（指向 `.lib/badge.png`，构建时由 `Assets/icon-1024.png` 缩成 512 点），注入库钩 `NSApplication finishLaunching`，完成后把图标换成右下角叠结界图标的一份，只改普通 App（`activationPolicy` 为 0）。CF 本地通知中心收不到 `NSApplicationDidFinishLaunchingNotification`（实测），所以改钩方法。位置与入口图标 `launcherIcon()` 相同。软件之后自己改图标会盖掉角标。坑：用 `/usr/bin/timeout` 等系统程序包一层测试会丢掉 DYLD 变量；测试程序放在会话暂存区（`/private/tmp`）会被沙盒拒读而段错误，要放进“应用程序”。
- **剪贴板三档**：`clipboardMode()`：off 挡剪贴板服务；paste（能注入时默认）由注入库钩 NSPasteboard 的读内容方法，⌘V 或“粘贴”菜单后 1.5 秒内放行，`types` 照答以免菜单变灰，拖放板不管；on 全放。
- **局域网**：“局域网设备”（`allow_lan`）关闭且能注入时设 `KEKKAI_NOLAN`，注入库让 `connect`／`connectx`／`sendto`／`sendmsg` 发往私有、链路本地、组播和广播地址的返回 EHOSTUNREACH（端口 53 和系统代理地址除外），`DNSServiceBrowse`／`Resolve`／`Register` 返回 PolicyDenied，`nw_browser_start` 改为取消（Network 框架的浏览器不经 dns_sd 函数，实测）。SBPL 的网络过滤写不了网段，不能注入的软件只能靠 macOS 的“本地网络”权限，结界不改系统设置。
- **语言与时区**：`commonLanguage` 取系统首选语言的第一项，换成该语言最常见的地区（`COMMON_REGION`），注入库在启动时 `CFPreferencesSetAppValue` 写 `AppleLanguages`／`AppleLocale`，软件域里已有 `AppleLanguages` 的不动。只在设了 `__CFPREFERENCES_AVOID_DAEMON` 时传：实测该变量下偏好设置的写入在沙盒内不落盘；不设时同样的调用会经 cfprefsd 写进真实的 `~/Library/Preferences/<id>.plist`。时区：设置里没选时，`appZone()` 换成该地区里今后两年钟点完全相同的时区（`sameClock()`），设了 `keep_identity` 的不换。设置里 `tz` 为 `location` 时按虚拟位置查时区：`zoneAt()` 读 CoreLocation 自带的 `timezone.db`（SQLite，R 树外框加多边形），点在多边形内即取该时区，海上按经度取 `Etc/GMT±N`；实测乌鲁木齐、拉萨得 Asia/Shanghai，香港得 Asia/Hong_Kong。没设虚拟位置时按自动处理。
- **偏好设置的实际去向（实测，待真实软件核对）**：`__CFPREFERENCES_AVOID_DAEMON` 下 CoreFoundation 按用户数据库里的家目录找偏好文件，不看 `CFFIXED_USER_HOME`；沙盒内查用户数据库被挡，测试程序写的值不落盘，结界文件夹的 `Library/Preferences` 也没有新文件。真实软件是否每次启动都丢失自己的偏好设置尚未核对。
- **进程**：“其他进程信息”关闭时，沙盒另挡 `kern.proc.all` 等 sysctl（只挡 process-info 实测能被它绕过）；能注入的由注入库把别人答成 ESRCH、列表只给自己，不能注入的连 `kern.proc.pid` 也挡。
- 注入库要先写新文件再替换，原地覆盖已签名的库会让加载它的软件被系统以 `OS_REASON_CODESIGNING` 杀掉。
- 拦截记录按各 `Contents/MacOS` 里的文件名认进程，不读 `CFBundleExecutable`（微信开发者工具的 Helper 不写这一项）。

## 安装映像

`make-dmg.sh` 不驱动访达，直接复制 `Assets/dmg.DS_Store` 作窗口布局（640×428 窗口、112 点图标、结界在 (170,180)、应用程序在 (470,180)、背景 `.background/background.tiff`），坐标与 `Assets/make-dmg-background.swift` 一一对应。

要改布局：用 `hdiutil` 建一个可写映像（卷宗名必须仍是“结界”，背景引用按卷宗名和路径找），用 AppleScript 让访达排好，`update` 后几秒内就把卷宗上的 `.DS_Store` 拷出来（关窗口后访达可能用别的设置覆盖它），再把 `bwsp` 里的 `ShowTabView` 改成 false。访达设成“总是以标签页打开”的 Mac 上，映像会作为标签页打开，看不到这个布局，这是系统设置决定的。

## 约定

- 文案是工具软件口吻：准确、简短，不口语、不拟人，参照 macOS 系统设置和帮助的书面语。中文避免“挡掉、带不过来、对不上号、搬走、一律、要你”这类口头说法，用“屏蔽、无法导入、互不相同、移动后、均、需”；少用“你”，按钮和菜单名照界面原文引用。说明文字只写必要条件，按钮不放进说明文字里。中英文分别写，不逐句直译。
- 说明文字的排版：会变的数值（时间、路径、日志原文）不和说明句混在一段，单独一行，日期和钟点之间用不换行空格；居中的说明限宽（`AddSheet.note()` 为 340 点），两件事分两行；一个脚注只用一个 `Text`，叠两个没有段距，看着像句中断行；日志原文用等宽小字左对齐、可选中。改完用截图看实际换行，中文断行规则（含 `pushOut`）不防末行孤字，只能靠限宽和拆句。
- 单个软件的设置面板分四页（`Detail.Pane`：活动、权限、伪装、文件，记住上次所选），默认只看到拦截记录；页内的分组不再写与页名重复的标题，长说明放进悬停提示或使用说明。拦截记录的档次用圆点（红越权、橙留意、灰常规），以前运行的条目变淡，不用文字标签。时区显示 `zoneName()` 给的城市名或系统本地化名称，不显示 `America/New_York` 这类标识符。
- 使用说明仿“使用技巧”：`helpTopics` 按主题分组，每条 `Tip` 一个符号、一句标题、正文只讲一件事，卡片限宽 600 点。
- 界面用系统字体、系统控件和系统动效，不自定义字体、阴影、品牌色。品牌色（蓝 #2359FF、黄 #FFD900、墨 #151515）只用在图标和安装映像背景。
- 公开文件里不写真实用户名、本机路径和个人信息，用占位符。
- 不绕过 App Store 收据校验和 Gatekeeper。
- 结界自身不联网。唯一例外是虚拟位置选点里用户点了“在地图上选择”才加载的 Apple 地图（`LocationPicker` 的 `online`）；新功能能离线做就离线做，确实要联网的要用户主动触发并写明发给谁。
- 只在 `main` 上提交，`git add` 写具体路径；不改写已推送的历史。
- 磁盘不区分大小写：新文件名不能和已有文件只差大小写（`kekkai.swift` 就是 `Kekkai.swift`，曾因此覆盖界面源文件），命令行源文件叫 `Sources/cli.swift`。
- 临时文件放会话暂存区，测试留下的结界文件夹、设置项和状态文件测完就清。

## 测试方法

1. 构建并安装：`./install.sh`。
2. 一次只测一个软件，只用本机已装的。先完全退出它，再 `kekkai add /Applications/X.app` 或在界面里添加。
3. 看三处：能否正常启动和登录；`kekkai blocked X.app` 的拦截记录；`log show --predicate 'sender == "Sandbox"'` 里有没有漏掉的拒绝。
4. 结论写进 README 的实测表，写明 macOS 版本、哪种模式、有无注入。
5. 试运行失败要先分清是沙盒挡的（日志有 deny）、签名问题（软件自检或 EPERM 来自 System Policy），还是软件自己的问题，再决定改规则、加 `rules/` 还是写进“做不到的”。

## 现状

已验证（macOS 27.2）：

- 百度网盘、微信开发者工具、QQ、微信、腾讯会议两个版本的结果见 README 实测表。
- 端口配额：微信开发者工具在“本机端口”关闭时编译正常，它开的端口全部挪进配额，系统日志没有网络拒绝。
- 设备信息、邻居条目、剪贴板、进程的注入与沙盒规则用测试程序逐项验证；百度网盘、腾讯会议 VooV、微信、开发者工具带上新规则都能正常运行（这几个这次都以可注入方式运行，“不能注入”那条路只有测试程序验证过）。剪贴板在真实软件里按 ⌘V 的效果未实测。IPv6 邻居表规则用测试程序（getifaddrs、IPv4/IPv6 联网正常）和 Obsidian（不能注入）验证过。
- 局域网屏蔽与语言统一（2026-11-03）：测试程序验证直连、URLSession、dns_sd、NSNetServiceBrowser、NWBrowser 均被拦，公网连接正常；VooV、微信开发者工具带新规则正常运行（开发者工具编译正常，端口仍在配额内），VooV 进程环境里语言为 zh-Hans-CN、时区 Asia/Shanghai。QQ、微信、百度网盘未重新运行。
- 添加流程：不能运行的软件（如要求 App Store 收据的）会被拒绝并清理，能运行的正常加入。
- 假用户、假设备在注入后生效；App 能自行安装 support 文件；设置和关于窗口正常。
- 命令行改写为 Swift（2026-11-03）：8 个软件生成的沙盒规则与 Python 版逐字一致（只差一组软件 ID 的排列顺序，现按字母排）；`list`、`blocked --json`、`never list` 输出一致；用测试程序跑通添加（含试运行与自动调整）、失败时清理、虚拟位置与时区、入口、停止、移除、重置。`list` 约 0.1 秒（Python 版约 0.18 秒）。所有组件为通用二进制，最低 macOS 14。
- 安装映像里存的布局已读回核对（图标大小、背景、位置、无工具栏和标签栏）。

未验证：

- 主界面双击大图标启动的实际操作。
- App Store 版腾讯会议登录后能否保持登录。
- 安装映像在默认标签页设置的 Mac 上的实际外观（开发机设成总是标签页）。
- 在 Intel Mac 和 macOS 14、15 上的实际运行（通用二进制、最低 macOS 14 已按目标编译，地图接口有旧系统的替代写法，但只在本机 macOS 27.2 上跑过）。
- 未公证的临时签名包在别的 Mac 上的 Gatekeeper 提示流程。

已发布 v0.1（2026-11-03，标签 `v0.1` 指向 d68ee43，附件 `Kekkai-0.1.dmg`，临时签名、未公证）和 v0.1.1（同日，修复系统程序可读到真实设备信息，附件 `Kekkai-0.1.1.dmg`）。已发布的标签和附件不覆盖，修复发新版本。发新版时沿用这个标签与附件命名，README 快速开始里的文件名同步改。

下一步可以考虑：

- 有开发者账号后做正式签名和公证。
- `sandbox-exec` 已被苹果标为弃用，系统升级后要先回归测试。
