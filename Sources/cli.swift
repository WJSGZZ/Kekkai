// 结界 Kekkai 的命令行：生成沙盒规则、用 sandbox-exec 启动软件、管理每个软件的结界文件夹、读系统日志得出拦截记录、添加时试运行。
// 界面只是调用它。编译成单个程序，不依赖系统 Python 和命令行工具。
import Foundation
import Security
import SystemConfiguration
import SQLite3

let usage = """
结界 Kekkai：让 macOS App 只看得到自己的文件。
用法:
  kekkai run|trial|learn|stop|report|reset|blocked|profile <App.app>
  kekkai blocked <App.app> --json
  kekkai import <App.app>
  kekkai tune <App.app>
  kekkai launcher <App.app> [名称]
  kekkai list
  kekkai set-tz <bundle id> <时区|location|->
  kekkai set-mode <bundle id> <space|real>
  kekkai set-bring-old <bundle id> <on|off>
  kekkai set-block <bundle id> clipboard <on|off>
  kekkai set-clipboard <bundle id> off|paste|on
  kekkai set-open <bundle id> <on|off>
  kekkai set <bundle id> localhost|procinfo|lan|clone <on|off>
  kekkai allow <bundle id> add|rm <文件夹>
  kekkai decide <bundle id> allow|deny <操作> <对象>
  kekkai set-location <bundle id> <WGS-84 纬度> <经度> [名称] | -
  kekkai new-identity <bundle id>
  kekkai add|remove <App.app>
  kekkai never list|add|rm [路径]
"""

// MARK: - 常量

let HOME = NSHomeDirectory()
let UID = getuid()
let FM = FileManager.default

func userDir(_ name: Int32) -> String {
    var buf = [CChar](repeating: 0, count: Int(PATH_MAX))
    confstr(name, &buf, buf.count)
    return realPath(String(cString: buf))
}
// 所有软件共用的临时和缓存文件夹，里面有别的软件的文件
let USER_TEMP = userDir(_CS_DARWIN_USER_TEMP_DIR)
let USER_CACHE = userDir(_CS_DARWIN_USER_CACHE_DIR)
// 列出内容就能看出装了什么的系统文件夹（只挡列目录，不挡按名字访问）
let NO_LIST = ["/Library/Application Support", "/Library/Preferences", "/Library/LaunchAgents", "/Library/LaunchDaemons",
               "/Library/PrivilegedHelperTools", "/Library/Extensions", "/opt", "/usr/local"]
// 本程序所在的文件夹：规则、注入库、中转程序都放在旁边
let ROOT: String = {
    var size: UInt32 = 0
    _NSGetExecutablePath(nil, &size)
    var buf = [CChar](repeating: 0, count: Int(size))
    _NSGetExecutablePath(&buf, &size)
    return (realPath(String(cString: buf)) as NSString).deletingLastPathComponent
}()
let STATE = HOME + "/Library/Application Support/Kekkai"
// .noindex 让聚焦搜索不收录里面的副本和数据，不然搜软件会冒出一堆（实测 .metadata_never_index 对文件夹无效）
var SPACES = "/Users/Shared/Kekkai.noindex"
let OLD_SPACES = "/Users/Shared/Kekkai"
var LIBDIR = SPACES + "/.lib"  // 注入库放这里：路径里没有你的用户名，软件看得到它的环境变量
let OWN_BASES = ["Application Support", "Caches", "Preferences", "Logs", "HTTPStorages", "WebKit", "Cookies",
                 "Saved Application State", "Containers", "Group Containers", "Application Scripts"]
let BLOCKED = [HOME, "/Users/Shared", "/Applications", "/Volumes", "/private/tmp"]
let NO_EXEC = ["/bin/launchctl", "/usr/bin/open", "/usr/bin/osascript",
               // 会说出局域网邻居和路由器网卡地址、Wi-Fi 信息的系统工具；系统程序不能注入，只能不让跑
               "/usr/sbin/arp", "/usr/sbin/ndp", "/usr/sbin/netstat", "/usr/sbin/ipconfig", "/usr/sbin/system_profiler"]
let DIRECTORY_SERVICES = ["com.apple.system.opendirectoryd.libinfo", "com.apple.system.opendirectoryd.api",
                          "com.apple.system.opendirectoryd.membership", "com.apple.system.DirectoryService.libinfo_v1"]
let DEFAULT_NEVER = ["\(HOME)/.ssh", "\(HOME)/.gnupg", "\(HOME)/.aws"]
// 可按 App 关掉的服务。摄像头、麦克风、定位由系统按软件管理，不在这里重复
let DEVICES: [String: [String]] = ["clipboard": ["(deny mach-lookup (global-name \"com.apple.pasteboard.1\"))"]]
let DEFAULT_BLOCK = ["clipboard"]  // 默认全部最严
let NAME_BASES = ["Application Support", "Caches", "Logs", "HTTPStorages", "WebKit", "Saved Application State"]
let SPACE_DIRS = ["Library/Application Support", "Library/Caches", "Library/Preferences", "Library/Logs",
                  "Downloads", "Documents", "Desktop", "tmp"]
let PERMISSION_KEYS = ["com.apple.security.files.downloads.read-write", "com.apple.security.files.user-selected.read-write",
                       "com.apple.security.files.user-selected.read-only", "com.apple.security.files.bookmarks.app-scope",
                       "com.apple.security.device.camera", "com.apple.security.device.audio-input",
                       "com.apple.security.personal-information.location", "com.apple.security.personal-information.photos-library",
                       "com.apple.security.personal-information.addressbook", "com.apple.security.network.client",
                       "com.apple.security.network.server", "com.apple.security.print"]
let PERMISSIONS: [String: (String, String)] = [
    "com.apple.security.files.downloads.read-write": ("读写下载文件夹", "Read and write Downloads"),
    "com.apple.security.files.user-selected.read-write": ("读写你手动选的文件", "Read and write files you choose"),
    "com.apple.security.files.user-selected.read-only": ("读取你手动选的文件", "Read files you choose"),
    "com.apple.security.files.bookmarks.app-scope": ("记住你选过的文件", "Remember files you chose"),
    "com.apple.security.device.camera": ("摄像头（首次要你同意）", "Camera (asks first)"),
    "com.apple.security.device.audio-input": ("麦克风（首次要你同意）", "Microphone (asks first)"),
    "com.apple.security.personal-information.location": ("定位（首次要你同意）", "Location (asks first)"),
    "com.apple.security.personal-information.photos-library": ("照片（首次要你同意）", "Photos (asks first)"),
    "com.apple.security.personal-information.addressbook": ("通讯录（首次要你同意）", "Contacts (asks first)"),
    "com.apple.security.network.client": ("联网", "Network access"),
    "com.apple.security.network.server": ("接受网络连接", "Accept network connections"),
    "com.apple.security.print": ("打印", "Printing"),
]

// MARK: - 基础工具

typealias Dict = [String: Any]

func t(_ zh: String, _ en: String) -> String { isChinese() ? zh : en }
func isChinese() -> Bool { (ProcessInfo.processInfo.environment["KEKKAI_LANG"] ?? "zh") == "zh" }

func q(_ s: String) -> String {
    "\"" + s.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"") + "\""
}

/// 正则转义，与 Python 3.7 起的 re.escape 相同，生成的规则和以前逐字一致
func reEscape(_ s: String) -> String {
    let special = Set("()[]{}?*+-|^$\\.&~# \t\n\r\u{0B}\u{0C}")
    return s.map { special.contains($0) ? "\\\($0)" : String($0) }.joined()
}

/// 按码位排序，与 Python 的 sorted 相同
func pySorted<S: Sequence>(_ s: S) -> [String] where S.Element == String {
    s.sorted { Array($0.unicodeScalars.map(\.value)).lexicographicallyPrecedes(Array($1.unicodeScalars.map(\.value))) }
}

/// 补全为绝对路径并解析符号链接；不存在的部分照原样接上（同 Python 的 Path.resolve）
func realPath(_ path: String) -> String {
    var p = path.hasPrefix("/") ? path : FM.currentDirectoryPath + "/" + path
    p = (p as NSString).standardizingPath
    if let r = realpath(p, nil) {
        defer { free(r) }
        return String(cString: r)
    }
    let parent = (p as NSString).deletingLastPathComponent
    if parent == p || parent.isEmpty { return p }
    return (realPath(parent) as NSString).appendingPathComponent((p as NSString).lastPathComponent)
}

func expandUser(_ p: String) -> String { (p as NSString).expandingTildeInPath }
func exists(_ p: String) -> Bool { FM.fileExists(atPath: p) }
func isDir(_ p: String) -> Bool { var d: ObjCBool = false; return FM.fileExists(atPath: p, isDirectory: &d) && d.boolValue }
func isSymlink(_ p: String) -> Bool { (try? FM.attributesOfItem(atPath: p)[.type] as? FileAttributeType) == .typeSymbolicLink }
func isFile(_ p: String) -> Bool { exists(p) && !isDir(p) }
func readText(_ p: String) -> String? { try? String(contentsOfFile: p, encoding: .utf8) }
func writeText(_ p: String, _ s: String) { try? s.write(toFile: p, atomically: false, encoding: .utf8) }
func remove(_ p: String) { try? FM.removeItem(atPath: p) }
func mkdirs(_ p: String) { try? FM.createDirectory(atPath: p, withIntermediateDirectories: true) }
func stem(_ p: String) -> String { ((p as NSString).lastPathComponent as NSString).deletingPathExtension }
func name(_ p: String) -> String { (p as NSString).lastPathComponent }
func parent(_ p: String) -> String { (p as NSString).deletingLastPathComponent }
func listDir(_ p: String) -> [String] { (try? FM.contentsOfDirectory(atPath: p)) ?? [] }
func fileSize(_ p: String) -> Int { (try? FM.attributesOfItem(atPath: p)[.size] as? Int) ?? 0 }

/// 文件修改时间，写法与 Python 的 str(st_mtime) 相同（副本旁的 .source 文件靠它判断原 App 是否更新）
func mtime(_ p: String) -> String {
    var st = stat()
    guard stat(p, &st) == 0 else { return "0.0" }
    return "\(Double(st.st_mtimespec.tv_sec) + Double(st.st_mtimespec.tv_nsec) * 1e-9)"
}

/// 遍历文件夹下全部项目，不进入符号链接
func walk(_ root: String) -> [String] {
    guard let e = FM.enumerator(atPath: root) else { return [] }
    return e.compactMap { ($0 as? String).map { root + "/" + $0 } }
}

struct Output { let code: Int32; let out: String; let err: String }

@discardableResult
func sh(_ args: [String], env: [String: String]? = nil) -> Output {
    let p = Process(), o = Pipe(), e = Pipe()
    p.executableURL = URL(fileURLWithPath: args[0])
    p.arguments = Array(args.dropFirst())
    if let env { p.environment = env }
    p.standardOutput = o
    p.standardError = e
    p.standardInput = FileHandle.nullDevice
    do { try p.run() } catch { return Output(code: -1, out: "", err: "\(error)") }
    var errData = Data()
    let g = DispatchGroup()
    g.enter()
    DispatchQueue.global().async { errData = e.fileHandleForReading.readDataToEndOfFile(); g.leave() }
    let outData = o.fileHandleForReading.readDataToEndOfFile()
    g.wait()
    p.waitUntilExit()
    return Output(code: p.terminationStatus, out: String(decoding: outData, as: UTF8.self), err: String(decoding: errData, as: UTF8.self))
}

func die(_ msg: String) -> Never {
    FileHandle.standardError.write((msg + "\n").data(using: .utf8)!)
    exit(1)
}

func sleepSeconds(_ s: Double) { Thread.sleep(forTimeInterval: s) }

func now() -> String {
    let f = DateFormatter()
    f.locale = Locale(identifier: "en_US_POSIX")
    f.dateFormat = "yyyy-MM-dd HH:mm:ss"
    return f.string(from: Date())
}

func parseTime(_ s: String) -> Date? {
    let f = DateFormatter()
    f.locale = Locale(identifier: "en_US_POSIX")
    f.dateFormat = "yyyy-MM-dd HH:mm:ss"
    return f.date(from: String(s.prefix(19)))
}

func match(_ pattern: String, _ s: String, _ options: NSRegularExpression.Options = []) -> [String?]? {
    guard let re = try? NSRegularExpression(pattern: pattern, options: options),
          let m = re.firstMatch(in: s, range: NSRange(s.startIndex..., in: s)) else { return nil }
    return (0..<m.numberOfRanges).map { i in Range(m.range(at: i), in: s).map { String(s[$0]) } }
}

func allMatches(_ pattern: String, _ s: String) -> [[String?]] {
    guard let re = try? NSRegularExpression(pattern: pattern) else { return [] }
    return re.matches(in: s, range: NSRange(s.startIndex..., in: s)).map { m in
        (0..<m.numberOfRanges).map { i in Range(m.range(at: i), in: s).map { String(s[$0]) } }
    }
}

func sub(_ pattern: String, _ with: String, _ s: String) -> String {
    guard let re = try? NSRegularExpression(pattern: pattern) else { return s }
    return re.stringByReplacingMatches(in: s, range: NSRange(s.startIndex..., in: s), withTemplate: with)
}

func jsonString(_ obj: Any, pretty: Bool = false) -> String {
    var opts: JSONSerialization.WritingOptions = [.withoutEscapingSlashes, .fragmentsAllowed]
    if pretty { opts.formUnion([.prettyPrinted, .sortedKeys]) }
    guard let d = try? JSONSerialization.data(withJSONObject: obj, options: opts) else { return "null" }
    return String(decoding: d, as: UTF8.self)
}

func readJSON(_ p: String) -> Any? {
    guard let d = FM.contents(atPath: p) else { return nil }
    return try? JSONSerialization.jsonObject(with: d)
}

func printJSON(_ obj: Any) { print(jsonString(obj)) }

/// 同 Python 的真值判断：false、0、空串、空列表都算否
func truthy(_ v: Any?) -> Bool {
    switch v {
    case nil, is NSNull: return false
    case let n as NSNumber: return n.boolValue
    case let s as String: return !s.isEmpty
    case let a as [Any]: return !a.isEmpty
    case let d as Dict: return !d.isEmpty
    default: return true
    }
}

func writePlist(_ obj: Any, _ path: String) {
    if let d = try? PropertyListSerialization.data(fromPropertyList: obj, format: .xml, options: 0) {
        FM.createFile(atPath: path, contents: d)
    }
}

