import AppKit

public struct RelatedItem: Identifiable, Sendable, Hashable {
    public var id: String { path }
    public let path: String
    public let label: String
    public let size: Int64
    public var newest: Date? = nil
}

public struct InstalledApp: Identifiable, Sendable {
    public var id: String { path }
    public let name: String
    public let bundleID: String
    public let version: String?
    public let path: String
    public var appSize: Int64 = -1
    public var related: [RelatedItem] = []
    /// Spotlight에 기록된 마지막 실행일
    public var lastUsed: Date?
    /// 앱 데이터 폴더가 마지막으로 바뀐 날 (Spotlight 기록이 없을 때 대신 씀)
    public var lastActivity: Date?
    public var isRunning = false
    public let isAppStore: Bool
    public var dataSize: Int64 { related.reduce(0) { $0 + $1.size } }
    public var totalSize: Int64 { max(0, appSize) + dataSize }
    public var sized: Bool { appSize >= 0 }
    /// 마지막으로 쓴 것으로 보이는 날
    public var lastSeen: Date? {
        if isRunning { return Date() }
        return [lastUsed, lastActivity].compactMap { $0 }.max()
    }
    public var lastSeenSource: String {
        if isRunning { return "지금 실행 중" }
        if let u = lastUsed, u >= (lastActivity ?? .distantPast) { return "Spotlight 실행 기록" }
        if lastActivity != nil { return "앱 데이터가 마지막으로 바뀐 날 (실행 기록이 없어 대신 사용)" }
        return "기록 없음"
    }
    public var daysUnused: Int? { Fmt.days(since: lastSeen) }
    /// 브라우저가 만든 웹 앱 바로가기(Chrome 앱 등)
    public var isWebAppShim: Bool {
        path.contains("/Chrome Apps.localized/") || bundleID.hasPrefix("com.google.Chrome.app.")
            || bundleID.hasPrefix("com.apple.Safari.WebApp") || bundleID.hasPrefix("com.microsoft.edgemac.app.")
            || bundleID.hasPrefix("com.brave.Browser.app.") || bundleID.hasPrefix("com.naver.Whale.app.")
    }
}

public enum AppScanner {
    /// 사용자가 지울 수 있는 앱 목록 (크기 계산 전)
    public static func listApps() -> [InstalledApp] {
        var result: [InstalledApp] = []
        var seen = Set<String>()
        let roots = ["/Applications", Paths.home + "/Applications"]
        func visit(_ dir: String, depth: Int) {
            for p in Paths.children(dir) {
                let name = Paths.name(p)
                if name.hasSuffix(".app") {
                    guard seen.insert(p).inserted, let app = makeApp(p) else { continue }
                    result.append(app)
                } else if depth > 1, Paths.isDirectory(p), !name.hasPrefix(".") {
                    visit(p, depth: depth - 1)
                }
            }
        }
        for r in roots { visit(r, depth: 2) }
        return result.sorted { $0.name.localizedCompare($1.name) == .orderedAscending }
    }

    static func makeApp(_ path: String) -> InstalledApp? {
        guard let d = NSDictionary(contentsOfFile: path + "/Contents/Info.plist") as? [String: Any],
              let id = d["CFBundleIdentifier"] as? String else { return nil }
        let receipt = Paths.exists(path + "/Contents/_MASReceipt")
        // Safari 등 시스템에 포함된 Apple 앱은 지울 수 없으므로 제외
        if id.hasPrefix("com.apple.") && !receipt && id != "com.apple.dt.Xcode" { return nil }
        var name = FileManager.default.displayName(atPath: path)
        if name.hasSuffix(".app") { name.removeLast(4) }
        return InstalledApp(name: name, bundleID: id, version: d["CFBundleShortVersionString"] as? String, path: path,
                            lastUsed: AppRegistry.lastUsedDate(path), isAppStore: receipt)
    }

    /// 앱 크기와 관련 데이터 크기를 계산
    public static func measure(_ app: InstalledApp) -> InstalledApp {
        var a = app
        a.appSize = DirSize.measure(app.path).bytes
        a.related = relatedItems(bundleID: app.bundleID, name: app.name, appPath: app.path, byName: !app.isWebAppShim)
        a.lastActivity = a.related.filter { $0.label != "설정 파일" }.compactMap(\.newest).max()
        a.isRunning = !NSRunningApplication.runningApplications(withBundleIdentifier: app.bundleID).isEmpty
        return a
    }

