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
    var added: Bool? = nil
    var clipboard: String? = nil
    var injectable: Bool? = nil
    var canClone: Bool? = nil
    var outside: [String]? = nil
}

struct AddResult: Decodable {
    let ok: Bool
    let reason: String
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
        for name in (try? fm.contentsOfDirectory(atPath: src.path)) ?? [] {
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
    private var timer: Timer?

    init() {
        Support.install()
        refresh()
        loadNever()
        timer = Timer.scheduledTimer(withTimeInterval: 3, repeats: true) { [weak self] _ in self?.refresh() }
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
        if app.inside, let running = NSRunningApplication.runningApplications(withBundleIdentifier: app.id).first {
            running.activate()
        } else if app.running {
            message = t("\(displayName(app)) 正在结界外运行，请先退出后再打开。", "\(displayName(app)) is running outside Kekkai. Quit it completely first.")
        } else {
            open(path: app.path)
        }
    }

    @Published var pendingAdd: PendingAdd?

    func makeLauncher(_ app: AppEntry) {
        DispatchQueue.global().async {
            let r = CLI.call(["launcher", app.path, displayName(app)])
            DispatchQueue.main.async {
                guard r.ok else { self.message = r.out; return }
                NSWorkspace.shared.setIcon(NSWorkspace.shared.icon(forFile: app.path), forFile: r.out, options: [])
                NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: r.out)])
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
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }
}

func openPrivacy(_ anchor: String) {
    NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?\(anchor)")!)
}

let presetZones: [(String, String)] = [
    (t("上海（UTC+8）", "Shanghai (UTC+8)"), "Asia/Shanghai"), (t("香港（UTC+8）", "Hong Kong (UTC+8)"), "Asia/Hong_Kong"), (t("东京（UTC+9）", "Tokyo (UTC+9)"), "Asia/Tokyo"),
    (t("新加坡（UTC+8）", "Singapore (UTC+8)"), "Asia/Singapore"), (t("伦敦", "London"), "Europe/London"), (t("巴黎", "Paris"), "Europe/Paris"),
    (t("纽约", "New York"), "America/New_York"), (t("洛杉矶", "Los Angeles"), "America/Los_Angeles"), (t("世界协调时 UTC", "UTC"), "Etc/UTC"),
]

