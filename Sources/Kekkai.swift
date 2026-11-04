import SwiftUI
import UniformTypeIdentifiers
import Combine
import MapKit

let isChinese = Locale.preferredLanguages.first?.hasPrefix("zh") ?? false
func t(_ zh: String, _ en: String) -> String { isChinese ? zh : en }
let repoURL = URL(string: "https://github.com/WJSGZZ/Kekkai")!
func displayName(_ app: AppEntry) -> String { (FileManager.default.displayName(atPath: app.path) as NSString).deletingPathExtension }

// 中国大陆的地图用 GCJ-02（“火星坐标”），软件从系统拿到的定位是 GPS 用的 WGS-84，相差约几百米
enum Mars {
    static let a = 6378245.0, ee = 0.00669342162296594323
    static func offset(_ lat: Double, _ lon: Double) -> (Double, Double) {
        let x = lon - 105, y = lat - 35
        var dLat = -100 + 2 * x + 3 * y + 0.2 * y * y + 0.1 * x * y + 0.2 * sqrt(abs(x))
        dLat += (20 * sin(6 * x * .pi) + 20 * sin(2 * x * .pi)) * 2 / 3
        dLat += (20 * sin(y * .pi) + 40 * sin(y / 3 * .pi)) * 2 / 3
        dLat += (160 * sin(y / 12 * .pi) + 320 * sin(y * .pi / 30)) * 2 / 3
        var dLon = 300 + x + 2 * y + 0.1 * x * x + 0.1 * x * y + 0.1 * sqrt(abs(x))
        dLon += (20 * sin(6 * x * .pi) + 20 * sin(2 * x * .pi)) * 2 / 3
        dLon += (20 * sin(x * .pi) + 40 * sin(x / 3 * .pi)) * 2 / 3
        dLon += (150 * sin(x / 12 * .pi) + 300 * sin(x / 30 * .pi)) * 2 / 3
        let rad = lat / 180 * .pi, m = 1 - ee * sin(rad) * sin(rad), s = sqrt(m)
        return (dLat * 180 / ((a * (1 - ee)) / (m * s) * .pi), dLon * 180 / (a / s * cos(rad) * .pi))
    }
    static func fromWGS(_ c: CLLocationCoordinate2D) -> CLLocationCoordinate2D {
        let d = offset(c.latitude, c.longitude)
        return .init(latitude: c.latitude + d.0, longitude: c.longitude + d.1)
    }
    static func toWGS(_ c: CLLocationCoordinate2D) -> CLLocationCoordinate2D {
        var g = c
        for _ in 0..<5 {
            let m = fromWGS(g)
            g = .init(latitude: g.latitude + c.latitude - m.latitude, longitude: g.longitude + c.longitude - m.longitude)
        }
        return g
    }
}

// lat／lon 是注入给软件的 WGS-84；mars 表示选点时在中国大陆，地图上要换回 GCJ-02 显示
struct Place: Codable, Equatable {
    var lat, lon: Double
    var name: String
    var mars: Bool?
    var coordinate: CLLocationCoordinate2D { .init(latitude: lat, longitude: lon) }
    var mapCoordinate: CLLocationCoordinate2D { mars == true ? Mars.fromWGS(coordinate) : coordinate }
}

// 结界给这个软件的假设备身份，第一次打开时生成
struct Identity: Codable, Equatable {
    var serial, uuid, name: String
}

struct AppEntry: Codable, Identifiable, Equatable {
    let id, name, path: String
    let sandboxed, inside, running, hasSpace: Bool
    var bringOld: Bool
    var tz: String?
    var zone: String? = nil  // 实际时区：设置里选的，或结界换成的同钟点时区
    var language: String? = nil
    let perms: [String]
    var block: [String]
    var location: Place?
    var identity: Identity? = nil
    var mode: String
    var allow: [String]
    var allowOpen: Bool
    var options: [String: Bool]? = nil
    var autoEnabled: [String]? = nil
    var reviewed: Bool
    let space: String
    var inbox: String? = nil  // 传入文件的位置
    var added: Bool? = nil
    var clipboard: String? = nil
    var injectable: Bool? = nil
    var canClone: Bool? = nil
    var outside: [String]? = nil
}

struct AddResult: Decodable {
    let ok: Bool
    let reason: String
    var detail: String? = nil   // 日志里的第一条错误，原文
    var stopped: Bool? = nil    // 用户点了“停止试运行”
    let autoEnabled: [String]
}

let tunableNames = ["allow_localhost": t("本机端口", "Ports on this Mac"), "allow_procinfo": t("其他进程信息", "Other processes"),
                    "allow_open": t("打开其他 App 与链接", "Opening other apps and links")]

/// App 包里带着命令行、注入库和规则；第一次打开或版本变化时装到 ~/Library/Application Support/Kekkai/bin。
/// 放在包外，是因为结界启动的软件要读注入库，而 /Applications 里的包随时可能被替换。
enum Support {
    static let dir = URL(fileURLWithPath: NSHomeDirectory() + "/Library/Application Support/Kekkai/bin")

    static func install() {
        guard let src = Bundle.main.resourceURL?.appendingPathComponent("support"),
              let want = try? String(contentsOf: src.appendingPathComponent("build-id"), encoding: .utf8) else { return }
        if (try? String(contentsOf: dir.appendingPathComponent("build-id"), encoding: .utf8)) == want { return }
        let fm = FileManager.default
        try? fm.createDirectory(at: dir, withIntermediateDirectories: true)
        let names = (try? fm.contentsOfDirectory(atPath: src.path)) ?? []
        for old in (try? fm.contentsOfDirectory(atPath: dir.path)) ?? [] where !names.contains(old) {
            try? fm.removeItem(at: dir.appendingPathComponent(old))  // 旧版留下的文件，如 Python 命令行的 __pycache__
        }
        for name in names {
            let to = dir.appendingPathComponent(name)
            try? fm.removeItem(at: to)
            try? fm.copyItem(at: src.appendingPathComponent(name), to: to)
        }
    }
}

enum CLI {
    static let path = Support.dir.appendingPathComponent("kekkai").path
    @discardableResult
    static func call(_ args: [String]) -> (ok: Bool, out: String) {
        let p = Process(), pipe = Pipe()
        p.executableURL = URL(fileURLWithPath: path)
        p.arguments = args
        p.environment = ProcessInfo.processInfo.environment.merging(["KEKKAI_LANG": isChinese ? "zh" : "en"]) { $1 }
        p.standardOutput = pipe
        p.standardError = pipe
        do { try p.run() } catch { return (false, t("无法运行结界：\(error.localizedDescription)", "Can't run Kekkai: \(error.localizedDescription)")) }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        return (p.terminationStatus == 0, String(decoding: data, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines))
    }
}

struct PendingAdd: Identifiable { let path: String; var id: String { path } }

final class Store: ObservableObject {
    static let shared = Store()
    @Published var apps: [AppEntry] = []
    @Published var message: String?
    @Published var never: [String] = []
    @Published var loaded = false  // 第一次读到列表前不显示“还没有软件”
    @Published var selected: String?
    /// 置顶的 App（软件 ID，按置顶先后）：主窗口排在最前，菜单栏图标里可直接打开。只是界面偏好，存在结界自己的偏好设置里
    @Published var pinned: [String] = UserDefaults.standard.stringArray(forKey: "pinned") ?? [] {
        didSet { UserDefaults.standard.set(pinned, forKey: "pinned") }
    }
    private var timer: Timer?

    func togglePin(_ app: AppEntry) {
        if let i = pinned.firstIndex(of: app.id) { pinned.remove(at: i) } else { pinned.append(app.id) }
    }

    /// 置顶的在前（按置顶先后），其余保持原来的顺序
    func pinnedFirst(_ list: [AppEntry]) -> [AppEntry] {
        list.filter { pinned.contains($0.id) }.sorted { pinned.firstIndex(of: $0.id)! < pinned.firstIndex(of: $1.id)! }
            + list.filter { !pinned.contains($0.id) }
    }

    init() {
        Support.install()
        refresh()
        loadNever()
        // 窗口开着时每 3 秒刷新；只剩菜单栏图标时每 15 秒，菜单打开时另行刷新
        var tick = 0
        timer = Timer.scheduledTimer(withTimeInterval: 3, repeats: true) { [weak self] _ in
            tick += 1
            if tick % 5 == 0 || NSApp.windows.contains(where: { $0.isVisible && $0.identifier?.rawValue.hasPrefix("main") == true }) { self?.refresh() }
        }
    }

    func refresh() {
        DispatchQueue.global().async {
            let r = CLI.call(["list"])
            guard r.ok, let list = try? JSONDecoder().decode([AppEntry].self, from: Data(r.out.utf8)) else {
                DispatchQueue.main.async { self.message = r.out }
                return
            }
            DispatchQueue.main.async {
                if self.apps != list { self.apps = list }
                self.loaded = true
                if let p = self.reveal, let a = list.first(where: { $0.path == p }) { self.reveal = nil; self.selected = a.id }
            }
        }
    }

    func perform(_ args: [String]) {
        DispatchQueue.global().async {
            let r = CLI.call(args)
            DispatchQueue.main.async {
                if !r.ok { self.message = r.out }
                self.refresh()
            }
        }
    }

    func update(_ id: String, _ change: (inout AppEntry) -> Void) {
        if let i = apps.firstIndex(where: { $0.id == id }) { change(&apps[i]) }
    }

    @Published var reveal: String?
    func open(path: String) {
        DispatchQueue.global().async {
            let r = CLI.call(["run", path])
            DispatchQueue.main.async {
                if !r.ok { self.message = r.out }
                self.refresh()
            }
        }
    }

    /// 添加就是第一次试运行，可能要一两分钟
    func add(path: String, done: @escaping (AddResult) -> Void) {
        DispatchQueue.global().async {
            let r = CLI.call(["add", path])
            let res = (try? JSONDecoder().decode(AddResult.self, from: Data(r.out.utf8)))
                ?? AddResult(ok: false, reason: r.out.isEmpty ? t("试运行没有结果。", "The trial run gave no result.") : r.out, autoEnabled: [])
            DispatchQueue.main.async { done(res); self.refresh() }
        }
    }

    /// 双击：没在运行就从结界打开，已在运行就切到它
    func launch(_ app: AppEntry) {
        if app.inside, let running = runningInside(app) {
            bringForward(running)
        } else if app.running {
            message = t("\(displayName(app)) 正在结界外运行，请先退出后再打开。", "\(displayName(app)) is running outside Kekkai. Quit it completely first.")
        } else {
            open(path: app.path)
        }
    }

    /// 结界中运行的这个 App：它本身，或它拉起的、在它结界文件夹里的程序（如 QQ 7.0.3 真正的界面是 versions 里的 QQUpdate.app）
    private func runningInside(_ app: AppEntry) -> NSRunningApplication? {
        let all = NSWorkspace.shared.runningApplications.filter { !$0.isTerminated }
        if let part = all.first(where: { $0.activationPolicy == .regular && ($0.bundleURL?.path.hasPrefix(app.space + "/") ?? false) }) { return part }
        return all.first { $0.bundleIdentifier == app.id }
    }

    /// 切到结界中运行的 App。只 activate 时，窗口已关、只剩菜单栏图标的软件（如 QQ）不会出现，
    /// 所以像点按程序坞图标一样让系统“重新打开”正在运行的那个副本，它会显示主窗口。
    /// 只对仍在运行的进程这样做：已退出的话系统会在结界外启动它
    private func bringForward(_ running: NSRunningApplication) {
        NSApp.yieldActivation(to: running)
        running.unhide()
        running.activate(options: .activateAllWindows)
        guard let url = running.bundleURL, !running.isTerminated else { return }
        let config = NSWorkspace.OpenConfiguration()
        config.createsNewApplicationInstance = false
        NSWorkspace.shared.openApplication(at: url, configuration: config)
    }

    @Published var pendingAdd: PendingAdd?

