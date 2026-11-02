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

struct AppEntry: Codable, Identifiable, Equatable {
    let id, name, path: String
    let sandboxed, inside, running, hasSpace: Bool
    var bringOld: Bool
    var tz: String?
    let perms: [String]
    var block: [String]
    var location: Place?
    var mode: String
    var allow: [String]
    var allowOpen: Bool
    var reviewed: Bool
    let space: String
}

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
                self.reveal = path
                self.refresh()
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
        urls.filter { $0.pathExtension == "app" }.forEach { Store.shared.open(path: $0.path) }
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
                Button(t("在结界中打开", "Open in Kekkai")) { store.open(path: app.path) }
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
                    Text(app.sandboxed
                         ? t("以独立副本运行，数据与原 App 分开，需单独登录。", "Runs as a separate copy with its own data. Sign in separately.")
                         : t("其他文件一律不可见。", "Everything else stays hidden."))
                        .foregroundStyle(.secondary)
                }

                BlockLogSection(app: app, store: store)

                Section {
                    Toggle(t("允许打开其他 App 和链接", "Allow opening other apps and links"), isOn: Binding(
                        get: { app.allowOpen },
                        set: { v in set(["set-open", app.id, v ? "on" : "off"]) { $0.allowOpen = v } }))
                    Toggle(t("禁止剪贴板和拖放", "Block clipboard and drag and drop"), isOn: Binding(
                        get: { app.block.contains("clipboard") },
                        set: { v in set(["set-block", app.id, "clipboard", v ? "on" : "off"]) { e in
                            e.block = e.block.filter { $0 != "clipboard" } + (v ? ["clipboard"] : []) } }))
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
                } header: { Text(t("隔离", "Isolation")) } footer: {
                    Text(t("结界内时间 \(clock(app.tz))。打开其他 App 可能绕过结界。下次打开生效。", "Time inside: \(clock(app.tz)). Opening other apps can bypass Kekkai. Changes apply next launch."))
                        .foregroundStyle(.secondary)
                }

                Section {
                    HStack {
                        Button(t("摄像头", "Camera")) { openPrivacy("Privacy_Camera") }
                        Button(t("麦克风", "Microphone")) { openPrivacy("Privacy_Microphone") }
                        Button(t("定位", "Location")) { openPrivacy("Privacy_LocationServices") }
                    }
                } header: { Text(t("系统权限", "System permissions")) } footer: {
                    Text(t("由 macOS 按 App 管理。", "Managed by macOS for each app."))
                        .foregroundStyle(.secondary)
                }

            }
            .formStyle(.grouped)
            .sheet(isPresented: $picking) {
                LocationPicker(current: app.location) { place in
                    store.update(app.id) { $0.location = place }
                    store.perform(place.map { ["set-location", app.id, String($0.lat), String($0.lon), $0.mars == true ? "--mars" : "--wgs", $0.name] } ?? ["set-location", app.id, "-"])
                }
            }
        }
    }
}

struct LogItem: Codable, Identifiable {
    var id: String { key }
    let key, op, target, verb, category, last, grant: String
    let count: Int
    let recent, suspicious, normal: Bool
    var ask: Bool? = nil
    var decision: String?
}

