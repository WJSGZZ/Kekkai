import SwiftUI
import UniformTypeIdentifiers
import Combine
import MapKit

let isChinese = Locale.preferredLanguages.first?.hasPrefix("zh") ?? false
func t(_ zh: String, _ en: String) -> String { isChinese ? zh : en }
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
}

struct AddResult: Decodable {
    let ok: Bool
    let reason: String
    let autoEnabled: [String]
}

let tunableNames = ["allow_localhost": t("本机端口", "Ports on this Mac"), "allow_procinfo": t("其他进程信息", "Other processes"),
                    "allow_open": t("打开其他 App 与链接", "Opening other apps and links")]

enum CLI {
    static let path = NSHomeDirectory() + "/Library/Application Support/Kekkai/bin/kekkai"
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
    @Published var selected: String?
    private var timer: Timer?

    init() {
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
            message = t("\(displayName(app)) 正在结界外运行。请先完全退出它，再从结界打开。", "\(displayName(app)) is running outside Kekkai. Quit it completely first.")
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
        if app.running { return (t("在结界外运行，请先退出", "Running outside Kekkai. Quit it first."), .orange) }
        return (t("未运行", "Not running"), .secondary)
    }
    func clock(_ tz: String?) -> String {
        let f = DateFormatter()
        f.locale = isChinese ? Locale(identifier: "zh_CN") : Locale(identifier: "en_US")
        f.dateFormat = isChinese ? "M月d日 HH:mm" : "MMM d, HH:mm"
        f.timeZone = tz.flatMap(TimeZone.init(identifier:)) ?? .current
        return f.string(from: now)
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
        HStack(spacing: 16) {
            Image(nsImage: NSWorkspace.shared.icon(forFile: app.path)).resizable().frame(width: 64, height: 64)
            VStack(alignment: .leading, spacing: 6) {
                Text(displayName(app)).font(.title.weight(.semibold))
                HStack(spacing: 6) {
                    Circle().fill(status.1).frame(width: 8, height: 8)
                    Text(status.0).foregroundStyle(.secondary)
                }
            }
            Spacer()
            if app.inside {
                Button(t("停止", "Stop")) { store.perform(["stop", app.path]) }.controlSize(.large)
            } else {
                Menu {
                    Button(t("在“应用程序”中创建结界入口", "Add a Kekkai Launcher to Applications")) { store.makeLauncher(app) }
                    Divider()
                    Button(t("从结界移除…", "Remove from Kekkai…")) { removing = true }
                } label: { Text(t("在结界中打开", "Open in Kekkai")) } primaryAction: { store.open(path: app.path) }
                    .menuStyle(.button).fixedSize()
                    .buttonStyle(.borderedProminent).controlSize(.large)
                    .keyboardShortcut(.defaultAction).disabled(app.running)
            }
        }
        .padding(.horizontal, 24).padding(.top, 22).padding(.bottom, 6)
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            Form {
                Section {
                    if app.allow.isEmpty {
                        Text(t("无", "None")).foregroundStyle(.secondary)
                    }
                    ForEach(app.allow, id: \.self) { p in
                        HStack {
                            Image(systemName: "folder")
                            Text((p as NSString).abbreviatingWithTildeInPath).lineLimit(1).truncationMode(.middle)
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
                    VStack(alignment: .leading, spacing: 6) {
                        Text(app.sandboxed || app.mode == "space"
                             ? t("其他文件一律不可见。它在自己的结界文件夹里运行：第一次打开时复制了它原来的数据，之后与原 App 分开，原 App 的数据不受影响。",
                                 "Everything else stays hidden. It runs in its own Kekkai folder: its existing data was copied in at first launch, and from then on it's separate from the original app, whose data stays untouched.")
                             : t("其他文件一律不可见。它直接使用原来的数据（这个软件用书签记住数据位置，搬走会失效）。",
                                 "Everything else stays hidden. It uses its existing data in place (this app remembers its data location with a bookmark, which breaks if moved)."))
                        if app.sandboxed || app.mode == "space" {
                            HStack(spacing: 14) {
                                Button(t("从原 App 导入数据…", "Import Data from Original…")) { importing = true }
                                if app.hasSpace {
                                    Button(t("在访达中显示它的数据", "Show Its Data in Finder")) {
                                        NSWorkspace.shared.selectFile(nil, inFileViewerRootedAtPath: app.space)
                                    }
                                }
                            }.buttonStyle(.link)
                        }
                    }
                    .foregroundStyle(.secondary)
                }

                BlockLogSection(app: app, store: store)

                Section {
                    Toggle(t("剪贴板与拖放", "Clipboard and drag and drop"), isOn: Binding(
                        get: { !app.block.contains("clipboard") },
                        set: { v in set(["set-block", app.id, "clipboard", v ? "off" : "on"]) { e in
                            e.block = e.block.filter { $0 != "clipboard" } + (v ? [] : ["clipboard"]) } }))
                    Toggle(t("你的钥匙串", "Your keychain"), isOn: Binding(
                        get: { !(app.options?["keychain"] ?? false) },
                        set: { v in set(["set", app.id, "keychain", v ? "off" : "on"]) { $0.options?["keychain"] = !v } }))
                    option("procinfo", t("其他进程信息", "Other processes"))
                    option("localhost", t("本机端口", "Ports on this Mac"))
                    Toggle(t("打开其他 App 与链接", "Opening other apps and links"), isOn: Binding(
                        get: { app.allowOpen },
                        set: { v in set(["set-open", app.id, v ? "on" : "off"]) { $0.allowOpen = v } }))
                } header: { Text(t("权限", "Permissions")) } footer: {
                    let auto = (app.autoEnabled ?? []).compactMap { tunableNames[$0] }
                    if !auto.isEmpty {
                        Text(t("首次运行时自动开启了：\(auto.joined(separator: "、"))。不开它会启动失败。", "Turned on automatically at first launch: \(auto.joined(separator: ", ")). It failed to start without them."))
                            .foregroundStyle(.orange)
                    }
                    Text(t("打开即允许，默认全部关闭。“你的钥匙串”关闭时，它用结界文件夹里自己的钥匙串，登录照样能记住，只是第一次要重新登录；“本机端口”指本机上其他程序开的网络服务，如代理面板、开发服务器；允许打开其他 App 后，被打开的 App 不在结界内。下次打开生效。",
                           "On means allowed; everything is off by default. With Your keychain off, the app gets its own keychain in its Kekkai folder, so sign-ins are still remembered after you sign in once. Ports on this Mac are network services opened by other programs here, such as proxy dashboards and dev servers. Apps it opens run outside Kekkai. Changes apply next launch."))
                        .foregroundStyle(.secondary)
                }

                Section {
                    Picker(t("时区", "Time zone"), selection: Binding(
                        get: { app.tz ?? "" },
                        set: { v in set(["set-tz", app.id, v.isEmpty ? "-" : v]) { $0.tz = v.isEmpty ? nil : v } })) {
                        Text(t("跟随系统", "System default")).tag("")
                        ForEach(presetZones, id: \.1) { Text($0.0).tag($0.1) }
                        if let tz = app.tz, !presetZones.contains(where: { $0.1 == tz }) { Text(tz).tag(tz) }
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
                            Button(t("换个身份", "New Identity")) { renewing = true }
                                .disabled(app.identity == nil)
                        }
                    }
                } header: { Text(t("伪装", "Disguise")) } footer: {
                    Text(t("结界内时间 \(clock(app.tz))。它看到的序列号、硬件 UUID、网卡地址和电脑名都是结界给它的一套，每个软件各不相同，真实的读不到；机型、系统版本这类很多台 Mac 都一样的不改。换个身份后，它会把这里当成一台新 Mac，账号可能要重新验证；它自己存下的设备号要清空数据才会消失。下次打开生效。",
                           "Time inside: \(clock(app.tz)). The serial number, hardware UUID, network addresses and computer name it sees are a set Kekkai made for this app alone; it can't read the real ones. Things many Macs share, such as model and macOS version, are left as is. After New Identity it treats this as a new Mac and your account may ask you to verify again; device IDs the app saved itself go only when you clear its data. Changes apply next launch."))
                        .foregroundStyle(.secondary)
                }
                .confirmationDialog(t("给它换一套设备身份？", "Give it a new device identity?"), isPresented: $renewing) {
                    Button(t("换个身份", "New Identity")) { set(["new-identity", app.id]) { $0.identity = nil } }
                } message: {
                    Text(t("下次打开时，它会看到另一台 Mac 的序列号、硬件 UUID 和网卡地址。", "Next launch it will see another Mac's serial number, hardware UUID and network addresses."))
                }

                Section {
                    HStack {
                        Button(t("摄像头", "Camera")) { openPrivacy("Privacy_Camera") }
                        Button(t("麦克风", "Microphone")) { openPrivacy("Privacy_Microphone") }
                        Button(t("定位", "Location")) { openPrivacy("Privacy_LocationServices") }
                        Button(t("本地网络", "Local Network")) { openPrivacy("Privacy_LocalNetwork") }
                    }
                } header: { Text(t("由 macOS 管理的权限", "Permissions managed by macOS")) } footer: {
                    Text(t("在系统设置里按 App 开关。本地网络在“隐私与安全性”页的列表里，控制它能否访问局域网设备。",
                           "Set per app in System Settings. Local Network, listed on the Privacy & Security page, controls access to devices on your network."))
                        .foregroundStyle(.secondary)
                }

            }
            .formStyle(.grouped)
            .confirmationDialog(t("从结界移除 \(displayName(app))？", "Remove \(displayName(app)) from Kekkai?"), isPresented: $removing) {
                Button(t("移除", "Remove"), role: .destructive) { store.perform(["remove", app.path]); store.selected = nil }
            } message: {
                Text(t("只是从列表里拿掉。它的结界文件夹和设置会留着，以后再添加接着用。", "It's only taken off the list. Its Kekkai folder and settings stay, ready if you add it again."))
            }
            .confirmationDialog(t("用原 App 的数据替换它在结界里的数据？", "Replace its data in Kekkai with the original app's data?"), isPresented: $importing) {
                Button(t("导入", "Import"), role: .destructive) { store.perform(["import", app.path]) }
            } message: {
                Text(t("它会先停止。原 App 的数据不动；结界文件夹里的数据会被替换。",
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
                        Label(t("macOS 不让它运行：它从网上下载，且没有经过苹果公证。", "macOS won't run it: it was downloaded and isn't notarized by Apple."),
                              systemImage: "lock.shield").foregroundStyle(.orange)
                        Text(t("确认来源可信，到“隐私与安全性”底部点“仍要打开”，再回到这里打开。", "If you trust it, click Open Anyway at the bottom of Privacy & Security, then open it here again."))
                            .foregroundStyle(.secondary)
                        Button(t("打开隐私与安全性", "Open Privacy & Security")) {
                            NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.settings.PrivacySecurity.extension")!)
                        }
                    }
                } else if l.receipt == true {
                    Label(t("这是 App Store 软件，启动时校验购买凭证，结界的副本过不了校验，无法在结界中运行。原版本身已有苹果沙盒，可以直接用原版。",
                            "This App Store app checks its purchase receipt at launch, and Kekkai's copy can't pass that check, so it can't run in Kekkai. The original already runs in Apple's sandbox, so use it directly."),
                          systemImage: "bag").foregroundStyle(.orange)
                } else if let s = l.seconds, s < 60, l.exited != nil {
                    Label(t("打开 \(s) 秒后就退出了（\(l.exitCode ?? "?")）。放行它需要的请求，再打开试试。",
                            "Quit \(s) s after opening (\(l.exitCode ?? "?")). Allow what it needs, then open it again."),
                          systemImage: "exclamationmark.triangle.fill").foregroundStyle(.orange)
                }
                if !l.errors.isEmpty {
                    Fold(isOpen: Binding(get: { open.contains("errors") }, set: { if $0 { open.insert("errors") } else { open.remove("errors") } })) {
                        Text(t("它自己的日志里有报错（\(l.errors.count)）", "Errors in its own log (\(l.errors.count))"))
                    } content: {
                        ForEach(l.errors, id: \.self) { Text($0).font(.caption.monospaced()).foregroundStyle(.secondary).lineLimit(2) }
                    }
                }
                if changed && app.inside {
                    HStack {
                        Text(t("已放行的请求重新打开后生效。", "Allowed requests take effect after reopening.")).foregroundStyle(.secondary)
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
            Text(app.inside ? t("实时更新，以上请求均已拦截。最前面几条它可能真的需要，可以逐条放行。越权：超出它本职的探查。留意：可能正常，但你该知道。常规：系统框架自动发出，不影响使用。", "Updates live. Everything above is blocked. The first items may be needed for the app to work and can be allowed one by one. Overreach: probing beyond what the app is for. Worth a look: may be normal, but you should know. Routine: sent by system frameworks on their own, harmless to block.") : t("以上请求均已拦截。在结界中运行时实时更新。", "Everything above is blocked. Updates live while the app runs in Kekkai."))
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

struct LocationPicker: View {
    let current: Place?
    let done: (Place?) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var position: MapCameraPosition = .automatic
    @State private var pin: Place?  // 存地图坐标，确定时再换算
    @State private var resolving = false
    @State private var query = ""
    @State private var results: [MKMapItem] = []

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

    var body: some View {
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
            HStack {
                Text(pin.map { $0.name } ?? t("搜索地点，或在地图上点一下", "Search for a place, or click the map")).foregroundStyle(.secondary).lineLimit(1)
                Spacer()
                if current != nil { Button(t("关闭虚拟位置", "Turn Off")) { done(nil); dismiss() } }
                Button(t("取消", "Cancel")) { dismiss() }.keyboardShortcut(.cancelAction)
                Button(t("使用这个位置", "Use This Location"), action: use)
                    .keyboardShortcut(.defaultAction).buttonStyle(.borderedProminent).disabled(pin == nil || resolving)
            }
            .padding(12)
        }
        .frame(width: 640, height: 520)
        .onAppear {
            pin = current.map { Place(lat: $0.mapCoordinate.latitude, lon: $0.mapCoordinate.longitude, name: $0.name) }
            if let c = current?.mapCoordinate { position = .region(MKCoordinateRegion(center: c, latitudinalMeters: 3000, longitudinalMeters: 3000)) }
        }
    }
}

struct NeverSheet: View {
    @ObservedObject var store: Store
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(t("必定隔离的文件夹", "Always-Blocked Folders")).font(.title3.weight(.semibold))
            Text(t("从结界打开的 App 一律无法访问，优先于任何放行。", "Apps opened from Kekkai can never access these. This overrides any allowed folder."))
                .foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            List(store.never, id: \.self) { p in
                HStack {
                    Text(p).lineLimit(1).truncationMode(.middle)
                    Spacer()
                    Button(t("移除", "Remove")) { store.loadNever(["never", "rm", p]) }
                }
            }
            .frame(minHeight: 180)
            HStack {
                Button(t("添加文件夹…", "Add Folder…")) {
                    let panel = NSOpenPanel()
                    panel.canChooseDirectories = true
                    panel.canChooseFiles = false
                    panel.allowsMultipleSelection = true
                    if panel.runModal() == .OK { panel.urls.forEach { store.loadNever(["never", "add", $0.path]) } }
                }
                Spacer()
                Button(t("完成", "Done")) { dismiss() }.keyboardShortcut(.defaultAction)
            }
        }
        .padding(20)
        .frame(width: 520)
    }
}

/// 网格里的一个软件：大图标、名字，在结界里运行时右下角一个绿点
struct AppTile: View {
    let app: AppEntry
    let selected: Bool
    @State private var hover = false

    var body: some View {
        VStack(spacing: 8) {
            Image(nsImage: NSWorkspace.shared.icon(forFile: app.path)).resizable().interpolation(.high)
                .frame(width: 72, height: 72)
                .overlay(alignment: .bottomTrailing) {
                    if app.inside {
                        Circle().fill(.green).frame(width: 12, height: 12)
                            .overlay(Circle().stroke(Color(nsColor: .windowBackgroundColor), lineWidth: 2.5))
                            .accessibilityLabel(t("在结界中运行", "Running in Kekkai"))
                    }
                }
            Text(displayName(app)).font(.callout).lineLimit(2).multilineTextAlignment(.center)
                .frame(height: 34, alignment: .top)
        }
        .padding(.top, 14).padding(.horizontal, 8).frame(width: 116)
        .background(RoundedRectangle(cornerRadius: 12, style: .continuous)
            .fill(selected ? Color.accentColor.opacity(0.16) : hover ? Color.primary.opacity(0.05) : .clear))
        .contentShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
        .onHover { hover = $0 }
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
                Text(t("添加时会在结界里试运行一次，能正常启动才加进来。", "Kekkai runs it once as a trial and adds it only if it starts properly."))
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
                Text(r.ok ? t("已添加 \(name)", "\(name) added") : t("\(name) 不能在结界中运行", "\(name) can't run in Kekkai"))
                    .font(.title3.weight(.semibold))
                Group {
                    if r.ok {
                        let auto = r.autoEnabled.compactMap { tunableNames[$0] }
                        Text(auto.isEmpty ? t("所有权限关着也能运行。它现在正在结界里运行，以后双击图标即可打开。", "It runs with every permission off. It's running in Kekkai now; double-click its icon to open it later.")
                             : t("为了能运行，自动开启了：\(auto.joined(separator: "、"))。它现在正在结界里运行。", "To run, it needed: \(auto.joined(separator: ", ")). It's running in Kekkai now."))
                    } else {
                        Text(r.reason + t("\n没有添加。", "\nIt wasn't added."))
                    }
                }
                .font(.callout).foregroundStyle(.secondary).multilineTextAlignment(.center).fixedSize(horizontal: false, vertical: true)
            } else {
                Text(t("正在结界里试运行 \(name)", "Trying \(name) in Kekkai")).font(.title3.weight(.semibold))
                ProgressView().controlSize(.small)
                Text(t("它会打开一会儿。所有权限关着撑得住就添加；撑不住会逐项试出它离不开的权限。通常二十多秒，最长约两分钟。",
                       "It opens for a moment. If it holds up with every permission off, it's added; if not, Kekkai finds the permissions it can't do without. Usually about 20 seconds, at most about two minutes."))
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
    @State private var showNever = false
    @State private var adding = false
    @State private var now = Date()
    private let tick = Timer.publish(every: 30, on: .main, in: .common).autoconnect()

    var added: [AppEntry] {
        let all = store.apps.filter { $0.added == true }
        return query.isEmpty ? all : all.filter { displayName($0).localizedCaseInsensitiveContains(query) || $0.name.localizedCaseInsensitiveContains(query) }
    }

    var body: some View {
        Group {
            if store.apps.contains(where: { $0.added == true }) {
                ScrollView {
                    LazyVGrid(columns: [GridItem(.adaptive(minimum: 116, maximum: 132), spacing: 6)], spacing: 10) {
                        ForEach(added) { app in
                            AppTile(app: app, selected: selection == app.id)
                                .onTapGesture(count: 2) { store.launch(app) }
                                .simultaneousGesture(TapGesture().onEnded { selection = app.id })
                                .contextMenu { menu(app) }
                                .help(t("双击在结界中打开", "Double-click to open in Kekkai"))
                        }
                    }
                    .padding(24)
                }
                .background(Color(nsColor: .windowBackgroundColor).onTapGesture { selection = nil })
            } else {
                VStack(spacing: 10) {
                    Image(systemName: "square.dashed").font(.system(size: 44, weight: .ultraLight)).foregroundStyle(.tertiary)
                    Text(t("还没有软件", "No apps yet")).font(.title3.weight(.medium))
                    Text(t("添加后，它只看得到自己的数据。", "Once added, an app sees only its own data.")).foregroundStyle(.secondary)
                    Button(t("添加软件…", "Add an App…")) { adding = true }.controlSize(.large).padding(.top, 6)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .frame(minWidth: 560, minHeight: 420)
        .navigationTitle(t("结界", "Kekkai"))
        .searchable(text: $query, placement: .toolbar, prompt: t("搜索", "Search"))
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button { adding = true } label: { Label(t("添加软件", "Add App"), systemImage: "plus") }
                    .help(t("添加软件", "Add an app"))
            }
            ToolbarItem(placement: .primaryAction) {
                Menu {
                    Button(t("必定隔离的文件夹…", "Always-Blocked Folders…")) { showNever = true }
                } label: { Label(t("更多", "More"), systemImage: "ellipsis.circle") }
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
        .sheet(isPresented: $showNever) { NeverSheet(store: store) }
        .onReceive(tick) { now = $0 }
        .onReceive(store.$selected) { if let id = $0 { selection = id } }
        .alert(t("结界", "Kekkai"), isPresented: Binding(get: { store.message != nil }, set: { if !$0 { store.message = nil } })) {
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
            Button(t("在访达中显示它的数据", "Show Its Data in Finder")) { NSWorkspace.shared.selectFile(nil, inFileViewerRootedAtPath: app.space) }
        }
        Divider()
        Button(t("从结界移除", "Remove from Kekkai")) { store.perform(["remove", app.path]); if selection == app.id { selection = nil } }
    }
}

@main
struct KekkaiApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var delegate
    var body: some Scene {
        WindowGroup(t("结界", "Kekkai")) { ContentView() }.windowResizability(.contentMinSize)
    }
}
