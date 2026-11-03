# 开发须知

给接手开发的人和 Agent。用户看的说明在 [README.zh-CN.md](README.zh-CN.md)（英文 [README.md](README.md)），这里只写改代码前要知道的事。

## 结构

| 位置 | 作用 |
|---|---|
| `kekkai` | 核心，一个 Python 脚本（`#!/usr/bin/python3 -I`，只用标准库）。生成 SBPL 沙盒规则、用 `sandbox-exec` 启动软件、管理每个软件的结界文件夹、读系统日志得出拦截记录、添加时试运行。界面只是调用它 |
| `Sources/Kekkai.swift` | SwiftUI 界面，单文件。通过 `CLI.path` 调命令行，读 `list --json` 和 `blocked --json` |
| `Sources/inject.c` → `libkekkai.dylib` | 用 DYLD interpose 注入：假用户（`KEKKAI_HOME`），假设备（序列号、硬件 UUID、网卡地址、电脑名、型号，按软件的种子生成），并在 `execve`/`posix_spawn` 时把环境变量补给子进程 |
| `Sources/fakeloc.m` → `libfakeloc.dylib` | 虚拟定位，替换 CoreLocation 回调 |
| `rules/<软件 id>.json` | 个别软件的额外放行，越少越好 |
| `scripts/build.sh` | 编译出自带全部组件的 `build/Kekkai.app`：命令行、规则、两个注入库放在 `Contents/Resources/support/`，`build-id` 是它们的哈希 |
| `install.sh` | 开发用：构建后装进 `/Applications`（非管理员装进 `~/Applications`），并让聚焦重新收录 |
| `scripts/make-dmg.sh` | 打安装映像 `build/Kekkai-<版本>.dmg`，拖到“应用程序”即装 |
| `Assets/` | 图标、安装映像背景的生成脚本、安装映像窗口布局 `dmg.DS_Store` |

运行时的位置：

- App 启动时 `Support.install()` 比对 `build-id`，不同就把 support 里的东西复制到 `~/Library/Application Support/Kekkai/bin/`，界面调用的是那里的 `kekkai`。所以改了命令行或规则，要重新构建 App，光改仓库不生效。
- 设置存在 `~/Library/Application Support/Kekkai/settings.json`，以软件 id 为键；`_added` 是已添加软件的路径表。
- 每个软件的结界文件夹在 `/Users/Shared/Kekkai.noindex/<软件 id>`（`.noindex` 让聚焦不收录；旧路径 `/Users/Shared/Kekkai` 会被 `migrate_spaces()` 迁移并留下符号链接）。注入库复制到其中的 `.lib/`。

## 关键机制

- **两种模式**（`effective_mode()`）：`space` 结界文件夹（默认，HOME 指到它的文件夹，第一次运行复制原数据）和 `real` 原地运行（规则或设置里写 `"mode": "real"`，用于腾讯会议官网版这类用书签记数据位置、搬走就失效的软件）。
- **能不能注入**由 `injectable()` 判断：带 hardened runtime 或库校验、又没有放开它的权限的软件不能注入，只靠沙盒挡；大多数国外软件属于这类。
- **自带苹果沙盒的软件**（QQ、微信、App Store 版）放 APFS 克隆副本，去掉沙盒权限后临时签名；副本数据不能用原容器，原因见 README。
- **添加就是试运行**：`kekkai add` = `run` + `tune`（等 20 秒）。失败会说明原因，并清掉这次试运行新建的文件夹和设置。
- **设备身份**：每个软件一套，存在设置里；`new-identity` 重置。`common_rules` 同时用 `iokit-property` 挡住真实硬件号，除非设了 `keep_identity`。
- **端口配额**：“本机端口”关闭时，`port_block()` 给每个软件分一组 32 个端口（20000–39999 里，各软件不重叠，启动前发现被别的程序占了就换一组，存在设置的 `ports`），沙盒只许它在本机连这组和系统代理端口。能注入的软件开 TCP 端口时，`inject.c` 的 `bind` 把端口挪进这组，挪过的记在 `TMPDIR/.kekkai-ports`，`connect` 连原端口时照着换；同一原端口再开时照实返回“已占用”。不能注入的软件只有沙盒这层，自己开的端口也连不上，要用就打开“本机端口”。
- 已核实的系统事实：macOS 上 `gethostuuid` 不经沙盒检查（XNU 里 `#if !defined(XNU_TARGET_OS_OSX)`），所以要靠注入改；SBPL 的 `(deny iokit-get-properties (iokit-property ...))` 有效；`network-bind`／`network-outbound` 能按单个端口放行，但端口写不了 0，也写不了范围；只按 `localhost` 限制，连本机局域网地址不算 localhost。
- **更多设备信息**：`DEVICE_IDS`（磁盘、分区、电池、蓝牙、芯片、触控板、键盘、显示器的序列号和 UUID）能注入时沙盒放行、`inject.c` 的 `morph()` 按种子换成同格式的值（同一原值在一个软件里总换成同一个）；不能注入时沙盒按属性名挡。开机时间、`kern.bootsessionuuid`、磁盘服务、显示器序列号也一样处理（显示器序列号走窗口服务，不能注入时挡不住）。
- **网络位置**：路由表里带 `RTF_LLINFO` 的条目（ARP、IPv6 邻居）由注入库删掉；`arp`、`ndp`、`netstat`、`ipconfig`、`system_profiler` 在 `NO_EXEC` 里。Wi-Fi 名称和 BSSID 系统本身对没有定位权限的程序打码（实测 `<redacted>`）。不能注入的软件仍能直接用 sysctl 读 ARP 表：`net.route` 同时管着 `getifaddrs`，不能整组挡。
- **剪贴板三档**：`clipboard_mode()`：off 挡剪贴板服务；paste（能注入时默认）由注入库钩 NSPasteboard 的读内容方法，⌘V 或“粘贴”菜单后 1.5 秒内放行，`types` 照答以免菜单变灰，拖放板不管；on 全放。
- **进程**：“其他进程信息”关闭时，沙盒另挡 `kern.proc.all` 等 sysctl（只挡 process-info 实测能被它绕过）；能注入的由注入库把别人答成 ESRCH、列表只给自己，不能注入的连 `kern.proc.pid` 也挡。
- 注入库要先写新文件再替换，原地覆盖已签名的库会让加载它的软件被系统以 `OS_REASON_CODESIGNING` 杀掉。
- 拦截记录按各 `Contents/MacOS` 里的文件名认进程，不读 `CFBundleExecutable`（微信开发者工具的 Helper 不写这一项）。