    /// 앱이 라이브러리에 남기는 데이터 위치
    public static func relatedItems(bundleID: String, name: String, appPath: String, byName: Bool = true) -> [RelatedItem] {
        let h = Paths.home
        let fileName = ((appPath as NSString).lastPathComponent as NSString).deletingPathExtension
        var names = [bundleID]
        if byName {
            for n in [name, fileName] where !names.contains(n) && n.count >= 3 { names.append(n) }
        }
        // 회사 폴더 아래에 데이터를 두는 앱
        let vendorDirs: [String: [String]] = [
            "com.google.Chrome": ["Google/Chrome"], "com.microsoft.edgemac": ["Microsoft Edge"],
            "com.brave.Browser": ["BraveSoftware/Brave-Browser"], "com.naver.Whale": ["Naver/Whale"],
            "com.microsoft.VSCode": ["Code"], "com.tinyspeck.slackmacgap": ["Slack"], "com.hnc.Discord": ["discord"],
            "com.anthropic.claudefordesktop": ["Claude"], "us.zoom.xos": ["zoom.us"], "org.mozilla.firefox": ["Firefox"],
        ]
        for d in vendorDirs[bundleID] ?? [] where !names.contains(d) { names.append(d) }
        var candidates: [(String, String)] = []
        for n in names {
            candidates += [
                (h + "/Library/Application Support/" + n, "앱 데이터"),
                (h + "/Library/Caches/" + n, "캐시"),
                (h + "/Library/Logs/" + n, "로그"),
            ]
        }
        candidates += [
            (h + "/Library/Containers/" + bundleID, "샌드박스 데이터"),
            (h + "/Library/Preferences/" + bundleID + ".plist", "설정 파일"),
            (h + "/Library/Saved Application State/" + bundleID + ".savedState", "창 상태"),
            (h + "/Library/HTTPStorages/" + bundleID, "웹 저장소"),
            (h + "/Library/HTTPStorages/" + bundleID + ".binarycookies", "쿠키"),
            (h + "/Library/WebKit/" + bundleID, "웹뷰 데이터"),
            (h + "/Library/Application Scripts/" + bundleID, "스크립트"),
            (h + "/Library/Cookies/" + bundleID + ".binarycookies", "쿠키"),
        ]
        // 확장 프로그램 컨테이너 (번들 ID로 시작)
        for c in Paths.children(h + "/Library/Containers") where Paths.name(c).hasPrefix(bundleID + ".") {
            candidates.append((c, "확장 프로그램 데이터"))
        }
        for c in Paths.children(h + "/Library/Application Scripts") where Paths.name(c).hasPrefix(bundleID + ".") {
            candidates.append((c, "확장 프로그램 스크립트"))
        }
        for c in Paths.children(h + "/Library/Group Containers") {
            let cleaned = AppRegistry.cleanIdentifier(Paths.name(c)).lowercased()
            if cleaned == bundleID.lowercased() || cleaned.hasPrefix(bundleID.lowercased() + ".") {
                candidates.append((c, "앱 그룹 데이터"))
            }
        }
        for c in Paths.children(h + "/Library/LaunchAgents") where Paths.name(c).lowercased().hasPrefix(bundleID.lowercased()) {
            candidates.append((c, "자동 실행 항목"))
        }
        for c in Paths.children(h + "/Library/Preferences/ByHost") where Paths.name(c).hasPrefix(bundleID + ".") {
            candidates.append((c, "설정 파일"))
        }
        var seen = Set<String>()
        let existing = candidates.filter { Paths.exists($0.0) && seen.insert($0.0.lowercased()).inserted }
        return parallelMap(existing) { e in
            let info = DirSize.measure(e.0)
            return RelatedItem(path: e.0, label: e.1, size: info.bytes, newest: info.newestDate)
        }
            .sorted { $0.size > $1.size }
    }

    /// 앱과 선택한 관련 데이터를 휴지통으로 보낸다.
    public static func uninstall(_ app: InstalledApp, related: [String]) -> DeletionReport {
        var report = DeletionReport()
        // 실행 중이면 종료
        let running = NSRunningApplication.runningApplications(withBundleIdentifier: app.bundleID)
        running.forEach { $0.terminate() }
        let deadline = Date().addingTimeInterval(6)
        while running.contains(where: { !$0.isTerminated }) && Date() < deadline { Thread.sleep(forTimeInterval: 0.2) }
        if running.contains(where: { !$0.isTerminated }) {
            report.failures.append(DeletionFailure(path: app.path, reason: "앱이 종료되지 않았습니다. 앱을 직접 종료한 뒤 다시 시도하세요."))
            return report
        }
        let r = Deleter.remove(app.path, permanent: false, knownSize: app.appSize)
        if r.failures.isEmpty {
            report.merge(r)
        } else {
            // root 소유 앱 등은 Finder에 맡기면 관리자 암호를 물어 처리한다.
            let (ok, out) = Deleter.trashWithFinder(app.path)
            if ok { report.trashedBytes += max(0, app.appSize); report.removedCount += 1 }
            else { report.failures.append(DeletionFailure(path: app.path, reason: "앱을 휴지통으로 옮기지 못했습니다: \(out)")) }
        }
        for p in related { report.merge(Deleter.remove(p, permanent: false)) }
        AppRegistry.shared.reload()
        return report
    }
}
