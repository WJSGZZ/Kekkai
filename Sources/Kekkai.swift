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
            DispatchQueue.main.async { if self.apps != list { self.apps = list } }
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

    func open(path: String) { perform(["run", path]) }

    func loadNever(_ args: [String] = ["never", "list"]) {
        DispatchQueue.global().async {
            let r = CLI.call(args)
            let list = (try? JSONDecoder().decode([String].self, from: Data(r.out.utf8))) ?? []
            DispatchQueue.main.async { if r.ok { self.never = list } else { self.message = r.out } }
        }
    }

    func showBlocked(path: String) {
        DispatchQueue.global().async {
            let r = CLI.call(["blocked", path])
            DispatchQueue.main.async {
                if r.ok { NSWorkspace.shared.open(URL(fileURLWithPath: r.out)) } else { self.message = r.out }
            }
        }
    }

    func showReport(path: String) {
        DispatchQueue.global().async {
            let r = CLI.call(["report", path])
            DispatchQueue.main.async {
                if r.ok { NSWorkspace.shared.open(URL(fileURLWithPath: r.out)) } else { self.message = t("先用学习模式运行一次，才有访问记录。", "Run the app in Learn Mode first to get an access log.") }
            }
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
    @State private var trying = false

    var status: (String, Color) {
        if app.inside { return (t("在结界中运行", "Running in Kekkai"), .green) }
        if app.running { return (t("在结界外运行，请先完全退出", "Running outside Kekkai. Quit it first."), .orange) }
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
                Button(app.reviewed ? t("在结界中打开", "Open in Kekkai") : t("试运行并打开", "Try and Open")) {
                    if app.reviewed { store.open(path: app.path) } else { trying = true }
                }
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
                        Text(t("没有。它只看得到自己的数据。", "None. It can only see its own data.")).foregroundStyle(.secondary)
                    }
                    ForEach(app.allow, id: \.self) { p in
                        HStack {
                            Image(systemName: "folder")
                            Text((p as NSString).abbreviatingWithTildeInPath).lineLimit(1).truncationMode(.middle)
                            Spacer()
                            Button(t("移除", "Remove")) { set(["allow", app.id, "rm", p]) { $0.allow.removeAll { $0 == p } } }
                        }
                    }
                    Button(t("批准一个文件夹…", "Allow a Folder…")) {
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
                         ? t("它照常用自己原来的数据，别的文件一律看不到。它自带苹果沙盒，结界会用一份去掉苹果沙盒的副本运行，原 App 不动；副本签名不同，可能要重新登录一次。", "It keeps using its own data and can't see anything else. Because it already has Apple's sandbox, Kekkai runs an unsandboxed copy and leaves the original alone. The copy is signed differently, so you may need to sign in once.")
                         : t("它照常用自己原来的数据，别的文件一律看不到，包括下载、桌面和文稿。要存下载的文件时，批准一个文件夹给它。", "It keeps using its own data and can't see anything else, including Downloads, Desktop and Documents. If it needs to save downloads, allow a folder here."))
                        .foregroundStyle(.secondary)
                }

                Section {
                    Toggle(t("允许打开其他软件和链接", "Allow opening other apps and links"), isOn: Binding(
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
                    Text(t("结界内显示 \(clock(app.tz))。它拉起的软件不在结界里，所以默认不许它打开其他软件，也不能用浏览器打开链接，要用时再打开。剪贴板关掉后复制、粘贴都不能用。虚拟位置只骗过向系统要定位的软件，按 IP 判断位置的骗不过；开启后会用副本运行。设置会记住，下次打开生效。", "Shows \(clock(app.tz)) inside. Apps it launches run outside Kekkai, so by default it can't open other apps or open links in your browser; turn this on when you need it. With the clipboard blocked, copy and paste stop working. A virtual location fools apps that ask macOS for your location, not ones that use your IP address, and the app runs as a copy. Settings are saved and apply next launch."))
                        .foregroundStyle(.secondary)
                }

                Section {
                    HStack {
                        Button(t("摄像头", "Camera")) { openPrivacy("Privacy_Camera") }
                        Button(t("麦克风", "Microphone")) { openPrivacy("Privacy_Microphone") }
                        Button(t("定位", "Location")) { openPrivacy("Privacy_LocationServices") }
                    }
                } header: { Text(t("系统权限", "System permissions")) } footer: {
                    Text(t("这些由系统按软件管理，从哪里打开都生效，在系统设置里关掉即可。", "macOS manages these for each app, however it's opened. Turn them off in System Settings."))
                        .foregroundStyle(.secondary)
                }

                Section {
                    HStack {
                        Button(t("拦截记录", "Block Log")) { store.showBlocked(path: app.path) }
                        Button(t("再试运行一次…", "Trial Run…")) { trying = true }.disabled(app.running && !app.inside)
                        Spacer()
                    }
                } header: { Text(t("记录", "Logs")) } footer: {
                    Text(t("第一次打开会先试运行：用最小权限打开，把它要过的东西列出来，你逐条允许或拒绝。拦截记录：它想碰却被挡下的东西，每次打开都会累积。", "The first launch is a trial run: it opens with minimal access and lists what the app asked for, so you can allow or deny each request. Block Log lists what it tried to reach and was refused, collected across launches."))
                        .foregroundStyle(.secondary)
                }
            }
            .formStyle(.grouped)
            .sheet(isPresented: $trying) { TrialSheet(app: app, store: store) }
            .sheet(isPresented: $picking) {
                LocationPicker(current: app.location) { place in
                    store.update(app.id) { $0.location = place }
                    store.perform(place.map { ["set-location", app.id, String($0.lat), String($0.lon), $0.mars == true ? "--mars" : "--wgs", $0.name] } ?? ["set-location", app.id, "-"])
                }
            }
        }
    }
}