func readPlist(_ path: String) -> Dict? {
    guard let d = FM.contents(atPath: path) else { return nil }
    return (try? PropertyListSerialization.propertyList(from: d, format: nil)) as? Dict
}

// MARK: - 软件信息

func info(_ app: String) -> (id: String, exe: String)? {
    guard let plist = readPlist(app + "/Contents/Info.plist"), var id = plist["CFBundleIdentifier"] as? String,
          let exe = plist["CFBundleExecutable"] as? String else { return nil }
    if id == "com.github.Electron" {  // 有的软件没改 Electron 的默认 id，按 App 名区分
        id += "." + sub("[^A-Za-z0-9.-]", "-", stem(app))
    }
    return (id, exe)
}

func mustInfo(_ app: String) -> (id: String, exe: String) {
    guard let i = info(app) else { die(t("无法读取 App 信息：\(app)", "Can't read app info: \(app)")) }
    return i
}

func loadRule(_ id: String) -> Dict { readJSON("\(ROOT)/rules/\(id).json") as? Dict ?? [:] }

/// 签名信息（标志位和权限），由系统的代码签名服务直接读，不调 codesign
func signing(_ path: String) -> (flags: UInt32, ents: Dict) {
    var code: SecStaticCode?
    guard SecStaticCodeCreateWithPath(URL(fileURLWithPath: path) as CFURL, [], &code) == errSecSuccess, let code else { return (0, [:]) }
    var info: CFDictionary?
    guard SecCodeCopySigningInformation(code, SecCSFlags(rawValue: kSecCSSigningInformation | kSecCSRequirementInformation), &info) == errSecSuccess,
          let d = info as? Dict else { return (0, [:]) }
    return ((d[kSecCodeInfoFlags as String] as? NSNumber)?.uint32Value ?? 0, d[kSecCodeInfoEntitlementsDict as String] as? Dict ?? [:])
}

func entitlements(_ app: String) -> Dict { signing(app).ents }

/// 从网上下载的软件带隔离标记。它的临时签名副本过不了门禁（实测 ASP 拒绝，OS_REASON_EXEC），不绕过门禁，所以不用副本
func quarantined(_ app: String) -> Bool { getxattr(app, "com.apple.quarantine", nil, 0, 0, 0) >= 0 }

/// 签名允许注入才注入：强化运行时要同时许可环境变量和外来库，否则系统会拒绝启动或忽略。
func injectable(_ app: String) -> Bool {
    let (flags, ents) = signing(app)
    let noValidation = truthy(ents["com.apple.security.cs.disable-library-validation"])
    if flags & 0x10000 != 0 {  // 强化运行时
        return truthy(ents["com.apple.security.cs.allow-dyld-environment-variables"]) && noValidation
    }
    return flags & 0x2000 == 0 || noValidation  // 0x2000：只许加载同一开发者签的库
}

// 会认出这台 Mac 的硬件属性；能注入的软件拿到假值，不能注入的直接拿不到
let HARDWARE_IDS = ["IOPlatformSerialNumber", "IOPlatformUUID", "serial-number", "mlb-serial-number", "IOMACAddress"]
// 磁盘、电池、蓝牙、芯片、触控板、键盘、显示器、摄像头的序列号和 UUID（实测结界里原本都读得到，且各软件读到的一样）。
// 能注入的软件放行，由注入库按它的种子换成另一套（要照着原值的格式换）；不能注入的直接挡。
// 与 inject.c 的 morphed、dropped 两表一致
let DEVICE_IDS = ["UUID", "VolGroupUUID", "SerialNumber", "Serial", "ECID", "ecid", "unique-chip-id", "BD_ADDR", "local-mac-address",
                  "mac-address", "USB Serial Number", "kUSBSerialNumberString", "Serial Number", "NamespaceUUID", "Domain UUID",
                  "BootSessionUUID", "FrontCameraModuleSerialNumString", "FrontIRStructuredLightProjectorSerialNumString",
                  "AccessoryCertificateSerialNumber", "BatteryData", "Device Characteristics", "Controller Characteristics",
                  "AdapterDetails", "AppleRawAdapterDetails", "EDID", "IODisplayEDID", "IODisplayEDIDOriginal", "DisplayAttributes"]

func modelName() -> String {
    let out = sh(["/usr/sbin/system_profiler", "SPHardwareDataType"]).out
    return match("(?:Model Name|型号名称)[:：]\\s*(.+)", out)?[1].map { $0.trimmingCharacters(in: .whitespaces) } ?? "Mac"
}

func randomHex(_ bytes: Int) -> String {
    var b = [UInt8](repeating: 0, count: bytes)
    arc4random_buf(&b, bytes)
    return b.map { String(format: "%02x", $0) }.joined()
}

/// 每个软件一套固定的假设备身份，第一次用时生成；软件之间各不相同，没法靠设备号把你串起来。
func identity(_ id: String) -> Dict {
    var data = settings()
    var entry = data[id] as? Dict ?? [:]
    if !truthy(entry["identity"]) {
        let chars = Array("ABCDEFGHJKLMNPQRSTUVWXYZ0123456789")  // 苹果序列号不用 I 和 O
        entry["identity"] = ["serial": String((0..<10).map { _ in chars[Int(arc4random_uniform(UInt32(chars.count)))] }),
                             "uuid": UUID().uuidString.uppercased(), "seed": randomHex(8),
                             "name": modelName()]  // 电脑名用机型，和新 Mac 的默认名一样，不带你的名字
        data[id] = entry
        saveSettings(data)
    }
    return entry["identity"] as? Dict ?? [:]
}

// MARK: - 语言与时区

// 语言最常见的地区和它的时区；美国、俄罗斯这类有多个时区的地区不配时区
let COMMON_REGION: [String: (String, String?)] = [
    "zh-Hans": ("CN", "Asia/Shanghai"), "zh-Hant": ("TW", "Asia/Taipei"), "en": ("US", nil),
    "ja": ("JP", "Asia/Tokyo"), "ko": ("KR", "Asia/Seoul"), "fr": ("FR", "Europe/Paris"),
    "de": ("DE", "Europe/Berlin"), "es": ("ES", "Europe/Madrid"), "it": ("IT", "Europe/Rome"),
    "pt": ("BR", nil), "ru": ("RU", nil), "nl": ("NL", "Europe/Amsterdam"), "vi": ("VN", "Asia/Ho_Chi_Minh"),
    "th": ("TH", "Asia/Bangkok"), "id": ("ID", nil)]

/// 系统首选语言换成它最常见的写法：只留一种语言，地区取该语言最常见的。返回 (语言, 地区设置, 时区) 或 nil。
let commonLanguage: (lang: String, locale: String, zone: String?)? = {
    var langs: [String]?
    for p in ["\(HOME)/Library/Preferences/.GlobalPreferences.plist", "/Library/Preferences/.GlobalPreferences.plist"] {
        if let l = readPlist(p)?["AppleLanguages"] as? [String], !l.isEmpty { langs = l; break }
    }
    guard let first = langs?.first else { return nil }
    let parts = first.split(separator: "-").map(String.init)
    let base = parts.count > 1 && parts[1].count == 4 ? parts[0] + "-" + parts[1] : parts[0]  // zh-Hans、sr-Latn 这类带文字
    guard let (region, zone) = COMMON_REGION[base] else { return nil }
    return ("\(base)-\(region)", "\(parts[0])_\(region)", zone)
}()

var sameClockCache: [String: Bool] = [:]
/// 时区和系统时区今后两年的钟点完全一样（偏移、夏令时都一致）才可替换
func sameClock(_ zone: String) -> Bool {
    if let c = sameClockCache[zone] { return c }
    var result = false
    if let link = try? FM.destinationOfSymbolicLink(atPath: "/etc/localtime"),
       let mine = TimeZone(identifier: link.components(separatedBy: "zoneinfo/").last ?? ""),
       let other = TimeZone(identifier: zone) {
        let start = Date()
        result = stride(from: 0, to: 2 * 365 * 24, by: 6).allSatisfy { h in
            let d = start.addingTimeInterval(Double(h) * 3600)
            return mine.secondsFromGMT(for: d) == other.secondsFromGMT(for: d)
        }
    }
    sameClockCache[zone] = result
    return result
}

/// 坐标所在的时区，查 CoreLocation 自带的时区边界库（离线）；海上按经度取航海时区
func zoneAt(_ lat: Double, _ lon: Double) -> String {
    var db: OpaquePointer?
    let path = "/System/Library/Frameworks/CoreLocation.framework/Versions/A/Support/timezone.db"
    if sqlite3_open_v2(path, &db, SQLITE_OPEN_READONLY, nil) == SQLITE_OK {
        defer { sqlite3_close(db) }
        func query(_ sql: String, _ bind: [Any], _ row: (OpaquePointer) -> Void) {
            var st: OpaquePointer?
            guard sqlite3_prepare_v2(db, sql, -1, &st, nil) == SQLITE_OK, let st else { return }
            defer { sqlite3_finalize(st) }
            for (i, v) in bind.enumerated() {
                if let d = v as? Double { sqlite3_bind_double(st, Int32(i + 1), d) } else if let n = v as? Int64 { sqlite3_bind_int64(st, Int32(i + 1), n) }
            }
            while sqlite3_step(st) == SQLITE_ROW { row(st) }
        }
        var boxes: [Int64] = []
        query("SELECT ROWID FROM BoundingBoxes WHERE MinimumLatitude <= ? AND MaximumLatitude >= ? AND MinimumLongitude <= ? AND MaximumLongitude >= ?",
              [lat, lat, lon, lon]) { boxes.append(sqlite3_column_int64($0, 0)) }
        for rid in boxes {
            var pts: [(Double, Double)] = []
            query("SELECT Latitude, Longitude FROM Points WHERE ZoneID = ? ORDER BY PointID", [rid]) {
                pts.append((sqlite3_column_double($0, 0), sqlite3_column_double($0, 1)))
            }
            guard !pts.isEmpty else { continue }
            var inside = false
            for i in pts.indices {
                let (y1, x1) = pts[i], (y2, x2) = pts[(i + pts.count - 1) % pts.count]
                if (y1 > lat) != (y2 > lat) && lon < (x2 - x1) * (lat - y1) / (y2 - y1) + x1 { inside.toggle() }
            }
            if inside {
                var zone: String?
                query("SELECT ZoneName FROM Names WHERE ROWID = ?", [rid]) { zone = sqlite3_column_text($0, 0).map { String(cString: $0) } }
                if let zone { return zone }
            }
        }
    }
    let hours = Int((lon / 15).rounded(.toNearestOrEven))
    return hours == 0 ? "Etc/GMT" : String(format: "Etc/GMT%+d", -hours)  // Etc 时区的符号与通常写法相反
}

/// 软件看到的时区：设置里选过的；跟随虚拟位置的按坐标查；没选过就换成语言常见地区里钟点完全一样的时区
func appZone(_ conf: Dict, _ rule: Dict) -> String? {
    let tz = conf["tz"] as? String
    if tz == "location", let loc = conf["location"] as? Dict, let lat = (loc["lat"] as? NSNumber)?.doubleValue, let lon = (loc["lon"] as? NSNumber)?.doubleValue {
        return zoneAt(lat, lon)
    }
    if (tz != nil && tz != "location") || opt(rule, conf, "keep_identity") {
        return tz != "location" ? tz : nil
    }
    guard let lang = commonLanguage, let zone = lang.zone, sameClock(zone) else { return nil }
    return zone
}

// MARK: - 设置

func settings() -> Dict { readJSON(STATE + "/settings.json") as? Dict ?? [:] }

func saveSettings(_ data: Dict) {
    mkdirs(STATE)
    writeText(STATE + "/settings.json", jsonString(data, pretty: true))
}

func conf(_ id: String) -> Dict { settings()[id] as? Dict ?? [:] }

func update(_ id: String, _ change: (inout Dict) -> Void) {
    var data = settings()
    var entry = data[id] as? Dict ?? [:]
    change(&entry)
    data[id] = entry
    saveSettings(data)
}

func setField(_ id: String, _ key: String, _ value: Any) {
    update(id) { e in
        if let s = value as? String, s == "-" { e.removeValue(forKey: key) } else { e[key] = value }
    }
}

// 隔离开关：界面里的名字 → 设置里的键。没设置时用规则文件的默认，再没有就是最严
let OPTIONS = ["localhost": "allow_localhost", "procinfo": "allow_procinfo", "lan": "allow_lan", "clone": "clone"]

func opt(_ rule: Dict, _ conf: Dict, _ key: String) -> Bool {
    conf.keys.contains(key) ? truthy(conf[key]) : truthy(rule[key])
}

func setTz(_ id: String, _ tz: String) {
    if tz != "-" && tz != "location" && !isFile("/usr/share/zoneinfo/" + tz) {
        die(t("未知时区：\(tz)", "Unknown time zone: \(tz)"))
    }
    setField(id, "tz", tz)
}

func neverList() -> [String] { settings()["_never"] as? [String] ?? DEFAULT_NEVER }

func neverCmd(_ action: String, _ path: String? = nil) {
    var items = neverList()
    if action == "add", let path {
        let real = realPath(expandUser(path))
        if !items.contains(real) { items.append(real) }
    } else if action == "rm", let path {
        let real = realPath(expandUser(path))
        items = items.filter { $0 != real && $0 != path }
    }
    if action != "list" {
        var data = settings()
        data["_never"] = items
        saveSettings(data)
    }
    printJSON(items)
}

func neverRules() -> [String] {
    // 放在规则最后，优先级高于任何放行
    let items = neverList().map(realPath)
    return items.isEmpty ? [] : ["(deny file-read* file-write* (with errno 2)"] + items.map { "  (subpath \(q($0)))" } + [")"]
}

func spaceOf(_ id: String) -> String { SPACES + "/" + id }

/// 传入文件的位置：结界文件夹里的“下载”，软件存的文件通常也在这里；原地运行的软件另用一个只给它的文件夹
func inboxOf(_ id: String, _ mode: String) -> String { mode == "space" ? spaceOf(id) + "/Downloads" : "\(SPACES)/.transfer/\(id)" }

/// App 的名字（含各语言）。Electron 等软件按名字建数据文件夹，如“微信开发者工具”。
func displayNames(_ app: String) -> [String] {
    let p = app + "/Contents"
    var found = Set<String>()
    let plist = readPlist(p + "/Info.plist") ?? [:]
    for k in ["CFBundleName", "CFBundleDisplayName"] { if let s = plist[k] as? String { found.insert(s) } }
    for l in listDir(p + "/Resources") where l.hasSuffix(".lproj") {
        if let d = NSDictionary(contentsOfFile: "\(p)/Resources/\(l)/InfoPlist.strings") as? Dict {
            for k in ["CFBundleName", "CFBundleDisplayName"] { if let s = d[k] as? String { found.insert(s) } }
        }
    }
    return pySorted(found.filter { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && !$0.contains("/") && $0 != "Electron" })
}