    /// 入口的图标：原 App 的图标，右下角叠一个结界图标，和原版区分开。
    /// 两者都按系统图标网格留了约 9.8% 的边，角标的圆角方块对齐原图标的右下角并略微探出
    func launcherIcon(_ path: String) -> NSImage {
        let base = NSWorkspace.shared.icon(forFile: path), badge = NSApp.applicationIconImage ?? NSImage()
        let image = NSImage(size: NSSize(width: 1024, height: 1024))
        image.lockFocus()
        base.draw(in: NSRect(x: 0, y: 0, width: 1024, height: 1024))
        let s = 470.0, margin = s * 0.098, out = 24.0
        badge.draw(in: NSRect(x: 1024 - 100 + out + margin - s, y: 100 - out - margin, width: s, height: s))
        image.unlockFocus()
        return image
    }

    func makeLauncher(_ app: AppEntry) {
        DispatchQueue.global().async {
            let r = CLI.call(["launcher", app.path, displayName(app)])
            DispatchQueue.main.async {
                guard r.ok else { self.message = r.out; return }
                NSWorkspace.shared.setIcon(self.launcherIcon(app.path), forFile: r.out, options: [])
                NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: r.out)])
            }
        }
    }

    /// 传入文件：复制进该软件的传输文件夹（APFS 上是克隆），在访达中选中，再拖入软件或在打开面板里选
    func send(_ app: AppEntry, _ urls: [URL]) {
        guard let inbox = app.inbox, !urls.isEmpty else { return }
        DispatchQueue.global().async {
            let fm = FileManager.default
            var copied: [URL] = [], failed: [String] = []
            let dir = URL(fileURLWithPath: inbox)
            try? fm.createDirectory(at: dir, withIntermediateDirectories: true)
            for src in urls {
                let base = src.deletingPathExtension().lastPathComponent, ext = src.pathExtension
                var dst = dir.appendingPathComponent(src.lastPathComponent), n = 2
                while fm.fileExists(atPath: dst.path) {
                    dst = dir.appendingPathComponent(ext.isEmpty ? "\(base) \(n)" : "\(base) \(n).\(ext)"); n += 1
                }
                do { try fm.copyItem(at: src, to: dst); stripOrigin(dst); copied.append(dst) }
                catch { failed.append(src.lastPathComponent) }
            }
            DispatchQueue.main.async {
                if !copied.isEmpty { NSWorkspace.shared.activateFileViewerSelecting(copied) }
                if !failed.isEmpty {
                    self.message = t("以下文件无法复制：", "These files couldn't be copied: ") + failed.joined(separator: t("、", ", "))
                }
            }
        }
    }

    func loadNever(_ args: [String] = ["never", "list"]) {
        DispatchQueue.global().async {
            let r = CLI.call(args)
            let list = (try? JSONDecoder().decode([String].self, from: Data(r.out.utf8))) ?? []
            DispatchQueue.main.async { if r.ok { self.never = list } else { self.message = r.out } }
        }
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    func application(_ application: NSApplication, open urls: [URL]) {
        // 拖到图标上的软件：已添加的直接打开，没添加的先走添加（试运行）
        for url in urls where url.pathExtension == "app" {
            if let app = Store.shared.apps.first(where: { $0.path == url.path && $0.added == true }) { Store.shared.launch(app) }
            else { Store.shared.pendingAdd = PendingAdd(path: url.path) }
        }
    }
    // 关闭窗口后留在菜单栏，从菜单栏图标查看运行中的 App 或退出
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }
}

/// 去掉记录来源的扩展属性（下载网址、标签、备注），保留隔离标记
func stripOrigin(_ url: URL) {
    let keep: Set<String> = ["com.apple.quarantine", "com.apple.ResourceFork"]
    let items = [url] + ((FileManager.default.enumerator(at: url, includingPropertiesForKeys: nil)?.allObjects as? [URL]) ?? [])
    for item in items {
        item.withUnsafeFileSystemRepresentation { path in
            guard let path else { return }
            let size = listxattr(path, nil, 0, XATTR_NOFOLLOW)
            guard size > 0 else { return }
            var buf = [CChar](repeating: 0, count: size)
            guard listxattr(path, &buf, size, XATTR_NOFOLLOW) == size else { return }
            let names = buf.split(separator: 0).map { String(decoding: $0.map { UInt8(bitPattern: $0) }, as: UTF8.self) }
            for name in names where !keep.contains(name) { removexattr(path, name, XATTR_NOFOLLOW) }
        }
    }
}

/// 选文件传入
func chooseFiles(_ done: ([URL]) -> Void) {
    let panel = NSOpenPanel()
    panel.canChooseFiles = true
    panel.canChooseDirectories = true
    panel.allowsMultipleSelection = true
    panel.prompt = t("传入", "Copy In")
    if panel.runModal() == .OK { done(panel.urls) }
}

func openPrivacy(_ anchor: String) {
    NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?\(anchor)")!)
}

let presetZones: [(String, String)] = [
    (t("上海（UTC+8）", "Shanghai (UTC+8)"), "Asia/Shanghai"), (t("香港（UTC+8）", "Hong Kong (UTC+8)"), "Asia/Hong_Kong"), (t("东京（UTC+9）", "Tokyo (UTC+9)"), "Asia/Tokyo"),
    (t("新加坡（UTC+8）", "Singapore (UTC+8)"), "Asia/Singapore"), (t("伦敦", "London"), "Europe/London"), (t("巴黎", "Paris"), "Europe/Paris"),
    (t("纽约", "New York"), "America/New_York"), (t("洛杉矶", "Los Angeles"), "America/Los_Angeles"), (t("世界协调时 UTC", "UTC"), "Etc/UTC"),
]

/// 时区给人看的名字：预设里有就用城市名，其余用系统的本地化名称（如“北美东部时间”），不显示 America/New_York 这类标识符
func zoneName(_ id: String) -> String {
    if let p = presetZones.first(where: { $0.1 == id }) { return p.0.components(separatedBy: CharacterSet(charactersIn: "（(")).first!.trimmingCharacters(in: .whitespaces) }
    return TimeZone(identifier: id)?.localizedName(for: .generic, locale: .current) ?? id.replacingOccurrences(of: "_", with: " ")
}

struct Detail: View {
    let app: AppEntry
    @ObservedObject var store: Store
    let now: Date
    @State private var picking = false
    @State private var renewing = false
    @State private var importing = false
    @State private var removing = false
    @AppStorage("inspectorPane") private var pane: Pane = .activity

    enum Pane: String, CaseIterable {
        case activity, access, disguise, files
        var title: String {
            switch self {
            case .activity: t("活动", "Activity")
            case .access: t("权限", "Access")
            case .disguise: t("伪装", "Disguise")
            case .files: t("文件", "Files")
            }
        }
    }

    var status: (String, Color) {
        if app.inside { return (t("在结界中运行", "Running in Kekkai"), .green) }
        if app.running { return (t("正在结界外运行", "Running outside Kekkai. Quit it first."), .orange) }
        return (t("未运行", "Not running"), .secondary)
    }
    func clock(_ tz: String?) -> String {
        let f = DateFormatter()
        f.locale = isChinese ? Locale(identifier: "zh_CN") : Locale(identifier: "en_US")
        f.dateFormat = isChinese ? "M月d日 HH:mm" : "MMM d, HH:mm"
        f.timeZone = tz.flatMap(TimeZone.init(identifier:)) ?? .current
        return f.string(from: now)
    }
    var languageName: String? {
        app.language.flatMap { Locale.current.localizedString(forIdentifier: $0) }
    }
    func set(_ args: [String], _ change: @escaping (inout AppEntry) -> Void) {
        store.update(app.id, change)
        store.perform(args)
    }

    func option(_ key: String, _ title: String) -> some View {
        Toggle(title, isOn: Binding(
            get: { app.options?[key] ?? false },
            set: { v in set(["set", app.id, key, v ? "on" : "off"]) { $0.options?[key] = v } }))
    }