struct BlockLog: Codable {
    let running: Bool
    var gatekeeper: Bool? = nil
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
                    if item.suspicious { Text(t("可疑", "Suspicious")).fontWeight(.semibold).foregroundStyle(.red) }
                    if item.recent { Text(t("本次", "This launch")).foregroundStyle(.blue) }
                }.font(.caption)
            }
            Spacer()
            if let d = item.decision {
                Text(d == "allow" ? t("已允许", "Allowed") : t("已拒绝", "Denied")).foregroundStyle(.secondary)
            } else if !item.grant.isEmpty {
                Button(t("拒绝", "Deny")) { decide(item, "deny") }
                Button(t("允许", "Allow")) { decide(item, "allow") }
            }
        }
    }
    func order(_ items: [LogItem]) -> [LogItem] {
        items.sorted { ($0.recent ? 0 : 1, $0.suspicious ? 0 : 1, -$0.count) < ($1.recent ? 0 : 1, $1.suspicious ? 0 : 1, -$1.count) }
    }
    /// 等你决定的：可能真需要的（你的文件夹、闪退前被挡的数据），打听类的折进分组
    var pending: [LogItem] { order((log?.items ?? []).filter { $0.ask == true && $0.decision == nil }) }
    /// 其余按类别折叠：可疑的在前，系统常规的在最后
    var groups: [(String, [LogItem])] {
        let rest = (log?.items ?? []).filter { !pending.map(\.key).contains($0.key) }
        return Dictionary(grouping: rest, by: \.category).map { ($0.key, order($0.value)) }.sorted {
            let a = ($0.1[0].normal ? 1 : 0, $0.1[0].suspicious ? 0 : 1, -$0.1.count), b = ($1.1[0].normal ? 1 : 0, $1.1[0].suspicious ? 0 : 1, -$1.1.count)
            return a < b
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
                } else if let s = l.seconds, s < 60, l.exited != nil {
                    Label(t("打开 \(s) 秒后就退出了（\(l.exitCode ?? "?")）。放行它需要的请求，再打开试试。",
                            "Quit \(s) s after opening (\(l.exitCode ?? "?")). Allow what it needs, then open it again."),
                          systemImage: "exclamationmark.triangle.fill").foregroundStyle(.orange)
                }
                if !l.errors.isEmpty {
                    DisclosureGroup(t("它自己的日志里有报错（\(l.errors.count)）", "Errors in its own log (\(l.errors.count))")) {
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
                ForEach(groups, id: \.0) { cat, items in
                    DisclosureGroup {
                        ForEach(items) { row($0) }
                    } label: {
                        HStack(spacing: 6) {
                            Text(cat)
                            Text("\(items.count)").foregroundStyle(.secondary)
                            if items[0].suspicious { Text(t("可疑", "Suspicious")).font(.caption.weight(.semibold)).foregroundStyle(.red) }
                            if items[0].normal { Text(t("多数软件都会", "Most apps do this")).font(.caption).foregroundStyle(.secondary) }
                            if items.contains(where: \.recent) { Text(t("本次", "This launch")).font(.caption).foregroundStyle(.blue) }
                        }
                    }
                }
            } else {
                ProgressView().controlSize(.small)
            }
        } header: { Text(t("拦截记录", "Block Log")) } footer: {
            Text(app.inside ? t("运行中，实时更新。上面是它可能需要的，其余一直挡着，展开分组也能放行。", "Running. Updates live. What it may need is listed first; everything else stays blocked, and you can still allow items inside each group.") : t("在结界中打开后，它被拦下的请求会出现在这里。", "Requests it makes that Kekkai blocks show up here once you open it."))
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

struct ContentView: View {
    @StateObject private var store = Store.shared
    @AppStorage("selection") private var selection: String?
    @State private var query = ""
    @State private var dropping = false
    @State private var showNever = false
    @State private var now = Date()
    private let tick = Timer.publish(every: 30, on: .main, in: .common).autoconnect()

    var shown: [AppEntry] { query.isEmpty ? store.apps : store.apps.filter { displayName($0).localizedCaseInsensitiveContains(query) || $0.name.localizedCaseInsensitiveContains(query) } }

    var body: some View {
        HSplitView {
            VStack(spacing: 0) {
                TextField(t("搜索 App", "Search apps"), text: $query).textFieldStyle(.roundedBorder).padding(10)
                List(shown, selection: $selection) { app in
                    HStack(spacing: 8) {
                        Image(nsImage: NSWorkspace.shared.icon(forFile: app.path)).resizable().frame(width: 20, height: 20)
                        Text(displayName(app)).lineLimit(1)
                        Spacer()
                        if app.inside { Circle().fill(.green).frame(width: 7, height: 7).accessibilityLabel(t("结界中", "In Kekkai")) }
                    }
                }
                Button(t("必定隔离的文件夹…", "Always-Blocked Folders…")) { showNever = true }.padding(10)
            }
            .frame(minWidth: 220, idealWidth: 250, maxWidth: 320)
            Group {
                if let app = store.apps.first(where: { $0.id == selection }) {
                    Detail(app: app, store: store, now: now)
                } else {
                    VStack(spacing: 8) {
                        Text(t("选择或拖入一个 App", "Choose or drop an app")).font(.title3)
                        Text(t("让它只看得到自己的数据", "It sees only its own data")).foregroundStyle(.secondary)
                    }.frame(maxWidth: .infinity, maxHeight: .infinity)
                }
            }
            .frame(minWidth: 380, maxWidth: .infinity, maxHeight: .infinity)
        }
        .frame(minWidth: 720, minHeight: 520)
        .overlay { if dropping { RoundedRectangle(cornerRadius: 8).stroke(Color.accentColor, lineWidth: 3).padding(4) } }
        .onDrop(of: [UTType.fileURL], isTargeted: $dropping) { providers in
            for p in providers {
                _ = p.loadObject(ofClass: URL.self) { url, _ in
                    if let url, url.pathExtension == "app" { Store.shared.open(path: url.path) }
                }
            }
            return true
        }
        .sheet(isPresented: $showNever) { NeverSheet(store: store) }
        .onReceive(tick) { now = $0 }
        .onReceive(store.$selected) { if let id = $0 { selection = id } }
        .alert(t("结界", "Kekkai"), isPresented: Binding(get: { store.message != nil }, set: { if !$0 { store.message = nil } })) {
            Button(t("好", "OK"), role: .cancel) {}
        } message: { Text(store.message ?? "") }
    }
}

@main
struct KekkaiApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var delegate
    var body: some Scene {
        WindowGroup(t("结界", "Kekkai")) { ContentView() }.windowResizability(.contentMinSize)
    }
}
