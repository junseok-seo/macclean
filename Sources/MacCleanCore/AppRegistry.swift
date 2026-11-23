import AppKit
import CoreServices

public struct AppInfo: Hashable, Sendable {
    public let bundleID: String
    public let name: String
    public let path: String
    public let version: String?
    public let isSystem: Bool
}

public enum AppMatch: Sendable {
    /// 설치된 앱의 데이터
    case installed(AppInfo)
    /// 같은 회사의 다른 앱이 설치됨(도우미·업데이트 도구 등)
    case related(AppInfo)
    /// macOS 기본 구성요소
    case system(AppInfo?)
    /// 번들 ID 형태인데 설치된 앱이 없음 → 삭제된 앱의 잔여물일 가능성
    case notInstalled(String)
    /// 판단 불가
    case unknown

    public var app: AppInfo? {
        switch self {
        case .installed(let a), .related(let a): a
        case .system(let a): a
        default: nil
        }
    }

    public var isOrphan: Bool {
        if case .notInstalled = self { return true }
        return false
    }
}

/// 설치된 앱 목록을 만들고, 폴더 이름(번들 ID나 앱 이름)이 어떤 앱 것인지 찾아준다.
public final class AppRegistry: @unchecked Sendable {
    public static let shared = AppRegistry()

    private let lock = NSRecursiveLock()
    private var loaded = false
    private var byID: [String: AppInfo] = [:]
    private var byName: [String: AppInfo] = [:]
    private var byVendor: [String: AppInfo] = [:]
    private var runningIDs: Set<String> = []
    private var lsCache: [String: AppInfo?] = [:]
    private var resolveCache: [String: AppMatch] = [:]

    /// 폴더 이름 → 실제 앱 번들 ID(또는 접두어)
    private let aliases: [String: String] = [
        "code": "com.microsoft.VSCode",
        "cursor": "com.todesktop.230313mzl4w4u92",
        "google": "com.google.",
        "chrome": "com.google.Chrome",
        "microsoft": "com.microsoft.",
        "microsoftedge": "com.microsoft.edgemac",
        "slack": "com.tinyspeck.slackmacgap",
        "discord": "com.hnc.Discord",
        "spotify": "com.spotify.client",
        "zoomus": "us.zoom.xos",
        "notion": "notion.id",
        "figma": "com.figma.Desktop",
        "bravesoftware": "com.brave.Browser",
        "arc": "company.thebrowser.Browser",
        "firefox": "org.mozilla.firefox",
        "mozilla": "org.mozilla.",
        "steam": "com.valvesoftware.steam",
        "telegramdesktop": "org.telegram.desktop",
        "docker": "com.docker.docker",
        "dockerdesktop": "com.docker.docker",
        "claude": "com.anthropic.claudefordesktop",
        "chatgpt": "com.openai.chat",
        "codex": "com.openai.",
        "obsidian": "md.obsidian",
        "naver": "com.naver.",
        "whale": "com.naver.Whale",
        "kakaotalk": "com.kakao.KakaoTalkMac",
        "jetbrains": "com.jetbrains.",
        "autodesk": "com.autodesk.",
        "adobe": "com.adobe.",
        "postman": "com.postmanlabs.mac",
        "audacity": "org.audacityteam.audacity",
        "blender": "org.blenderfoundation.blender",
        "windsurf": "com.exafunction.windsurf",
        "vscodium": "com.vscodium",
        "electron": "",
    ]

    public init() {}

    public func ensureLoaded() {
        lock.lock(); defer { lock.unlock() }
        if !loaded { load(); loaded = true }
    }

    public func reload() {
        lock.lock(); defer { lock.unlock() }
        byID = [:]; byName = [:]; byVendor = [:]; lsCache = [:]; resolveCache = [:]
        load(); loaded = true
    }

    public var allApps: [AppInfo] {
        ensureLoaded()
        lock.lock(); defer { lock.unlock() }
        var seen = Set<String>()
        return byID.values.filter { seen.insert($0.path).inserted }.sorted { $0.name.localizedCompare($1.name) == .orderedAscending }
    }

    public func app(bundleID: String) -> AppInfo? {
        ensureLoaded()
        lock.lock(); defer { lock.unlock() }
        return byID[bundleID.lowercased()] ?? launchServices(bundleID)
    }