    var header: some View {
        HStack(alignment: .center, spacing: 14) {
            Image(nsImage: NSWorkspace.shared.icon(forFile: app.path)).resizable().interpolation(.high).frame(width: 56, height: 56)
            VStack(alignment: .leading, spacing: 3) {
                Text(displayName(app)).font(.title2.weight(.semibold)).lineLimit(1).truncationMode(.tail)
                HStack(spacing: 5) {
                    Circle().fill(status.1).frame(width: 7, height: 7)
                    Text(status.0).font(.callout).foregroundStyle(.secondary).lineLimit(1)
                }
            }
            .layoutPriority(1)
            Spacer(minLength: 8)
            if app.inside {
                Button(t("停止", "Stop")) { store.perform(["stop", app.path]) }.controlSize(.large)
            } else {
                Menu {
                    Button(t("在“应用程序”中创建入口", "Add a Kekkai Launcher to Applications")) { store.makeLauncher(app) }
                    Divider()
                    Button(t("从结界移除…", "Remove from Kekkai…")) { removing = true }
                } label: { Text(t("打开", "Open")) } primaryAction: { store.open(path: app.path) }
                    .menuStyle(.button).fixedSize()
                    .buttonStyle(.borderedProminent).controlSize(.large)
                    .keyboardShortcut(.defaultAction).disabled(app.running)
                    .help(t("在结界中打开", "Open in Kekkai"))
            }
        }
        .padding(.horizontal, 20).padding(.top, 18).padding(.bottom, 4)
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            Picker("", selection: $pane) {
                ForEach(Pane.allCases, id: \.self) { Text($0.title).tag($0) }
            }
            .pickerStyle(.segmented).labelsHidden().padding(.horizontal, 20).padding(.top, 10).padding(.bottom, 12)
            Form {
                if let parts = app.outside, !parts.isEmpty {
                    Section {
                        Label(parts.joined(separator: t("、", ", ")), systemImage: "exclamationmark.triangle.fill")
                            .foregroundStyle(.orange).lineLimit(2)
                    } header: { Text(t("结界外的组件", "Components outside Kekkai")) } footer: {
                        Text(t("由系统直接启动，不受结界限制。可在“系统设置 › 通用 › 登录项与扩展”中关闭。",
                               "Started by macOS directly and not restricted by Kekkai. Turn them off in System Settings › General › Login Items & Extensions."))
                            .foregroundStyle(.secondary)
                    }
                }
                // 分页显示：打开面板先看到正在发生什么，设置按用途分开，不一次铺满
                switch pane {
                case .activity:
                    BlockLogSection(app: app, store: store)
                case .access:
                    Section {
                        Picker(t("剪贴板与拖放", "Clipboard and drag and drop"), selection: Binding(
                            get: { app.clipboard ?? (app.block.contains("clipboard") ? "off" : "on") },
                            set: { v in set(["set-clipboard", app.id, v]) { e in
                                e.clipboard = v
                                e.block = e.block.filter { $0 != "clipboard" } + (v == "off" ? ["clipboard"] : []) } })) {
                            Text(t("禁止", "Off")).tag("off")
                            if app.injectable ?? false { Text(t("可写入，粘贴时可读", "Write, read on paste")).tag("paste") }
                            Text(t("允许", "On")).tag("on")
                        }
                        option("procinfo", t("其他进程信息", "Other processes"))
                        option("localhost", t("本机端口", "Ports on this Mac"))
                        if app.injectable ?? false {
                            option("lan", t("局域网设备", "Devices on the local network"))
                        }
                        Toggle(t("打开其他 App 与链接", "Opening other apps and links"), isOn: Binding(
                            get: { app.allowOpen },
                            set: { v in set(["set-open", app.id, v ? "on" : "off"]) { $0.allowOpen = v } }))
                        .help(t("经它打开的 App 和网页不受结界限制。", "Apps and pages it opens run outside Kekkai."))
                    } footer: {
                        let auto = (app.autoEnabled ?? []).compactMap { tunableNames[$0] }
                        if !auto.isEmpty {
                            Text(t("添加时自动开启：\(auto.joined(separator: "、"))（关闭后无法启动）。", "Turned on automatically at first launch: \(auto.joined(separator: ", ")). It failed to start without them."))
                                .foregroundStyle(.orange)
                        }
                        Text(t("更改在下次打开时生效。", "Changes take effect next launch."))
                            .foregroundStyle(.secondary)
                    }
                    Section {
                        if app.allow.isEmpty {
                            Text(t("无", "None")).foregroundStyle(.secondary)
                        }
                        ForEach(app.allow, id: \.self) { p in
                            HStack {
                                Image(nsImage: NSWorkspace.shared.icon(forFile: p)).resizable().frame(width: 16, height: 16)
                                Text((p as NSString).abbreviatingWithTildeInPath).lineLimit(1).truncationMode(.middle)
                                    .help((p as NSString).abbreviatingWithTildeInPath)
                                Spacer()
                                Button(t("移除", "Remove")) { set(["allow", app.id, "rm", p]) { $0.allow.removeAll { $0 == p } } }
                            }
                        }
                        Button(t("添加文件夹…", "Add Folder…")) {
                            let panel = NSOpenPanel()
                            panel.canChooseDirectories = true
                            panel.canChooseFiles = false
                            panel.canCreateDirectories = true
                            panel.prompt = t("批准", "Allow")
                            if panel.runModal() == .OK, let p = panel.url?.path {
                                set(["allow", app.id, "add", p]) { $0.allow.append(p) }
                            }
                        }
                    } header: { Text(t("允许访问的文件夹", "Allowed folders")) }
                    Section {
                        HStack {
                            Button(t("摄像头", "Camera")) { openPrivacy("Privacy_Camera") }
                            Button(t("麦克风", "Microphone")) { openPrivacy("Privacy_Microphone") }
                            Button(t("定位", "Location")) { openPrivacy("Privacy_LocationServices") }
                            Button(t("本地网络", "Local Network")) { openPrivacy("Privacy_LocalNetwork") }
                        }
                    } header: { Text(t("由 macOS 管理的权限", "Permissions managed by macOS")) }
                case .disguise:
                    Section {
                        Picker(t("时区", "Time zone"), selection: Binding(
                            get: { app.tz ?? "" },
                            set: { v in set(["set-tz", app.id, v.isEmpty ? "-" : v]) { $0.tz = v.isEmpty ? nil : v } })) {
                            if let zone = app.zone, app.tz == nil {
                                Text(t("自动（\(zoneName(zone))）", "Automatic (\(zoneName(zone)))")).tag("")
                            } else {
                                Text(t("跟随系统", "System default")).tag("")
                            }
                            if app.location != nil || app.tz == "location" {
                                Text(app.tz == "location" && app.location != nil
                                     ? t("跟随虚拟位置（\(zoneName(app.zone ?? ""))）", "Match virtual location (\(zoneName(app.zone ?? "")))")
                                     : t("跟随虚拟位置", "Match virtual location")).tag("location")
                            }
                            ForEach(presetZones, id: \.1) { Text($0.0).tag($0.1) }
                            if let tz = app.tz, tz != "location", !presetZones.contains(where: { $0.1 == tz }) { Text(zoneName(tz)).tag(tz) }
                        }
                        LabeledContent(t("虚拟位置", "Virtual location")) {
                            HStack {
                                Text(app.location.map { $0.name.isEmpty ? String(format: "%.4f, %.4f", $0.lat, $0.lon) : $0.name } ?? t("关", "Off"))
                                    .foregroundStyle(.secondary).lineLimit(1)
                                Button(t("选择…", "Choose…")) { picking = true }
                            }
                        }
                        LabeledContent(t("设备", "Device")) {
                            HStack {
                                Text(app.identity.map { "\($0.name) · \($0.serial)" } ?? t("下次打开时生成", "Created at next launch"))
                                    .foregroundStyle(.secondary).lineLimit(1).textSelection(.enabled)
                                Button(t("重置设备身份", "Reset Device Identity")) { renewing = true }
                                    .disabled(app.identity == nil)
                            }
                        }
                        .help(t("序列号、硬件 UUID、网卡地址和电脑名为该软件专用。", "The serial number, hardware UUID, network addresses and computer name are unique to this app."))
                        if app.canClone ?? false {
                            option("clone", t("以可注入副本运行", "Run as an injectable copy"))
                        }
                    } footer: {
                        if app.canClone ?? false {
                            Text(t("该软件的签名不允许注入，设备信息仅能屏蔽。开启后运行可注入的副本，系统权限需重新授权。", "This app's signature doesn't allow injection, so device information can only be blocked. When on, Kekkai runs an injectable copy; system permissions must be granted again."))
                                .foregroundStyle(.secondary)
                        }
                        // 随时间变化的状态单独一行，日期和钟点之间不换行
                        VStack(alignment: .leading, spacing: 4) {
                            Text(t("结界内时间：\(clock(app.zone ?? app.tz).replacingOccurrences(of: " ", with: "\u{00A0}"))\(languageName.map { " · " + $0 } ?? "")",
                                   "Time inside: \(clock(app.zone ?? app.tz).replacingOccurrences(of: " ", with: "\u{00A0}"))\(languageName.map { " · " + $0 } ?? "")"))
                        }
                            .foregroundStyle(.secondary)
                    }
                    .confirmationDialog(t("重置设备身份？", "Reset device identity?"), isPresented: $renewing) {
                        Button(t("重置设备身份", "Reset Device Identity")) { set(["new-identity", app.id]) { $0.identity = nil } }
                    } message: {
                        Text(t("下次打开时将使用新的设备信息，账号可能需要重新验证。软件自行保存的设备标识需清除数据后失效。", "New device information is used next launch, and accounts may ask for verification again. Device IDs the app saved itself remain until its data is cleared."))
                    }
                case .files:
                    Section {
                        let space = app.sandboxed || app.mode == "space"
                        LabeledContent(t("存放位置", "Stored in"), value: space ? t("结界文件夹", "Its Kekkai folder") : t("原位置", "Original location"))
                        if space {
                            HStack {
                                Button(t("从原 App 导入…", "Import from Original…")) { importing = true }
                                if app.hasSpace {
                                    Button(t("在访达中显示", "Show in Finder")) {
                                        NSWorkspace.shared.selectFile(nil, inFileViewerRootedAtPath: app.space)
                                    }
                                }
                            }
                        }
                    } header: { Text(t("数据", "Data")) } footer: {
                        Text(!(app.sandboxed || app.mode == "space")
                             ? t("该软件以书签记录数据位置，因此在原位置运行。", "This app records its data location in a bookmark, so it runs in place.")
                             : app.sandboxed
                             ? t("导入将以原 App 的当前数据替换结界中的数据。登录状态无法导入。",
                                 "Importing replaces the data in Kekkai with the original app's current data. Sign-in state can't be imported.")
                             : t("导入将以原 App 的当前数据替换结界中的数据。",
                                 "Importing replaces the data in Kekkai with the original app's current data."))
                            .foregroundStyle(.secondary)
                    }
                    Section {
                        HStack {
                            Button(t("传入文件…", "Copy Files In…")) { chooseFiles { store.send(app, $0) } }
                            if let inbox = app.inbox, FileManager.default.fileExists(atPath: inbox) {
                                Button(t("在访达中显示", "Show in Finder")) { NSWorkspace.shared.selectFile(nil, inFileViewerRootedAtPath: inbox) }
                            }
                        }
                    } header: { Text(t("传输文件", "Transfer Files")) } footer: {
                        let direct = (app.injectable ?? false) && (app.clipboard ?? (app.block.contains("clipboard") ? "off" : "on")) != "off"
                        let copyIn = app.sandboxed || app.mode == "space"
                            ? t("“传入文件…”复制到该软件的“下载”文件夹，它存储的文件也在此处。", "Copy Files In… puts copies in its Downloads folder, next to the files it saves.")
                            : t("“传入文件…”复制到该软件专用的传输文件夹。", "Copy Files In… puts copies in a transfer folder for this app only.")
                        // 合成一段：两个 Text 叠在脚注里没有段距，看起来像在句中断行
                        Text(direct ? t("拖入或粘贴的文件以副本交给该软件，粘贴需确认。", "Dragged or pasted files arrive as copies; pasting asks first.") + (isChinese ? "" : " ") + copyIn : copyIn)
                            .foregroundStyle(.secondary)
                    }
                }
            }
            .formStyle(.grouped)
            .contentMargins(.top, 0, for: .scrollContent)  // 分段按钮下的空白固定在滚动区外，滚动与否都一样
            .confirmationDialog(t("从结界移除 \(displayName(app))？", "Remove \(displayName(app)) from Kekkai?"), isPresented: $removing) {
                Button(t("移除", "Remove"), role: .destructive) { store.perform(["remove", app.path]); store.selected = nil }
            } message: {
                Text(t("仅从列表中移除。结界文件夹与设置将保留，重新添加后继续使用。", "It's only taken off the list. Its Kekkai folder and settings stay, ready if you add it again."))
            }
            .confirmationDialog(t("用原 App 的数据替换它在结界里的数据？", "Replace its data in Kekkai with the original app's data?"), isPresented: $importing) {
                Button(t("导入", "Import"), role: .destructive) { store.perform(["import", app.path]) }
            } message: {
                Text(t("软件将先停止。原 App 的数据不受影响，结界文件夹中的数据将被替换。",
                       "It stops first. The original app's data is untouched; the data in its Kekkai folder is replaced."))
            }
            .sheet(isPresented: $picking) {
                LocationPicker(current: app.location) { place in
                    store.update(app.id) { $0.location = place }
                    store.perform(place.map { ["set-location", app.id, String($0.lat), String($0.lon), $0.mars == true ? "--mars" : "--wgs", $0.name] } ?? ["set-location", app.id, "-"])
                }
            }
        }
    }
}