struct Detail: View {
    let app: AppEntry
    @ObservedObject var store: Store
    let now: Date
    @State private var picking = false
    @State private var renewing = false
    @State private var importing = false
    @State private var removing = false

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
                } header: { Text(t("允许访问的文件夹", "Allowed folders")) } footer: {
                    Text(t("仅可访问以上文件夹和自身数据。", "Only these folders and its own data are accessible."))
                        .foregroundStyle(.secondary)
                }

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

                BlockLogSection(app: app, store: store)

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
                } header: { Text(t("权限", "Permissions")) } footer: {
                    let auto = (app.autoEnabled ?? []).compactMap { tunableNames[$0] }
                    if !auto.isEmpty {
                        Text(t("添加时自动开启：\(auto.joined(separator: "、"))（关闭后无法启动）。", "Turned on automatically at first launch: \(auto.joined(separator: ", ")). It failed to start without them."))
                            .foregroundStyle(.orange)
                    }
                    Text(t("开启即允许，更改在下次打开时生效。经它打开的其他 App 不受结界限制。", "On means allowed. Changes take effect next launch. Apps it opens run outside Kekkai."))
                        .foregroundStyle(.secondary)
                }

                Section {
                    Picker(t("时区", "Time zone"), selection: Binding(
                        get: { app.tz ?? "" },
                        set: { v in set(["set-tz", app.id, v.isEmpty ? "-" : v]) { $0.tz = v.isEmpty ? nil : v } })) {
                        if let zone = app.zone, app.tz == nil {
                            Text(t("自动（\(zone)）", "Automatic (\(zone))")).tag("")
                        } else {
                            Text(t("跟随系统", "System default")).tag("")
                        }
                        if app.location != nil || app.tz == "location" {
                            Text(app.tz == "location" && app.location != nil
                                 ? t("跟随虚拟位置（\(app.zone ?? "")）", "Match virtual location (\(app.zone ?? ""))")
                                 : t("跟随虚拟位置", "Match virtual location")).tag("location")
                        }
                        ForEach(presetZones, id: \.1) { Text($0.0).tag($0.1) }
                        if let tz = app.tz, tz != "location", !presetZones.contains(where: { $0.1 == tz }) { Text(tz).tag(tz) }
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
                    if app.canClone ?? false {
                        option("clone", t("以可注入副本运行", "Run as an injectable copy"))
                    }
                } header: { Text(t("伪装", "Disguise")) } footer: {
                    if app.canClone ?? false {
                        Text(t("该软件的签名不允许注入，设备信息仅能屏蔽。开启后运行可注入的副本，系统权限需重新授权。", "This app's signature doesn't allow injection, so device information can only be blocked. When on, Kekkai runs an injectable copy; system permissions must be granted again."))
                            .foregroundStyle(.secondary)
                    }
                    Text(t("结界内时间：\(clock(app.zone ?? app.tz))\(languageName.map { "，语言：" + $0 } ?? "")。序列号、硬件 UUID、网卡地址和电脑名为该软件专用，各软件互不相同。", "Time inside: \(clock(app.zone ?? app.tz))\(languageName.map { ". Language: " + $0 } ?? ""). The serial number, hardware UUID, network addresses and computer name are unique to this app."))
                        .foregroundStyle(.secondary)
                }
                .confirmationDialog(t("重置设备身份？", "Reset device identity?"), isPresented: $renewing) {
                    Button(t("重置设备身份", "Reset Device Identity")) { set(["new-identity", app.id]) { $0.identity = nil } }
                } message: {
                    Text(t("下次打开时将使用新的设备信息，账号可能需要重新验证。软件自行保存的设备标识需清除数据后失效。", "New device information is used next launch, and accounts may ask for verification again. Device IDs the app saved itself remain until its data is cleared."))
                }

                Section {
                    HStack {
                        Button(t("摄像头", "Camera")) { openPrivacy("Privacy_Camera") }
                        Button(t("麦克风", "Microphone")) { openPrivacy("Privacy_Microphone") }
                        Button(t("定位", "Location")) { openPrivacy("Privacy_LocationServices") }
                        Button(t("本地网络", "Local Network")) { openPrivacy("Privacy_LocalNetwork") }
                    }
                } header: { Text(t("由 macOS 管理的权限", "Permissions managed by macOS")) } footer: {
                    Text(t("在系统设置中按 App 授权。", "Granted per app in System Settings."))
                        .foregroundStyle(.secondary)
                }

            }
            .formStyle(.grouped)
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
                }
                HStack(spacing: 6) {
                    Text(item.category).foregroundStyle(.secondary)
                    if item.count > 1 { Text("×\(item.count)").foregroundStyle(.secondary) }
                    if item.recent { Text(t("本次运行", "This run")).foregroundStyle(.blue) }
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

    func tag(_ level: String) -> some View {
        let (text, color): (String, Color) = switch level {
        case "overreach": (t("越权", "Overreach"), .red)
        case "note": (t("留意", "Worth a look"), .orange)
        default: (t("常规", "Routine"), .secondary)
        }
        return Text(text).font(.caption.weight(.semibold)).foregroundStyle(color)
    }
    func group(_ title: String, _ items: [LogItem], level: String) -> some View {
        Fold(isOpen: Binding(get: { open.contains(title) }, set: { if $0 { open.insert(title) } else { open.remove(title) } })) {
            HStack(spacing: 6) {
                Text(title)
                Text("\(items.count)").foregroundStyle(.secondary)
                tag(level)
                if items.contains(where: \.recent) { Text(t("本次运行", "This run")).font(.caption).foregroundStyle(.blue) }
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
            Text(app.inside ? t("实时更新。排在前面的项目可能为正常运行所需，可逐项放行。", "Updates live. Items near the top may be needed for the app to work and can be allowed individually.") : t("在结界中运行时实时更新。", "Updates live while the app runs in Kekkai."))
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
        let c = item.location.coordinate
        pin = Place(lat: c.latitude, lon: c.longitude, name: item.name ?? "")
        position = .region(MKCoordinateRegion(center: c, latitudinalMeters: 2000, longitudinalMeters: 2000))
        results = []
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
                                Text(item.address?.shortAddress ?? "").font(.caption).foregroundStyle(.secondary)
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
            Text(t("所有软件均无法访问以下文件夹，优先于单个软件的设置。", "No app in Kekkai can access these folders, regardless of per-app settings."))
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

    var body: some View {
        VStack(spacing: 4) {
            Image(nsImage: NSWorkspace.shared.icon(forFile: app.path)).resizable().interpolation(.high)
                .frame(width: 64, height: 64)
                .overlay(alignment: .bottomTrailing) {
                    if app.inside {
                        Circle().fill(.green).frame(width: 11, height: 11)
                            .overlay(Circle().stroke(Color(nsColor: .windowBackgroundColor), lineWidth: 2))
                            .accessibilityLabel(t("在结界中运行", "Running in Kekkai"))
                    }
                }
                .padding(5)
                .background(RoundedRectangle(cornerRadius: 6).fill(selected ? Color.primary.opacity(0.1) : .clear))
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
                        Image(systemName: r.ok ? "checkmark.circle.fill" : "xmark.circle.fill")
                            .font(.system(size: 28)).symbolRenderingMode(.palette)
                            .foregroundStyle(.white, r.ok ? Color.green : Color.red)
                            .background(Circle().fill(Color(nsColor: .windowBackgroundColor)).padding(-2))
                    }
                }
            if let r = result {
                Text(r.ok ? t("已添加 \(name)", "\(name) added") : t("\(name) 无法在结界中运行", "\(name) can't run in Kekkai"))
                    .font(.title3.weight(.semibold))
                Group {
                    if r.ok {
                        let auto = r.autoEnabled.compactMap { tunableNames[$0] }
                        Text(auto.isEmpty ? t("所有权限关闭时运行正常，已在结界中打开。之后可双击图标启动。", "It runs with every permission off. It's running in Kekkai now; double-click its icon to open it later.")
                             : t("已自动开启必需权限：\(auto.joined(separator: "、"))。已在结界中打开。", "To run, it needed: \(auto.joined(separator: ", ")). It's running in Kekkai now."))
                    } else {
                        Text(r.reason + t("\n未添加。", "\nIt wasn't added."))
                    }
                }
                .font(.callout).foregroundStyle(.secondary).multilineTextAlignment(.center).fixedSize(horizontal: false, vertical: true)
            } else {
                Text(t("正在试运行 \(name)", "Trying \(name) in Kekkai")).font(.title3.weight(.semibold))
                ProgressView().controlSize(.small)
                Text(t("先关闭所有权限运行，无法运行时逐项检测必需权限。约需 20 秒，最长 2 分钟。",
                       "Runs with all permissions off first, then checks which ones are required if needed. About 20 seconds, up to 2 minutes."))
                    .font(.callout).foregroundStyle(.secondary).multilineTextAlignment(.center).fixedSize(horizontal: false, vertical: true)
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
}

struct ContentView: View {
    @StateObject private var store = Store.shared
    @State private var selection: String?
    @State private var query = ""
    @State private var dropping = false
    @State private var adding = false
    @State private var now = Date()
    private let tick = Timer.publish(every: 30, on: .main, in: .common).autoconnect()

    var added: [AppEntry] {
        let all = store.apps.filter { $0.added == true }
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
                                AppTile(app: app, selected: selection == app.id)
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

    @ViewBuilder func menu(_ app: AppEntry) -> some View {
        if app.inside {
            Button(t("切换到它", "Switch to It")) { store.launch(app) }
            Button(t("停止", "Stop")) { store.perform(["stop", app.path]) }
        } else {
            Button(t("在结界中打开", "Open in Kekkai")) { store.launch(app) }
        }
        Button(t("设置…", "Settings…")) { selection = app.id }
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
        WindowGroup(t("结界", "Kekkai")) { ContentView() }
            .windowResizability(.contentMinSize)
            .windowToolbarStyle(.unified)
        Settings { SettingsView() }
        Window(t("结界使用说明", "Kekkai Help"), id: "help") { HelpView() }
            .windowResizability(.contentSize)
            .commands { HelpCommands() }
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

/// 使用说明：随 App 带着，不联网
let helpSections: [(String, [String])] = isChinese ? [
    ("开始使用", [
        "点按工具栏中的“添加”按钮，或将 App 拖入窗口。添加时将进行一次试运行，App 在约 20 秒内正常启动方可加入；未能启动时将显示原因，并清除试运行产生的文件。",
        "连按图标可在结界中打开 App，单击图标可查看设置和拦截记录。按住 Control 点按图标，可在“应用程序”中创建结界入口，供程序坞和聚焦使用。",
        "打开前请完全退出原 App。通过原图标打开的 App 不受结界保护。",
    ]),
    ("隔离范围", [
        "文件：仅可访问自身数据和已批准的文件夹，其他位置均显示为不存在。",
        "设备信息：序列号、硬件 UUID、网卡地址等替换为该 App 专用的值，各 App 之间互不相同。",
        "其他程序：无法查看其他进程、运行中的软件和窗口，无法用聚焦搜索列出已装软件，无法连接本机其他程序提供的端口，无法打开其他 App。",
        "剪贴板：默认可随时写入，仅在按下 ⌘V 或选择“粘贴”后可读取。",
        "局域网：可注入的 App 无法连接局域网中的设备，也无法发现 Bonjour 服务；DNS 和系统代理不受影响。不可注入的 App 由 macOS 的“本地网络”权限控制，建议在“系统设置 › 隐私与安全性 › 本地网络”中保持关闭。",
        "语言与地区：可注入的 App 看到的首选语言仅保留一种，地区为该语言最常见的地区，如简体中文对应中国。未单独设置时区时，系统时区换为该地区中钟点完全相同的时区，如台北换为上海。",
    ]),
    ("数据与登录", [
        "首次打开时，结界将原 App 的数据复制到该 App 的结界文件夹，此后两者相互独立，原数据保持不变。如需更新，可在“数据”一栏重新导入。",
        "QQ、微信等自带 App 沙盒的 App 以副本运行。登录状态由系统按签名保存，无法导入，首次打开需重新登录。",
        "每个 App 使用其结界文件夹中的独立钥匙串，无法读取你的钥匙串。",
    ]),
    ("权限", [
        "设置中的权限默认全部关闭，开启即允许，更改在下次打开 App 时生效。",
        "本机端口：指本机其他程序提供的网络服务，如代理面板和开发服务器。关闭时仅可连接结界为其分配的端口；可注入的 App 自行打开的端口将移入该范围。",
        "局域网设备：开启后可连接局域网中的设备并使用 Bonjour，如投屏和局域网传输。",
        "打开其他 App 与链接：开启后，经它打开的 App 和网页不受结界限制。",
        "拦截记录分三档：越权为超出其功能所需的探查；留意为可能正常但值得关注的请求；常规为系统框架自动发出的请求，不影响使用。",
        "App 功能异常时，请先查看拦截记录。排在前面且标有“本次运行”的项目最可能相关，可逐项放行。",
    ]),
    ("常见问题", [
        "无法添加：App Store 付费 App 会校验购买凭证，副本无法通过校验，因此不受支持。其他原因见提示信息。",
        "导入失败：请在“系统设置 › 隐私与安全性 › 完全磁盘访问权限”中开启“结界”。",
        "摄像头、麦克风、定位：由 macOS 管理，可通过设置底部的按钮前往对应的系统设置。",
        "以可注入副本运行：部分 App 的签名不允许注入。添加这类 App 时，结界先运行去除强化运行时的 APFS 克隆副本（几乎不占用额外空间），试运行失败才改用原版。原版无法替换设备信息，且可看到运行中的软件、窗口列表、显示器序列号和电脑名。原 App 更新后，副本在下次打开时重建；副本功能异常时，可在“伪装”一栏关闭。",
        "结界外的组件：网盘同步扩展、登录项、特权助手等由系统直接启动，不受结界限制。结界禁止 App 在其中注册此类组件；已存在的会列在设置顶部，可在“系统设置 › 通用 › 登录项与扩展”中关闭。",
        "原地运行：少数 App（如腾讯会议官网版）以书签记录数据位置，只能在原位置运行，此时主目录路径中的账户名对其可见。",
        "电脑名：不可注入的 App 可读取真实电脑名。如电脑名包含本人姓名，建议在“系统设置 › 通用 › 关于本机”中修改。",
        "重置设备身份：该 App 将把本机识别为新设备，账号可能需要重新验证；App 自行保存的设备标识需清除数据后失效。机型、系统版本等非唯一信息保持不变。",
        "时区：可按 App 单独设置。使用代理的 App，建议将时区设为代理出口所在地区；两者不一致时更易被识别。设置虚拟位置后可选“跟随虚拟位置”，时区按该位置确定，查询使用 macOS 自带的时区边界数据，不联网；未设置虚拟位置时按“自动”处理。",
    ]),
    ("隐私", [
        "结界本身不联网。仅当在虚拟位置中选择“在地图上选择”时加载 Apple 地图。",
        "结界保护的是本机信息。基于 IP 地址的定位，以及基于账号和使用习惯的识别，不在其保护范围内。",
    ]),
] : [
    ("Getting Started", [
        "Click Add in the toolbar, or drag an app into the window. Adding performs a trial run: the app is added only if it starts within about 20 seconds. Otherwise Kekkai shows the reason and removes the files the trial created.",
        "Double-click an icon to open the app in Kekkai; click once to view its settings and Block Log. Control-click an icon to create a Kekkai launcher in Applications for the Dock and Spotlight.",
        "Quit the original app completely first. An app opened from its own icon isn't protected by Kekkai.",
    ]),
    ("What Is Isolated", [
        "Files: only the app's own data and approved folders are accessible. All other locations appear not to exist.",
        "Device information: the serial number, hardware UUID, network addresses and similar values are replaced with values unique to the app.",
        "Other programs: the app can't see other processes, running apps or their windows, list installed apps through Spotlight, connect to ports opened by other programs on this Mac, or open other apps.",
        "Clipboard: by default the app can write at any time and read only after you press ⌘V or choose Paste.",
        "Local network: injectable apps can't connect to devices on the local network or discover Bonjour services. DNS and the system proxy are unaffected. Apps that can't be injected are governed by the macOS Local Network permission; keep it off in System Settings › Privacy & Security › Local Network.",
        "Language and region: injectable apps see a single preferred language, with the region most common for it, such as China for Simplified Chinese. Unless a time zone is set for the app, the system time zone is replaced with one in that region that keeps exactly the same clock, such as Shanghai for Taipei.",
    ]),
    ("Data and Sign-In", [
        "At first launch, Kekkai copies the original app's data into the app's Kekkai folder. The two are independent after that, and the original data is unchanged. To update it, import again from the Data section.",
        "Apps that include Apple's App Sandbox, such as QQ and WeChat, run as a copy. Sign-in state is stored by macOS per signature and can't be imported; sign in again at first launch.",
        "Each app uses a separate keychain in its Kekkai folder and can't read your keychain.",
    ]),
    ("Permissions", [
        "All permissions in Settings are off by default. Turning one on allows it; changes take effect the next time the app opens.",
        "Ports on this Mac: network services provided by other programs, such as proxy dashboards and development servers. When off, the app can connect only to the ports Kekkai assigns it; for injectable apps, ports the app opens itself are moved into that range.",
        "Devices on the local network: when on, the app can connect to devices on the local network and use Bonjour, for screen mirroring or local file transfer, for example.",
        "Opening other apps and links: when on, apps and web pages it opens run outside Kekkai.",
        "The Block Log has three levels: Overreach is probing beyond what the app needs; Worth a look may be normal but deserves attention; Routine is sent automatically by system frameworks and is harmless to block.",
        "If the app doesn't work as expected, check the Block Log first. Items near the top marked This Run are the most likely cause and can be allowed individually.",
    ]),
    ("Troubleshooting", [
        "Can't add an app: paid App Store apps verify their purchase receipt, which a copy can't pass, so they aren't supported. Other reasons are shown in the message.",
        "Import fails: turn on Kekkai in System Settings › Privacy & Security › Full Disk Access.",
        "Camera, microphone and location: managed by macOS. Use the buttons at the bottom of an app's settings to open the relevant System Settings pane.",
        "Run as an injectable copy: some apps' signatures don't allow injection. When adding such an app, Kekkai first runs an APFS clone without the hardened runtime (using almost no additional space) and uses the original only if the copy fails its trial run. The original can't have its device information replaced and can see running apps, the window list, the display serial and the computer name. The copy is rebuilt at next launch after the original app updates; if it misbehaves, turn it off in Disguise.",
        "Components outside Kekkai: sync extensions, login items, privileged helpers and similar components are started by macOS and aren't restricted by Kekkai. Apps in Kekkai can't register them; existing ones are listed at the top of the app's settings and can be turned off in System Settings › General › Login Items & Extensions.",
        "Running in place: a few apps, such as Tencent Meeting's direct download, record their data location in bookmarks and must run in place. Your account name in the home folder path is then visible to them.",
        "Computer name: apps that can't be injected can read the real computer name. If it contains your name, change it in System Settings › General › About.",
        "Reset device identity: the app treats this Mac as a new device, and accounts may ask for verification again. Device IDs the app saved itself remain until its data is cleared. Non-unique details such as model and macOS version are unchanged.",
        "Time zone: set per app. For an app that uses a proxy, set the time zone to the proxy's region; a mismatch makes identification easier. With a virtual location set, choose Match Virtual Location to use that location's time zone. The lookup uses time zone boundary data included with macOS and works offline; without a virtual location, Automatic applies.",
    ]),
    ("Privacy", [
        "Kekkai doesn't connect to the internet. Apple Maps loads only when you click Choose on a Map in the virtual-location picker.",
        "Kekkai protects information on this Mac. Location by IP address, and identification by account or usage patterns, are outside its scope.",
    ]),
]

struct HelpView: View {
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 22) {
                ForEach(helpSections, id: \.0) { section in
                    VStack(alignment: .leading, spacing: 8) {
                        Text(section.0).font(.title3.weight(.semibold))
                        ForEach(section.1, id: \.self) { Text($0).fixedSize(horizontal: false, vertical: true) }
                    }
                }
            }
            .textSelection(.enabled)
            .padding(28)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .frame(width: 560, height: 620)
    }
}