/// App 里附带的小程序和扩展，如 QQ 的 com.tencent.qqexdoc。
func nestedIds(_ app: String) -> Set<String> {
    var ids = Set<String>()
    for p in walk(app + "/Contents") where name(p) == "Info.plist" {
        let c = parent(p)
        guard name(c) == "Contents", ["app", "appex", "xpc"].contains((parent(c) as NSString).pathExtension), !isSymlink(p) else { continue }
        if let id = readPlist(p)?["CFBundleIdentifier"] as? String { ids.insert(id) }
    }
    return ids
}

func ownNames(_ id: String, _ rule: Dict) -> [String] { pySorted(Set([id] + (rule["names"] as? [String] ?? []))) }

// MARK: - 结界文件夹与数据导入

func copyFailed(_ err: String) -> String {
    // macOS 保护其他 App 的容器（系统策略拒绝读，实测不弹授权框），要给结界“完全磁盘访问权限”
    if err.contains("Operation not permitted") {
        return t("macOS 不允许结界读取原 App 的数据。请在“系统设置 › 隐私与安全性 › 完全磁盘访问权限”中打开“结界”，然后重试。",
                 "macOS won't let Kekkai read the original app's data. Turn on Kekkai in System Settings › Privacy & Security › Full Disk Access, then try again.")
    }
    let e = String(err.trimmingCharacters(in: .whitespacesAndNewlines).prefix(200))
    return t("导入失败：\(e)", "Import failed: \(e)")
}

/// 把原 App 沙盒容器里的数据用 APFS 克隆放进副本，替换副本现有数据。原 App 的数据不动。
func importContainer(_ id: String) -> String? {
    let src = "\(HOME)/Library/Containers/\(id)/Data/Library", dst = spaceOf(id) + "/Library"
    guard isDir(src) else { return t("原 App 还没有数据。", "The original app has no data yet.") }
    let tmp = parent(dst) + "/Library.importing"
    remove(tmp)
    let r = sh(["/bin/cp", "-cR", src, tmp])
    if r.code != 0 {
        remove(tmp)
        return copyFailed(r.err)
    }
    remove(dst)
    try? FM.moveItem(atPath: tmp, toPath: dst)
    return nil
}

/// 它在资料库里的数据：按 ID（含附带的小程序）、名字、声明的群组容器认，和放行规则同一套认法。
func ownSources(_ app: String, _ id: String, _ rule: Dict) -> [String] {
    let lib = HOME + "/Library"
    let ids = pySorted(Set(ownNames(id, rule)).union(nestedIds(app)))
    let pat = "^(" + ids.map { NSRegularExpression.escapedPattern(for: $0) }.joined(separator: "|") + ")([-._].*)?$"
    let skip = rule["skip_seed"] as? [String] ?? []
    let names = displayNames(app)
    var found: [String] = []
    for base in OWN_BASES where base != "Group Containers" && !skip.contains(base) {  // 群组容器按声明认，下面单独加
        let d = lib + "/" + base
        guard isDir(d) else { continue }
        for n in listDir(d) where match(pat, n) != nil || NAME_BASES.contains(base) && names.contains(n) {
            found.append(d + "/" + n)
        }
    }
    found += appGroups(app).map { "\(lib)/Group Containers/\($0)" }.filter(exists)
    found += (rule["home_paths"] as? [String] ?? []).map { HOME + "/" + $0 }.filter(exists)
    return found
}

/// 把它原来的数据用 APFS 克隆放进它的结界文件夹，替换那里的同名数据。原数据不动。
func importOwn(_ app: String, _ id: String, _ rule: Dict) -> String? {
    let space = spaceOf(id)
    for src in ownSources(app, id, rule) {
        let dst = space + String(src.dropFirst(HOME.count))
        if exists(dst) || isSymlink(dst) { remove(dst) }
        mkdirs(parent(dst))
        let r = sh(["/bin/cp", "-cR", src, dst])
        if r.code != 0 { return copyFailed(r.err) }
    }
    return nil
}

/// 首次进入时把软件原来的数据用 APFS 克隆放进它的结界文件夹，原数据不动。所有软件同一套做法。
func seedSpace(_ app: String, _ id: String, _ rule: Dict, container: Bool) {
    let space = spaceOf(id)
    // 副本程序可能先建好了，看数据区里有没有真的数据
    let fresh = !exists(space + "/Library") || !walk(space + "/Library").contains(where: isFile)
    mkdirs(SPACES)
    if let o = try? FM.attributesOfItem(atPath: SPACES)[.ownerAccountID] as? NSNumber, o.uint32Value == UID { chmod(SPACES, 0o1777) }
    for d in SPACE_DIRS { mkdirs(space + "/" + d) }
    chmod(space, 0o700)
    for rel in rule["space_dirs"] as? [String] ?? [] { mkdirs(space + "/" + rel) }
    if fresh {
        // 自带苹果沙盒的软件，数据都在它的容器里；其他软件按 ID 和名字认
        _ = container ? importContainer(id) : importOwn(app, id, rule)
    }
}

/// 结界文件夹里它自己的钥匙串：它存的登录凭据留在这里，读不到你的钥匙串。
/// 家目录换到结界文件夹后，系统按新家目录里的偏好找钥匙串（实测），所以只改它自己的那份设置。
/// 文件不能叫 login.keychain-db（链接也不行），系统会特殊对待、解不开锁（实测）。系统在结界里找不到默认钥匙串，
/// 由注入库把 SecItem 请求指向这个文件（inject.c 的“钥匙串”一节）。你的钥匙串在结界文件夹之外，不提供放开的选项。
func privateKeychain(_ id: String) {
    let space = spaceOf(id)
    let kc = space + "/Library/Keychains/kekkai.keychain-db"
    let pwFile = "\(STATE)/\(id).keychain"
    var env = ProcessInfo.processInfo.environment
    env["HOME"] = space; env["CFFIXED_USER_HOME"] = space; env["__CFPREFERENCES_AVOID_DAEMON"] = "1"
    func sec(_ a: String...) { sh(["/usr/bin/security"] + a, env: env) }
    if !exists(kc) || !exists(pwFile) {
        remove(kc)
        if isSymlink(parent(kc)) { remove(parent(kc)) }  // 从苹果沙盒容器复制来的，是指向外面的链接，在结界里本来就失效
        mkdirs(parent(kc))
        writeText(pwFile, randomHex(24))
        chmod(pwFile, 0o600)
        sec("create-keychain", "-p", readText(pwFile) ?? "", kc)
        sec("set-keychain-settings", kc)  // 不自动上锁
    }
    sec("list-keychains", "-d", "user", "-s", kc)
    sec("default-keychain", "-d", "user", "-s", kc)
    sec("unlock-keychain", "-p", readText(pwFile) ?? "", kc)
}

func ancestors(_ path: String) -> [String] {
    var out: [String] = [], p = parent(path)
    while p != "/" && !p.isEmpty { out.append(p); p = parent(p) }
    return out
}

func blockedDevices(_ conf: Dict, _ injected: Bool) -> [String] {
    // 剪贴板：能注入的默认不挡服务，改为“能写、按粘贴才能读”；不能注入的做不到这一步，默认整个挡掉
    let block = conf["block"] as? [String] ?? (injected ? [] : DEFAULT_BLOCK)
    return DEVICES.keys.sorted().filter { block.contains($0) }
}

/// off 整个挡掉；paste 能写，你按 ⌘V 或点“粘贴”时才能读（要注入）；on 随便读写。
func clipboardMode(_ conf: Dict, _ injected: Bool) -> String {
    if blockedDevices(conf, injected).contains("clipboard") { return "off" }
    return injected && (conf["clipboard_read"] as? String ?? "paste") == "paste" ? "paste" : "on"
}

func setClipboard(_ id: String, _ mode: String) {
    setBlock(id, "clipboard", mode == "off")
    if mode != "off" { setField(id, "clipboard_read", mode == "paste" ? "paste" : "always") }
}

func setLocation(_ id: String, _ args: [String]) {
    if args == ["-"] { return setField(id, "location", "-") }
    guard let lat = Double(args[0]), let lon = Double(args[1]) else { die(usage) }
    if !(-90...90).contains(lat) || !(-180...180).contains(lon) { die(t("经纬度超出范围", "Latitude or longitude out of range")) }
    var rest = Array(args.dropFirst(2))
    let mars = rest.first == "--mars"  // 界面在中国大陆选点时已换算成 WGS-84，记下来以便地图上换回显示
    if rest.first == "--mars" || rest.first == "--wgs" { rest.removeFirst() }
    setField(id, "location", ["lat": lat, "lon": lon, "name": rest.joined(separator: " "), "mars": mars])
}

func setBlock(_ id: String, _ device: String, _ on: Bool) {
    update(id) { e in
        let items = (e["block"] as? [String] ?? DEFAULT_BLOCK).filter { $0 != device } + (on ? [device] : [])
        e["block"] = pySorted(items)
    }
}

// MARK: - 沙盒规则

func commonRules(_ rule: Dict, _ conf: Dict, _ mode: String = "space") -> [String] {
    let inject = truthy(conf["inject"])
    var L = [";; 不许借系统工具跑到结界外", "(deny process-exec"] + NO_EXEC.map { "  (literal \(q($0)))" } + [")"]
    if !opt(rule, conf, "keep_username") {
        L += [";; 挡住目录服务，软件查不到真实用户名", "(deny mach-lookup"] + DIRECTORY_SERVICES.map { "  (global-name \(q($0)))" } + [")"]
    }
    if !opt(rule, conf, "keep_identity") {
        let ids = HARDWARE_IDS + (inject ? [] : DEVICE_IDS)
        L += [";; 挡住序列号、硬件 UUID、网卡地址等能认出这台 Mac 的值",
              "(deny iokit-get-properties (with errno 2) (iokit-property " + ids.map(q).joined(separator: " ") + "))"]
        if !inject {
            // 开机时间、本次开机编号、磁盘服务给的分区 UUID 也能对上号；能注入的换成假的，不能注入的挡掉
            L += ["(deny sysctl-read (sysctl-name \"kern.bootsessionuuid\") (sysctl-name \"kern.boottime\"))",
                  "(deny mach-lookup (global-name \"com.apple.DiskArbitration.diskarbitrationd\"))"]
        } else {
            // 注入库只进得了软件自己的程序；它调起的系统程序（ioreg、diskutil、ifconfig、scutil、hostname）不能注入，
            // 实测会读出真实的序列号、分区 UUID、网卡地址、电脑名和主机名。这些只对系统程序挡掉
            let sys = "(process-attribute is-platform-binary)"
            L += [";; 软件调起的系统程序读不到真实的设备信息",
                  "(deny iokit-get-properties (with errno 2) (require-all \(sys) (iokit-property " + DEVICE_IDS.map(q).joined(separator: " ") + ")))",
                  "(deny sysctl-read (require-all \(sys) (sysctl-name \"kern.bootsessionuuid\" \"kern.boottime\" \"kern.hostname\")))",
                  "(deny sysctl-read (require-all \(sys) (sysctl-name-regex #\"^net\\.routetable\\.0\\.[0-9]+\\.(3|6)\\.\")))",
                  "(deny mach-lookup (require-all \(sys) (global-name \"com.apple.DiskArbitration.diskarbitrationd\" \"com.apple.SystemConfiguration.configd\")))",
                  "(deny file-read* (require-all \(sys) (literal \"/Library/Preferences/SystemConfiguration/preferences.plist\")))"]
        }
    }
    if !inject {
        // IPv4 的 ARP 条目系统已不给普通程序，IPv6 的邻居表仍带路由器的网卡地址，能认出你在哪个网络。
        // 只挡 IPv6 与全部协议的整表导出（1 dump、2 按标志、7 dump2）；网卡列表（3、6）照常，不影响联网
        L += [";; 看不到局域网邻居的网卡地址",
              "(deny sysctl-read (sysctl-name-regex #\"^net\\.routetable\\.[0-9]+\\.(0|30)\\.(1|2|7)\\.\"))"]
    }
    if !truthy(conf["allow_open"]) {
        // 经系统拉起的软件不在结界里，挡住它就挡住了借别的软件逃出去的路；代价是不能用浏览器打开链接
        L += [";; 不许拉起其他软件、不许给其他软件发自动化指令", "(deny lsopen)", "(deny appleevent-send)"]
    }
    // 运行中的软件列表来自 launchservicesd，挡住它图形软件就启动不了，所以只挡进程信息
    if !opt(rule, conf, "allow_procinfo") {
        // 进程表另有一条 sysctl 的路，只挡 process-info 挡不住（实测能列出全部进程和名字）；
        // 按编号查查得到自己也查得到别人，能注入的由注入库只放行自己，不能注入的整个挡掉
        var procs = ["(sysctl-name \"kern.proc.all\")"] + ["uid", "ruid", "pgrp", "tty", "sid"].map { "(sysctl-name-prefix \"kern.proc.\($0)\")" }
        if !inject { procs.append("(sysctl-name-prefix \"kern.proc.pid\")") }
        L += [";; 看不到其他进程", "(deny process-info* (target others))", "(deny process-info-listpids)",
              "(deny sysctl-read \(procs.joined(separator: " ")))"]
    }
    // 登录项、后台项目和特权助手由 launchd 在结界外启动，等于逃出结界（实测沙盒内 SMAppService 注册登录项成功）；
    // 申请管理员权限同理。挡住后注册返回错误、不弹密码框，要装助手请在结界外进行
    L += [";; 不许注册登录项、后台项目和特权助手，不许申请管理员权限",
          "(deny mach-lookup (global-name \"com.apple.xpc.smd\") (global-name-prefix \"com.apple.backgroundtaskmanagement\")",
          "  (global-name \"com.apple.authd\") (global-name \"com.apple.security.authtrampoline\"))"]
    if !truthy(rule["allow_spotlight"]) {
        // 聚焦搜索由系统服务代查，不过文件规则：实测挡住“应用程序”文件夹后仍能搜出 /Applications 里的全部软件。
        // 代价是软件内和打开／存储面板里的搜索失效
        L += [";; 不许用聚焦搜索列出已安装的软件和文件", "(deny mach-lookup (global-name \"com.apple.metadata.mds\"))"]
    }
    if !opt(rule, conf, "allow_localhost") {
        // 本机上别的程序开的端口（代理面板、开发服务器、其他软件的本地接口）不让它碰；系统代理的端口留着，不然上不了网。
        // 它只能连分给它的那组端口：能注入的软件自己开端口时，注入库把端口挪进这组（见 inject.c）。
        // 沙盒规则只能写“任意地址”或“本机”，局域网设备交给 macOS 的“本地网络”权限
        let ports = (conf["ports"] as? [NSNumber])?.map(\.intValue) ?? [0, 0]
        let (start, count) = (ports.first ?? 0, ports.count > 1 ? ports[1] : 0)
        L += [";; 不许连本机上其他程序的网络端口，只许连分给它的端口", "(deny network-outbound (remote ip \"localhost:*\"))"]
        L += (proxyPorts() + Array(start..<(start + count))).map { "(allow network-outbound (remote ip \"localhost:\($0)\"))" }
    }
    if mode != "space" {
        // 你的钥匙串在结界文件夹之外，不开放。原地运行的软件家目录就是你的，没法给它单独的钥匙串，只能整个挡住
        L += [";; 挡住钥匙串，代价是依赖钥匙串的登录会失效",
              "(deny mach-lookup (global-name \"com.apple.securityd.xpc\") (global-name \"com.apple.SecurityServer\") (global-name \"com.apple.secd.keychain\"))"]
    }
    for d in blockedDevices(conf, inject) { L += DEVICES[d] ?? [] }
    return L
}