/// 可折叠的一行：点整行（不只是小箭头）就展开或收起
struct Fold<Label: View, Content: View>: View {
    @Binding var isOpen: Bool
    @ViewBuilder let label: Label
    @ViewBuilder let content: Content
    var body: some View {
        Button {
            withAnimation(.easeInOut(duration: 0.15)) { isOpen.toggle() }
        } label: {
            HStack(spacing: 6) {
                Image(systemName: "chevron.right").font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                    .rotationEffect(.degrees(isOpen ? 90 : 0))
                label
                Spacer()
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        if isOpen { content.padding(.leading, 18) }
    }
}

struct LogItem: Codable, Identifiable {
    var id: String { key }
    let key, op, target, verb, category, last, grant: String
    let count: Int
    let recent, suspicious, normal: Bool
    var level: String? = nil
    var ask: Bool? = nil
    var decision: String?
}

struct BlockLog: Codable {
    let running: Bool
    var gatekeeper: Bool? = nil
    var receipt: Bool? = nil
    let started, exited, exitCode: String?
    let seconds: Int?
    let errors: [String]
    var items: [LogItem]
}

/// 拦截记录：在结界中运行时每几秒刷新，每条可以直接允许或拒绝
struct BlockLogSection: View {
    let app: AppEntry
    @ObservedObject var store: Store
    @State private var log: BlockLog?
    @State private var changed = false
    @State private var open: Set<String> = []

    func load() async {
        let r = await Task.detached { CLI.call(["blocked", app.path, "--json"]) }.value
        if let l = try? JSONDecoder().decode(BlockLog.self, from: Data(r.out.utf8)) { log = l }
    }
    func decide(_ item: LogItem, _ choice: String) {
        if let i = log?.items.firstIndex(where: { $0.key == item.key }) { log?.items[i].decision = choice }
        if choice == "allow" { changed = true }
        store.perform(["decide", app.id, choice, item.key])
    }
    func row(_ item: LogItem) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 6) {
                    Text(item.verb).foregroundStyle(.secondary)
                    Text((item.target as NSString).abbreviatingWithTildeInPath).lineLimit(1).truncationMode(.middle).help(item.target)
                        .foregroundStyle(item.recent ? .primary : .secondary)
                }
                HStack(spacing: 6) {
                    Text(item.category).foregroundStyle(.secondary)
                    if item.count > 1 { Text("×\(item.count)").foregroundStyle(.secondary) }
                }.font(.caption)
            }
            Spacer()
            if let d = item.decision {
                Text(d == "allow" ? t("已允许", "Allowed") : t("已拒绝", "Denied")).foregroundStyle(.secondary)
            } else if !item.grant.isEmpty {
                // 分组里的本来就一直挡着，只需要“允许”；退出前被挡的那几条才要你二选一
                if item.ask == true { Button(t("拒绝", "Deny")) { decide(item, "deny") } }
                Button(t("允许", "Allow")) { decide(item, "allow") }
            }
        }
    }
    func order(_ items: [LogItem]) -> [LogItem] {
        items.sorted { ($0.recent ? 0 : 1, $0.suspicious ? 0 : 1, -$0.count, $0.key) < ($1.recent ? 0 : 1, $1.suspicious ? 0 : 1, -$1.count, $1.key) }
    }
    /// 等你决定的：可能真需要的（你的文件夹、闪退前被挡的数据），打听类的折进分组
    var pending: [LogItem] { order((log?.items ?? []).filter { $0.ask == true && $0.decision == nil }) }
    /// 其余按档次和类别折叠：越权、留意各按类别分组，常规合成一组
    func groups(_ level: String) -> [(String, [LogItem])] {
        let rest = (log?.items ?? []).filter { $0.level == level && !pending.map(\.key).contains($0.key) }
        // 条数相同按名称排，刷新时位置不跳
        return Dictionary(grouping: rest, by: \.category).map { ($0.key, order($0.value)) }.sorted { ($0.1.count, $1.0) > ($1.1.count, $0.0) }
    }
    var routine: [LogItem] { order((log?.items ?? []).filter { $0.level == "routine" }) }

    /// 档次用圆点表示：红为越权，橙为留意，灰为常规；名称放在悬停提示和读屏标签里
    func dot(_ level: String) -> some View {
        let (text, color): (String, Color) = switch level {
        case "overreach": (t("越权", "Overreach"), .red)
        case "note": (t("留意", "Worth a look"), .orange)
        default: (t("常规", "Routine"), .gray)
        }
        return Circle().fill(color).frame(width: 8, height: 8).help(text).accessibilityLabel(text)
    }
    func group(_ title: String, _ items: [LogItem], level: String) -> some View {
        Fold(isOpen: Binding(get: { open.contains(title) }, set: { if $0 { open.insert(title) } else { open.remove(title) } })) {
            // 本次运行出现过的照常显示，只在以前运行出现的变淡
            HStack(spacing: 8) {
                dot(level)
                Text(title).foregroundStyle(items.contains(where: \.recent) ? .primary : .secondary)
                Spacer()
                Text("\(items.count)").monospacedDigit().foregroundStyle(.secondary)
            }
        } content: {
            ForEach(items) { row($0) }
        }
    }

    var body: some View {
        Section {
            if let l = log {
                if l.gatekeeper == true {
                    VStack(alignment: .leading, spacing: 6) {
                        Label(t("macOS 已阻止运行：该软件从网络下载且未经 Apple 公证。", "macOS won't run it: it was downloaded and isn't notarized by Apple."),
                              systemImage: "lock.shield").foregroundStyle(.orange)
                        Text(t("确认来源可信后，在“隐私与安全性”底部点按“仍要打开”，再从结界打开。", "If you trust it, click Open Anyway at the bottom of Privacy & Security, then open it here again."))
                            .foregroundStyle(.secondary)
                        Button(t("打开隐私与安全性", "Open Privacy & Security")) {
                            NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.settings.PrivacySecurity.extension")!)
                        }
                    }
                } else if l.receipt == true {
                    Label(t("该软件为 App Store 版本，启动时校验购买凭证，结界副本无法通过校验。原版已受 Apple 沙盒保护，可直接使用。",
                            "This App Store app checks its purchase receipt at launch, and Kekkai's copy can't pass that check, so it can't run in Kekkai. The original already runs in Apple's sandbox, so use it directly."),
                          systemImage: "bag").foregroundStyle(.orange)
                } else if let s = l.seconds, s < 60, l.exited != nil {
                    Label(t("打开 \(s) 秒后退出（\(l.exitCode ?? "?")）。可放行所需请求后重新打开。",
                            "Quit \(s) s after opening (\(l.exitCode ?? "?")). Allow what it needs, then open it again."),
                          systemImage: "exclamationmark.triangle.fill").foregroundStyle(.orange)
                }
                if !l.errors.isEmpty {
                    Fold(isOpen: Binding(get: { open.contains("errors") }, set: { if $0 { open.insert("errors") } else { open.remove("errors") } })) {
                        Text(t("软件日志中的错误（\(l.errors.count)）", "Errors in its own log (\(l.errors.count))"))
                    } content: {
                        ForEach(l.errors, id: \.self) { Text($0).font(.caption.monospaced()).foregroundStyle(.secondary).lineLimit(2) }
                    }
                }
                if changed && app.inside {
                    HStack {
                        Text(t("放行的请求在重新打开后生效。", "Allowed requests take effect after reopening.")).foregroundStyle(.secondary)
                        Spacer()
                        Button(t("重新打开", "Reopen")) {
                            changed = false
                            store.perform(["stop", app.path])
                            DispatchQueue.main.asyncAfter(deadline: .now() + 2) { store.open(path: app.path) }
                        }
                    }
                }
                if l.items.isEmpty { Text(t("暂无拦截", "Nothing blocked yet")).foregroundStyle(.secondary) }
                ForEach(pending) { row($0) }
                ForEach(groups("overreach"), id: \.0) { group($0.0, $0.1, level: "overreach") }
                ForEach(groups("note"), id: \.0) { group($0.0, $0.1, level: "note") }
                if !routine.isEmpty { group(t("系统框架的常规请求", "Routine requests from system frameworks"), routine, level: "routine") }
            } else {
                ProgressView().controlSize(.small)
            }
        } header: { Text(t("拦截记录", "Block Log")) } footer: {
            Text(t("红点为越权，橙点为留意，灰点为常规；文字变淡的来自以前的运行。", "Red: overreach. Orange: worth a look. Gray: routine. Dimmed items are from earlier runs."))
                .foregroundStyle(.secondary)
        }
        .task(id: "\(app.id) \(app.inside)") {
            changed = false
            await load()
            while app.inside && !Task.isCancelled {
                try? await Task.sleep(for: .seconds(4))
                await load()
            }
            await load()  // 刚退出时再取一次，记下退出状态
        }
    }
}

// 常用城市的 WGS-84 坐标，离线选点用；mars 表示在中国大陆，地图上要换成 GCJ-02 显示
let presetPlaces: [(String, String, Double, Double, Bool)] = [
    ("北京", "Beijing", 39.9042, 116.4074, true), ("上海", "Shanghai", 31.2304, 121.4737, true),
    ("广州", "Guangzhou", 23.1291, 113.2644, true), ("深圳", "Shenzhen", 22.5431, 114.0579, true),
    ("杭州", "Hangzhou", 30.2741, 120.1551, true), ("成都", "Chengdu", 30.5728, 104.0668, true),
    ("武汉", "Wuhan", 30.5928, 114.3055, true), ("西安", "Xi'an", 34.3416, 108.9398, true),
    ("香港", "Hong Kong", 22.3193, 114.1694, false), ("台北", "Taipei", 25.0330, 121.5654, false),
    ("东京", "Tokyo", 35.6762, 139.6503, false), ("首尔", "Seoul", 37.5665, 126.9780, false),
    ("新加坡", "Singapore", 1.3521, 103.8198, false), ("悉尼", "Sydney", -33.8688, 151.2093, false),
    ("伦敦", "London", 51.5074, -0.1278, false), ("巴黎", "Paris", 48.8566, 2.3522, false),
    ("纽约", "New York", 40.7128, -74.0060, false), ("洛杉矶", "Los Angeles", 34.0522, -118.2437, false),
]

struct LocationPicker: View {
    let current: Place?
    let done: (Place?) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var online = false  // 地图、搜索和地址反查走 Apple 地图，要联网，用户点了才加载
    @State private var typed = ""
    @State private var position: MapCameraPosition = .automatic
    @State private var pin: Place?  // 存地图坐标，确定时再换算
    @State private var resolving = false
    @State private var query = ""
    @State private var results: [MKMapItem] = []

    /// 城市中心挪开几百米，免得用同一预设的人坐标完全一样
    func preset(_ p: (String, String, Double, Double, Bool)) {
        let j = { Double.random(in: -0.004...0.004) }
        done(Place(lat: p.2 + j(), lon: p.3 + j(), name: t(p.0, p.1), mars: p.4))
        dismiss()
    }
    var typedPlace: Place? {
        let n = typed.split(whereSeparator: { ", ，".contains($0) }).compactMap { Double($0) }
        guard n.count == 2, abs(n[0]) <= 90, abs(n[1]) <= 180 else { return nil }
        return Place(lat: n[0], lon: n[1], name: String(format: "%.4f, %.4f", n[0], n[1]))
    }

    func search() {
        let request = MKLocalSearch.Request()
        request.naturalLanguageQuery = query
        MKLocalSearch(request: request).start { r, _ in results = r?.mapItems ?? [] }
    }
    func use() {
        guard let p = pin else { return }
        resolving = true
        CLGeocoder().reverseGeocodeLocation(CLLocation(latitude: p.lat, longitude: p.lon)) { marks, _ in
            let china = marks?.first?.isoCountryCode == "CN"
            let w = china ? Mars.toWGS(p.coordinate) : p.coordinate
            done(Place(lat: w.latitude, lon: w.longitude, name: p.name, mars: china))
            dismiss()
        }
    }
    func choose(_ item: MKMapItem) {
        let c: CLLocationCoordinate2D
        if #available(macOS 26, *) { c = item.location.coordinate } else { c = item.placemark.coordinate }
        pin = Place(lat: c.latitude, lon: c.longitude, name: item.name ?? "")
        position = .region(MKCoordinateRegion(center: c, latitudinalMeters: 2000, longitudinalMeters: 2000))
        results = []
    }

    func shortAddress(_ item: MKMapItem) -> String {
        if #available(macOS 26, *) { return item.address?.shortAddress ?? "" }
        return item.placemark.title ?? ""
    }