    public func isRunning(bundleID: String) -> Bool {
        NSRunningApplication.runningApplications(withBundleIdentifier: bundleID).isEmpty == false
    }

    // MARK: 로딩

    private func load() {
        let home = Paths.home
        let roots: [(String, Int)] = [
            ("/Applications", 2),
            (home + "/Applications", 2),
            ("/System/Applications", 2),
            ("/System/Library/CoreServices", 1),
            ("/System/Library/CoreServices/Applications", 1),
            ("/Applications/Xcode.app/Contents/Developer/Applications", 1),
            ("/Library/Application Support", 2),
        ]
        for (root, depth) in roots { scan(root, depth: depth) }
        for app in NSWorkspace.shared.runningApplications {
            if let id = app.bundleIdentifier { runningIDs.insert(id.lowercased()) }
            if let url = app.bundleURL, url.pathExtension == "app" { add(url.path) }
        }
    }

    private func scan(_ dir: String, depth: Int) {
        guard let items = try? FileManager.default.contentsOfDirectory(atPath: dir) else { return }
        for item in items where !item.hasPrefix(".") {
            let p = dir + "/" + item
            if item.hasSuffix(".app") {
                add(p)
            } else if depth > 1, Paths.isDirectory(p), !item.hasSuffix(".bundle"), !item.hasSuffix(".framework") {
                scan(p, depth: depth - 1)
            }
        }
    }

    @discardableResult
    private func add(_ path: String) -> AppInfo? {
        let plist = URL(fileURLWithPath: path + "/Contents/Info.plist")
        guard let d = NSDictionary(contentsOf: plist) as? [String: Any],
              let id = d["CFBundleIdentifier"] as? String else { return nil }
        var name = FileManager.default.displayName(atPath: path)
        if name.hasSuffix(".app") { name.removeLast(4) }
        let info = AppInfo(bundleID: id, name: name, path: path,
                           version: d["CFBundleShortVersionString"] as? String,
                           isSystem: path.hasPrefix("/System/"))
        let key = id.lowercased()
        if byID[key] == nil || path.hasPrefix("/Applications/") { byID[key] = info }
        byName[normalize(name)] = byName[normalize(name)] ?? info
        let fileName = normalize(((path as NSString).lastPathComponent as NSString).deletingPathExtension)
        byName[fileName] = byName[fileName] ?? info
        let comps = key.split(separator: ".")
        if comps.count >= 3 {
            let vendor = comps.prefix(2).joined(separator: ".")
            let helperWords = ["remove", "uninstall", "updater", "helper", "installer", "agent", "launcher", "제거"]
            let isHelper = { (n: String) in helperWords.contains { n.lowercased().contains($0) } }
            if let existing = byVendor[vendor] {
                if isHelper(existing.name) && !isHelper(name) { byVendor[vendor] = info }
            } else {
                byVendor[vendor] = info
            }
        }
        return info
    }