## 安装映像

`make-dmg.sh` 不驱动访达，直接复制 `Assets/dmg.DS_Store` 作窗口布局（640×428 窗口、112 点图标、结界在 (170,180)、应用程序在 (470,180)、背景 `.background/background.tiff`），坐标与 `Assets/make-dmg-background.swift` 一一对应。

要改布局：用 `hdiutil` 建一个可写映像（卷宗名必须仍是“结界”，背景引用按卷宗名和路径找），用 AppleScript 让访达排好，`update` 后几秒内就把卷宗上的 `.DS_Store` 拷出来（关窗口后访达可能用别的设置覆盖它），再把 `bwsp` 里的 `ShowTabView` 改成 false。访达设成“总是以标签页打开”的 Mac 上，映像会作为标签页打开，看不到这个布局，这是系统设置决定的。

## 约定

- 文案是工具软件口吻：准确、简短，不口语、不拟人。中英文分别写，不逐句直译。
- 界面用系统字体、系统控件和系统动效，不自定义字体、阴影、品牌色。品牌色（蓝 #2359FF、黄 #FFD900、墨 #151515）只用在图标和安装映像背景。
- 公开文件里不写真实用户名、本机路径和个人信息，用占位符。
- 不绕过 App Store 收据校验和 Gatekeeper。
- 只在 `main` 上提交，`git add` 写具体路径；不改写已推送的历史。
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
- 设备信息、邻居条目、剪贴板、进程的注入与沙盒规则用测试程序逐项验证；百度网盘、腾讯会议 VooV、微信、开发者工具带上新规则都能正常运行（这几个这次都以可注入方式运行，“不能注入”那条路只有测试程序验证过）。剪贴板在真实软件里按 ⌘V 的效果未实测。
- 添加流程：不能运行的软件（如要求 App Store 收据的）会被拒绝并清理，能运行的正常加入。
- 假用户、假设备在注入后生效；App 能自行安装 support 文件；设置和关于窗口正常。
- 安装映像里存的布局已读回核对（图标大小、背景、位置、无工具栏和标签栏）。

未验证：

- 主界面双击大图标启动的实际操作。
- App Store 版腾讯会议登录后能否保持登录。
- 安装映像在默认标签页设置的 Mac 上的实际外观（开发机设成总是标签页）。
- 在没装命令行工具的 Mac 上：`/usr/bin/python3` 会弹出安装命令行工具的提示，后台脚本在装好前不能运行。
- 未公证的临时签名包在别的 Mac 上的 Gatekeeper 提示流程。

下一步可以考虑：

- 去掉对系统 Python 的依赖（把命令行改写成 Swift，或随 App 带一个解释器），这样新 Mac 不用装命令行工具。
- 有开发者账号后做正式签名和公证。
- `sandbox-exec` 已被苹果标为弃用，系统升级后要先回归测试。