    var offline: some View {
        Form {
            Section {
                LazyVGrid(columns: Array(repeating: GridItem(.flexible()), count: 4), spacing: 8) {
                    ForEach(presetPlaces, id: \.1) { p in
                        Button(t(p.0, p.1)) { preset(p) }.frame(maxWidth: .infinity)
                    }
                }
            } header: { Text(t("常用城市", "Cities")) } footer: {
                Text(t("使用城市中心附近的随机位置。", "Uses a random point near the city center.")).foregroundStyle(.secondary)
            }
            Section {
                HStack {
                    TextField(t("纬度, 经度", "Latitude, longitude"), text: $typed).onSubmit { if let p = typedPlace { done(p); dismiss() } }
                    Button(t("使用", "Use")) { if let p = typedPlace { done(p); dismiss() } }.disabled(typedPlace == nil)
                }
            } header: { Text(t("坐标", "Coordinates")) } footer: {
                Text(t("WGS-84 坐标。中国大陆地图 App 的坐标有数百米偏差。",
                       "WGS-84. Coordinates from mainland Chinese map apps are offset by several hundred meters."))
                    .foregroundStyle(.secondary)
            }
            Section {
                Button(t("在地图上选择…", "Choose on a Map…")) { online = true }
            } footer: {
                Text(t("需要联网，搜索内容和所选位置将发送给 Apple。",
                       "Requires the internet; searches and the selected location are sent to Apple."))
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
    }

    var map: some View {
        VStack(spacing: 0) {
            HStack {
                TextField(t("搜索地点", "Search for a place"), text: $query).textFieldStyle(.roundedBorder).onSubmit(search)
                Button(t("搜索", "Search"), action: search)
            }
            .padding(12)
            ZStack(alignment: .top) {
                MapReader { proxy in
                    Map(position: $position) {
                        if let pin { Marker(pin.name, coordinate: pin.coordinate) }
                    }
                    .onTapGesture { p in
                        if let c = proxy.convert(p, from: .local) {
                            pin = Place(lat: c.latitude, lon: c.longitude, name: String(format: "%.4f, %.4f", c.latitude, c.longitude))
                        }
                    }
                }
                if !results.isEmpty {
                    List(results, id: \.self) { item in
                        Button { choose(item) } label: {
                            VStack(alignment: .leading) {
                                Text(item.name ?? "")
                                Text(shortAddress(item)).font(.caption).foregroundStyle(.secondary)
                            }
                        }
                        .buttonStyle(.plain)
                    }
                    .frame(maxHeight: 220).clipShape(RoundedRectangle(cornerRadius: 8)).padding(10)
                }
            }
        }
        .onAppear {
            pin = current.map { Place(lat: $0.mapCoordinate.latitude, lon: $0.mapCoordinate.longitude, name: $0.name) }
            if let c = current?.mapCoordinate { position = .region(MKCoordinateRegion(center: c, latitudinalMeters: 3000, longitudinalMeters: 3000)) }
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            if online { map } else { offline }
            HStack {
                Text(online ? (pin.map { $0.name } ?? t("搜索地点，或在地图上点按选择", "Search for a place, or click the map"))
                            : t("当前：\(current?.name ?? "关")", "Current: \(current?.name ?? "Off")"))
                    .foregroundStyle(.secondary).lineLimit(1)
                Spacer()
                if current != nil { Button(t("关闭虚拟位置", "Turn Off")) { done(nil); dismiss() } }
                Button(t("取消", "Cancel")) { dismiss() }.keyboardShortcut(.cancelAction)
                if online {
                    Button(t("使用这个位置", "Use This Location"), action: use)
                        .keyboardShortcut(.defaultAction).buttonStyle(.borderedProminent).disabled(pin == nil || resolving)
                }
            }
            .padding(12)
        }
        .frame(width: 640, height: 520)
    }
}

/// 必定隔离的文件夹：任何软件都碰不到，优先于任何放行
struct NeverList: View {
    @ObservedObject var store: Store

    var body: some View {
        Section {
            if store.never.isEmpty { Text(t("无", "None")).foregroundStyle(.secondary) }
            ForEach(store.never, id: \.self) { p in
                HStack {
                    Image(systemName: "lock.fill").foregroundStyle(.secondary).font(.caption)
                    Text((p as NSString).abbreviatingWithTildeInPath).lineLimit(1).truncationMode(.middle)
                    Spacer()
                    Button(t("移除", "Remove")) { store.loadNever(["never", "rm", p]) }.buttonStyle(.link)
                }
            }
            Button(t("添加文件夹…", "Add Folder…")) {
                let panel = NSOpenPanel()
                panel.canChooseDirectories = true
                panel.canChooseFiles = false
                panel.allowsMultipleSelection = true
                if panel.runModal() == .OK { panel.urls.forEach { store.loadNever(["never", "add", $0.path]) } }
            }
        } header: { Text(t("必定隔离的文件夹", "Always-blocked folders")) } footer: {
            Text(t("所有软件均无法访问以上文件夹，优先于单个软件的设置。", "No app in Kekkai can access these folders, regardless of per-app settings."))
                .foregroundStyle(.secondary)
        }
    }
}

struct SettingsView: View {
    @ObservedObject var store = Store.shared

    var body: some View {
        TabView {
            Form {
                NeverList(store: store)
                Section {
                    LabeledContent(t("位置", "Location")) {
                        Text("/Users/Shared/Kekkai.noindex").foregroundStyle(.secondary).textSelection(.enabled)
                    }
                    Button(t("在访达中显示", "Show in Finder")) {
                        NSWorkspace.shared.selectFile(nil, inFileViewerRootedAtPath: "/Users/Shared/Kekkai.noindex")
                    }
                } header: { Text(t("结界文件夹", "Kekkai folders")) } footer: {
                    Text(t("各软件的数据、副本和钥匙串分别存放于此，不被聚焦收录。", "Each app's data, copy and keychain are stored here, excluded from Spotlight."))
                        .foregroundStyle(.secondary)
                }
                Section {
                    Label(t("权限默认全部关闭，必需项在添加时自动检测", "Every permission off; the ones an app can't do without are found when you add it"), systemImage: "hand.raised")
                    Label(t("隐藏真实用户名与设备标识", "Your real user name and device IDs stay hidden"), systemImage: "person.crop.circle.badge.questionmark")
                    Label(t("每个软件使用独立钥匙串", "Each app gets its own keychain and can't read yours"), systemImage: "key")
                } header: { Text(t("默认设置", "Defaults for new apps")) }
            }
            .formStyle(.grouped)
            .tabItem { Label(t("通用", "General"), systemImage: "gearshape") }

            AboutView()
                .tabItem { Label(t("关于", "About"), systemImage: "info.circle") }
        }
        .frame(width: 540, height: 500)
    }
}

struct AboutView: View {
    var version: String { Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "" }

    var body: some View {
        VStack(spacing: 14) {
            Spacer()
            Image(nsImage: NSApp.applicationIconImage).resizable().frame(width: 104, height: 104)
            VStack(spacing: 4) {
                Text(t("结界", "Kekkai")).font(.title.weight(.semibold))
                Text(t("Kekkai · 版本 \(version)", "Version \(version)")).font(.callout).foregroundStyle(.secondary)
            }
            Text(t("为每个 macOS 软件建立独立的运行环境，\n使其仅能访问自身数据。", "Every Mac app sees only its own files,\nso you can use the ones you don't trust."))
                .multilineTextAlignment(.center).foregroundStyle(.secondary)
                .padding(.top, 4)
            HStack(spacing: 10) {
                Link(destination: repoURL) { Label("GitHub", systemImage: "chevron.left.forwardslash.chevron.right") }
                Link(destination: repoURL.appendingPathComponent("issues")) { Label(t("反馈问题", "Report an Issue"), systemImage: "exclamationmark.bubble") }
            }
            .buttonStyle(.bordered).controlSize(.large).padding(.top, 8)
            Spacer()
            HStack(spacing: 6) {
                Text("© 2026 Xik Pai")
                Text("·")
                Link(t("MIT 许可证", "MIT License"), destination: repoURL.appendingPathComponent("blob/main/LICENSE"))
            }
            .font(.caption).foregroundStyle(.tertiary).padding(.bottom, 16)
        }
        .frame(maxWidth: .infinity)
    }
}

/// 网格里的一个软件，样式同访达的图标视图；在结界中运行时右下角有绿点
struct AppTile: View {
    let app: AppEntry
    let selected: Bool
    var targeted = false
    var pinned = false

    var body: some View {
        VStack(spacing: 4) {
            Image(nsImage: NSWorkspace.shared.icon(forFile: app.path)).resizable().interpolation(.high)
                .frame(width: 64, height: 64)
                .overlay(alignment: .topLeading) {
                    if pinned {
                        Image(systemName: "pin.fill").font(.system(size: 10)).foregroundStyle(.secondary).rotationEffect(.degrees(45))
                            .accessibilityLabel(t("已置顶", "Pinned"))
                    }
                }
                .overlay(alignment: .bottomTrailing) {
                    if app.inside {
                        Circle().fill(.green).frame(width: 11, height: 11)
                            .overlay(Circle().stroke(Color(nsColor: .windowBackgroundColor), lineWidth: 2))
                            .accessibilityLabel(t("在结界中运行", "Running in Kekkai"))
                    }
                }
                .padding(5)
                .background(RoundedRectangle(cornerRadius: 6).fill(selected ? Color.primary.opacity(0.1) : .clear))
                .overlay { if targeted { RoundedRectangle(cornerRadius: 6).stroke(Color.accentColor, lineWidth: 3) } }
            Text(displayName(app)).font(.system(size: 12)).lineLimit(2).multilineTextAlignment(.center)
                .padding(.horizontal, 4).padding(.vertical, 1)
                .background(RoundedRectangle(cornerRadius: 4).fill(selected ? Color.accentColor : .clear))
                .foregroundStyle(selected ? Color.white : Color.primary)
        }
        .frame(width: 100, height: 112, alignment: .top)
        .contentShape(Rectangle())
    }
}

/// 从左到右排、放不下就换行；容器宽度变化时已有的位置不动
struct TileFlow: Layout {
    var spacing: CGFloat = 8
    var lineSpacing: CGFloat = 14

    func frames(_ width: CGFloat, _ subviews: Subviews) -> ([CGRect], CGFloat) {
        var x: CGFloat = 0, y: CGFloat = 0, row: CGFloat = 0, out: [CGRect] = []
        for s in subviews {
            let size = s.sizeThatFits(.unspecified)
            if x > 0 && x + size.width > width { x = 0; y += row + lineSpacing; row = 0 }
            out.append(CGRect(origin: CGPoint(x: x, y: y), size: size))
            x += size.width + spacing
            row = max(row, size.height)
        }
        return (out, y + row)
    }
    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let width = proposal.width ?? .infinity
        let (rects, height) = frames(width, subviews)
        return CGSize(width: proposal.width ?? (rects.map(\.maxX).max() ?? 0), height: height)
    }
    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        for (s, r) in zip(subviews, frames(bounds.width, subviews).0) {
            s.place(at: CGPoint(x: bounds.minX + r.minX, y: bounds.minY + r.minY), proposal: ProposedViewSize(r.size))
        }
    }
}

/// 添加：选一个软件，在结界里试运行，撑得住才加进来
struct AddSheet: View {
    @ObservedObject var store: Store
    let initialPath: String?
    @Environment(\.dismiss) private var dismiss
    @State private var query = ""
    @State private var testing: AppEntry?
    @State private var testingPath: String?
    @State private var result: AddResult?

    var library: [AppEntry] {
        let all = store.apps.filter { $0.added != true && !$0.id.hasPrefix("com.apple.") }
        return query.isEmpty ? all : all.filter { displayName($0).localizedCaseInsensitiveContains(query) || $0.name.localizedCaseInsensitiveContains(query) }
    }
    var name: String {
        testing.map(displayName) ?? testingPath.map { (FileManager.default.displayName(atPath: $0) as NSString).deletingPathExtension } ?? ""
    }

    func start(_ path: String) {
        testingPath = path
        testing = store.apps.first { $0.path == path }
        result = nil
        store.add(path: path) { result = $0 }
    }

    var body: some View {
        Group {
            if let path = testingPath { trial(path) } else { chooser }
        }
        .frame(width: 460, height: 520)
        .onAppear { if let p = initialPath { start(p) } }
    }

