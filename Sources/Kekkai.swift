import SwiftUI
import UniformTypeIdentifiers

let isChinese = Locale.preferredLanguages.first?.hasPrefix("zh") ?? false
func t(_ zh: String, _ en: String) -> String { isChinese ? zh : en }
func displayName(_ app: AppEntry) -> String { (FileManager.default.displayName(atPath: app.path) as NSString).deletingPathExtension }

struct AppEntry: Codable, Identifiable, Equatable {
    let id, name, path: String
    let sandboxed, inside, running, hasSpace, bringOld: Bool
    let tz: String?
    let perms: [String]
    let block: [String]
    let mode, space: String
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

let devices: [(String, String)] = [
    ("camera", t("摄像头", "Camera")), ("microphone", t("麦克风", "Microphone")),
    ("clipboard", t("剪贴板（含拖放）", "Clipboard (and drag and drop)")), ("location", t("定位", "Location")),
]

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

    var status: String {
        if app.inside { return t("正在结界中运行", "Running in Kekkai") }
        if app.sandboxed { return t("自带苹果沙盒，不再套一层", "Has Apple's own sandbox") }
        if app.running { return t("正在结界外运行，请先完全退出", "Running outside Kekkai. Quit it first.") }
        return t("未运行", "Not running")
    }
    func clock(_ tz: String?) -> String {
        let f = DateFormatter()
        f.locale = isChinese ? Locale(identifier: "zh_CN") : Locale(identifier: "en_US")
        f.dateFormat = isChinese ? "M月d日 HH:mm" : "MMM d, HH:mm"
        f.timeZone = tz.flatMap(TimeZone.init(identifier:)) ?? .current
        return f.string(from: now)
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack(spacing: 14) {
                Image(nsImage: NSWorkspace.shared.icon(forFile: app.path)).resizable().frame(width: 56, height: 56)
                VStack(alignment: .leading, spacing: 4) {
                    Text(displayName(app)).font(.title2.weight(.semibold))
                    Text(status).foregroundStyle(.secondary)
                }
            }
            Divider()
            if app.sandboxed {
                Text(t("苹果沙盒已限制它，它能碰的只有：", "Apple's sandbox already limits this app. It can only access:")).font(.headline)
                ForEach(app.perms, id: \.self) { Text("• \($0)") }
                Text(t("桌面、文稿和你的其他文件，它按声明碰不到。再套一层会让它崩溃，所以结界不接管它。别把敏感文件放进下载文件夹。", "By its declared permissions it can't reach Desktop, Documents or your other files. Adding another layer would crash it, so Kekkai leaves it alone. Keep sensitive files out of Downloads."))
                    .font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                Text(t("摄像头、麦克风和读取剪贴板由系统设置管，关掉后它就用不了：", "Camera, microphone and pasting are controlled in System Settings. Turn them off there:"))
                    .font(.callout).fixedSize(horizontal: false, vertical: true)
                HStack {
                    Button(t("摄像头", "Camera")) { openPrivacy("Privacy_Camera") }
                    Button(t("麦克风", "Microphone")) { openPrivacy("Privacy_Microphone") }
                    Button(t("隐私与安全性", "Privacy & Security")) { openPrivacy("Privacy") }
                }
            } else {
                Picker(t("存放改动", "Save changes to"), selection: Binding(
                    get: { app.mode },
                    set: { store.perform(["set-mode", app.id, $0]) })) {
                    Text(t("模拟区域（可丢弃）", "Private space (discardable)")).tag("space")
                    Text(t("真实文件", "Real files")).tag("real")
                }
                .disabled(app.inside)
                if app.mode == "space" {
                    Toggle(t("首次打开时带入旧数据", "Bring existing data on first launch"), isOn: Binding(
                        get: { app.bringOld },
                        set: { store.perform(["set-bring-old", app.id, $0 ? "on" : "off"]) }))
                        .disabled(app.inside || app.hasSpace)
                    Text(app.bringOld ? t("首次打开时克隆它原有的数据，登录可能保留。", "Clones its existing data on first launch. You may stay signed in.") : t("当作新软件使用，不带任何旧数据，需要重新登录。", "Starts as a new app with no old data. You'll need to sign in again."))
                        .font(.callout).foregroundStyle(.secondary)
                }
                Picker(t("结界内时区", "Time zone in Kekkai"), selection: Binding(
                    get: { app.tz ?? "" },
                    set: { store.perform(["set-tz", app.id, $0.isEmpty ? "-" : $0]) })) {
                    Text(t("跟随系统", "System default")).tag("")
                    ForEach(presetZones, id: \.1) { Text($0.0).tag($0.1) }
                    if let tz = app.tz, !presetZones.contains(where: { $0.1 == tz }) { Text(tz).tag(tz) }
                }
                .disabled(app.inside)
                Text(t("结界内显示：\(clock(app.tz))。改设置后下次打开生效。", "Shows \(clock(app.tz)). Changes apply next launch."))
                    .font(.callout).foregroundStyle(.secondary)
                VStack(alignment: .leading, spacing: 6) {
                    Text(t("在结界中禁止使用", "Block in Kekkai")).font(.headline)
                    HStack(spacing: 14) {
                        ForEach(devices, id: \.0) { d in
                            Toggle(d.1, isOn: Binding(
                                get: { app.block.contains(d.0) },
                                set: { store.perform(["set-block", app.id, d.0, $0 ? "on" : "off"]) }))
                        }
                    }
                    .disabled(app.inside)
                }
                HStack {
                    if app.inside {
                        Button(t("停止", "Stop")) { store.perform(["stop", app.path]) }
                    } else {
                        Button(t("在结界中打开", "Open in Kekkai")) { store.open(path: app.path) }
                            .keyboardShortcut(.defaultAction)
                            .disabled(app.running)
                        Button(t("学习模式（不隔离）", "Learn Mode (No Isolation)")) { store.perform(["learn", app.path]) }
                            .disabled(app.running)
                    }
                    Button(t("访问记录", "Access Log")) { store.showReport(path: app.path) }
                }
                HStack {
                    Button(t("打开交换文件夹", "Open Exchange Folder")) {
                        let path = app.mode == "space" ? app.space + "/Downloads" : NSHomeDirectory() + "/KekkaiShare/" + app.name
                        let url = URL(fileURLWithPath: path)
                        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
                        NSWorkspace.shared.open(url)
                    }
                    if app.hasSpace {
                        Button(t("丢弃所有改动…", "Discard All Changes…"), role: .destructive) { confirmReset = true }
                            .disabled(app.inside)
                    }
                }
                .confirmationDialog(t("丢弃 \(displayName(app)) 在模拟区域里的所有改动？", "Discard all of \(displayName(app))'s changes in its private space?"), isPresented: $confirmReset) {
                    Button(t("丢弃", "Discard"), role: .destructive) { store.perform(["reset", app.path]) }
                    Button(t("取消", "Cancel"), role: .cancel) {}
                } message: { Text(t("包括放在交换文件夹里的文件，不能恢复。下次打开时回到初始状态。", "This includes files in the exchange folder and can't be undone. The app starts fresh next time.")) }
            }
            Spacer()
        }
        .padding(24)
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
    @State private var selection: String?
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
                        if app.inside { Circle().fill(.green).frame(width: 7, height: 7).accessibilityLabel("结界中") }
                    }
                    .opacity(app.sandboxed ? 0.5 : 1)
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
        .frame(minWidth: 640, minHeight: 420)
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