struct TrialItem: Codable, Identifiable {
    var id: String { key }
    let key, op, target, verb, category, time, grant: String
    let count: Int
    let suspicious, normal, suspect: Bool
    var decision: String?
}

struct TrialResult: Codable {
    let alive: Bool?
    let exitCode: String?
    let seconds: Int?
    let items: [TrialItem]?
    let error: String?
}

struct TrialSheet: View {
    let app: AppEntry
    @ObservedObject var store: Store
    @Environment(\.dismiss) private var dismiss
    @State private var result: TrialResult?
    @State private var showNormal = false

    func start() {
        result = nil
        DispatchQueue.global().async {
            let r = CLI.call(["trial", app.path])
            let decoded = try? JSONDecoder().decode(TrialResult.self, from: Data(r.out.utf8))
            DispatchQueue.main.async { result = decoded ?? TrialResult(alive: nil, exitCode: nil, seconds: nil, items: nil, error: r.out) }
        }
    }
    func decide(_ item: TrialItem, _ choice: String) {
        if let i = result?.items?.firstIndex(where: { $0.key == item.key }) {
            var items = result!.items!
            items[i].decision = choice
            result = TrialResult(alive: result!.alive, exitCode: result!.exitCode, seconds: result!.seconds, items: items, error: nil)
        }
        store.perform(["decide", app.id, choice, item.key])
    }