    private func launchServices(_ id: String) -> AppInfo? {
        let key = id.lowercased()
        if let cached = lsCache[key] { return cached }
        var result: AppInfo? = nil
        if let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: id) {
            result = add(url.path)
        }
        lsCache[key] = result
        return result
    }

    func normalize(_ s: String) -> String {
        s.lowercased().filter { $0.isLetter || $0.isNumber }
    }

    public static func looksLikeBundleID(_ s: String) -> Bool {
        let comps = s.split(separator: ".", omittingEmptySubsequences: false)
        guard comps.count >= 3, comps.allSatisfy({ !$0.isEmpty }) else { return false }
        return s.allSatisfy { $0.isLetter || $0.isNumber || $0 == "." || $0 == "-" || $0 == "_" }
    }

    /// 확장자·팀 ID 접두어를 떼고 순수 번들 ID 후보를 돌려준다.
    public static func cleanIdentifier(_ raw: String) -> String {
        var n = raw
        for suffix in [".savedState", ".plist", ".binarycookies", ".sfl2", ".sfl3", ".log", ".txt", ".json", ".db"] where n.hasSuffix(suffix) {
            n.removeLast(suffix.count)
        }
        if n.hasPrefix("group.") { n.removeFirst(6) }
        if let r = n.range(of: #"^[A-Z0-9]{10}\."#, options: .regularExpression) { n.removeSubrange(r) }
        if n.hasPrefix("group.") { n.removeFirst(6) }
        if n.hasPrefix("groups.") { n.removeFirst(7) }
        return n
    }

    // MARK: 판정

    /// 라이브러리 폴더 안의 항목 이름으로 소유 앱을 찾는다.
    public func resolve(_ raw: String) -> AppMatch {
        ensureLoaded()
        lock.lock(); defer { lock.unlock() }
        if let c = resolveCache[raw] { return c }
        let r = resolveUncached(raw)
        resolveCache[raw] = r
        return r
    }

    private func resolveUncached(_ raw: String) -> AppMatch {
        let id = Self.cleanIdentifier(raw)
        let lower = id.lowercased()

        if Self.looksLikeBundleID(lower) {
            if lower.hasPrefix("com.apple.") {
                return .system(byID[lower] ?? launchServices(id))
            }
            if let a = byID[lower] { return .installed(a) }
            if runningIDs.contains(lower), let a = launchServices(id) { return .installed(a) }
            // 상위 ID가 설치된 앱인지 (com.foo.app.helper → com.foo.app)
            var comps = lower.split(separator: ".").map(String.init)
            while comps.count > 2 {
                comps.removeLast()
                if let a = byID[comps.joined(separator: ".")] { return .installed(a) }
            }
            // 이 ID로 시작하는 앱이 있는지
            if let a = byID.first(where: { $0.key.hasPrefix(lower + ".") })?.value { return .related(a) }
            if let a = launchServices(id) { return .installed(a) }
            let vendor = lower.split(separator: ".").prefix(2).joined(separator: ".")
            if let a = byVendor[vendor] { return .related(a) }
            if runningIDs.contains(where: { $0.hasPrefix(vendor + ".") }) { return .unknown }
            return .notInstalled(id)
        }

        let key = normalize(id)
        if key.isEmpty { return .unknown }
        if let a = byName[key] { return .installed(a) }
        if let target = aliases[key] {
            if target.isEmpty { return .unknown }
            if target.hasSuffix(".") {
                let vendor = String(target.lowercased().dropLast())
                if let a = byVendor[vendor] { return .installed(a) }
                return .unknown
            }
            if let a = byID[target.lowercased()] ?? launchServices(target) { return .installed(a) }
            return .notInstalled(target)
        }
        // "Google Chrome" 처럼 앱 이름의 앞부분과 일치
        if key.count >= 4, let a = byName.first(where: { $0.key.hasPrefix(key) })?.value { return .related(a) }
        return .unknown
    }

    /// 사람이 읽기 좋은 이름. 앱을 찾으면 앱 이름, 아니면 번들 ID에서 추정.
    public func displayName(for raw: String) -> String {
        // "Adobe", "Google" 같은 회사 폴더는 특정 앱 이름 대신 폴더 이름 그대로
        if !Self.looksLikeBundleID(Self.cleanIdentifier(raw)), let t = aliases[normalize(raw)], t.hasSuffix(".") { return raw }
        switch resolve(raw) {
        case .installed(let a), .related(let a): return a.name
        case .system(let a): return a?.name ?? Self.guessName(raw)
        case .notInstalled, .unknown: return Self.guessName(raw)
        }
    }

    public static func guessName(_ raw: String) -> String {
        let id = cleanIdentifier(raw)
        guard looksLikeBundleID(id) else { return id }
        let generic: Set<String> = ["client", "app", "mac", "macos", "osx", "desktop", "helper", "agent", "main", "shared", "launcher", "mas", "pro"]
        let comps = id.split(separator: ".").map(String.init)
        var pick = comps.last ?? id
        var i = comps.count - 1
        while i > 1, generic.contains(comps[i].lowercased()) { i -= 1; pick = comps[i] }
        return pick.prefix(1).uppercased() + pick.dropFirst()
    }

    /// Spotlight에 기록된 마지막 사용 날짜
    public static func lastUsedDate(_ path: String) -> Date? {
        guard let item = MDItemCreate(kCFAllocatorDefault, path as CFString) else { return nil }
        return MDItemCopyAttribute(item, kMDItemLastUsedDate) as? Date
    }
}