/// 系统代理的端口，读系统的网络配置
func proxyPorts() -> [Int] {
    guard let p = SCDynamicStoreCopyProxies(nil) as? Dict else { return [] }
    return Array(Set(["HTTPPort", "HTTPSPort", "SOCKSPort"].compactMap { (p[$0] as? NSNumber)?.intValue })).sorted()
}

let PORT_RANGE = (20000, 40000), PORT_BLOCK = 32  // 每个软件分一组端口，各组不重叠

/// 本机上已经有程序占着的端口（TCP 在监听的、UDP 绑定了的）。
func busyPorts() -> Set<Int> {
    var out = Set<Int>()
    for line in sh(["/usr/sbin/netstat", "-an"]).out.split(separator: "\n").map(String.init)
    where (line.hasPrefix("tcp") || line.hasPrefix("udp")) && (line.contains("LISTEN") || line.hasPrefix("udp")) {
        let f = line.split(whereSeparator: { $0 == " " || $0 == "\t" }).map(String.init)
        guard f.count > 3, let p = match("[.:](\\d+)\\s", f[3] + " ")?[1].flatMap({ Int($0) }) else { continue }
        out.insert(p)
    }
    return out
}

/// 分给它的端口：沿用上次的；启动前那组里有别的程序在占（它此时没在运行），就换一组。
func portBlock(_ id: String) -> (Int, Int) {
    let data = settings()
    let busy = busyPorts()
    let taken = Set(data.compactMap { k, c -> Int? in
        guard k != id, let c = c as? Dict, truthy(c["ports"]) else { return nil }
        return ((c["ports"] as? [NSNumber])?.first)?.intValue
    })
    let start = ((data[id] as? Dict)?["ports"] as? [NSNumber])?.first?.intValue ?? 0
    if start != 0 && busy.isDisjoint(with: start..<(start + PORT_BLOCK)) { return (start, PORT_BLOCK) }
    for s in stride(from: PORT_RANGE.0, to: PORT_RANGE.1, by: PORT_BLOCK) where !taken.contains(s) && busy.isDisjoint(with: s..<(s + PORT_BLOCK)) {
        setField(id, "ports", [s, PORT_BLOCK])
        return (s, PORT_BLOCK)
    }
    return (0, 0)
}

func allowedDirs(_ conf: Dict) -> [String] { (conf["allow"] as? [String] ?? []).map(realPath) }

func setAllow(_ id: String, _ action: String, _ path: String) {
    let real = realPath(expandUser(path))
    update(id) { e in
        let items = (e["allow"] as? [String] ?? []).filter { $0 != real }
        e["allow"] = action == "add" ? items + [real] : items
    }
}

func appGroups(_ app: String) -> [String] { entitlements(app)["com.apple.security.application-groups"] as? [String] ?? [] }

func buildProfile(_ app: String, _ id: String, _ rule: Dict, _ conf: Dict, _ mode: String, _ groups: [String] = []) -> String {
    var L = ["(version 1)", "(allow default)", ";; 被挡的路径一律显示为不存在", "(deny file-read* file-write* (with errno 2)"]
        + BLOCKED.map { "  (subpath \(q($0)))" } + [")", "(deny file-read-data (with errno 2) (literal \"/Users\"))"]
    if !truthy(rule["shared_tmp"]) {
        // 共用临时、缓存文件夹只放行系统的和它自己的条目；临时文件改放它自己的文件夹
        let mine = (ownNames(id, rule) + nestedIds(app).sorted() + ["com.apple."]).map(reEscape).joined(separator: "|")
        L += ["(deny file-read* file-write* (with errno 2)", "  (subpath \(q(USER_TEMP))) (subpath \(q(USER_CACHE))))"]
        L += [USER_TEMP, USER_CACHE].map { "(allow file-read* file-write* (regex #\"^\(reEscape($0))/\\.?(\(mine))[^/]*(/.*)?$\"))" }
        L.append("(allow file-read-metadata (literal \(q(USER_TEMP))) (literal \(q(USER_CACHE))) (literal \(q(USER_TEMP + "/TemporaryItems"))))")
        // 系统安全替换文件时建的临时文件夹，以软件显示名命名
        let shown = (displayNames(app) + ownNames(id, rule)).map(reEscape).joined(separator: "|")
        L.append("(allow file-read* file-write* (regex #\"^\(reEscape(USER_TEMP))/TemporaryItems/NSIRD_(\(shown))_[^/]+(/.*)?$\"))")
    }
    L += ["(deny file-read-data (with errno 2)"] + NO_LIST.map { "  (literal \(q($0)))" } + [")"]
    var system = (rule["system_paths"] as? [String] ?? []).map { "(subpath \(q($0)))" }
    system += (rule["system_regex"] as? [String] ?? []).map { "(regex #\"\($0.replacingOccurrences(of: "^~", with: "^" + reEscape(HOME)))\")" }
    L.append("(allow file-read* (subpath \(q(app))) (subpath \(q(LIBDIR))))")
    // /usr/bin/git、clang 等只是转到 Xcode 命令行工具的壳，挡住开发工具目录它们就全失效
    var dev = sh(["/usr/bin/xcode-select", "-p"]).out.trimmingCharacters(in: .whitespacesAndNewlines)
    if !dev.isEmpty {
        dev = ancestors(dev).first { $0.hasSuffix(".app") } ?? dev  // xcodebuild 还要读 Xcode.app 里别的框架
        L += ["(allow file-read-metadata \(ancestors(dev).map { "(literal \(q($0)))" }.joined(separator: " ")))", "(allow file-read* (subpath \(q(dev))))"]
    }
    let approved = allowedDirs(conf)
    if mode == "space" {
        let space = spaceOf(id)
        L += [";; 所有改动都落在模拟区域，另加你批准的文件夹", "(allow file-read-metadata"]
        L += pySorted(Set(ancestors(space) + approved.flatMap(ancestors))).map { "  (literal \(q($0)))" }
        L += ["  (literal \"/Applications\") (literal \"/Volumes\"))", "(allow file-read* file-write*", "  (subpath \(q(space)))"]
        L += approved.map { "  (subpath \(q($0)))" } + system.map { "  " + $0 } + [")"]
        // 打开项目时常先列出上一级找它（实测微信开发者工具），只给看名字，不给读内容
        L += approved.map { "(allow file-read-data (literal \(q(parent($0)))))" }
        // 软件存下的旧绝对路径要经过旧位置的链接（实测 QQ 的储存路径），只放行链接本身，指向的地方照常按上面判断
        if isSymlink(OLD_SPACES) { L.append("(allow file-read-metadata (literal \(q(OLD_SPACES))))") }
    } else {
        // 按 ID 放行 com.tencent.qq 和 com.tencent.qq.share 这类，不放行 com.tencent.qqmusic
        let names = pySorted(Set(ownNames(id, rule)).union(nestedIds(app)))
        // 沙盒正则把 [._-] 当范围，连字符要放最前
        var own = names.map { "(regex #\"^\(reEscape(HOME))/Library/([^/]+/)?\(reEscape($0))([-._][^/]*)?(/.*)?$\")" }
        // 按名字只在常见数据目录里放行同名文件夹，避免名字叫 Mail 的软件碰到 ~/Library/Mail
        let bases = NAME_BASES.map(reEscape).joined(separator: "|")
        own += displayNames(app).map { "(regex #\"^\(reEscape(HOME))/Library/(\(bases))/\(reEscape($0))(/.*)?$\")" }
        var extra = (rule["home_paths"] as? [String] ?? []).map { "(subpath \(q(HOME + "/" + $0)))" }
        extra += groups.map { "(subpath \(q("\(HOME)/Library/Group Containers/\($0)")))" }
        let inbox = inboxOf(id, mode)
        extra.append("(subpath \(q(inbox)))")  // 不放行上一级，看不到别的软件的传输文件夹
        let parents = pySorted(Set(["/Users", HOME, "\(HOME)/Library", "/Applications", "/Volumes"] + ancestors(inbox)
                                   + OWN_BASES.map { "\(HOME)/Library/\($0)" } + ancestors(app) + approved.flatMap(ancestors)))
        L += [";; 只放行它自己的数据和你批准的文件夹", "(allow file-read-metadata"] + parents.map { "  (literal \(q($0)))" } + [")"]
        L += ["(allow file-read* file-write*"] + own.map { "  " + $0 } + extra.map { "  " + $0 }
            + approved.map { "  (subpath \(q($0)))" } + system.map { "  " + $0 } + [")"]
        L += approved.map { "(allow file-read-data (literal \(q(parent($0)))))" }
        L += ["(allow file-read* (literal \(q(HOME + "/.CFUserTextEncoding"))))", "(allow file-read-metadata (subpath \(q(HOME + "/Library/Keychains"))))"]
    }
    // 输入法和键盘布局，打字要用
    L.append("(allow file-read* (subpath \(q(HOME + "/Library/Input Methods"))) (subpath \(q(HOME + "/Library/Keyboard Layouts"))))")
    // 模拟区域里没有旧数据，有的软件发现空的旧数据目录就要授权，让这一步看到“目录不存在”
    let hide = mode == "space" ? (rule["space_hide_stat"] as? [String] ?? []).map { "  (literal \(q(spaceOf(id) + "/" + $0)))" } : []
    if !hide.isEmpty { L += ["(deny file-read-metadata (with errno 2)"] + hide + [")"] }
    return (L + commonRules(rule, conf, mode) + neverRules()).joined(separator: "\n") + "\n"
}

func effectiveMode(_ id: String, _ conf: Dict, _ rule: Dict) -> String {
    // 所有软件默认在自己的结界文件夹里运行。个别软件用“书签”记住数据文件夹的真实位置，搬走就失效（实测腾讯会议），规则里写 "mode": "real" 原地运行
    conf["mode"] as? String ?? rule["mode"] as? String ?? "space"
}

func label(_ id: String) -> String { "io.github.wjsgzz.kekkai.\(id)" }

func launchctl(_ args: String...) -> Output { sh(["/bin/launchctl"] + args) }

/// 换下同名的任务再装上。bootout 返回时旧进程可能还在退出，这时 bootstrap 报 5（实测 QQ 退出约一秒后再打开），
/// 所以等旧任务从 launchd 里消失，仍报错就稍后再试
@discardableResult
func reload(_ name: String, _ job: String) -> Output {
    launchctl("bootout", "gui/\(UID)/\(name)")
    var waited = 0
    while waited < 50 && launchctl("print", "gui/\(UID)/\(name)").code == 0 { sleepSeconds(0.1); waited += 1 }
    var r = launchctl("bootstrap", "gui/\(UID)", job), tries = 0
    while r.code != 0 && tries < 5 {
        sleepSeconds(0.5); tries += 1
        r = launchctl("bootstrap", "gui/\(UID)", job)
    }
    return r
}

/// 替这个软件接住拖进来、粘贴进来的文件的中转程序：在结界外运行，复制一份进传输文件夹，软件退出后自行结束
func startRelay(_ id: String, _ app: String, _ sock: String, _ inbox: String) {
    let n = label(id) + ".relay", job = "\(STATE)/\(n).plist"
    writePlist(["Label": n, "ProgramArguments": [ROOT + "/kekkai-relay", sock, app, STATE, inbox] + neverList(),
                "RunAtLoad": true, "KeepAlive": false, "ProcessType": "Interactive", "LimitLoadToSessionType": "Aqua",
                "StandardErrorPath": "/dev/null", "StandardOutPath": "/dev/null",
                "EnvironmentVariables": ["KEKKAI_SPACE": spaceOf(id)]] as Dict, job)
    reload(n, job)
}

let LEARN_PROFILE = "(version 1)\n(allow default)\n(allow file-read* file-write* (with report))\n"
let INTERESTING = [HOME + "/", "/Users/Shared", "/Volumes/", "/Applications/", "/private/tmp/"]

func logShow(_ start: String, _ predicate: String) -> String {
    sh(["/usr/bin/log", "show", "--start", start, "--style", "compact", "--predicate", predicate]).out
}