    var chooser: some View {
        VStack(spacing: 0) {
            VStack(alignment: .leading, spacing: 4) {
                Text(t("添加软件", "Add an App")).font(.title3.weight(.semibold))
                Text(t("添加时将在结界中试运行，能正常启动的软件才会加入列表。", "Kekkai runs it once as a trial and adds it only if it starts properly."))
                    .font(.callout).foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, alignment: .leading).padding([.horizontal, .top], 20).padding(.bottom, 12)
            TextField(t("搜索", "Search"), text: $query).textFieldStyle(.roundedBorder).padding(.horizontal, 20).padding(.bottom, 8)
            List(library) { app in
                Button { start(app.path) } label: {
                    HStack(spacing: 10) {
                        Image(nsImage: NSWorkspace.shared.icon(forFile: app.path)).resizable().frame(width: 28, height: 28)
                        Text(displayName(app))
                        Spacer()
                        if app.running { Text(t("正在运行", "Running")).font(.caption).foregroundStyle(.secondary) }
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain).padding(.vertical, 2)
            }
            .listStyle(.inset)
            HStack {
                Button(t("其他位置…", "Other…")) {
                    let panel = NSOpenPanel()
                    panel.allowedContentTypes = [.applicationBundle]
                    panel.directoryURL = URL(fileURLWithPath: "/Applications")
                    if panel.runModal() == .OK, let p = panel.url?.path { start(p) }
                }
                Spacer()
                Button(t("取消", "Cancel")) { dismiss() }.keyboardShortcut(.cancelAction)
            }
            .padding(16)
        }
    }

    func trial(_ path: String) -> some View {
        VStack(spacing: 18) {
            Spacer()
            Image(nsImage: NSWorkspace.shared.icon(forFile: path)).resizable().frame(width: 96, height: 96)
                .overlay(alignment: .bottomTrailing) {
                    if let r = result {
                        Image(systemName: r.ok ? "checkmark.circle.fill" : r.stopped == true ? "stop.circle.fill" : "xmark.circle.fill")
                            .font(.system(size: 28)).symbolRenderingMode(.palette)
                            .foregroundStyle(.white, r.ok ? Color.green : r.stopped == true ? Color.gray : Color.red)
                            .background(Circle().fill(Color(nsColor: .windowBackgroundColor)).padding(-2))
                    }
                }
            if let r = result {
                Text(r.ok ? t("已添加 \(name)", "\(name) added") : r.stopped == true ? t("已停止试运行", "Trial Stopped") : t("\(name) 无法在结界中运行", "\(name) can't run in Kekkai"))
                    .font(.title3.weight(.semibold)).multilineTextAlignment(.center)
                if r.ok {
                    let auto = r.autoEnabled.compactMap { tunableNames[$0] }
                    note(auto.isEmpty ? t("关闭全部权限时运行正常，已在结界中打开。之后可连按图标启动。", "It runs with every permission off and is now open in Kekkai. Double-click its icon to open it later.")
                         : t("已自动开启必需的权限：\(auto.joined(separator: "、"))。已在结界中打开。", "Kekkai turned on what it needs to run: \(auto.joined(separator: ", ")). It's now open in Kekkai."))
                } else if r.stopped == true {
                    note(t("\(name) 未添加，试运行产生的文件已清除。", "\(name) wasn't added, and the files the trial created were removed."))
                } else {
                    note(r.reason + t("未添加。", " It wasn't added."))
                    // 日志原文：长、不分词，单独小字左对齐，可选中复制
                    if let d = r.detail, !d.isEmpty {
                        Text(d).font(.caption.monospaced()).foregroundStyle(.secondary).textSelection(.enabled)
                            .lineLimit(4).truncationMode(.middle)
                            .frame(maxWidth: .infinity, alignment: .leading).padding(8)
                            .background(RoundedRectangle(cornerRadius: 6).fill(Color.primary.opacity(0.05)))
                    }
                }
            } else {
                Text(t("正在试运行 \(name)", "Trying \(name) in Kekkai")).font(.title3.weight(.semibold)).multilineTextAlignment(.center)
                ProgressView().controlSize(.small)
                // 两件事分两行：时长单独一行，不会断在“约 / 需”之间
                VStack(spacing: 2) {
                    note(t("先关闭全部权限运行，无法运行时再逐项检测必需的权限。", "It runs with every permission off first, then Kekkai checks which ones it needs."))
                    note(t("约需 20 秒，最长 2 分钟。", "About 20 seconds, up to 2 minutes."))
                }
            }
            Spacer()
            HStack {
                Spacer()
                if result == nil {
                    Button(t("停止试运行", "Stop Trial")) { store.perform(["stop", path]) }
                } else {
                    Button(t("完成", "Done")) {
                        if result?.ok == true, let id = store.apps.first(where: { $0.path == path })?.id { store.selected = id }
                        dismiss()
                    }
                    .keyboardShortcut(.defaultAction)
                }
            }
        }
        .padding(28)
    }

    /// 居中的说明：限制行宽，免得一行太长、末行只剩一两个字
    func note(_ s: String) -> some View {
        Text(s).font(.callout).foregroundStyle(.secondary).multilineTextAlignment(.center)
            .frame(maxWidth: 340).fixedSize(horizontal: false, vertical: true)
    }
}

struct ContentView: View {
    @StateObject private var store = Store.shared
    @State private var selection: String?
    @State private var query = ""
    @State private var dropping = false
    @State private var target: String?  // 正拖着文件经过的软件
    @State private var adding = false
    @State private var now = Date()
    private let tick = Timer.publish(every: 30, on: .main, in: .common).autoconnect()

    var added: [AppEntry] {
        let all = store.pinnedFirst(store.apps.filter { $0.added == true })
        return query.isEmpty ? all : all.filter { displayName($0).localizedCaseInsensitiveContains(query) || $0.name.localizedCaseInsensitiveContains(query) }
    }

    @Environment(\.openWindow) private var openWindow
    var summary: String {
        let all = store.apps.filter { $0.added == true }
        let on = all.filter(\.inside).count
        return on > 0 ? t("\(all.count) 个软件 · \(on) 个正在结界中", "\(all.count) apps · \(on) in Kekkai now") : t("\(all.count) 个软件", "\(all.count) apps")
    }

    var body: some View {
        Group {
            if store.apps.contains(where: { $0.added == true }) {
                // 图标靠左排、位置固定：侧边栏展开时左边变窄，图标不跟着每帧重排，放不下才换行
                GeometryReader { geo in
                    ScrollView {
                        TileFlow {
                            ForEach(added) { app in
                                AppTile(app: app, selected: selection == app.id, targeted: target == app.id, pinned: store.pinned.contains(app.id))
                                    .onDrop(of: [UTType.fileURL], isTargeted: Binding(get: { target == app.id }, set: { target = $0 ? app.id : (target == app.id ? nil : target) })) { providers in
                                        receive(providers) { store.send(app, $0) }
                                        return true
                                    }
                                    .onTapGesture(count: 2) { store.launch(app) }
                                    .simultaneousGesture(TapGesture().onEnded { selection = app.id })
                                    .contextMenu { menu(app) }
                                    .help(t("双击在结界中打开", "Double-click to open in Kekkai"))
                            }
                        }
                        .padding(.horizontal, 20).padding(.vertical, 24)
                        .frame(maxWidth: .infinity, minHeight: geo.size.height, alignment: .topLeading)
                        .contentShape(Rectangle())
                        .onTapGesture { selection = nil }
                    }
                }
            } else if !store.loaded {
                ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                VStack(spacing: 10) {
                    Image(systemName: "square.dashed").font(.system(size: 44, weight: .ultraLight)).foregroundStyle(.tertiary)
                    Text(t("还没有软件", "No apps yet")).font(.title3.weight(.medium))
                    Text(t("添加的软件仅能访问自身数据。", "Once added, an app sees only its own data.")).foregroundStyle(.secondary)
                    Button(t("添加软件…", "Add an App…")) { adding = true }.controlSize(.large).padding(.top, 6)
                    Button(t("使用说明", "How Kekkai Works")) { openWindow(id: "help") }.buttonStyle(.link)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .frame(minWidth: 600, minHeight: 440)
        .background(Color(nsColor: .controlBackgroundColor))
        .navigationTitle(t("结界", "Kekkai"))
        .navigationSubtitle(store.loaded ? summary : "")
        .searchable(text: $query, placement: .toolbar, prompt: t("搜索", "Search"))
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button { adding = true } label: { Label(t("添加软件", "Add App"), systemImage: "plus") }
                    .help(t("添加软件", "Add an app"))
            }
            ToolbarItem(placement: .primaryAction) {
                SettingsLink { Label(t("设置", "Settings"), systemImage: "gearshape") }.help(t("设置", "Settings"))
            }
        }
        .inspector(isPresented: Binding(get: { selection != nil }, set: { if !$0 { selection = nil } })) {
            Group {
                if let app = store.apps.first(where: { $0.id == selection }) { Detail(app: app, store: store, now: now) }
            }
            .inspectorColumnWidth(min: 380, ideal: 440, max: 600)
        }
        .overlay { if dropping { RoundedRectangle(cornerRadius: 10).stroke(Color.accentColor, lineWidth: 3).padding(4).allowsHitTesting(false) } }
        .onDrop(of: [UTType.fileURL], isTargeted: $dropping) { providers in
            for p in providers {
                _ = p.loadObject(ofClass: URL.self) { url, _ in
                    guard let url, url.pathExtension == "app" else { return }
                    DispatchQueue.main.async {
                        if let app = store.apps.first(where: { $0.path == url.path && $0.added == true }) { selection = app.id }
                        else { store.pendingAdd = PendingAdd(path: url.path) }
                    }
                }
            }
            return true
        }
        .sheet(isPresented: $adding) { AddSheet(store: store, initialPath: nil) }
        .sheet(item: $store.pendingAdd) { AddSheet(store: store, initialPath: $0.path) }
        .onReceive(tick) { now = $0 }
        .onReceive(store.$selected) { if let id = $0 { selection = id } }
        .alert(t("结界", "Kekkai"), isPresented: Binding(get: { store.message != nil }, set: { if !$0 { store.message = nil } })) {
            if let m = store.message, m.contains("完全磁盘访问权限") || m.contains("Full Disk Access") {
                Button(t("打开系统设置", "Open System Settings")) { openPrivacy("Privacy_AllFiles") }
            }
            Button(t("好", "OK"), role: .cancel) {}
        } message: { Text(store.message ?? "") }
    }

    func receive(_ providers: [NSItemProvider], _ done: @escaping ([URL]) -> Void) {
        var urls: [URL] = []
        let group = DispatchGroup()
        for p in providers {
            group.enter()
            _ = p.loadObject(ofClass: URL.self) { url, _ in
                DispatchQueue.main.async { if let url { urls.append(url) }; group.leave() }
            }
        }
        group.notify(queue: .main) { done(urls) }
    }

    @ViewBuilder func menu(_ app: AppEntry) -> some View {
        if app.inside {
            Button(t("切换到它", "Switch to It")) { store.launch(app) }
            Button(t("停止", "Stop")) { store.perform(["stop", app.path]) }
        } else {
            Button(t("在结界中打开", "Open in Kekkai")) { store.launch(app) }
        }
        Button(t("设置…", "Settings…")) { selection = app.id }
        Button(store.pinned.contains(app.id) ? t("取消置顶", "Unpin") : t("置顶", "Pin to Top")) { store.togglePin(app) }
        Divider()
        Button(t("传入文件…", "Copy Files In…")) { chooseFiles { store.send(app, $0) } }
        if let inbox = app.inbox, FileManager.default.fileExists(atPath: inbox) {
            Button(t("显示传输文件夹", "Show Transfer Folder")) { NSWorkspace.shared.selectFile(nil, inFileViewerRootedAtPath: inbox) }
        }
        Divider()
        Button(t("在“应用程序”中创建入口", "Add a Launcher to Applications")) { store.makeLauncher(app) }
        if app.hasSpace {
            Button(t("在访达中显示数据", "Show Its Data in Finder")) { NSWorkspace.shared.selectFile(nil, inFileViewerRootedAtPath: app.space) }
        }
        Divider()
        Button(t("从结界移除", "Remove from Kekkai")) { store.perform(["remove", app.path]); if selection == app.id { selection = nil } }
    }
}

@main
struct KekkaiApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var delegate
    var body: some Scene {
        // 拖到程序坞图标或用“打开方式”传来的 App 交给已开的窗口处理，不另开窗口或标签页
        WindowGroup(t("结界", "Kekkai"), id: "main") { ContentView().handlesExternalEvents(preferring: ["*"], allowing: ["*"]) }
            .handlesExternalEvents(matching: [])
            .windowResizability(.contentMinSize)
            .windowToolbarStyle(.unified)
        Settings { SettingsView() }
        Window(t("结界使用说明", "Kekkai Help"), id: "help") { HelpView() }
            .defaultSize(width: 820, height: 600)
            .commands { HelpCommands() }
        MenuBarExtra { StatusMenu() } label: { StatusIcon() }
    }
}

/// 菜单栏图标：图标的单色版，天地之间一扇门；有 App 在结界中运行时门里的灯亮着
func statusGlyph(lit: Bool) -> NSImage {
    let image = NSImage(size: NSSize(width: 18, height: 18), flipped: false) { _ in
        // 与 Assets/make-icon.swift 同一套 8 格网格，每格 2 点
        func cell(_ x: Double, _ y: Double, _ w: Double, _ h: Double) -> NSRect { NSRect(x: 1 + x * 2, y: 1 + y * 2, width: w * 2, height: h * 2) }
        guard let ctx = NSGraphicsContext.current else { return false }
        ctx.cgContext.beginTransparencyLayer(auxiliaryInfo: nil)
        NSBezierPath(roundedRect: cell(0, 0, 8, 8), xRadius: 3.4, yRadius: 3.4).addClip()
        NSColor.black.setFill(); cell(0, 3.2, 8, 4.8).fill()                         // 天
        NSColor.black.withAlphaComponent(0.45).setFill(); cell(0, 0, 8, 3.2).fill()  // 地
        ctx.compositingOperation = .clear; cell(2.6, 2.2, 2.8, 3.6).fill()            // 门
        ctx.compositingOperation = .sourceOver
        if lit { NSColor.black.setFill(); cell(3.5, 3.5, 1, 1).fill() }               // 灯
        ctx.cgContext.endTransparencyLayer()
        return true
    }
    image.isTemplate = true
    image.accessibilityDescription = t("结界", "Kekkai")
    return image
}

struct StatusIcon: View {
    @ObservedObject var store = Store.shared
    var body: some View { Image(nsImage: statusGlyph(lit: store.apps.contains { $0.inside })) }
}

/// 点按菜单栏图标：列出正在结界中运行的 App，选中即切换到它
struct StatusMenu: View {
    @ObservedObject var store = Store.shared
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        let running = store.pinnedFirst(store.apps.filter { $0.inside })
        let pinned = store.pinnedFirst(store.apps.filter { $0.added == true && !$0.inside && store.pinned.contains($0.id) })
        Group {
            if running.isEmpty {
                Text(t("没有在结界中运行的 App", "No Apps Running in Kekkai"))
            } else {
                Section(t("在结界中运行", "Running in Kekkai")) { ForEach(running) { item($0) } }
            }
            if !pinned.isEmpty {
                Section(t("置顶", "Pinned")) { ForEach(pinned) { item($0) } }
            }
            Divider()
            Button(t("打开结界", "Open Kekkai")) {
                NSApp.activate(ignoringOtherApps: true)
                if let w = NSApp.windows.first(where: { $0.identifier?.rawValue.hasPrefix("main") == true }) { w.makeKeyAndOrderFront(nil) }
                else { openWindow(id: "main") }
            }
            Button(t("退出结界", "Quit Kekkai")) { NSApp.terminate(nil) }.keyboardShortcut("q")
        }
        .onAppear { store.refresh() }
    }

