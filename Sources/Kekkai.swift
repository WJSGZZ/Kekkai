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
    @State private var confirmReset = false
    @State private var picking = false

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
                    if app.sandboxed {
                        LabeledContent(t("运行方式", "How it runs"), value: t("去掉苹果沙盒的副本", "Unsandboxed copy"))
                    } else {
                        Picker(t("存放改动", "Save changes to"), selection: Binding(
                            get: { app.mode },
                            set: { v in set(["set-mode", app.id, v]) { $0.mode = v } })) {
                            Text(t("模拟区域", "Private space")).tag("space")
                            Text(t("真实文件", "Real files")).tag("real")
                        }
                        .pickerStyle(.segmented)
                        if app.mode == "space" {
                            Toggle(t("首次打开时带入旧数据", "Bring existing data on first launch"), isOn: Binding(
                                get: { app.bringOld },
                                set: { v in set(["set-bring-old", app.id, v ? "on" : "off"]) { $0.bringOld = v } }))
                                .disabled(app.hasSpace)
                        }
                    }
                } header: { Text(t("数据", "Data")) } footer: {
                    Text(app.sandboxed
                         ? t("它自带苹果沙盒，不能再套一层。结界在模拟区域里放一份去掉苹果沙盒的副本来运行，原 App 和数据不动。副本要重新登录，原 App 更新后会自动重建。", "It already has Apple's sandbox, which can't be stacked. Kekkai runs an unsandboxed copy from the private space and leaves the original and its data alone. You'll sign in again, and the copy is rebuilt when the original updates.")
                         : app.mode == "real" ? t("改动直接写进它原来的数据，只放行它自己的文件。", "Changes go straight into its existing data. Only its own files are allowed.")
                         : app.hasSpace ? t("模拟区域已建好，想重来可以丢弃所有改动。", "The private space already exists. Discard all changes to start over.")
                         : app.bringOld ? t("首次打开时克隆它原有的数据，登录可能保留。", "Clones its existing data on first launch, so you may stay signed in.")
                         : t("当作新软件使用，不带任何旧数据，需要重新登录。", "Starts as a new app with no old data. You'll sign in again."))
                        .foregroundStyle(.secondary)
                }

                Section {
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
                    Text(t("结界内显示 \(clock(app.tz))。剪贴板关掉后复制、粘贴都不能用。虚拟位置只骗过向系统要定位的软件，按 IP 判断位置的骗不过；开启后会用副本运行。设置会记住，下次打开生效。", "Shows \(clock(app.tz)) inside. With the clipboard blocked, copy and paste stop working. A virtual location fools apps that ask macOS for your location, not ones that use your IP address, and the app runs as a copy. Settings are saved and apply next launch."))
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

                Section(t("更多", "More")) {
                    HStack {
                        Button(t("学习模式（不隔离）", "Learn Mode (No Isolation)")) { store.perform(["learn", app.path]) }
                            .disabled(app.running || app.inside)
                        Button(t("访问记录", "Access Log")) { store.showReport(path: app.path) }
                        Button(t("交换文件夹", "Exchange Folder")) {
                            let path = app.mode == "space" || app.sandboxed ? app.space + "/Downloads" : NSHomeDirectory() + "/KekkaiShare/" + app.name
                            let url = URL(fileURLWithPath: path)
                            try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
                            NSWorkspace.shared.open(url)
                        }
                        Spacer()
                        if app.hasSpace {
                            Button(t("丢弃所有改动…", "Discard All Changes…"), role: .destructive) { confirmReset = true }
                                .disabled(app.inside)
                        }
                    }
                }
            }
            .formStyle(.grouped)
            .sheet(isPresented: $picking) {
                LocationPicker(current: app.location) { place in
                    store.update(app.id) { $0.location = place }
                    store.perform(place.map { ["set-location", app.id, String($0.lat), String($0.lon), $0.mars == true ? "--mars" : "--wgs", $0.name] } ?? ["set-location", app.id, "-"])
                }
            }
            .confirmationDialog(t("丢弃 \(displayName(app)) 在模拟区域里的所有改动？", "Discard all of \(displayName(app))'s changes in its private space?"), isPresented: $confirmReset) {
                Button(t("丢弃", "Discard"), role: .destructive) { store.perform(["reset", app.path]) }
                Button(t("取消", "Cancel"), role: .cancel) {}
            } message: { Text(t("包括放在交换文件夹里的文件，不能恢复。下次打开时回到初始状态。", "This includes files in the exchange folder and can't be undone. The app starts fresh next time.")) }
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
                        Text(t("结界里的软件只看得到自己的文件", "Apps in Kekkai can only see their own files")).foregroundStyle(.secondary)
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