    func row(_ item: TrialItem) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 6) {
                    Text(item.verb).foregroundStyle(.secondary)
                    Text((item.target as NSString).abbreviatingWithTildeInPath).lineLimit(1).truncationMode(.middle)
                }
                HStack(spacing: 6) {
                    Text(item.category).font(.caption).foregroundStyle(.secondary)
                    if item.suspect { Text(t("可能是它退出的原因", "May be why it quit")).font(.caption.weight(.semibold)).foregroundStyle(.orange) }
                    else if item.suspicious { Text(t("可疑", "Suspicious")).font(.caption.weight(.semibold)).foregroundStyle(.red) }
                }
            }
            Spacer()
            if let d = item.decision {
                Text(d == "allow" ? t("已允许", "Allowed") : t("已拒绝", "Denied")).foregroundStyle(.secondary)
            } else {
                Button(t("拒绝", "Deny")) { decide(item, "deny") }
                Button(t("允许", "Allow")) { decide(item, "allow") }.disabled(item.grant.isEmpty)
                    .help(item.grant.isEmpty ? t("这一项不能单独放行", "This one can't be allowed on its own") : "")
            }
        }
        .padding(.vertical, 2)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(t("试运行 \(displayName(app))", "Trial run: \(displayName(app))")).font(.title3.weight(.semibold))
            if let r = result {
                if let e = r.error, !e.isEmpty {
                    Text(e).foregroundStyle(.red)
                } else {
                    let items = r.items ?? []
                    let main = items.filter { !$0.normal }, normal = items.filter { $0.normal }
                    Label(r.alive == true
                          ? t("在最小权限下正常运行了 \(r.seconds ?? 40) 秒。下面这些被拒绝了也没影响，可以放心拒绝。", "It ran normally for \(r.seconds ?? 40) seconds with minimal access. Denying the requests below didn't stop it, so it's safe to deny them.")
                          : t("它中途退出了（退出码 \(r.exitCode ?? "?")）。看看标着“可能是它退出的原因”的那几条，允许后再试一次。", "It quit (exit code \(r.exitCode ?? "?")). Check the requests marked “May be why it quit”, allow what makes sense, then try again."),
                          systemImage: r.alive == true ? "checkmark.circle.fill" : "exclamationmark.triangle.fill")
                        .foregroundStyle(r.alive == true ? .green : .orange)
                        .fixedSize(horizontal: false, vertical: true)
                    List {
                        if main.isEmpty { Text(t("没有被拒绝的请求。", "No requests were denied.")).foregroundStyle(.secondary) }
                        ForEach(main.sorted { ($0.suspect ? 0 : 1, $0.decision == nil ? 0 : 1) < ($1.suspect ? 0 : 1, $1.decision == nil ? 0 : 1) }) { row($0) }
                        if !normal.isEmpty {
                            DisclosureGroup(t("还有 \(normal.count) 条系统的常规请求，拒绝了也不影响", "\(normal.count) routine system requests, safe to leave denied"), isExpanded: $showNormal) {
                                ForEach(normal) { row($0) }
                            }
                        }
                    }
                    .frame(minHeight: 280)
                }
            } else {
                HStack(spacing: 10) {
                    ProgressView().controlSize(.small)
                    Text(t("正在用最小权限打开它，观察约 40 秒…", "Opening it with minimal access and watching for about 40 seconds…")).foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, minHeight: 280)
            }
            HStack {
                if let items = result?.items, items.contains(where: { $0.decision == nil && !$0.normal }) {
                    Button(t("其余全部拒绝", "Deny the Rest")) { items.filter { $0.decision == nil && !$0.normal }.forEach { decide($0, "deny") } }
                }
                Spacer()
                Button(t("再试一次", "Try Again"), action: start).disabled(result == nil)
                Button(t("完成", "Done")) { dismiss() }.keyboardShortcut(.defaultAction)
            }
        }
        .padding(20)
        .frame(width: 640, height: 520)
        .onAppear(perform: start)
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
            Text(t("从结界打开的软件，包括学习模式，都看不到这些文件夹，优先级高于任何放行。", "Apps opened from Kekkai, including in Learn Mode, can't see these folders. This overrides every other rule."))
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
                        Text(t("选一个 App，或把 App 拖到这里", "Choose an app, or drag one here")).font(.title3)
                        Text(t("结界里的软件只看得到自己的数据", "Apps in Kekkai can only see their own files")).foregroundStyle(.secondary)
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