    /// 运行中的切换过去，置顶但没在运行的在结界中打开
    func item(_ app: AppEntry) -> some View {
        Button { store.launch(app) } label: {
            Label { Text(displayName(app)) } icon: { Image(nsImage: menuIcon(app.path)) }
        }
    }

    func menuIcon(_ path: String) -> NSImage {
        let icon = NSWorkspace.shared.icon(forFile: path).copy() as! NSImage
        icon.size = NSSize(width: 16, height: 16)
        return icon
    }
}

struct HelpCommands: Commands {
    @Environment(\.openWindow) private var openWindow
    var body: some Commands {
        CommandGroup(replacing: .help) {
            Button(t("结界使用说明", "Kekkai Help")) { openWindow(id: "help") }.keyboardShortcut("?", modifiers: .command)
        }
    }
}

/// 使用说明：随 App 带着，不联网。仿照“使用技巧”：左边按主题分组，右边每条一张卡片，标题一句话，正文只写一件事
struct Tip: Hashable { let symbol, title, body: String }
struct HelpTopic: Hashable, Identifiable {
    let symbol, title, intro: String
    let tips: [Tip]
    var id: String { title }
}

let helpTopics: [HelpTopic] = isChinese ? [
    HelpTopic(symbol: "sparkles", title: "开始使用", intro: "添加一次，之后都在结界中打开。", tips: [
        Tip(symbol: "plus.app", title: "添加 App", body: "点按工具栏中的“添加”按钮，或将 App 拖入窗口。添加时进行一次试运行，约 20 秒内正常启动的 App 才会加入；未能启动时将显示原因，并清除试运行产生的文件。"),
        Tip(symbol: "exclamationmark.triangle", title: "先退出原 App", body: "打开前请完全退出原 App。通过原图标打开的 App 不受结界保护。"),
        Tip(symbol: "cursorarrow.click.2", title: "打开与设置", body: "连按图标在结界中打开 App，单击图标查看设置和拦截记录。"),
        Tip(symbol: "pin", title: "置顶", body: "按住 Control 点按图标并选择“置顶”，App 将排在最前，并显示在菜单栏图标的菜单中，可从那里直接打开。"),
        Tip(symbol: "menubar.rectangle", title: "菜单栏图标", body: "列出正在结界中运行的 App，选择即可切换。图标中央的方块表示有 App 正在运行。关闭窗口后结界仍保留在菜单栏中，可通过该菜单退出。"),
        Tip(symbol: "dock.rectangle", title: "程序坞与聚焦", body: "按住 Control 点按图标，选择“在‘应用程序’中创建入口”，即可从程序坞或聚焦在结界中打开 App。"),
    ]),
    HelpTopic(symbol: "shield.lefthalf.filled", title: "隔离范围", intro: "App 只能看到自身数据和专为它生成的设备信息。", tips: [
        Tip(symbol: "folder", title: "文件", body: "仅可访问自身数据和已批准的文件夹，其他位置均显示为不存在。"),
        Tip(symbol: "desktopcomputer", title: "设备信息", body: "序列号、硬件 UUID、网卡地址等替换为该 App 专用的值，各 App 之间互不相同。"),
        Tip(symbol: "macwindow.on.rectangle", title: "其他程序", body: "无法查看其他进程、运行中的软件和窗口，无法用聚焦搜索列出已装软件，无法连接本机其他程序提供的端口，也无法打开其他 App。"),
        Tip(symbol: "doc.on.clipboard", title: "剪贴板", body: "默认可随时写入，仅在按下 ⌘V 或选择“粘贴”后可读取。"),
        Tip(symbol: "network", title: "局域网", body: "可注入的 App 无法连接局域网中的设备，也无法发现 Bonjour 服务；DNS 和系统代理不受影响。不可注入的 App 由 macOS 的“本地网络”权限控制，建议在“系统设置 › 隐私与安全性 › 本地网络”中保持关闭。"),
        Tip(symbol: "globe", title: "语言与地区", body: "可注入的 App 看到的首选语言仅保留一种，地区为该语言最常见的地区，如简体中文对应中国。未单独设置时区时，系统时区换为该地区中钟点完全相同的时区，如台北换为上海。"),
    ]),
    HelpTopic(symbol: "doc.on.doc", title: "文件与数据", intro: "结界中的数据与原 App 相互独立，文件以副本进出。", tips: [
        Tip(symbol: "square.and.arrow.down.on.square", title: "导入原有数据", body: "首次打开时，结界将原 App 的数据复制到该 App 的结界文件夹，此后两者相互独立，原数据保持不变。如需更新，可在“数据”一栏重新导入。"),
        Tip(symbol: "person.badge.key", title: "登录状态", body: "QQ、微信等自带 App 沙盒的 App 以副本运行。登录状态由系统按签名保存，无法导入，首次打开需重新登录。"),
        Tip(symbol: "key", title: "钥匙串", body: "每个 App 使用其结界文件夹中的独立钥匙串，无法读取用户的钥匙串。"),
        Tip(symbol: "arrow.down.doc", title: "拖入文件", body: "可注入的 App 可直接从结界外拖入文件。结界在 App 外复制一份并去除下载来源等附加信息，App 读到的是副本及其位置，接触不到原文件。同一磁盘上的副本为 APFS 克隆，几乎不占空间，一周后删除。"),
        Tip(symbol: "doc.on.clipboard", title: "粘贴文件", body: "粘贴的文件同样以副本交付。剪贴板的内容无法确认来源，每次粘贴需在结界显示的提示中确认。剪贴板设为“禁止”时，拖入和粘贴文件均不可用。"),
        Tip(symbol: "tray.and.arrow.down", title: "传入文件", body: "不可注入的 App 无法读取结界外的文件。可将文件拖到主窗口中该 App 的图标上，或使用设置中的“传入文件…”，文件将复制到该 App 的“下载”文件夹，再从访达拖入或在打开面板中选择。"),
        Tip(symbol: "tray.and.arrow.up", title: "取出文件", body: "App 存储到“下载”的文件，可通过设置中“传输文件”一栏的“在访达中显示”取出。"),
        Tip(symbol: "lock", title: "必定隔离的文件夹", body: "设置中列出的文件夹对所有 App 均不可见，其中的文件也不会经拖入或粘贴复制给 App。"),
    ]),
    HelpTopic(symbol: "switch.2", title: "权限", intro: "权限默认全部关闭，开启即允许，下次打开 App 时生效。", tips: [
        Tip(symbol: "server.rack", title: "本机端口", body: "本机其他程序提供的网络服务，如代理面板和开发服务器。关闭时仅可连接结界为其分配的端口；可注入的 App 自行打开的端口将移入该范围。"),
        Tip(symbol: "wifi", title: "局域网设备", body: "开启后可连接局域网中的设备并使用 Bonjour，如投屏和局域网传输。"),
        Tip(symbol: "arrow.up.forward.app", title: "打开其他 App 与链接", body: "开启后，经它打开的 App 和网页不受结界限制。"),
        Tip(symbol: "list.bullet.rectangle", title: "拦截记录", body: "在设置的“活动”页中。红点为越权，即超出其功能所需的探查；橙点为留意，可能正常但值得关注；灰点为常规，由系统框架自动发出，不影响使用。文字变淡的来自以前的运行。"),
        Tip(symbol: "wrench.and.screwdriver", title: "功能异常时", body: "请先查看拦截记录。排在前面且标有“本次运行”的项目最可能相关，可逐项放行。"),
    ]),
    HelpTopic(symbol: "questionmark.circle", title: "常见问题", intro: "遇到问题时，可先在这里查找原因。", tips: [
        Tip(symbol: "xmark.app", title: "无法添加", body: "App Store 付费 App 会校验购买凭证，副本无法通过校验，因此不受支持。其他原因见添加时显示的提示。"),
        Tip(symbol: "lock.shield", title: "导入失败", body: "请在“系统设置 › 隐私与安全性 › 完全磁盘访问权限”中开启“结界”。"),
        Tip(symbol: "camera", title: "摄像头、麦克风与定位", body: "由 macOS 管理，可通过设置底部的按钮前往对应的系统设置。"),
        Tip(symbol: "square.on.square.dashed", title: "以可注入副本运行", body: "部分 App 的签名不允许注入。添加这类 App 时，结界先运行去除强化运行时的 APFS 克隆副本，几乎不占用额外空间，试运行失败才改用原版。原版无法替换设备信息，且可看到运行中的软件、窗口列表、显示器序列号和电脑名。原 App 更新后，副本在下次打开时重建；副本功能异常时，可在“伪装”一栏关闭。"),
        Tip(symbol: "puzzlepiece.extension", title: "结界外的组件", body: "网盘同步扩展、登录项、特权助手等由系统直接启动，不受结界限制。结界禁止 App 在其中注册此类组件；已存在的会列在设置顶部，可在“系统设置 › 通用 › 登录项与扩展”中关闭。"),
        Tip(symbol: "house", title: "原地运行", body: "少数 App（如腾讯会议官网版）以书签记录数据位置，只能在原位置运行，此时主目录路径中的账户名对其可见。"),
        Tip(symbol: "laptopcomputer", title: "电脑名", body: "不可注入的 App 可读取真实电脑名。如电脑名包含本人姓名，建议在“系统设置 › 通用 › 关于本机”中修改。"),
        Tip(symbol: "arrow.counterclockwise", title: "重置设备身份", body: "该 App 将把本机识别为新设备，账号可能需要重新验证；App 自行保存的设备标识需清除数据后失效。机型、系统版本等非唯一信息保持不变。"),
        Tip(symbol: "clock", title: "时区", body: "可按 App 单独设置。使用代理的 App，建议将时区设为代理出口所在地区，两者不一致时更易被识别。设置虚拟位置后可选“跟随虚拟位置”，时区按 macOS 自带的时区边界数据离线确定。"),
    ]),
    HelpTopic(symbol: "hand.raised", title: "隐私", intro: "结界保护的是本机上的信息。", tips: [
        Tip(symbol: "wifi.slash", title: "结界本身不联网", body: "仅当在虚拟位置中选择“在地图上选择”时加载 Apple 地图。"),
        Tip(symbol: "scope", title: "保护范围", body: "基于 IP 地址的定位，以及基于账号和使用习惯的识别，不在结界的保护范围内。"),
    ]),
] : [
    HelpTopic(symbol: "sparkles", title: "Getting Started", intro: "Add an app once, then open it in Kekkai every time.", tips: [
        Tip(symbol: "plus.app", title: "Add an app", body: "Click Add in the toolbar, or drag an app into the window. Adding performs a trial run: the app is added only if it starts within about 20 seconds. Otherwise Kekkai shows the reason and removes the files the trial created."),
        Tip(symbol: "exclamationmark.triangle", title: "Quit the original first", body: "Quit the original app completely before opening it in Kekkai. An app opened from its own icon isn't protected."),
        Tip(symbol: "cursorarrow.click.2", title: "Open and configure", body: "Double-click an icon to open the app in Kekkai. Click once to see its settings and Block Log."),
        Tip(symbol: "pin", title: "Pin to Top", body: "Control-click an icon and choose Pin to Top. The app comes first in the window and appears in the menu bar icon's menu, ready to open."),
        Tip(symbol: "menubar.rectangle", title: "Menu bar icon", body: "Lists the apps running in Kekkai; choose one to switch to it. A square in the middle of the icon means something is running. Kekkai stays in the menu bar after its window closes; quit it from that menu."),
        Tip(symbol: "dock.rectangle", title: "Dock and Spotlight", body: "Control-click an icon and choose Add a Launcher to Applications to open the app in Kekkai from the Dock or Spotlight."),
    ]),
    HelpTopic(symbol: "shield.lefthalf.filled", title: "What Is Isolated", intro: "An app sees only its own data and a device identity made for it.", tips: [
        Tip(symbol: "folder", title: "Files", body: "Only the app's own data and approved folders are accessible. Everything else appears not to exist."),
        Tip(symbol: "desktopcomputer", title: "Device information", body: "The serial number, hardware UUID, network addresses and similar values are replaced with values unique to the app."),
        Tip(symbol: "macwindow.on.rectangle", title: "Other programs", body: "The app can't see other processes, running apps or their windows, list installed apps through Spotlight, connect to ports opened by other programs on this Mac, or open other apps."),
        Tip(symbol: "doc.on.clipboard", title: "Clipboard", body: "By default the app can write at any time and read only after you press ⌘V or choose Paste."),
        Tip(symbol: "network", title: "Local network", body: "Injectable apps can't connect to devices on the local network or discover Bonjour services; DNS and the system proxy are unaffected. Apps that can't be injected are governed by the macOS Local Network permission; keep it off in System Settings › Privacy & Security › Local Network."),
        Tip(symbol: "globe", title: "Language and region", body: "Injectable apps see a single preferred language, with the region most common for it, such as China for Simplified Chinese. Unless a time zone is set for the app, the system time zone becomes one in that region with exactly the same clock, such as Shanghai for Taipei."),
    ]),
    HelpTopic(symbol: "doc.on.doc", title: "Files and Data", intro: "Data in Kekkai is separate from the original app, and files move in and out as copies.", tips: [
        Tip(symbol: "square.and.arrow.down.on.square", title: "Bring in existing data", body: "At first launch, Kekkai copies the original app's data into the app's Kekkai folder. The two are independent after that, and the original is unchanged. To update it, import again from the Data section."),
        Tip(symbol: "person.badge.key", title: "Sign-in", body: "Apps that include Apple's App Sandbox, such as QQ and WeChat, run as a copy. Sign-in state is stored by macOS per signature and can't be imported; sign in again at first launch."),
        Tip(symbol: "key", title: "Keychain", body: "Each app uses a separate keychain in its Kekkai folder and can't read your keychain."),
        Tip(symbol: "arrow.down.doc", title: "Drag files in", body: "Injectable apps accept files dragged in from outside Kekkai. Kekkai makes a copy outside the app without extras such as where it was downloaded from, so the app sees only the copy and its location. On the same disk the copy is an APFS clone that takes almost no space; it's deleted after a week."),
        Tip(symbol: "doc.on.clipboard", title: "Paste files", body: "Pasted files arrive as copies too. Clipboard contents can't be traced to their source, so each paste must be confirmed in a prompt from Kekkai. With the clipboard Off, files can't be dragged or pasted in."),
        Tip(symbol: "tray.and.arrow.down", title: "Copy files in", body: "Apps that can't be injected can't read files outside Kekkai. Drop files on the app's icon in the main window, or use Copy Files In… in its settings; they're copied to the app's Downloads folder, ready to drag in from Finder or choose in its Open dialog."),
        Tip(symbol: "tray.and.arrow.up", title: "Get files out", body: "Files the app saves to Downloads can be reached with Show in Finder in the Transfer Files section of its settings."),
        Tip(symbol: "lock", title: "Always-isolated folders", body: "Folders listed in Settings are invisible to every app, and files in them are never copied in by dragging or pasting."),
    ]),
    HelpTopic(symbol: "switch.2", title: "Permissions", intro: "All permissions start off. Turning one on allows it the next time the app opens.", tips: [
        Tip(symbol: "server.rack", title: "Ports on this Mac", body: "Network services provided by other programs, such as proxy dashboards and development servers. When off, the app can connect only to the ports Kekkai assigns it; for injectable apps, ports the app opens itself move into that range."),
        Tip(symbol: "wifi", title: "Devices on the local network", body: "When on, the app can connect to devices on the local network and use Bonjour, for screen mirroring or local file transfer."),
        Tip(symbol: "arrow.up.forward.app", title: "Opening other apps and links", body: "When on, apps and web pages it opens run outside Kekkai."),
        Tip(symbol: "list.bullet.rectangle", title: "Block Log", body: "On the Activity page of its settings. Red marks overreach, probing beyond what the app needs; orange is worth a look, possibly normal; gray is routine, sent by system frameworks and harmless to block. Dimmed items are from earlier runs."),
        Tip(symbol: "wrench.and.screwdriver", title: "When something doesn't work", body: "Check the Block Log first. Items near the top marked This Run are the most likely cause and can be allowed one at a time."),
    ]),
    HelpTopic(symbol: "questionmark.circle", title: "Troubleshooting", intro: "Common problems and what causes them.", tips: [
        Tip(symbol: "xmark.app", title: "Can't add an app", body: "Paid App Store apps verify their purchase receipt, which a copy can't pass, so they aren't supported. Other reasons are shown when adding."),
        Tip(symbol: "lock.shield", title: "Import fails", body: "Turn on Kekkai in System Settings › Privacy & Security › Full Disk Access."),
        Tip(symbol: "camera", title: "Camera, microphone and location", body: "Managed by macOS. Use the buttons at the bottom of an app's settings to open the relevant System Settings pane."),
        Tip(symbol: "square.on.square.dashed", title: "Run as an injectable copy", body: "Some apps' signatures don't allow injection. When adding such an app, Kekkai first runs an APFS clone without the hardened runtime, using almost no extra space, and uses the original only if the copy fails its trial run. The original can't have its device information replaced and can see running apps, the window list, the display serial and the computer name. The copy is rebuilt after the original updates; if it misbehaves, turn it off in Disguise."),
        Tip(symbol: "puzzlepiece.extension", title: "Components outside Kekkai", body: "Sync extensions, login items and privileged helpers are started by macOS and aren't restricted by Kekkai. Apps in Kekkai can't register them; existing ones are listed at the top of the app's settings and can be turned off in System Settings › General › Login Items & Extensions."),
        Tip(symbol: "house", title: "Running in place", body: "A few apps, such as Tencent Meeting's direct download, record their data location in bookmarks and must run in place. The account name in your home folder path is then visible to them."),
        Tip(symbol: "laptopcomputer", title: "Computer name", body: "Apps that can't be injected can read the real computer name. If it contains your name, change it in System Settings › General › About."),
        Tip(symbol: "arrow.counterclockwise", title: "Reset device identity", body: "The app treats this Mac as a new device, and accounts may ask for verification again. Device IDs the app saved itself remain until its data is cleared. Model and macOS version are unchanged."),
        Tip(symbol: "clock", title: "Time zone", body: "Set per app. For an app that uses a proxy, match the proxy's region; a mismatch makes identification easier. With a virtual location set, Match Virtual Location looks up its time zone offline in boundary data included with macOS."),
    ]),
    HelpTopic(symbol: "hand.raised", title: "Privacy", intro: "Kekkai protects the information on this Mac.", tips: [
        Tip(symbol: "wifi.slash", title: "Kekkai stays offline", body: "Apple Maps loads only when you click Choose on a Map in the virtual-location picker."),
        Tip(symbol: "scope", title: "What's out of scope", body: "Location by IP address, and identification by account or usage patterns, are outside what Kekkai protects."),
    ]),
]