func report(_ appArg: String) {
    let app = realPath(appArg), id = mustInfo(app).id
    let start = (readText("\(STATE)/\(id).learn-start") ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
    var seen: [String: Set<String>] = [:]
    for line in logShow(start, "senderImagePath CONTAINS \"Sandbox\" AND eventMessage CONTAINS \" allow file-\"").split(separator: "\n").map(String.init) {
        guard let m = match(" allow file-(read|write)[^ ]* (/.*)$", line), let kind = m[1], let path = m[2],
              !path.hasPrefix(app + "/"), INTERESTING.contains(where: path.hasPrefix) else { continue }
        let parts = path.components(separatedBy: "/")
        let key = parts.prefix(path.hasPrefix(HOME + "/Library/") ? 7 : 5).joined(separator: "/")
        seen[key, default: []].insert(kind)
    }
    let lines = pySorted(seen.keys).map { k -> String in
        let v = seen[k]!
        return "\(v.count > 1 ? t("读写", "R/W") : v.contains("write") ? t("写", "W") : t("读", "R"))  \(k)"
    }
    let head = t("\(stem(app)) 从 \(start) 起碰过的外部路径（共 \(lines.count) 组，系统日志可能合并或遗漏）：",
                 "Outside paths \(stem(app)) touched since \(start) (\(lines.count) groups; the system log may merge or drop entries):")
    let out = "\(STATE)/\(id)-report.txt"
    writeText(out, head + "\n" + lines.joined(separator: "\n") + "\n")
    print(out)
}

// MARK: - 副本

// 去掉这些后才能用临时签名重签；苹果沙盒不能叠加，受限权限没有描述文件会被系统拒绝
let STRIP = ["com.apple.security.app-sandbox", "com.apple.security.inherit", "com.apple.application-identifier",
             "com.apple.developer.", "keychain-access-groups"]

func stripped(_ key: String) -> Bool { STRIP.contains(where: key.hasPrefix) }

func resign(_ bundle: String) {
    let kept = entitlements(bundle).filter { !stripped($0.key) }
    mkdirs(STATE)
    let tmp = STATE + "/entitlements.plist"
    writePlist(kept, tmp)
    let r = sh(["/usr/bin/codesign", "-f", "-s", "-", "--entitlements", tmp, bundle])
    if r.code != 0 { die(t("重签名失败：\(r.err.trimmingCharacters(in: .whitespacesAndNewlines))", "Re-signing failed: \(r.err.trimmingCharacters(in: .whitespacesAndNewlines))")) }
}

/// 在模拟区域里放一份 APFS 克隆，去掉苹果沙盒和强化运行时后重签，原 App 不动。
/// 自带苹果沙盒的 App 再套一层会崩溃；虚拟定位要注入，也要用副本。
func localCopy(_ app: String, _ id: String) -> String {
    mkdirs(SPACES)
    let dst = spaceOf(id) + "/Applications/" + name(app)
    let stamp = dst + ".source"
    let srcId = mtime(app + "/Contents/Info.plist")
    if exists(dst) && readText(stamp) == srcId { return dst }
    remove(dst)
    mkdirs(parent(dst))
    if sh(["/bin/cp", "-cR", app, dst]).code != 0 { die(t("无法复制 \(name(app))", "Couldn't copy \(name(app))")) }
    resignDeep(dst)
    writeText(stamp, srcId)
    return dst
}

/// 连同里面的小程序一起去掉苹果沙盒和强化运行时重签
func resignDeep(_ dst: String) {
    let files = walk(dst + "/Contents").filter { !isSymlink($0) }
    let bundles = files.filter { ["app", "appex", "xpc"].contains(($0 as NSString).pathExtension) && isDir($0) }
    let loose = files.filter { isFile($0) && access($0, X_OK) == 0 && name(parent($0)) != "MacOS" && entitlements($0).keys.contains(where: stripped) }  // 如微信的 crashpad_handler
    for b in loose + bundles.sorted(by: { $0.components(separatedBy: "/").count > $1.components(separatedBy: "/").count }) {  // 先签里层
        resign(b)
    }
    resign(dst)
}

/// 软件自己下载到结界文件夹里的程序（实测 QQ 7.0.3 起真正的 QQ 是 versions/<版本>/QQUpdate.app，由 QQ.app 拉起）。
/// 它们带原厂的强化签名，注入库进不去，伪装不生效：和副本一样重签。记下它们的程序名，拦截记录也算上
func prepareParts(_ id: String) {
    let space = spaceOf(id)
    let found = sh(["/usr/bin/find", space + "/Library", "-maxdepth", "7", "-type", "d", "-name", "*.app", "-prune"]).out
        .split(separator: "\n").map(String.init).filter { !$0.contains("/Caches/") }
    var exes: [String] = []
    for b in found {
        guard let (_, exe) = info(b) else { continue }
        exes.append(exe)
        let stamp = parent(b) + "/." + name(b) + ".kekkai"
        let srcId = mtime(b + "/Contents/Info.plist")
        if readText(stamp) == srcId || injectable(b) { continue }
        resignDeep(b)
        writeText(stamp, srcId)
    }
    writeText("\(STATE)/\(id).parts", exes.joined(separator: "\n"))
}

/// App Store 版的程序按容器的位置找数据（~/Library/Containers/<id>/Data/Library/Application Support）；
/// 副本不在容器里，数据在结界文件夹的 Library/Application Support。补一条同名路径指过去，两边看到同一份（实测 QQ 7.0.3 的 QQUpdate.app）
func linkContainerData(_ id: String) {
    let space = spaceOf(id)
    let lib = "\(space)/Library/Containers/\(id)/Data/Library"
    let link = lib + "/Application Support"
    if exists(link) || isSymlink(link) { return }
    mkdirs(lib)
    mkdirs(space + "/Library/Application Support")
    try? FM.createSymbolicLink(atPath: link, withDestinationPath: "../../../../Application Support")
}

// MARK: - 拦截记录

/// 操作的准确叫法。
func verb(_ opIn: String) -> String {
    let op = opIn.hasPrefix("system:") ? String(opIn.dropFirst(7)) : opIn
    let names: [String: (String, String)] = [
        "file-read-metadata": ("读取属性", "Inspect"), "file-write-create": ("创建", "Create"), "file-write-unlink": ("删除", "Delete"),
        "mach-lookup": ("连接", "Connect to"), "network-outbound": ("连接", "Connect to"), "lsopen": ("启动", "Launch"),
        "appleevent-send": ("发送指令", "Send events to"), "process-info-listpids": ("列出", "List")]
    if let n = names[op] { return t(n.0, n.1) }
    if op.hasPrefix("file-write-data") { return t("写入", "Write") }
    if op.hasPrefix("file-write") { return t("修改属性", "Modify") }
    if op.hasPrefix("file-read") { return t("读取", "Read") }
    return op.hasPrefix("process-info") ? t("读取信息", "Inspect") : op
}

// 类别：(中文, 英文, 档次)。常规：系统框架自己发出的；留意：可能是正常需要，值得你知道；越权：超出它本职的探查
let CATS: [String: (String, String, String)] = [
    "macos": ("被 macOS 拒绝（非结界）", "Refused by macOS (not Kekkai)", "note"),
    "bundle": ("自身应用包", "Its own app bundle", "routine"),
    "owndata": ("原版自己的数据", "The original app's own data", "routine"),
    "sysproc": ("系统进程信息", "System process info", "routine"),
    "account": ("用户账户信息", "User account info", "routine"),
    "service": ("系统服务", "System services", "routine"),
    "sysfiles": ("系统设置、词典与崩溃报告", "System settings, dictionaries and crash reports", "routine"),
    "temp": ("临时文件", "Temporary files", "routine"),
    "sysvol": ("系统分区", "System volumes", "routine"),
    "homeroot": ("主目录本身", "Your home folder itself", "routine"),
    "personal": ("个人文件夹", "Your folders", "note"),
    "home": ("主目录中的其他项目", "Other items in your home folder", "note"),
    "disk": ("外接磁盘", "External disks", "note"),
    "ownport": ("连接自身组件（本机临时端口）", "Its own parts (temporary ports on this Mac)", "note"),
    "downloads": ("系统下载记录", "System download history", "note"),
    "clipboard": ("剪贴板（已设为禁止）", "Clipboard (set to Off)", "note"),
    "launch": ("启动或控制其他应用", "Launching or controlling other apps", "note"),
    "sharedtmp": ("共享临时文件夹", "Shared temporary folders", "note"),
    "other": ("其他", "Other", "note"),
    "proc": ("获取其他程序的运行信息", "Inspecting other running programs", "overreach"),
    "apps": ("扫描已安装的应用", "Scanning installed apps", "overreach"),
    "installs": ("扫描系统级安装内容", "Scanning system-wide installs", "overreach"),
    "appdata": ("查看其他应用的数据", "Looking at other apps' data", "overreach"),
    "apptemp": ("查看其他应用的临时文件", "Looking at other apps' temporary files", "overreach"),
    "spaces": ("查看其他软件的结界文件夹", "Looking at other apps' Kekkai folders", "overreach"),
    "hidden": ("读取主目录中的隐藏文件", "Reading hidden files in your home folder", "overreach"),
    "localhost": ("探测本机端口", "Probing ports on this Mac", "overreach"),
]
let NORMAL = Set(CATS.filter { $0.value.2 == "routine" }.keys)
let SUSPICIOUS = Set(CATS.filter { $0.value.2 == "overreach" }.keys)
// 它可能真需要、值得你决定的
let ASKS: Set = ["personal", "home", "other", "disk", "ownport"]
// 图形软件的系统框架自己会查这些进程【推断，依据是各软件都有这几条】
let SYSTEM_PROCS: Set = ["WindowServer", "initproc", "launchd", "WindowManager", "MenuBarAgent", "Dock", "loginwindow",
                         "ControlCenter", "SystemUIServer", "ScreenTimeSettingsAgent", "NotificationCenter"]
// 系统框架自己会碰的个人资料库位置【推断，依据是各软件都有：拼写检查、崩溃报告、系统偏好、网络缓存的上层文件夹】
let SYSTEM_LIBRARY = ["Spelling", "Application Support/CrashReporter", "Preferences/com.apple.", "Preferences/.GlobalPreferences",
                      "Keychains", "Caches/com.apple.", "Keyboard Layouts", "Input Methods"]

func catName(_ key: String) -> String { let c = CATS[key]!; return t(c.0, c.1) }

/// 把一条拦截归类，返回 CATS 里的键。
func categorize(_ op: String, _ targetIn: String, _ app: String = "", _ id: String = "") -> String {
    let h = HOME + "/"
    let target = sub("^remote:\\*:", "localhost:", targetIn)
    func starts(_ prefixes: [String]) -> Bool { prefixes.contains(where: target.hasPrefix) }
    if op.hasPrefix("system:") { return "macos" }
    if !app.isEmpty && (target == app || target.hasPrefix(app + "/")) { return "bundle" }
    if !app.isEmpty && target.hasPrefix(SPACES + "/") && target.contains("/Applications/" + name(app)) { return "bundle" }  // 它自己的副本
    if !id.isEmpty && target.hasPrefix("\(h)Library/Containers/\(id)/") { return "owndata" }
    if op.hasPrefix("process-info") { return SYSTEM_PROCS.contains(target) ? "sysproc" : "proc" }
    if op == "lsopen" || op == "appleevent-send" { return "launch" }
    if op.hasPrefix("network") {
        // 临时端口（49152 起）多半是它自己的子进程开的；固定端口是别的程序的服务
        let port = target.components(separatedBy: ":").last ?? ""
        return Int(port).map { $0 >= 49152 } == true && port.allSatisfy(\.isASCII) ? "ownport" : "localhost"
    }
    if op == "mach-lookup" {
        if target.contains("opendirectoryd") { return "account" }
        return target.contains("pasteboard") ? "clipboard" : "service"
    }
    if target == "/Applications" || target == h + "Applications" || starts(["/Applications/", "/System/Applications/", h + "Applications/"]) { return "apps" }
    if starts(["Desktop", "Documents", "Downloads", "Pictures", "Movies", "Music", "Library/Mobile Documents"].map { h + $0 }) { return "personal" }
    if target.contains("QuarantineEvents") { return "downloads" }
    if target.hasPrefix(h + "Library/") {
        let rel = String(target.dropFirst((h + "Library/").count))
        // 上层文件夹只查属性，是系统框架在建自己的位置；列出内容或进到别人的文件夹才算越权
        if SYSTEM_LIBRARY.contains(where: rel.hasPrefix) || !rel.contains("/") && !op.hasPrefix("file-read-data") { return "sysfiles" }
        return "appdata"
    }
    if target == HOME { return "homeroot" }
    if target.hasPrefix(h + ".") { return "hidden" }
    if ["/Volumes/Recovery", "/Volumes/Preboot", "/Volumes/VM", "/Volumes/Data"].contains(target) { return "sysvol" }
    if target.hasPrefix("/Volumes/") { return "disk" }
    if target == USER_TEMP || target == USER_CACHE || target == parent(USER_TEMP) { return "apptemp" }  // 列出共用临时文件夹，看得到所有软件的东西
    if starts([USER_TEMP + "/TemporaryItems", USER_TEMP + "/scoped_dir"]) || !id.isEmpty && starts([USER_TEMP, USER_CACHE]) && target.contains(id) { return "temp" }
    if starts([USER_TEMP, USER_CACHE]) { return "apptemp" }
    if NO_LIST.contains(target) || starts(["/Library/", "/opt/", "/usr/local/"]) { return "installs" }
    if target == SPACES || target.hasPrefix(SPACES + "/") { return "spaces" }
    if starts(["/private/tmp", "/Users/Shared"]) { return "sharedtmp" }
    if target.hasPrefix(h) { return "home" }
    return "other"
}

typealias Denial = (when: String, op: String, target: String)

/// 系统日志里这个软件（含附带的小程序）从 start 起被沙盒拒绝的请求。
func denials(_ app: String, _ start: String) -> [Denial] {
    // 按 MacOS 文件夹里的文件认进程：有的辅助程序 Info.plist 不写 CFBundleExecutable（实测微信开发者工具的 Helper）
    var dirs = [app + "/Contents/MacOS"]
    dirs += walk(app + "/Contents").filter { $0.hasSuffix("/Contents/MacOS") && isDir($0) && !isSymlink($0) }
    var exes = Set(dirs.filter(isDir).flatMap(listDir))
    if let id = info(app)?.id, let parts = readText("\(STATE)/\(id).parts") {  // 结界文件夹里它自己下载的程序
        exes.formUnion(parts.split(separator: "\n").map(String.init))
    }
    var out: [Denial] = []
    let lines = logShow(start, "senderImagePath CONTAINS \"Sandbox\" AND eventMessage CONTAINS \" deny(\"").split(separator: "\n").map(String.init)
    for line in lines {
        guard let m = match("(Sandbox|System Policy): (.+?)\\(\\d+\\) deny\\(\\d+\\) (\\S+) (.*)$", line), let proc = m[2], exes.contains(proc) else { continue }
        let op = (m[1] == "System Policy" ? "system:" : "") + (m[3] ?? "")
        var target = (m[4] ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        if op.hasPrefix("process-info") { target = sub("\\(\\d+\\)", "", sub("^others \\[|\\]$", "", target)) }
        if op.hasPrefix("network") { target = sub("^remote:\\*:", "localhost:", target) }
        out.append((String(line.prefix(19)), op, target))
    }
    return out
}

/// 这条请求能怎么放行：folder 批准路径，open 允许打开其他软件，clipboard 解除剪贴板禁止。
func grantKind(_ op: String, _ target: String) -> String {
    if op.hasPrefix("system:") { return "" }
    if op.hasPrefix("file-") && target.hasPrefix("/") {
        // 这些是很多软件共用的上层文件夹，放行就等于放出别人的数据
        let lib = HOME + "/Library"
        let shared = Set(["/", "/Users", HOME, "/Applications", "/Volumes", "/private/tmp", "/Users/Shared", lib,
                          USER_TEMP, USER_CACHE, parent(USER_TEMP)] + NO_LIST)
        let p = (target as NSString).standardizingPath, pp = parent(p)
        let mixed = pp == USER_TEMP || pp == USER_CACHE || pp == lib || p.hasPrefix(USER_TEMP + "/TemporaryItems")
        return shared.contains(p) || mixed ? "" : "folder"
    }
    if op == "lsopen" || op == "appleevent-send" { return "open" }
    if op.hasPrefix("network") { return "localhost" }
    return target.contains("pasteboard") ? "clipboard" : ""
}

let ERROR_PATTERN = "EPERM|EACCES|FATAL|Uncaught|Traceback|Exception|operation not permitted"

/// 软件自己日志里从 from 字节起的报错行，最多 6 条
func logErrors(_ file: String, from: Int) -> [String] {
    guard let h = FileHandle(forReadingAtPath: file) else { return [] }
    defer { try? h.close() }
    try? h.seek(toOffset: UInt64(max(0, from)))
    let text = String(decoding: h.readDataToEndOfFile(), as: UTF8.self)
    var errors: [String] = []
    for ln in text.split(separator: "\n", omittingEmptySubsequences: false) where errors.count < 6 {
        let s = String(ln)
        if match(ERROR_PATTERN, s, .caseInsensitive) != nil { errors.append(String(s.trimmingCharacters(in: .whitespacesAndNewlines).prefix(240))) }
    }
    return errors
}

/// 试运行：按结界的最小权限打开，看它能不能活下来，列出它被拒绝的请求。输出 JSON 给界面用。
func trial(_ appArg: String, wait: Int = 40) {
    let app = realPath(appArg), id = mustInfo(app).id
    stop(app)  // 改了放行后再试，要先关掉上一次的
    for _ in 0..<10 {
        if launchctl("print", "gui/\(UID)/\(label(id))").code != 0 { break }
        sleepSeconds(1)
    }
    if let msg = run(app) { return printJSON(["error": msg]) }
    let start = (readText("\(STATE)/\(id).started") ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
    let binary = readText("\(STATE)/\(id).binary") ?? ""
    let logFile = "\(STATE)/\(id).log"
    let logFrom = fileSize(logFile)
    var exitedAt: String?
    for _ in 0..<wait {
        sleepSeconds(1)
        if !processRunning(binary) { exitedAt = now(); break }
    }
    sleepSeconds(2)  // 等系统日志写完
    let events = denials(app, start)
    let code = match("last exit code = (\\S+)", launchctl("print", "gui/\(UID)/\(label(id))").out)?[1]
    let decisions = conf(id)["decided"] as? Dict ?? [:]
    var seen = Set<String>(), items: [Dict] = []
    for e in events {
        let key = "\(e.op) \(e.target)"
        guard seen.insert(key).inserted else { continue }
        let cat = categorize(e.op, e.target, app, id)
        let suspect = e.op.hasPrefix("system:") || exitedAt.map { e.when >= String($0.prefix(17)) + "00" && !NORMAL.contains(cat) } == true
        items.append(["key": key, "decision": decisions[key] ?? NSNull(), "op": e.op, "target": e.target, "verb": verb(e.op), "category": catName(cat),
                      "time": e.when, "count": events.filter { $0.op == e.op && $0.target == e.target }.count,
                      "suspicious": SUSPICIOUS.contains(cat), "normal": NORMAL.contains(cat), "grant": grantKind(e.op, e.target),
                      // 退出前几秒内被拒的，最可能是它退出的原因
                      "suspect": suspect])
    }
    blocked(app, quiet: true)
    // 软件还活着不代表正常，它可能弹了报错；把它自己日志里的报错也带上
    let errors = logErrors(logFile, from: logFrom)
    let systemDenied = items.contains { ($0["op"] as? String ?? "").hasPrefix("system:") }
    printJSON(["errors": errors, "systemDenied": systemDenied, "alive": exitedAt == nil,
               "exitCode": (exitedAt != nil ? code ?? nil : nil) ?? NSNull(), "seconds": wait, "items": items] as Dict)
}

/// 记下你对一条请求的决定；允许时顺带放行。
func decide(_ id: String, _ choice: String, _ key: String) {
    let parts = key.split(separator: " ", maxSplits: 1).map(String.init)
    let (op, target) = (parts[0], parts.count > 1 ? parts[1] : "")
    if choice == "allow" {
        switch grantKind(op, target) {
        case "folder": setAllow(id, "add", target)
        case "open": setField(id, "allow_open", true)
        case "localhost": setField(id, "allow_localhost", true)
        case "clipboard": setBlock(id, "clipboard", false)
        default: break
        }
    }
    update(id) { e in
        var d = e["decided"] as? Dict ?? [:]
        d[key] = choice
        e["decided"] = d
    }
}

/// (是否在运行, 上次退出码)。
func jobState(_ id: String) -> (running: Bool, code: String?) {
    let out = launchctl("print", "gui/\(UID)/\(label(id))").out
    return (out.contains("state = running"), match("last exit (?:code|reason) = (\\S+)", out)?[1] ?? nil)
}

/// 从系统日志里取出结界拦下的请求，并入这个软件的长期记录。
func blocked(_ appArg: String, quiet: Bool = false, asJSON: Bool = false) {
    let app = realPath(appArg), id = mustInfo(app).id
    let startFile = "\(STATE)/\(id).started", historyFile = "\(STATE)/\(id)-blocked.json"
    var history = readJSON(historyFile) as? [String: Dict] ?? [:]
    if exists(startFile) {
        let cursor = now()  // 先记下时间再查，查的过程中新来的下次再取
        for e in denials(app, (readText(startFile) ?? "").trimmingCharacters(in: .whitespacesAndNewlines)) {
            var h = history["\(e.op) \(e.target)"] ?? ["first": e.when, "count": 0]
            h["last"] = e.when
            h["count"] = ((h["count"] as? NSNumber)?.intValue ?? 0) + 1
            history["\(e.op) \(e.target)"] = h
        }
        writeText(historyFile, jsonString(history, pretty: true))
        writeText(startFile, cursor)
    }
    if asJSON { return printJSON(logStatus(app, id, history)) }
    var groups: [String: [(String, Dict)]] = [:]
    for (key, e) in history {
        let parts = key.split(separator: " ", maxSplits: 1).map(String.init)
        let (op, target) = (parts[0], parts.count > 1 ? parts[1] : "")
        groups[categorize(op, target, app, id), default: []].append(("\(verb(op))  \(target)", e))
    }
    func count(_ e: Dict) -> Int { (e["count"] as? NSNumber)?.intValue ?? 0 }
    var lines = [t("\(stem(app)) 被结界拦下的请求（同一请求系统日志只记一部分，次数偏少）", "Requests Kekkai blocked for \(stem(app)) (the system log keeps only some repeats, so counts run low)"), ""]
    for (cat, items) in groups.sorted(by: { $0.value.reduce(0) { $0 + count($1.1) } > $1.value.reduce(0) { $0 + count($1.1) } }) {
        let tag = NORMAL.contains(cat) ? t("　常规", "  Routine") : SUSPICIOUS.contains(cat) ? t("　越权", "  Overreach") : t("　留意", "  Worth a look")
        lines.append(isChinese() ? "## \(catName(cat))（\(items.count)）\(tag)" : "## \(catName(cat)) (\(items.count))\(tag)")
        for (target, e) in items.sorted(by: { count($0.1) > count($1.1) }).prefix(40) {
            let c = String(count(e))
            lines.append("  \(String(repeating: " ", count: max(0, 4 - c.count)))\(c)×  \(target.replacingOccurrences(of: HOME, with: "~"))   \(e["last"] as? String ?? "")")
        }
        lines.append("")
    }
    if history.isEmpty { lines.append(t("还没有记录。在结界中打开它用一会儿再来看。", "Nothing yet. Open it in Kekkai, use it for a while, then check again.")) }
    let out = "\(STATE)/\(id)-blocked.txt"
    writeText(out, lines.joined(separator: "\n") + "\n")
    if !quiet { print(out) }
}

/// 给界面的拦截记录：这次运行的状态、它自己日志里的报错、每条被拦请求和你的决定。
func logStatus(_ app: String, _ id: String, _ historyIn: [String: Dict]) -> Dict {
    var history: [String: Dict] = [:]  // 旧记录把本机端口写成 remote:*:端口，和新写法合并
    for (key, e) in historyIn {
        let k = sub(" remote:\\*:", " localhost:", key)
        var m = history[k] ?? ["first": e["first"] ?? "", "count": 0, "last": e["last"] ?? ""]
        m["count"] = ((m["count"] as? NSNumber)?.intValue ?? 0) + ((e["count"] as? NSNumber)?.intValue ?? 0)
        m["last"] = max(m["last"] as? String ?? "", e["last"] as? String ?? "")
        history[k] = m
    }
    let (running, code) = jobState(id)
    let runStart = (readText("\(STATE)/\(id).run-start") ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
    let exitedFile = "\(STATE)/\(id).exited"
    if !runStart.isEmpty && !running && !exists(exitedFile) {
        writeText(exitedFile, now())  // 界面开着时每几秒查一次，退出时间误差就是这几秒
    }
    let exited = !runStart.isEmpty && !running ? (readText(exitedFile) ?? "").trimmingCharacters(in: .whitespacesAndNewlines) : ""
    var seconds: Int?
    if !exited.isEmpty && !exists("\(STATE)/\(id).stopped"), let a = parseTime(exited), let b = parseTime(runStart) {
        seconds = Int(a.timeIntervalSince(b))
    }
    let logFile = "\(STATE)/\(id).log", posFile = "\(STATE)/\(id).logpos"
    let errors = exists(logFile) && exists(posFile) ? logErrors(logFile, from: Int((readText(posFile) ?? "").trimmingCharacters(in: .whitespacesAndNewlines)) ?? 0) : []
    let decisions = conf(id)["decided"] as? Dict ?? [:]
    let crashed = seconds.map { $0 < 60 } ?? false  // 被停止的不算
    var items: [Dict] = []
    for (key, e) in history {
        let parts = key.split(separator: " ", maxSplits: 1).map(String.init)
        let op = parts[0]
        var target = parts.count > 1 ? parts[1] : ""
        let cat = categorize(op, target, app, id)
        target = sub("^remote:\\*:", "localhost:", target)
        let last = e["last"] as? String ?? ""
        let recent = !runStart.isEmpty && last >= runStart
        let grant = grantKind(op, target)
        // 只在它异常退出时，把退出前被挡、又能放行的请求列出来让你决定；平时都折在分组里
        let ask = crashed && recent && !grant.isEmpty && !NORMAL.contains(cat) && (ASKS.contains(cat) || cat == "appdata")
        items.append(["key": key, "decision": decisions[key] ?? NSNull(), "op": op, "target": target, "verb": verb(op), "category": catName(cat),
                      "count": e["count"] ?? 0, "last": last, "recent": recent, "suspicious": SUSPICIOUS.contains(cat), "normal": NORMAL.contains(cat),
                      "level": CATS[cat]!.2, "grant": grant, "ask": ask])
    }
    // 从网上下载、没经苹果公证的软件，macOS 的门禁在启动时就拦下（实测 OS_REASON_EXEC）；要不要放行是你的决定
    let gatekeeper = !exited.isEmpty && code == "OS_REASON_EXEC" && quarantined(app)
    // 退出码 173 是 App Store 软件要求重新校验购买凭证，重签的副本过不了
    let receipt = !exited.isEmpty && code == "173"
    return ["running": running, "gatekeeper": gatekeeper, "receipt": receipt, "started": runStart.isEmpty ? NSNull() : runStart,
            "exited": exited.isEmpty ? NSNull() : exited, "seconds": seconds.map { $0 as Any } ?? NSNull(),
            "exitCode": (!exited.isEmpty ? code : nil) ?? NSNull(), "errors": errors, "items": items]
}

// MARK: - 进程

/// 进程启动时用的程序路径（ps 显示的那个）。有的软件从系统临时克隆的副本运行（实测 Chrome），这时它和实际文件路径不同
func launchPath(_ pid: Int32) -> String {
    var mib = [CTL_KERN, KERN_PROCARGS2, pid], size = 0
    guard sysctl(&mib, 3, nil, &size, nil, 0) == 0, size > MemoryLayout<Int32>.size else { return "" }
    var buf = [UInt8](repeating: 0, count: size)
    guard sysctl(&mib, 3, &buf, &size, nil, 0) == 0 else { return "" }
    let start = MemoryLayout<Int32>.size  // 开头是参数个数，接着是程序路径
    guard let end = buf[start..<size].firstIndex(of: 0) else { return "" }
    return String(decoding: buf[start..<end], as: UTF8.self)
}

/// 全部进程：pid → (父进程, 实际文件路径, 启动路径)，由系统接口直接取，不调 ps
func processTable() -> [Int32: (ppid: Int32, path: String, launched: String)] {
    let n = proc_listallpids(nil, 0)
    var pids = [Int32](repeating: 0, count: Int(n) + 64)
    let count = proc_listallpids(&pids, Int32(pids.count * MemoryLayout<Int32>.size))
    var table: [Int32: (Int32, String, String)] = [:]
    var buf = [CChar](repeating: 0, count: 4 * Int(MAXPATHLEN))
    for pid in pids.prefix(Int(max(0, count))) where pid > 0 {
        var info = proc_bsdinfo()
        guard proc_pidinfo(pid, PROC_PIDTBSDINFO, 0, &info, Int32(MemoryLayout<proc_bsdinfo>.size)) > 0 else { continue }
        let path = proc_pidpath(pid, &buf, UInt32(buf.count)) > 0 ? String(cString: buf) : ""
        table[pid] = (Int32(info.pbi_ppid), path, launchPath(pid))
    }
    return table
}

/// 有没有进程正在运行这个程序文件
func processRunning(_ binary: String) -> Bool {
    let paths: Set = [binary, realPath(binary)]
    return processTable().values.contains { paths.contains($0.path) || paths.contains($0.launched) }
}

// MARK: - 运行

func run(_ appArg: String, learn: Bool = false) -> String? {
    let original = realPath(appArg)
    var app = original
    let (id, exe) = mustInfo(app)
    let sandboxed = truthy(entitlements(app)["com.apple.security.app-sandbox"])
    let rule = loadRule(id)
    var c = conf(id)
    let fake = c["location"] as? Dict
    let groups = appGroups(app)
    // 虚拟定位和设备伪装要注入，原版的强化运行时不允许，用去掉强化运行时的副本
    if sandboxed || (fake != nil || opt(rule, c, "clone")) && !injectable(app) && !quarantined(app) {
        app = localCopy(app, id)
    }
    let binary = "\(app)/Contents/MacOS/\(exe)"
    if processRunning(binary) {
        return t("\(stem(app)) 正在运行，请先退出。", "\(stem(app)) is already running. Quit it completely first.")
    }
    // 苹果的“系统策略”只许原签名的软件进它的容器，重签的副本进不去，只能用自己的一份数据（实测 EPERM）
    let mode = sandboxed ? "space" : effectiveMode(id, c, rule)
    let ports = learn || opt(rule, c, "allow_localhost") ? (0, 0) : portBlock(id)
    let canInject = !learn && injectable(app)
    if mode == "space" {
        if sandboxed { linkContainerData(id) }
        if canInject { prepareParts(id) }
    }
    c["ports"] = [ports.0, ports.1]
    c["inject"] = canInject
    mkdirs(STATE)
    let started = "\(STATE)/\(id).started"
    if exists(started) { blocked(original, quiet: true) }  // 先把上一次的拦截存进长期记录
    let stamp = now()
    writeText(started, stamp)
    writeText("\(STATE)/\(id).run-start", stamp)
    remove("\(STATE)/\(id).exited")
    remove("\(STATE)/\(id).stopped")
    let logFile = "\(STATE)/\(id).log"
    writeText("\(STATE)/\(id).logpos", String(exists(logFile) ? fileSize(logFile) : 0))
    writeText("\(STATE)/\(id).binary", binary)
    if !original.hasPrefix("/Applications/") && !original.hasPrefix("\(HOME)/Applications/") {
        var data = settings()  // 不在应用程序文件夹里的软件，记下来让它留在列表里
        data["_apps"] = pySorted(Set((data["_apps"] as? [String] ?? []) + [original]))
        saveSettings(data)
    }
    var env: [String: String] = [:]
    if let zone = appZone(c, rule) { env["TZ"] = zone }
    var cwd = "/"
    let sb = "\(STATE)/\(id).sb"
    if learn {
        writeText(sb, LEARN_PROFILE + neverRules().joined(separator: "\n") + "\n")
        writeText("\(STATE)/\(id).learn-start", now())
    } else {
        writeText(sb, buildProfile(app, id, rule, c, mode, groups))
        if mode == "space" {
            seedSpace(original, id, rule, container: sandboxed)
            let space = spaceOf(id)
            cwd = space
            env["HOME"] = space; env["CFFIXED_USER_HOME"] = space
            env["TMPDIR"] = space + "/tmp/"; env["MAC_CHROMIUM_TMPDIR"] = space + "/tmp/"
            if !truthy(rule["keep_prefs_service"]) {
                env["__CFPREFERENCES_AVOID_DAEMON"] = "1"  // 偏好设置直接读写模拟区域，不经系统服务
                privateKeychain(id)
            }
        }
        if !opt(rule, c, "keep_username") { env["USER"] = "user"; env["LOGNAME"] = "user" }
    }
    if !learn && !truthy(rule["shared_tmp"]) && mode != "space" {
        let tmp = "\(HOME)/Library/Caches/\(id)/kekkai-tmp"  // 在它自己的文件夹里
        mkdirs(tmp)
        env["TMPDIR"] = tmp + "/"; env["MAC_CHROMIUM_TMPDIR"] = tmp + "/"  // Chromium 内核不认 TMPDIR
    }
    var libs: [String] = []
    if canInject {
        if mode == "space" && !opt(rule, c, "keep_username") { env["KEKKAI_HOME"] = env["HOME"] }  // 问用户名时答 user，不必放开系统查询
        if !opt(rule, c, "keep_identity") {
            let i = identity(id)
            env["KEKKAI_SERIAL"] = i["serial"] as? String; env["KEKKAI_UUID"] = i["uuid"] as? String
            env["KEKKAI_SEED"] = i["seed"] as? String; env["KEKKAI_NAME"] = i["name"] as? String
        }
        if ports.1 != 0 {
            // 它要开的端口挪进分给它的那组；挪过的记在这个文件里，它的各个进程连原端口时照着换
            let portmap = (env["TMPDIR"] ?? "/private/tmp/") + ".kekkai-ports"
            mkdirs(parent(portmap))
            writeText(portmap, "")
            env["KEKKAI_PORTS"] = "\(ports.0):\(ports.1)"; env["KEKKAI_PORTMAP"] = portmap
        }
        if clipboardMode(c, true) == "paste" { env["KEKKAI_PASTE"] = "1" }
        if !opt(rule, c, "allow_procinfo") { env["KEKKAI_PROCS"] = "1" }
        if !opt(rule, c, "allow_lan") { env["KEKKAI_NOLAN"] = "1" }
        if clipboardMode(c, true) != "off" && exists(ROOT + "/kekkai-relay") {
            let sock = (env["TMPDIR"] ?? spaceOf(id) + "/tmp/") + ".kekkai-relay"
            if sock.utf8.count < 104 {  // 套接字路径的长度上限
                mkdirs(parent(sock))
                startRelay(id, app, sock, inboxOf(id, mode))
                env["KEKKAI_RELAY"] = sock
            }
        }
        // 只在偏好设置不经系统服务时改，否则会写进真实的偏好设置
        if env["__CFPREFERENCES_AVOID_DAEMON"] != nil && !opt(rule, c, "keep_identity"), let lang = commonLanguage {
            env["KEKKAI_LANG"] = lang.lang; env["KEKKAI_LOCALE"] = lang.locale
        }
        if ["KEKKAI_HOME", "KEKKAI_SEED", "KEKKAI_PORTS", "KEKKAI_PASTE", "KEKKAI_PROCS", "KEKKAI_NOLAN", "KEKKAI_LANG", "KEKKAI_RELAY"].contains(where: { env[$0] != nil }) {
            libs.append("libkekkai.dylib")
            if exists(ROOT + "/badge.png") { env["KEKKAI_BADGE"] = LIBDIR + "/badge.png" }  // 程序坞图标加结界角标
        }
    }
    if let fake {
        libs.append("libfakeloc.dylib")
        env["KEKKAI_LAT"] = "\((fake["lat"] as? NSNumber)?.doubleValue ?? 0)"; env["KEKKAI_LON"] = "\((fake["lon"] as? NSNumber)?.doubleValue ?? 0)"
    }
    mkdirs(LIBDIR)
    for n in libs {
        // 先写新文件再替换：原地覆盖已签名的库，系统会按旧的签名缓存把加载它的进程杀掉（实测 OS_REASON_CODESIGNING）
        let tmp = "\(LIBDIR)/.\(n).new"
        remove(tmp)
        try? FM.copyItem(atPath: "\(ROOT)/\(n)", toPath: tmp)
        rename(tmp, "\(LIBDIR)/\(n)")
    }
    if let badge = env["KEKKAI_BADGE"] {
        remove(badge)
        try? FM.copyItem(atPath: ROOT + "/badge.png", toPath: badge)
    }
    var args = ["/usr/bin/sandbox-exec", "-f", sb, binary]
    if !libs.isEmpty {  // 系统程序会丢掉 DYLD_ 变量，经 env 在最后一步交给软件
        args.insert(contentsOf: ["/usr/bin/env", "DYLD_INSERT_LIBRARIES=" + libs.map { "\(LIBDIR)/\($0)" }.joined(separator: ":")], at: 3)
    }
    if listDir(app + "/Contents/Frameworks").contains(where: { $0.hasSuffix(" Helper (GPU).app") }) {
        args.append("--no-sandbox")  // Electron／Chromium 自带沙盒不能嵌套
    }
    args += rule["args"] as? [String] ?? []
    let job = "\(STATE)/\(label(id)).plist"
    writePlist(["Label": label(id), "ProgramArguments": args, "RunAtLoad": true, "KeepAlive": false,
                "WorkingDirectory": cwd, "ProcessType": "Interactive", "LimitLoadToSessionType": "Aqua",
                "StandardErrorPath": "\(STATE)/\(id).log", "StandardOutPath": "/dev/null", "EnvironmentVariables": env] as Dict, job)
    let r = reload(label(id), job)
    let err = r.err.trimmingCharacters(in: .whitespacesAndNewlines)
    return r.code == 0 ? nil : t("启动失败：\(err)", "Launch failed: \(err)")
}

/// 打印将要使用的沙盒规则，不启动软件（排查与核对用）
func printProfile(_ appArg: String) {
    var app = realPath(appArg)
    let id = mustInfo(app).id
    let sandboxed = truthy(entitlements(app)["com.apple.security.app-sandbox"])
    let rule = loadRule(id)
    var c = conf(id)
    let groups = appGroups(app)
    if sandboxed || (c["location"] != nil || opt(rule, c, "clone")) && !injectable(app) && !quarantined(app) {
        let copy = spaceOf(id) + "/Applications/" + name(app)
        if exists(copy) { app = copy }
    }
    c["ports"] = (c["ports"] as? [Any]) ?? [0, 0]
    c["inject"] = injectable(app)
    print(buildProfile(app, id, rule, c, sandboxed ? "space" : effectiveMode(id, c, rule), groups), terminator: "")
}

func stop(_ app: String) {
    let id = mustInfo(app).id
    if jobState(id).running { writeText("\(STATE)/\(id).stopped", now()) }  // 是结界或你停的，不算它自己退出
    launchctl("bootout", "gui/\(UID)/\(label(id))")
    launchctl("bootout", "gui/\(UID)/\(label(id)).relay")
    // 它拉起的附带程序在自己的进程组里，任务结束时不跟着退出（见 inject.c 的 spawn_part），按位置找出来结束
    let space = spaceOf(id) + "/"
    for (pid, p) in processTable() where p.path.hasPrefix(space) { kill(pid, SIGTERM) }
}

let TUNABLE = ["allow_localhost", "allow_procinfo", "allow_open"]
let TUNE_CAT = ["ownport": "allow_localhost", "localhost": "allow_localhost", "proc": "allow_procinfo", "launch": "allow_open"]

/// 第一次在结界中打开时在后台试：可选权限全关能撑过 wait 秒就结束；不行就找出缺的是哪一项，只开那一项。
/// 先按退出前被挡的请求找；系统日志不一定记下（实测秒退的程序没留日志），找不到就全开再逐项关回去试。
/// 只看得出“能不能启动”；登录、粘贴这类功能坏没坏，要你自己用了才知道。
func tune(_ appArg: String, wait: Int = 30) {
    let app = realPath(appArg), id = mustInfo(app).id
    let stopped = "\(STATE)/\(id).stopped"

    /// 运行一次，撑过 wait 秒返回 true，提前退出返回 false，被你停掉返回 nil。
    func survives(first: Bool = false) -> Bool? {
        if !first {
            stop(app)
            remove(stopped)
            if run(app) != nil { return false }
        }
        for _ in 0..<wait {
            sleepSeconds(1)
            if !jobState(id).running { return exists(stopped) ? nil : false }
        }
        return true
    }
    func setting(_ keys: [String]) {
        for k in TUNABLE { setField(id, k, keys.contains(k) ? true : "-") }
    }

    let start = (readText("\(STATE)/\(id).run-start") ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
    var ok = survives(first: true)
    var needed: [String] = []
    if ok == false {
        sleepSeconds(2)  // 等系统日志写完
        let guess = pySorted(Set(denials(app, start).compactMap { TUNE_CAT[categorize($0.op, $0.target, app, id)] }))
        if !guess.isEmpty {
            setting(guess)
            ok = survives()
            needed = ok == true ? guess : []
        }
        if ok != true && ok != nil {
            setting(TUNABLE)
            ok = survives()
            if ok == true {
                needed = TUNABLE
                for k in TUNABLE {  // 逐项关回去，关了就退出的才是必需的
                    setting(needed.filter { $0 != k })
                    let r = survives()
                    if r == nil { break }
                    if r == true { needed.removeAll { $0 == k } }
                }
                setting(needed)
                if survives() == false {
                    setting(TUNABLE)
                    needed = TUNABLE
                    _ = survives()
                }
            } else {
                setting([])  // 全开也不行，原因不在这几项；交给拦截记录里的文件请求
                needed = []
            }
        }
    }
    update(id) { e in
        e["tuned"] = now()
        e["auto_enabled"] = needed
    }
}

/// 添加就是第一次试运行：在结界里撑得住才加进列表，撑不住说明原因、不加。顺带找出它离不开的权限。
func add(_ appArg: String, wait: Int = 20) {
    let app = realPath(appArg), id = mustInfo(app).id
    let space = spaceOf(id), hadConf = settings()[id] != nil
    let hadSpace = exists(space)

    func result(_ ok: Bool, _ reason: String = "", _ detail: String = "", stopped: Bool = false) {
        if !ok {  // 没加进来就不留下这次试运行新建的结界文件夹和设置
            stop(app)
            if !hadSpace && exists(space) { remove(space) }
            if !hadConf {
                var data = settings()
                data.removeValue(forKey: id)
                saveSettings(data)
            }
        } else {
            var data = settings()
            data["_added"] = pySorted(Set((data["_added"] as? [String] ?? []) + [app]))
            saveSettings(data)
        }
        let needed = ok ? conf(id)["auto_enabled"] as? [String] ?? [] : []
        printJSON(["ok": ok, "reason": reason, "detail": detail, "stopped": stopped, "autoEnabled": needed] as Dict)
    }

    // 签名不许注入的软件先试可注入副本：电脑名、显示器序列号、运行中的软件这些沙盒挡不住的，副本能换成假的。
    // 副本起不来再回到原版；你在设置里明确选过的不动
    let sandboxed = truthy(entitlements(app)["com.apple.security.app-sandbox"])
    let cloneFirst = !sandboxed && !injectable(app) && !quarantined(app) && conf(id)["clone"] == nil
    if cloneFirst { setField(id, "clone", true) }
    var msg = run(app)
    if msg == nil { tune(app, wait: wait) }
    if cloneFirst && !jobState(id).running && !exists("\(STATE)/\(id).stopped") {
        stop(app)
        remove("\(space)/Applications/\(name(app))")
        remove("\(space)/Applications/\(name(app)).source")
        setField(id, "clone", false)
        msg = run(app)
        if msg == nil { tune(app, wait: wait) }
    }
    if let msg { return result(false, msg) }
    if jobState(id).running { return result(true) }
    if exists("\(STATE)/\(id).stopped") { return result(false, stopped: true) }
    let s = logStatus(app, id, [:])
    let (reason, detail) = failureReason(id, s)
    result(false, reason, detail)
}

/// 试运行失败的原因：一句话说明，能分清的说清楚，分不清的照实说退出码；另附日志里的第一条错误（界面单独显示）
func failureReason(_ id: String, _ s: Dict) -> (String, String) {
    let signal = match("last terminating signal = ([^\n]+)", launchctl("print", "gui/\(UID)/\(label(id))").out)?[1]?.trimmingCharacters(in: .whitespaces)
    if truthy(s["receipt"]) {
        return (t("App Store 付费软件会校验购买凭证，结界中的副本无法通过校验。", "Paid App Store apps check their purchase receipt, which the copy in Kekkai can't pass."), "")
    }
    if truthy(s["gatekeeper"]) {
        return (t("该 App 未经 Apple 公证，已被 macOS 阻止。请先在结界外打开一次并允许，再重新添加。",
                  "macOS blocked it because it isn't notarized. Open it once outside Kekkai and allow it, then add it again."), "")
    }
    let code = s["exitCode"] as? String ?? "None"
    if code == "OS_REASON_CODESIGNING" {
        return (t("代码签名校验未通过，macOS 不允许其在结界中运行。", "It failed a code signature check, so macOS won't run it in Kekkai."), "")
    }
    if let signal {
        return (t("启动后崩溃（\(signal)），开启全部权限后仍然如此。", "It crashed after starting (\(signal)), even with every permission on."), "")
    }
    return (t("启动后自行退出（退出码 \(code)），开启全部权限后仍然如此。", "It quit on its own (exit code \(code)), even with every permission on."),
            (s["errors"] as? [String])?.first ?? "")
}

/// 从列表里拿掉；它的结界文件夹和设置留着，以后再添加接着用。
func removeApp(_ appArg: String) {
    let app = realPath(appArg)
    var data = settings()
    data["_added"] = (data["_added"] as? [String] ?? []).filter { $0 != app }
    saveSettings(data)
}

/// 在“应用程序”里做一个从结界打开它的图标，放进程序坞或用聚焦搜索都能用。
func makeLauncher(_ appArg: String, _ nameArg: String? = nil) {
    let app = realPath(appArg), id = mustInfo(app).id
    let n = nameArg ?? stem(app)
    // 放进系统的“应用程序”，和其他软件在一起；没有写入权限（非管理员）才放个人的 ~/Applications
    let apps = access("/Applications", W_OK) == 0 ? "/Applications" : HOME + "/Applications"
    let dst = "\(apps)/\(t("\(n) 结界", "\(n) Kekkai")).app"  // 后缀让它在列表里紧挨着原版
    remove(dst)
    mkdirs(dst + "/Contents/MacOS")
    let exe = dst + "/Contents/MacOS/launch"
    writeText(exe, "#!/bin/sh\nexec \(q(ROOT + "/kekkai")) run \(q(app))\n")
    chmod(exe, 0o755)
    writePlist(["CFBundleIdentifier": "io.github.wjsgzz.kekkai.launch.\(id)", "CFBundleExecutable": "launch",
                "CFBundleName": stem(dst), "CFBundlePackageType": "APPL", "LSUIElement": true] as Dict, dst + "/Contents/Info.plist")
    print(dst)
}

/// 丢弃模拟区域里的全部改动，下次打开时重新从真实数据克隆。
func reset(_ app: String) {
    let id = mustInfo(app).id
    stop(app)
    let space = spaceOf(id)
    if parent(space) == SPACES && exists(space) { remove(space) }
}

/// 它在结界外的组件：不是结界启动的进程（如网盘的同步扩展、开机启动的登录项），和装在系统里的常驻任务（如特权助手）。
/// 这些由 launchd 或系统直接启动，结界管不到，只能告诉你。
func outsideParts(_ app: String, _ id: String, _ procs: [Int32: (ppid: Int32, path: String, launched: String)], _ jobs: String) -> [String] {
    let job = jobs.split(separator: "\n").map(String.init).first { $0.hasSuffix("\t" + label(id)) }
        .flatMap { Int32($0.components(separatedBy: "\t")[0]) }
    func inside(_ start: Int32) -> Bool {
        var pid = start
        while pid > 1 {
            if pid == job { return true }
            pid = procs[pid]?.ppid ?? 0
        }
        return false
    }
    typealias CheckFn = @convention(c) (Int32, UnsafePointer<CChar>?, Int32) -> Int32
    let check = dlsym(UnsafeMutableRawPointer(bitPattern: -2), "sandbox_check").map { unsafeBitCast($0, to: CheckFn.self) }
    let copy = spaceOf(id) + "/Applications/" + name(app)
    let usesCopy = exists(copy)
    func outside(_ pid: Int32, _ path: String) -> Bool {
        if inside(pid) { return false }
        // 扩展由系统启动；用副本时原版的进程都不是结界开的；脱离父进程（ppid 1）但仍在沙盒里的，是结界开的
        return path.contains(".appex/") || usesCopy && path.hasPrefix(app + "/") || (check?(pid, nil, 0) ?? 1) == 0
    }
    var found = Set<String>()
    for (pid, p) in procs {
        let path = p.launched.isEmpty ? p.path : p.launched  // 和 ps 显示的一样，按启动路径认
        if (path.hasPrefix(app + "/") || path.hasPrefix(copy + "/")) && outside(pid, path) { found.insert(name(path)) }
    }
    let vendor = id.split(separator: ".").prefix(2).joined(separator: ".").lowercased()
    if vendor.hasPrefix("com.apple") || !vendor.contains(".") { return pySorted(found) }
    for d in ["\(HOME)/Library/LaunchAgents", "/Library/LaunchAgents", "/Library/LaunchDaemons", "/Library/PrivilegedHelperTools"] {
        for n in listDir(d) where n.lowercased().hasPrefix(vendor + ".") {
            found.insert(n.hasSuffix(".plist") ? String(n.dropLast(6)) : n)
        }
    }
    return pySorted(found)
}

func listApps() {
    let cachePath = STATE + "/entitlements-cache.json"
    var cache = readJSON(cachePath) as? [String: Dict] ?? [:]
    let tree = processTable()
    let paths = Set(tree.values.flatMap { [$0.path, $0.launched] })
    let jobs = launchctl("list").out
    var data = settings()
    var out: [Dict] = []
    let added = Set(data["_added"] as? [String] ?? [])
    let extra = (data["_apps"] as? [String] ?? []).filter(exists)
    let jobLines = jobs.split(separator: "\n").map(String.init)
    for base in ["/Applications", "\(HOME)/Applications", nil] as [String?] {
        let apps = base.map { b in pySorted(listDir(b).filter { $0.hasSuffix(".app") }).map { b + "/" + $0 } } ?? extra
        for app in apps {
            guard let (id, exe) = info(app), !id.hasPrefix("io.github.wjsgzz.kekkai") else { continue }
            let key = "\(app):\(mtime(app + "/Contents/Info.plist"))"
            var entry = cache[key] ?? [:]
            if entry["perm_keys"] == nil {
                let e = entitlements(app)
                entry = ["sandboxed": truthy(e["com.apple.security.app-sandbox"]), "perm_keys": PERMISSION_KEYS.filter { truthy(e[$0]) }]
            }
            if entry["inj"] == nil { entry["inj"] = truthy(entry["sandboxed"]) || injectable(app) }  // 自带苹果沙盒的软件跑的是重签的副本，副本能注入
            if entry["q"] == nil { entry["q"] = quarantined(app) }
            cache[key] = entry
            let c = data[id] as? Dict ?? [:]
            let rule = loadRule(id)
            let space = spaceOf(id)
            // 任务在运行，或它拉起的附带程序（在结界文件夹里）还在运行
            let inside = jobLines.contains { $0.components(separatedBy: "\t").last == label(id) && !$0.hasPrefix("-") }
                || paths.contains { $0.hasPrefix(space + "/") }
            let inj = truthy(entry["inj"]) || (opt(rule, c, "clone") && !truthy(entry["q"]))  // 带隔离标记的不用副本
            let mode = effectiveMode(id, c, rule)
            let language: Any = inj && mode == "space" && !opt(rule, c, "keep_identity") ? commonLanguage?.lang ?? NSNull() : NSNull()
            out.append([
                "id": id, "name": stem(app), "path": app, "sandboxed": truthy(entry["sandboxed"]),
                "perms": (entry["perm_keys"] as? [String] ?? []).compactMap { PERMISSIONS[$0].map { t($0.0, $0.1) } },
                "inside": inside, "running": paths.contains("\(app)/Contents/MacOS/\(exe)"),
                "tz": c["tz"] ?? NSNull(), "zone": appZone(c, rule) ?? NSNull(), "mode": mode, "language": language,
                "bringOld": truthy(c["bring_old_data"]), "block": blockedDevices(c, inj), "clipboard": clipboardMode(c, inj), "injectable": inj,
                "canClone": !truthy(entry["inj"]) && !truthy(entry["q"]), "location": c["location"] ?? NSNull(), "identity": c["identity"] ?? NSNull(),
                "allow": c["allow"] ?? [], "allowOpen": truthy(c["allow_open"]), "options": OPTIONS.mapValues { opt(rule, c, $0) },
                "autoEnabled": c["auto_enabled"] ?? [], "tuned": truthy(c["tuned"]), "reviewed": truthy(c["decided"]), "space": space,
                "inbox": inboxOf(id, mode), "hasSpace": exists(space), "added": added.contains(app),
                "outside": added.contains(app) ? outsideParts(app, id, tree, jobs) : []])
        }
    }
    if data["_added"] == nil {  // 有“添加”之前就在结界里用过的软件，直接算已添加
        let ids = out.filter { truthy($0["hasSpace"]) || data[$0["id"] as! String] != nil }.map { $0["path"] as! String }
        data["_added"] = pySorted(ids)
        saveSettings(data)
        out = out.map { var e = $0; e["added"] = ids.contains(e["path"] as! String); return e }
    }
    mkdirs(STATE)
    writeText(cachePath, jsonString(cache))
    printJSON(out)
}

/// 旧位置搬到 .noindex，旧路径留一个链接，软件存下的旧绝对路径照样能用。有软件正在里面运行就先不搬。
func migrateSpaces() {
    guard isDir(OLD_SPACES), !isSymlink(OLD_SPACES) else { return }
    if exists(SPACES) || listDir(OLD_SPACES).contains(where: { jobState($0).running }) {
        SPACES = OLD_SPACES
        LIBDIR = OLD_SPACES + "/.lib"
        return
    }
    rename(OLD_SPACES, SPACES)
    try? FM.createSymbolicLink(atPath: OLD_SPACES, withDestinationPath: SPACES)
}

// MARK: - 入口

func main() {
    setvbuf(stdout, nil, _IOLBF, 0)
    migrateSpaces()
    let a = Array(CommandLine.arguments.dropFirst())
    let n = a.count, cmd = a.first ?? ""
    switch (cmd, n) {
    case ("list", 1): return listApps()
    case ("set-tz", 3): return setTz(a[1], a[2])
    case ("set-mode", 3) where ["space", "real"].contains(a[2]): return setField(a[1], "mode", a[2])
    case ("set-bring-old", 3) where ["on", "off"].contains(a[2]): return setField(a[1], "bring_old_data", a[2] == "on" ? true : "-")
    case ("allow", 4) where ["add", "rm"].contains(a[2]): return setAllow(a[1], a[2], a[3])
    case ("new-identity", 2): return setField(a[1], "identity", "-")  // 下次打开时生成新的一套
    case ("set-location", _) where n >= 3 && (Array(a[2...]) == ["-"] || n >= 4): return setLocation(a[1], Array(a[2...]))
    case ("set", 4) where OPTIONS[a[2]] != nil && ["on", "off"].contains(a[3]): return setField(a[1], OPTIONS[a[2]]!, a[3] == "on")
    case ("set-open", 3) where ["on", "off"].contains(a[2]): return setField(a[1], "allow_open", a[2] == "on" ? true : "-")
    case ("set-block", 4) where DEVICES[a[2]] != nil && ["on", "off"].contains(a[3]): return setBlock(a[1], a[2], a[3] == "on")
    case ("set-clipboard", 3) where ["off", "paste", "on"].contains(a[2]): return setClipboard(a[1], a[2])
    case ("never", 2) where a[1] == "list": return neverCmd("list")
    case ("never", 3) where ["add", "rm"].contains(a[1]): return neverCmd(a[1], a[2])
    case ("decide", _) where n >= 4 && ["allow", "deny"].contains(a[2]): return decide(a[1], a[2], a[3...].joined(separator: " "))
    case ("add", 2): return add(a[1])
    case ("remove", 2): return removeApp(a[1])
    case ("trial", 2): return trial(a[1])
    case ("blocked", 2): return blocked(a[1])
    case ("blocked", 3) where a[2] == "--json": return blocked(a[1], asJSON: true)
    case ("profile", 2): return printProfile(a[1])
    case ("import", 2):
        let id = mustInfo(a[1]).id
        stop(a[1])
        let app = realPath(a[1])
        let sandboxed = truthy(entitlements(app)["com.apple.security.app-sandbox"])
        if let msg = sandboxed ? importContainer(id) : importOwn(app, id, loadRule(id)) { die(msg) }
    case ("tune", 2): return tune(a[1])
    case ("launcher", 2), ("launcher", 3): return makeLauncher(a[1], n == 3 ? a[2] : nil)
    case ("stop", 2): return stop(a[1])
    case ("reset", 2): return reset(a[1])
    case ("report", 2): return report(a[1])
    case ("run", 2), ("learn", 2):
        if let msg = run(a[1], learn: cmd == "learn") {
            print(msg)
            exit(1)
        }
        let id = mustInfo(a[1]).id
        if cmd == "run" && !truthy(conf(id)["tuned"]) {
            // 第一次打开：后台盯着，必要时自动放开权限重开；不拖住界面
            let p = Process()
            p.executableURL = URL(fileURLWithPath: ROOT + "/kekkai")
            p.arguments = ["tune", a[1]]
            p.standardInput = FileHandle.nullDevice
            p.standardOutput = FileHandle.nullDevice
            p.standardError = FileHandle.nullDevice
            try? p.run()
        }
    default: die(usage)
    }
}

main()