struct HelpView: View {
    @State private var topic: HelpTopic? = helpTopics.first

    var body: some View {
        NavigationSplitView {
            List(helpTopics, selection: $topic) { topic in
                Label(topic.title, systemImage: topic.symbol).tag(topic)
            }
            .navigationSplitViewColumnWidth(min: 170, ideal: 190, max: 240)
        } detail: {
            if let topic {
                ScrollView {
                    VStack(alignment: .leading, spacing: 24) {
                        VStack(alignment: .leading, spacing: 6) {
                            Image(systemName: topic.symbol).font(.system(size: 34)).foregroundStyle(.tint).padding(.bottom, 6)
                            Text(topic.title).font(.largeTitle.weight(.bold))
                            Text(topic.intro).font(.title3).foregroundStyle(.secondary)
                        }
                        VStack(spacing: 12) {
                            ForEach(topic.tips, id: \.self) { TipCard(tip: $0) }
                        }
                    }
                    // 行宽上限：正文一行不超过约 42 个汉字，窗口拉宽时卡片不跟着变成长条
                    .frame(maxWidth: 600, alignment: .leading)
                    .padding(32)
                    .frame(maxWidth: .infinity)
                    .textSelection(.enabled)
                }
                .id(topic.id)
            }
        }
        .frame(minWidth: 800, minHeight: 540)
    }
}

struct TipCard: View {
    let tip: Tip
    var body: some View {
        HStack(alignment: .top, spacing: 14) {
            Image(systemName: tip.symbol).font(.system(size: 18)).foregroundStyle(.tint)
                .frame(width: 36, height: 36)
                .background(RoundedRectangle(cornerRadius: 9).fill(Color.accentColor.opacity(0.12)))
            VStack(alignment: .leading, spacing: 4) {
                Text(tip.title).font(.headline)
                Text(tip.body).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 0)
        }
        .padding(16)
        .background(RoundedRectangle(cornerRadius: 12).fill(.background.secondary))
    }
}
