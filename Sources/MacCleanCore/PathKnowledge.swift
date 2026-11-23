import Foundation

/// 경로 → "이게 뭔지, 지워도 되는지" 판정
public final class PathKnowledge: @unchecked Sendable {
    public static let shared = PathKnowledge()

    enum Target { case any, dir, file }

    struct Rule {
        var patterns: [[String]]
        var title: String
        var kind: ItemKind
        var safety: Safety
        var detail: String
        var consequence: String?
        var action: SuggestedAction
        var inherit: Bool
        var target: Target
        var sibling: [String]
        var child: String?
        var excluding: [String]
        var appCapture: Bool
        var orphanTitle: String?
    }

    private let rules: [Rule]
    private let cache = Locked<[String: Insight]>([:])

    public init() { rules = Self.buildRules() }

    public func invalidate(_ path: String? = nil) {
        cache.mutate { c in
            if let path { c = c.filter { !$0.key.hasPrefix(path) } } else { c.removeAll() }
        }
    }

    public func insight(for rawPath: String, isDirectory: Bool) -> Insight {
        if let c = cache.get()[rawPath] { return c }
        let r = compute(rawPath, isDirectory: isDirectory)
        cache.mutate { $0[rawPath] = r }
        return r
    }

    // MARK: 계산

    static func components(_ rawPath: String) -> [String] {
        var path = rawPath
        if path.hasPrefix("/System/Volumes/Data/") { path = String(path.dropFirst("/System/Volumes/Data".count)) }
        let home = Paths.home
        if path == home { return ["~"] }
        if path.hasPrefix(home + "/") {
            return ["~"] + path.dropFirst(home.count + 1).split(separator: "/").map(String.init)
        }
        return ["/"] + path.split(separator: "/").map(String.init)
    }

    private func compute(_ path: String, isDirectory: Bool) -> Insight {
        let comps = Self.components(path)
        if let (rule, caps) = directMatch(comps, path: path, isDirectory: isDirectory, inheritOnly: false) {
            return makeInsight(rule, caps: caps, path: path, comps: comps)
        }
        // 상위 폴더 규칙 상속
        var anc = comps
        var ancPath = path
        while anc.count > 1 {
            anc.removeLast()
            ancPath = Paths.parent(ancPath)
            if let (rule, caps) = directMatch(anc, path: ancPath, isDirectory: true, inheritOnly: true) {
                let base = makeInsight(rule, caps: caps, path: ancPath, comps: anc)
                return derive(base, ancestorName: anc.last ?? ancPath, name: comps.last ?? path, isDirectory: isDirectory)
            }
        }
        return heuristic(name: comps.last ?? path, comps: comps, isDirectory: isDirectory)
    }

    private func directMatch(_ comps: [String], path: String, isDirectory: Bool, inheritOnly: Bool) -> (Rule, [String])? {
        for rule in rules {
            if inheritOnly && !rule.inherit { continue }
            if rule.target == .dir && !isDirectory { continue }
            if rule.target == .file && isDirectory { continue }
            var caps: [String] = []
            var matched = false
            for p in rule.patterns {
                var c: [String] = []
                if Self.match(p[...], comps[...], &c) { caps = c; matched = true; break }
            }
            guard matched else { continue }
            if !rule.excluding.isEmpty {
                let abbr = Paths.abbreviate(path)
                if rule.excluding.contains(where: { ex in
                    (ex.hasSuffix(".") || ex.hasSuffix("/")) ? abbr.hasPrefix(ex) : (abbr == ex || abbr.hasPrefix(ex + "/"))
                }) { continue }
            }
            if !rule.sibling.isEmpty {
                let parent = Paths.parent(path)
                if !rule.sibling.contains(where: { Paths.exists(parent + "/" + $0) }) { continue }
            }
            if let child = rule.child, !Paths.exists(path + "/" + child) { continue }
            return (rule, caps)
        }
        return nil
    }

    static func segMatch(_ pat: String, _ seg: String) -> Bool {
        if pat == "*" { return true }
        if pat.contains("|") {
            return pat.split(separator: "|").contains { segMatch(String($0), seg) }
        }
        if pat.contains("*") || pat.contains("?") {
            return fnmatch(pat, seg, FNM_CASEFOLD) == 0
        }
        return pat.caseInsensitiveCompare(seg) == .orderedSame
    }

    static func match(_ p: ArraySlice<String>, _ s: ArraySlice<String>, _ caps: inout [String]) -> Bool {
        guard let first = p.first else { return s.isEmpty }
        if first == "**" {
            let rest = p.dropFirst()
            var idx = s.startIndex
            while idx <= s.endIndex {
                var c = caps
                if match(rest, s[idx...], &c) { caps = c; return true }
                idx += 1
            }
            return false
        }
        guard let seg = s.first, segMatch(first, seg) else { return false }
        if first.contains("*") { caps.append(seg) }
        return match(p.dropFirst(), s.dropFirst(), &caps)
    }

    /// ~/Library/<위치>/<이름> 형태면 <이름>을 소유 앱 후보로 돌려준다.
    static func ownerKey(_ comps: [String]) -> String? {
        guard comps.count >= 4, comps[0] == "~", comps[1] == "Library" else { return nil }
        let libDirs: Set<String> = ["Application Support", "Caches", "Containers", "Group Containers", "Logs",
                                    "Preferences", "Saved Application State", "HTTPStorages", "WebKit",
                                    "Application Scripts", "LaunchAgents", "Cookies"]
        return libDirs.contains(comps[2]) ? comps[3] : nil
    }

    private func makeInsight(_ rule: Rule, caps: [String], path: String, comps: [String]) -> Insight {
        let name = comps.last ?? path
        var ins = Insight(title: rule.title, detail: rule.detail, consequence: rule.consequence,
                          kind: rule.kind, safety: rule.safety, action: rule.action)
        let capture = rule.appCapture ? caps.last : nil
        var appLabel = capture.map { AppRegistry.guessName($0) } ?? name

        var match: AppMatch? = nil
        if let capture {
            match = AppRegistry.shared.resolve(capture)
        } else if let owner = Self.ownerKey(comps) {
            match = AppRegistry.shared.resolve(owner)
        } else if comps.count >= 3, comps[0] == "/", comps[1] == "Applications", comps[2].hasSuffix(".app") {
            match = appFromBundle("/Applications/" + comps[2])
        } else if name.hasSuffix(".app") {
            match = appFromBundle(path)
        }

        if let m = match {
            let folderLabel = capture.map { AppRegistry.shared.displayName(for: $0) }
            if let a = m.app, folderLabel == nil || folderLabel == a.name {
                ins.appName = a.name
                ins.appBundleID = a.bundleID
                ins.appPath = a.path
                if capture != nil { appLabel = a.name }
            } else if let folderLabel, m.app != nil {
                // "Adobe", "Google" 같은 회사 폴더
                ins.appName = folderLabel
                appLabel = folderLabel
            } else if let capture {
                appLabel = AppRegistry.shared.displayName(for: capture)
            }
            if let capture, m.isOrphan {
                ins.isOrphan = true
                if let t = rule.orphanTitle { ins.title = t }
                ins.detail = "이 데이터를 쓰는 앱(\(AppRegistry.cleanIdentifier(capture)))을 이 Mac에서 찾지 못했습니다. 앱을 지운 뒤 남은 찌꺼기일 가능성이 높습니다. 다시 설치할 계획이 없다면 지워도 됩니다.\n\n" + rule.detail
                if ins.safety >= .caution { ins.safety = .review }
                if ins.action == .none { ins.action = .trash }
            }
        }

        let stem = name.hasSuffix(".app") ? String(name.dropLast(4)) : name
        ins.title = ins.title
            .replacingOccurrences(of: "{app}", with: appLabel)
            .replacingOccurrences(of: "{name}", with: stem)
            .replacingOccurrences(of: "{ext}", with: Paths.ext(name).uppercased())
        return ins
    }

    private func appFromBundle(_ path: String) -> AppMatch? {
        guard let d = NSDictionary(contentsOfFile: path + "/Contents/Info.plist"),
              let id = d["CFBundleIdentifier"] as? String else { return nil }
        var name = FileManager.default.displayName(atPath: path)
        if name.hasSuffix(".app") { name.removeLast(4) }
        return .installed(AppInfo(bundleID: id, name: name, path: path,
                                  version: d["CFBundleShortVersionString"] as? String, isSystem: false))
    }

    private func derive(_ base: Insight, ancestorName: String, name: String, isDirectory: Bool) -> Insight {
        var d = base
        d.inherited = true
        d.detail = "상위 폴더 '\(ancestorName)'(\(base.title))에 속한 항목입니다.\n\n" + base.detail
        if d.action == .emptyContents { d.action = .trash }
        // 사용자 폴더 안의 파일은 확장자로 종류를 더 구체화
        if !isDirectory, d.safety == .review, [.userFiles, .download, .folder, .media, .video, .image, .audio].contains(base.kind) {
            let k = Self.fileKind(Paths.ext(name))
            if k != .file {
                d.kind = k
                d.title = "\(k.label) 파일"
                if k == .installer { d.detail = "앱 설치용 파일입니다. 이미 설치했다면 지워도 됩니다.\n\n" + d.detail }
                if k == .archive { d.detail = "압축 파일입니다. 이미 풀어서 쓰고 있다면 원본 압축 파일은 지워도 됩니다.\n\n" + d.detail }
            }
        }
        return d
    }

    static func fileKind(_ ext: String) -> ItemKind {
        switch ext {
        case "mp4", "mov", "m4v", "mkv", "avi", "webm", "wmv", "flv", "mts", "m2ts", "3gp": return .video
        case "jpg", "jpeg", "png", "heic", "heif", "gif", "tiff", "tif", "bmp", "webp", "raw", "cr2", "cr3", "nef", "arw", "dng", "psd", "ai", "svg": return .image
        case "mp3", "m4a", "wav", "aiff", "aif", "flac", "aac", "ogg", "caf", "opus": return .audio
        case "pdf", "doc", "docx", "ppt", "pptx", "xls", "xlsx", "key", "pages", "numbers", "hwp", "hwpx", "txt", "md", "rtf", "csv", "epub": return .document
        case "zip", "rar", "7z", "tar", "gz", "tgz", "bz2", "xz", "zst": return .archive
        case "dmg", "pkg", "mpkg", "iso", "xip", "ipsw", "img": return .installer
        case "vmdk", "vdi", "qcow2", "vhd", "vhdx", "hdd", "raw2": return .virtualMachine
        default: return .file
        }
    }

    private func heuristic(name: String, comps: [String], isDirectory: Bool) -> Insight {
        let lower = name.lowercased()
        if isDirectory {
            if lower.contains("cache") {
                return Insight(title: "캐시로 보이는 폴더",
                               detail: "이름에 'cache'가 들어 있어 다시 만들 수 있는 임시 데이터일 가능성이 높습니다. 확인된 규칙은 아니므로 어느 프로그램의 것인지 확인한 뒤 지우세요.",
                               kind: .cache, safety: .review, action: .emptyContents, confident: false)
            }
            if lower == "logs" || lower == "log" {
                return Insight(title: "로그 폴더", detail: "프로그램이 남긴 기록으로 보입니다. 보통 지워도 되지만 확인된 규칙은 아닙니다.",
                               kind: .logs, safety: .review, action: .emptyContents, confident: false)
            }
            if ["tmp", "temp", ".tmp"].contains(lower) {
                return Insight(title: "임시 폴더", detail: "임시 파일 폴더로 보입니다. 해당 프로그램이 실행 중이 아니라면 대부분 지워도 됩니다.",
                               kind: .cache, safety: .review, action: .emptyContents, confident: false)
            }
            return Insight(title: "폴더",
                           detail: "용도를 자동으로 판단하지 못한 폴더입니다. 안에 든 항목을 열어 보고, 오랫동안 수정되지 않았는데 무엇인지 모르겠다면 Finder에서 먼저 확인하세요.",
                           kind: .folder, safety: .review, action: .trash, confident: false)
        }
        let k = Self.fileKind(Paths.ext(name))
        let title = k == .file ? "파일" : "\(k.label) 파일"
        let systemArea = comps.first == "/" && comps.count > 1 && ["System", "Library", "private", "usr", "bin", "sbin", "opt"].contains(comps[1])
        return Insight(title: title,
                       detail: systemArea ? "시스템 영역의 파일입니다. 무엇인지 확실하지 않다면 건드리지 마세요."
                                          : "용도를 자동으로 판단하지 못한 파일입니다. 열어 보고 필요 없으면 지우세요.",
                       kind: k, safety: systemArea ? .caution : .review, action: systemArea ? .none : .trash, confident: false)
    }

    // MARK: 규칙

    private static func R(_ pattern: String, _ title: String, _ kind: ItemKind, _ safety: Safety, _ detail: String,
                          then consequence: String? = nil, action: SuggestedAction = .none, inherit: Bool = true,
                          target: Target = .any, sibling: [String] = [], child: String? = nil,
                          excluding: [String] = [], app: Bool = false, orphan: String? = nil) -> Rule {
        let patterns: [[String]] = pattern.split(separator: ";").map { alt in
            let a = String(alt)
            if a == "~" { return ["~"] }
            if a.hasPrefix("~/") { return ["~"] + a.dropFirst(2).split(separator: "/").map(String.init) }
            if a.hasPrefix("/") { return ["/"] + a.split(separator: "/").map(String.init) }
            return a.split(separator: "/").map(String.init)
        }
        let defaultAction: SuggestedAction = action != .none ? action : (safety <= .caution ? .trash : .none)
        return Rule(patterns: patterns, title: title, kind: kind, safety: safety, detail: detail, consequence: consequence,
                    action: defaultAction, inherit: inherit, target: target, sibling: sibling, child: child,
                    excluding: excluding, appCapture: app, orphanTitle: orphan)
    }

    private static func buildRules() -> [Rule] {
        let cacheNote = "지워도 앱이 필요할 때 다시 만듭니다. 실행 중인 앱의 캐시는 앱을 종료한 뒤 지우는 것이 좋습니다."
        let notUserArea = ["~/Library", "~/.", "/System", "/Library", "/private", "/usr", "/opt", "/Applications"]
        var r: [Rule] = []

        // ───────── 시스템 영역
        r += [
            R("/System", "macOS 시스템", .system, .keep, "Apple이 서명한 읽기 전용 시스템 영역입니다. 사용자가 수정하거나 지울 수 없고, 그럴 필요도 없습니다."),
            R("/private/var/vm", "가상 메모리(스왑) 파일", .system, .keep, "메모리가 부족할 때 macOS가 디스크를 메모리처럼 쓰는 스왑 파일과 잠자기 이미지입니다. 재시동하면 줄어듭니다. 크다면 메모리를 많이 쓰는 앱을 줄이세요."),
            R("/private/var/folders", "시스템 임시 폴더", .system, .keep, "앱들이 쓰는 임시 파일과 캐시가 사용자별로 저장됩니다. 직접 지우면 실행 중인 앱이 오작동할 수 있으며, 재시동하면 일부가 자동으로 정리됩니다."),
            R("/private", "시스템 내부 데이터", .system, .keep, "macOS 내부 데이터(데이터베이스, 임시 파일, 설정)입니다. 직접 건드리지 마세요."),
            R("/Library/Developer/CoreSimulator", "시뮬레이터 런타임", .developer, .caution,
              "Xcode 시뮬레이터가 쓰는 iOS·watchOS 등의 OS 이미지입니다. 버전마다 수 GB를 차지합니다.",
              action: .manual("Xcode > Settings > Components에서 안 쓰는 런타임을 삭제하거나, 터미널에서 'xcrun simctl runtime list'로 확인 후 'xcrun simctl runtime delete <ID>'를 사용하세요.")),
            R("/Library/Application Support/com.apple.idleassetsd", "에어리얼 화면보호기·배경화면", .media, .review,
              "움직이는 에어리얼 배경화면·화면보호기 동영상입니다.",
              action: .manual("시스템 설정 > 배경화면(또는 화면 보호기)에서 받은 에어리얼 항목을 우클릭해 삭제할 수 있습니다.")),
            R("/Library/Application Support/GarageBand|Logic", "GarageBand·Logic 사운드 라이브러리", .media, .review,
              "악기·루프 사운드 라이브러리입니다. 음악 작업을 하지 않는다면 필요 없습니다.",
              action: .manual("GarageBand > 사운드 라이브러리 메뉴에서 관리하세요.")),
            R("/Library/Audio/Apple Loops", "Apple 루프 사운드", .media, .review, "GarageBand·Logic용 루프 음원입니다. 음악 작업을 하지 않는다면 필요 없습니다."),
            R("/Library/Caches", "시스템 공용 캐시", .cache, .safe, "모든 사용자가 공유하는 캐시입니다. 지우려면 관리자 권한이 필요합니다."),
            R("/Library/Updates", "macOS 업데이트 파일", .system, .keep, "macOS가 받아 둔 업데이트입니다. 설치되면 자동으로 정리됩니다."),
            R("/Library", "시스템 공용 라이브러리", .system, .caution, "모든 사용자가 공유하는 앱 지원 파일·드라이버·설정입니다. 앱을 지운 뒤 찌꺼기가 남기도 하지만 관리자 권한이 필요하고 신중해야 합니다.", inherit: false),
            R("/opt/homebrew;/usr/local/Homebrew", "Homebrew 패키지", .developer, .caution,
              "Homebrew로 설치한 명령줄 도구와 라이브러리입니다.",
              action: .manual("'brew list'로 설치 목록을 보고 'brew uninstall <이름>'으로 지우세요. 'brew cleanup'은 오래된 버전을 정리합니다.")),
            R("/opt", "추가 설치 프로그램", .developer, .caution, "패키지 관리자나 설치 프로그램이 쓰는 위치입니다."),
            R("/usr|bin|sbin|etc|var|cores", "Unix 시스템 영역", .system, .keep, "운영체제의 Unix 영역입니다. 직접 건드리지 마세요."),
            R("/Applications/*.app", "{name} 앱", .appBundle, .review,
              "설치된 응용 프로그램입니다. 오랫동안 쓰지 않았다면 '앱 관리' 메뉴에서 관련 데이터까지 함께 삭제하세요.",
              then: "앱이 삭제됩니다. 필요하면 다시 설치할 수 있습니다."),
            R("/Applications", "응용 프로그램 폴더", .appBundle, .review, "설치된 앱들이 있는 곳입니다. '앱 관리' 메뉴에서 앱별 용량과 마지막 사용일을 볼 수 있습니다.", inherit: false),
            R("/Users", "사용자 폴더 모음", .userFiles, .keep, "이 Mac의 모든 사용자 계정 폴더입니다.", inherit: false),
        ]

        // ───────── 홈: 휴지통·클라우드
        r += [
            R("~/.Trash", "휴지통", .trash, .safe,
              "이미 지운 파일들이 아직 공간을 차지하고 있습니다. 휴지통을 비워야 실제로 공간이 확보됩니다.",
              then: "영구 삭제되어 복구할 수 없습니다.", action: .emptyContents),
            R("~/Library/Mobile Documents", "iCloud Drive", .cloud, .review,
              "iCloud Drive에 동기화되는 파일입니다. 여기서 지우면 모든 기기에서 지워집니다.",
              action: .manual("공간만 확보하려면 Finder에서 파일을 우클릭 > '다운로드 항목 제거'를 선택하세요. 파일은 iCloud에 남습니다.")),
            R("~/Library/CloudStorage/*", "{name} 클라우드 폴더", .cloud, .review,
              "Google Drive·Dropbox·OneDrive 등 클라우드 동기화 폴더입니다. 여기서 지우면 클라우드에서도 지워집니다.",
              action: .manual("해당 앱의 '온라인 전용' 기능이나 Finder의 '다운로드 항목 제거'로 로컬 공간만 확보하세요.")),
            R("~/Library/CloudStorage", "클라우드 동기화 폴더", .cloud, .review, "클라우드 서비스와 동기화되는 폴더 모음입니다."),
        ]

        // ───────── Xcode·개발 도구
        r += [
            R("~/Library/Developer/Xcode/DerivedData", "Xcode 빌드 캐시 (DerivedData)", .buildArtifact, .safe,
              "Xcode가 빌드할 때 만드는 중간 파일과 코드 색인입니다. 지우면 다음 빌드가 한 번 느려질 뿐 자동으로 다시 만들어집니다.",
              action: .emptyContents),
            R("~/Library/Developer/Xcode/Archives", "Xcode 아카이브", .developer, .caution,
              "앱을 배포할 때 만든 아카이브(.xcarchive)입니다. 출시한 버전의 크래시 로그를 해석(dSYM)하는 데 필요할 수 있으니 오래된 것부터 정리하세요."),
            R("~/Library/Developer/Xcode/*DeviceSupport", "기기 지원 파일 ({name})", .developer, .safe,
              "실제 iPhone 등을 연결했을 때 OS 버전별로 받는 디버깅 심볼입니다. 지워도 기기를 다시 연결하면 자동으로 받습니다. 더 이상 쓰지 않는 버전부터 지우세요.",
              action: .emptyContents),
            R("~/Library/Developer/Xcode/UserData/Previews", "SwiftUI 프리뷰 데이터", .buildArtifact, .safe,
              "SwiftUI 프리뷰용 시뮬레이터 데이터입니다. 지워도 프리뷰를 열면 다시 만들어집니다.", action: .emptyContents),
            R("~/Library/Developer/CoreSimulator/Caches", "시뮬레이터 캐시", .cache, .safe, "시뮬레이터 실행 캐시입니다. " + cacheNote, action: .emptyContents),
            R("~/Library/Developer/CoreSimulator/Devices/*", "시뮬레이터 기기", .developer, .caution,
              "시뮬레이터 기기 하나와 그 안에 설치한 앱·데이터입니다. 지금 개발에 쓰지 않는 기기라면 지워도 됩니다.",
              action: .command(title: "사용 불가 시뮬레이터 삭제", command: "xcrun simctl delete unavailable", admin: false)),
            R("~/Library/Developer/CoreSimulator/Devices", "iOS 시뮬레이터 기기 모음", .developer, .caution,
              "시뮬레이터 기기들과 설치된 앱 데이터입니다. 더 이상 지원되지 않는(사용 불가) 기기는 안전하게 지울 수 있습니다.",
              action: .command(title: "사용 불가 시뮬레이터 삭제", command: "xcrun simctl delete unavailable", admin: false)),
            R("~/Library/Developer/XCPGDevices|XCTestDevices", "테스트·플레이그라운드용 시뮬레이터", .developer, .safe,
              "Xcode 테스트나 플레이그라운드 실행 시 자동으로 만든 임시 시뮬레이터입니다.", action: .emptyContents),
            R("~/Library/Developer", "개발자 도구 데이터", .developer, .caution,
              "Xcode와 시뮬레이터가 쓰는 데이터입니다. 하위 폴더마다 안전도가 다르니 하나씩 확인하세요."),
        ]

        // ───────── 캐시 (구체적인 것 먼저)
        r += [
            R("~/Library/Caches/Homebrew", "Homebrew 다운로드 캐시", .cache, .safe,
              "brew로 설치할 때 받은 패키지 파일입니다. 설치가 끝난 뒤에는 필요 없습니다. ('brew cleanup --prune=all'과 같은 효과)",
              action: .emptyContents),
            R("~/Library/Caches/ms-playwright", "Playwright 테스트용 브라우저", .cache, .safe,
              "자동화 테스트용으로 받은 Chromium·Firefox·WebKit입니다. 지우면 다음 테스트 때 다시 받습니다.", action: .emptyContents),
            R("~/Library/Caches/vscode-cpptools", "VS Code C/C++ 코드 색인 캐시", .cache, .safe,
              "C/C++ 확장이 만든 IntelliSense 색인입니다. 지우면 프로젝트를 열 때 다시 만듭니다.", action: .emptyContents),
            R("~/Library/Caches/*", "{app} 캐시", .cache, .safe,
              "앱이 속도를 위해 임시로 저장해 둔 데이터입니다. " + cacheNote,
              action: .emptyContents, app: true, orphan: "{app} 캐시 (삭제된 앱)"),
            R("~/Library/Caches", "앱 캐시 모음", .cache, .safe,
              "모든 앱의 캐시가 모인 폴더입니다. 폴더 자체는 두고 안의 내용만 지우세요. '정리 추천'에서 앱별로 골라 지울 수 있습니다.",
              action: .emptyContents),
            R("~/Library/Logs/DiagnosticReports", "충돌·진단 보고서", .logs, .safe,
              "앱이 멈추거나 충돌했을 때 남긴 기록입니다. 문제를 해결했다면 필요 없습니다.", action: .emptyContents),
            R("~/Library/Logs/*", "앱 로그 ({name})", .logs, .safe, "앱이 남긴 동작 기록입니다. 문제 해결용이며 지워도 됩니다.", action: .emptyContents),
            R("~/Library/Logs", "앱 로그 모음", .logs, .safe, "앱들이 남긴 동작 기록입니다. 문제 해결용이며 지워도 됩니다.", action: .emptyContents),
        ]

        // ───────── 백업
        r += [
            R("~/Library/Application Support/MobileSync/Backup/*", "iPhone·iPad 백업", .backup, .caution,
              "Finder로 만든 기기 로컬 백업입니다. 기기를 잃어버리거나 초기화했을 때 복원에 필요합니다. iCloud 백업을 쓰거나 이미 쓰지 않는 기기라면 오래된 백업은 지워도 됩니다.",
              then: "이 백업으로 기기를 복원할 수 없게 됩니다.",
              action: .manual("Finder 사이드바에서 기기 선택 > '백업 관리'에서도 삭제할 수 있습니다.")),
            R("~/Library/Application Support/MobileSync", "기기 백업 모음", .backup, .caution,
              "iPhone·iPad 로컬 백업이 저장되는 곳입니다. 백업마다 수십 GB가 될 수 있습니다."),
        ]

        // ───────── 웹 엔진(Chromium/Electron) 캐시 — 앱 데이터보다 먼저
        r += [
            R("~/Library/Application Support/**/Service Worker/CacheStorage|ScriptCache", "웹사이트 오프라인 캐시", .cache, .safe,
              "웹사이트나 웹 기반 앱(Slack, Notion 등)이 오프라인용으로 저장한 캐시입니다. 지우면 처음 접속할 때처럼 다시 받습니다.",
              action: .emptyContents),
            R("~/Library/Application Support/**/Cache|Code Cache|GPUCache|CachedData|DawnCache|DawnGraphiteCache|DawnWebGPUCache|GrShaderCache|GraphiteDawnCache|ShaderCache|component_crx_cache|extensions_crx_cache", "웹 엔진 캐시 ({name})", .cache, .safe,
              "Chrome이나 Electron 기반 앱(VS Code, Slack, Discord, Claude 등)이 만든 캐시입니다. " + cacheNote,
              action: .emptyContents, target: .dir),
            R("~/Library/Application Support/Code|Cursor|Windsurf|VSCodium/CachedExtensionVSIXs", "에디터 확장 설치 파일 캐시", .cache, .safe,
              "확장 프로그램을 설치·업데이트할 때 받은 설치 파일입니다. 설치가 끝난 뒤에는 필요 없습니다.", action: .emptyContents),
            R("~/Library/Application Support/Code|Cursor|Windsurf|VSCodium/User/workspaceStorage", "에디터 작업공간 기록", .appData, .review,
              "열었던 프로젝트마다 저장되는 편집 상태와 검색 색인입니다. 오래된 프로젝트 것은 지워도 되며, 열린 탭 같은 상태만 초기화됩니다.",
              action: .emptyContents),
            R("~/Library/Application Support/Google/Chrome/OptGuideOnDeviceModel", "Chrome 내장 AI 모델", .aiModel, .review,
              "Chrome이 기기 내 AI 기능을 위해 받은 모델입니다. 지워도 Chrome이 필요하면 다시 받습니다."),
            R("~/Library/Application Support/Google/GoogleUpdater", "Google 업데이트 도구", .appData, .review,
              "Chrome 등 Google 앱의 자동 업데이트 도구와 받아 둔 업데이트 파일입니다. Google 앱을 쓰고 있다면 그대로 두세요."),
            R("~/Library/Application Support/Google/Chrome", "Chrome 사용자 프로필", .appData, .caution,
              "북마크, 방문 기록, 로그인 정보, 확장 프로그램이 저장된 프로필입니다. 통째로 지우면 Chrome 데이터가 사라집니다. 캐시만 정리하세요."),
            R("~/Library/Application Support/Claude/vm_bundles", "Claude 앱 가상머신 이미지", .virtualMachine, .review,
              "Claude 데스크톱 앱이 코드 실행·에이전트 기능에 쓰는 가상머신 이미지입니다. 지우면 해당 기능을 다시 쓸 때 다시 받습니다. Claude 앱을 종료한 상태에서 정리하세요."),
            R("~/Library/Application Support/Autodesk/webdeploy", "Fusion 360 프로그램 본체", .appBundle, .caution,
              "Autodesk Fusion은 /Applications 대신 이곳에 설치됩니다. 지우면 Fusion이 실행되지 않습니다. 이전 버전이 함께 남아 있을 수 있지만 Fusion이 직접 관리합니다.",
              action: .manual("Fusion을 쓰지 않는다면 Autodesk 제거 도구(Fusion > 'Remove' 앱)로 삭제하세요.")),
            R("~/Library/Application Support/Steam/steamapps", "Steam 게임 파일", .appData, .review, "설치한 게임 파일입니다.",
              action: .manual("Steam 라이브러리에서 게임 우클릭 > 관리 > 제거를 사용하세요.")),
            R("~/Library/Application Support/Spotify/PersistentCache", "Spotify 스트리밍 캐시", .cache, .safe,
              "음악을 빠르게 재생하려고 저장한 캐시입니다. 오프라인 저장한 곡은 따로 관리됩니다.", action: .emptyContents),
            R("~/Library/Application Support/Adobe/Common/Media Cache Files|Media Cache", "Adobe 미디어 캐시", .cache, .safe,
              "Premiere·After Effects가 만든 미디어 캐시입니다. 지우면 프로젝트를 열 때 다시 만듭니다.", action: .emptyContents),
            R("~/Library/Application Support/CrashReporter", "충돌 보고 기록", .logs, .safe, "앱 충돌 기록입니다.", action: .emptyContents),
            R("~/Library/Application Support/FileProvider", "클라우드 동기화 내부 데이터", .cloud, .keep,
              "iCloud Drive나 클라우드 앱의 동기화 상태 데이터입니다. 직접 지우면 동기화가 꼬일 수 있습니다."),
            R("~/Library/Application Support/AddressBook|CallHistoryDB|CallHistoryTransactions|Knowledge|DifferentialPrivacy", "macOS 개인 데이터베이스", .system, .keep,
              "연락처·통화 기록 등 macOS가 관리하는 데이터베이스입니다. 직접 지우지 마세요."),
            R("~/Library/Application Support/com.apple.*", "macOS 구성요소 데이터", .system, .keep,
              "Apple 기본 앱과 시스템 서비스의 데이터입니다. 직접 지우지 마세요.", app: true),
            R("~/Library/Application Support/*", "{app} 데이터", .appData, .caution,
              "앱의 설정, 기록, 다운로드한 콘텐츠 등이 저장된 곳입니다. 지우면 해당 앱의 데이터와 로그인이 초기화될 수 있습니다.",
              then: "앱이 처음 설치한 상태처럼 초기화될 수 있습니다.", app: true, orphan: "{app} 데이터 (삭제된 앱)"),
            R("~/Library/Application Support", "앱 데이터 모음", .appData, .caution,
              "각 앱의 핵심 데이터가 저장되는 폴더입니다. 폴더 자체는 지우면 안 되며, 앱별로 확인하세요.", inherit: false),
        ]

        // ───────── 샌드박스 컨테이너
        r += [
            R("~/Library/Containers/com.apple.mail/Data/Library/Mail Downloads", "메일 첨부파일 임시 사본", .cache, .safe,
              "Mail에서 첨부파일을 열 때 만든 사본입니다. 원본은 메일에 그대로 있으므로 지워도 됩니다.", action: .emptyContents),
            R("~/Library/Containers/*/Data/Library/Caches", "{app} 캐시", .cache, .safe, "샌드박스 앱의 캐시입니다. " + cacheNote,
              action: .emptyContents, app: true, orphan: "{app} 캐시 (삭제된 앱)"),
            R("~/Library/Containers/com.docker.docker", "Docker Desktop 가상 디스크", .virtualMachine, .caution,
              "Docker 이미지·컨테이너·볼륨·빌드 캐시가 들어 있는 가상 디스크(Docker.raw)입니다. 파일을 직접 지우면 모든 Docker 데이터가 사라집니다. 안 쓰는 이미지와 빌드 캐시를 정리하면 크게 줄어듭니다.",
              then: "직접 지우면 모든 이미지·컨테이너·볼륨이 사라집니다.",
              action: .command(title: "안 쓰는 Docker 데이터 정리", command: "docker system prune -af", admin: false)),
            R("~/Library/Containers/com.kakao.KakaoTalkMac", "카카오톡 데이터", .messenger, .caution,
              "카카오톡 대화 기록과 주고받은 사진·동영상·파일 캐시가 저장됩니다. 폴더를 직접 지우면 대화 기록이 사라질 수 있습니다.",
              action: .manual("카카오톡 > 설정 > 채팅에서 '캐시 데이터 삭제' 등 저장공간 관리 메뉴로 정리하세요.")),
            R("~/Library/Containers/jp.naver.line.mac", "LINE 데이터", .messenger, .caution, "LINE 대화와 미디어 캐시입니다.",
              action: .manual("LINE > 설정 > 대화에서 캐시·데이터 삭제를 사용하세요.")),
            R("~/Library/Containers/com.tinyspeck.slackmacgap", "Slack 데이터", .messenger, .caution, "Slack 앱 데이터와 캐시입니다.",
              action: .manual("Slack > 도움말 > 문제 해결 > '캐시 지우기'를 사용하세요.")),
            R("~/Library/Containers/com.utmapp.UTM", "UTM 가상머신", .virtualMachine, .caution, "UTM 가상머신 디스크입니다.",
              action: .manual("UTM 앱에서 필요 없는 가상머신을 삭제하세요.")),
            R("~/Library/Containers/com.apple.*", "{app} (macOS 기본 앱) 데이터", .system, .keep,
              "macOS 기본 앱·서비스의 데이터입니다. 직접 지우지 말고 해당 앱 안에서 정리하세요.", app: true),
            R("~/Library/Containers/*", "{app} 데이터 (샌드박스)", .appData, .caution,
              "App Store 앱 등 샌드박스 앱의 데이터 폴더입니다. 지우면 해당 앱이 처음 설치한 상태로 초기화됩니다.",
              app: true, orphan: "{app} 데이터 (삭제된 앱)"),
            R("~/Library/Containers", "샌드박스 앱 데이터 모음", .appData, .caution, "샌드박스 앱마다 하나씩 만들어지는 데이터 폴더 모음입니다.", inherit: false),
            R("~/Library/Group Containers/*ru.keepcoder.Telegram", "텔레그램 데이터", .messenger, .caution, "텔레그램 대화와 미디어 캐시입니다.",
              action: .manual("Telegram > 설정 > 데이터 및 저장소 > 저장 공간 사용량에서 캐시를 지우세요.")),
            R("~/Library/Group Containers/*whatsapp*", "WhatsApp 데이터", .messenger, .caution, "WhatsApp 대화와 미디어입니다.",
              action: .manual("WhatsApp > 설정 > 저장 공간 및 데이터에서 관리하세요.")),
            R("~/Library/Group Containers/*.Office", "Microsoft Office 공유 데이터", .appData, .caution, "Word·Excel·PowerPoint·Outlook이 함께 쓰는 데이터입니다."),
            R("~/Library/Group Containers/group.com.apple.*|*.com.apple.*|*.groups.com.apple.*", "macOS 앱 공유 데이터", .system, .keep, "Apple 앱들이 함께 쓰는 데이터입니다. 직접 지우지 마세요."),
            R("~/Library/Group Containers/*", "{app} 공유 데이터 (앱 그룹)", .appData, .caution,
              "같은 회사 앱·확장 프로그램이 함께 쓰는 데이터입니다.", app: true, orphan: "{app} 공유 데이터 (삭제된 앱)"),
            R("~/Library/Group Containers", "앱 그룹 공유 데이터 모음", .appData, .caution, "같은 회사 앱들이 공유하는 데이터 폴더 모음입니다.", inherit: false),
        ]

        // ───────── 메일·메시지·사진 등 앱으로 관리해야 하는 것
        r += [
            R("~/Library/Mail", "Mail 보관함", .mail, .keep,
              "Mail 앱의 메일과 첨부파일 데이터베이스입니다. 직접 지우면 메일이 손상될 수 있습니다.",
              action: .manual("Mail 앱에서 큰 첨부가 있는 메일을 지우세요. 계정 설정에서 '첨부 파일 다운로드: 안 함'을 고르면 새 첨부는 저장하지 않습니다.")),
            R("~/Library/Messages/Attachments", "iMessage 첨부파일", .messenger, .caution,
              "메시지로 주고받은 사진·동영상입니다. 직접 지우면 대화에서 깨진 첨부로 보입니다.",
              action: .manual("시스템 설정 > 일반 > 저장 공간 > 메시지에서 큰 첨부를 지우거나, 메시지 > 설정에서 '메시지 보관'을 1년으로 바꾸세요.")),
            R("~/Library/Messages", "iMessage 대화 기록", .messenger, .caution, "메시지 앱의 대화와 첨부파일입니다.",
              action: .manual("시스템 설정 > 일반 > 저장 공간 > 메시지에서 관리하세요.")),
            R("~/Library/Photos", "사진 앱 시스템 데이터", .media, .keep, "사진 앱이 관리하는 데이터입니다."),
            R("**/*.photoslibrary", "사진 보관함", .media, .keep,
              "사진 앱의 라이브러리입니다. Finder에서 직접 지우거나 내부를 건드리면 라이브러리가 손상됩니다.",
              action: .manual("사진 앱에서 사진을 지운 뒤 '최근 삭제된 항목'도 비우세요. iCloud 사진을 쓴다면 사진 > 설정 > iCloud > 'Mac 저장 공간 최적화'를 켜면 원본은 iCloud에만 남아 공간이 크게 줄어듭니다.")),
            R("**/*.fcpbundle", "Final Cut Pro 라이브러리", .media, .caution, "Final Cut Pro 프로젝트와 미디어, 렌더 파일입니다.",
              action: .manual("Final Cut Pro에서 라이브러리 선택 > 파일 > '생성된 라이브러리 파일 삭제'로 렌더 파일을 정리하세요.")),
            R("**/*.imovielibrary", "iMovie 라이브러리", .media, .caution, "iMovie 프로젝트와 미디어입니다.",
              action: .manual("iMovie > 파일 > '렌더 파일 삭제'로 정리하세요.")),
            R("**/*.musiclibrary|*.tvlibrary|*.photolibrary", "미디어 보관함", .media, .keep, "음악·TV 앱 보관함입니다. 앱 안에서 관리하세요."),
            R("**/*.logicx|*.band", "음악 프로젝트", .media, .review, "Logic·GarageBand 프로젝트입니다."),
            R("~/Music/Music/Media.localized|Media", "음악 앱 미디어", .audio, .review, "음악 앱이 관리하는 음원 파일입니다.",
              action: .manual("음악 앱에서 곡을 삭제하세요.")),
            R("~/Library/Safari", "Safari 데이터", .appData, .keep, "Safari 방문 기록·북마크 등입니다. Safari 설정에서 관리하세요."),
            R("~/Library/Keychains", "키체인 (암호 저장소)", .system, .keep, "모든 암호와 인증서가 저장됩니다. 절대 지우지 마세요."),
            R("~/Library/Preferences/*", "{app} 설정 파일", .appSettings, .caution,
              "앱 설정 파일(plist)입니다. 용량이 작고, 지우면 해당 앱 설정이 초기화됩니다.", app: true, orphan: "{app} 설정 (삭제된 앱)"),
            R("~/Library/Preferences", "앱 설정 파일 모음", .appSettings, .keep, "앱들의 설정 파일입니다. 용량이 작아 정리 효과가 거의 없습니다.", inherit: false),
            R("~/Library/Saved Application State/*", "{app} 창 복원 정보", .cache, .safe,
              "앱을 다시 열 때 이전 창 상태를 복원하는 데 쓰입니다. 지워도 문제없습니다.", app: true, orphan: "{app} 창 복원 정보 (삭제된 앱)"),
            R("~/Library/Saved Application State", "창 복원 정보 모음", .cache, .safe, "앱 창 상태 복원 정보입니다.", action: .emptyContents),
            R("~/Library/HTTPStorages/*", "{app} 웹 쿠키·저장소", .cache, .review,
              "앱이 인터넷 통신에 쓰는 쿠키와 캐시입니다. 지우면 앱 안의 일부 로그인이 풀릴 수 있습니다.", app: true, orphan: "{app} 웹 저장소 (삭제된 앱)"),
            R("~/Library/WebKit/*", "{app} 웹뷰 데이터", .cache, .review,
              "앱 안의 웹 화면이 저장한 캐시·로컬 데이터입니다. 지우면 일부 로그인 상태가 풀릴 수 있습니다.", app: true, orphan: "{app} 웹뷰 데이터 (삭제된 앱)"),
            R("~/Library/LaunchAgents/*", "{app} 자동 실행 항목", .appSettings, .caution,
              "로그인할 때 자동으로 실행되는 백그라운드 작업 설정입니다. 지운 앱의 것이라면 지워도 됩니다.", app: true, orphan: "{app} 자동 실행 (삭제된 앱)"),
            R("~/Library/Application Scripts/*", "{app} 스크립트", .appSettings, .caution, "앱 확장 기능용 스크립트 폴더입니다.", app: true, orphan: "{app} 스크립트 (삭제된 앱)"),
            R("~/Library/Metadata/CoreSpotlight", "Spotlight 검색 색인", .system, .keep, "앱 내용 검색용 색인입니다. 시스템이 관리합니다."),
            R("~/Library/Fonts", "사용자 글꼴", .userFiles, .review, "직접 설치한 글꼴입니다. 서체 관리자 앱에서 관리하세요."),
            R("~/Library/Autosave Information", "자동 저장된 문서", .userFiles, .caution, "저장하지 않은 문서의 자동 저장본입니다. 지우면 복구할 수 없습니다."),
            R("~/Library/Arduino15/staging", "Arduino 다운로드 파일", .cache, .safe,
              "보드 패키지·라이브러리를 설치할 때 받은 압축 파일입니다. 설치가 끝났다면 필요 없습니다.", action: .emptyContents),
            R("~/Library/Arduino15/packages", "Arduino 보드 패키지", .developer, .caution,
              "설치된 보드 코어와 컴파일러 툴체인입니다.",
              action: .manual("Arduino IDE > 보드 매니저에서 안 쓰는 보드를 제거하세요.")),
            R("~/Library/Arduino15", "Arduino 데이터", .developer, .caution, "Arduino IDE의 보드·라이브러리 데이터입니다."),
            R("~/Library/Android/sdk/system-images", "Android 에뮬레이터 시스템 이미지", .developer, .caution,
              "Android 에뮬레이터용 OS 이미지입니다. 버전마다 수 GB입니다.",
              action: .manual("Android Studio > SDK Manager에서 안 쓰는 시스템 이미지를 체크 해제하세요.")),
            R("~/Library/Android/sdk", "Android SDK", .developer, .caution, "Android 개발 도구입니다. SDK Manager로 관리하세요.",
              action: .manual("Android Studio > SDK Manager에서 안 쓰는 플랫폼·도구를 제거하세요.")),
            R("~/Library/Android", "Android 개발 도구", .developer, .caution, "Android SDK와 에뮬레이터 이미지입니다. Android Studio에서 관리하세요."),
            R("~/Library/HTTPStorages", "앱 웹 저장소 모음", .cache, .review, "앱들이 인터넷 통신에 쓰는 쿠키·캐시 모음입니다.", inherit: false),
            R("~/Library/WebKit", "앱 웹뷰 데이터 모음", .cache, .review, "앱 안의 웹 화면이 저장한 데이터 모음입니다.", inherit: false),
            R("~/Library/Google", "Google 앱 데이터", .appData, .caution, "Google 소프트웨어(업데이트 도구 등)의 데이터입니다."),
            R("~/Library/pnpm", "pnpm 데이터", .cache, .review, "pnpm 패키지 관리자의 공유 저장소와 실행 파일입니다."),
            R("~/Library/pnpm/store", "pnpm 패키지 저장소", .cache, .review,
              "pnpm이 모든 프로젝트에서 공유하는 패키지 저장소입니다. 지우면 각 프로젝트에서 'pnpm install'을 다시 해야 합니다.",
              action: .command(title: "안 쓰는 패키지 정리", command: "pnpm store prune", admin: false)),
            R("~/Library/Biome|Trial|DuetExpertCenter|IntelligencePlatform|Assistant|Suggestions|Daemon Containers|Accounts|IdentityServices|Sharing|Shortcuts|Calendars|Reminders|Accessibility|Finance|PersonalizationPortrait|Weather|Translation|Passes|StatusKit|LanguageModeling|Spelling|AppleMediaServices|com.apple.*|homeenergyd|MediaAnalysis|Metadata|Cookies|Keyboard|Sounds", "macOS 시스템 데이터 ({name})", .system, .keep,
              "macOS가 관리하는 데이터입니다. 직접 지우지 마세요."),
            R("~/Library/*", "{name} (라이브러리)", .appData, .caution,
              "앱이나 도구가 라이브러리에 만든 폴더입니다. 어느 프로그램의 것인지 확인한 뒤 판단하세요."),
            R("~/Library", "라이브러리 (앱 데이터·설정)", .system, .keep,
              "앱 설정, 캐시, 데이터가 모인 숨김 폴더입니다. 폴더 자체를 지우면 절대 안 되며, 하위 폴더를 하나씩 확인하세요.", inherit: false),
        ]

        // ───────── 홈의 숨김 개발 도구 폴더
        r += [
            R("~/.npm/_cacache", "npm 패키지 캐시", .cache, .safe, "npm으로 받은 패키지 캐시입니다. 지우면 다음 설치 때 다시 받습니다.", action: .emptyContents),
            R("~/.npm", "npm 데이터", .cache, .safe, "npm 캐시와 로그입니다.", action: .emptyContents),
            R("~/.yarn/berry/cache;~/.yarn/cache", "Yarn 패키지 캐시", .cache, .safe, "Yarn이 받은 패키지 캐시입니다.", action: .emptyContents),
            R("~/.yarn", "Yarn 데이터", .cache, .safe, "Yarn 패키지 캐시와 설정입니다."),
            R("~/.bun/install/cache", "Bun 패키지 캐시", .cache, .safe, "Bun이 받은 패키지 캐시입니다.", action: .emptyContents),
            R("~/.pnpm-store", "pnpm 패키지 저장소", .cache, .review, "pnpm 공유 저장소입니다. 지우면 프로젝트마다 다시 설치해야 합니다."),
            R("~/.cache/huggingface", "Hugging Face AI 모델", .aiModel, .caution,
              "Python 라이브러리로 받은 AI 모델과 데이터셋입니다. 지우면 다음에 쓸 때 수 GB를 다시 받아야 합니다.",
              action: .manual("필요 없는 모델만 지우려면 'huggingface-cli delete-cache'를 사용하세요.")),
            R("~/.cache/torch", "PyTorch 모델 캐시", .aiModel, .caution, "PyTorch가 받은 모델 가중치입니다. 지우면 다시 받아야 합니다."),
            R("~/.cache/codex-runtimes", "Codex 실행 환경 캐시", .cache, .review, "Codex CLI가 받아 둔 실행 환경입니다. 지우면 다음 실행 때 다시 받습니다."),
            R("~/.cache/uv|pip|pre-commit|puppeteer|selenium|node-gyp|yarn|go-build|bazel|deno|typescript|prisma|ms-playwright|black|ruff", "{name} 캐시", .cache, .safe,
              "명령줄 도구의 캐시입니다. 지우면 필요할 때 다시 받거나 만듭니다.", action: .emptyContents),
            R("~/.cache", "명령줄 도구 캐시 모음", .cache, .review,
              "여러 개발 도구가 쓰는 캐시입니다. 대부분 지워도 되지만 AI 모델처럼 다시 받기 무거운 것도 있으니 하위 폴더를 확인하세요."),
            R("~/.ollama/models", "Ollama 로컬 AI 모델", .aiModel, .caution, "Ollama로 받은 AI 모델입니다.",
              action: .manual("터미널에서 'ollama list'로 확인하고 'ollama rm <모델명>'으로 삭제하세요.")),
            R("~/.lmstudio/models;~/.cache/lm-studio", "LM Studio AI 모델", .aiModel, .caution, "LM Studio로 받은 AI 모델입니다.",
              action: .manual("LM Studio > My Models에서 삭제하세요.")),
            R("~/.gradle/caches|wrapper", "Gradle 캐시", .cache, .safe,
              "Gradle이 받은 의존성과 Gradle 배포판입니다. 지우면 다음 빌드 때 다시 받습니다.", action: .emptyContents),
            R("~/.gradle", "Gradle 데이터", .developer, .review, "Gradle 캐시·데몬 데이터입니다."),
            R("~/.m2/repository", "Maven 저장소 캐시", .cache, .safe, "Maven이 받은 라이브러리입니다. 지우면 다음 빌드 때 다시 받습니다.", action: .emptyContents),
            R("~/.cargo/registry|git", "Rust 크레이트 캐시", .cache, .safe, "cargo가 받은 크레이트 소스입니다. 지우면 다시 받습니다.", action: .emptyContents),
            R("~/.rustup/toolchains", "Rust 툴체인", .developer, .caution, "설치된 Rust 컴파일러 버전들입니다.",
              action: .manual("'rustup toolchain list'로 확인 후 'rustup toolchain uninstall <이름>'으로 지우세요.")),
            R("~/go/pkg/mod", "Go 모듈 캐시", .cache, .safe, "Go가 받은 모듈입니다. 지우면 다음 빌드 때 다시 받습니다.",
              action: .command(title: "Go 모듈 캐시 비우기", command: "go clean -modcache", admin: false)),
            R("~/.cocoapods/repos", "CocoaPods 스펙 저장소", .cache, .safe, "CocoaPods 라이브러리 목록 캐시입니다.", action: .emptyContents),
            R("~/.pub-cache", "Dart·Flutter 패키지 캐시", .cache, .review, "Dart 패키지 캐시입니다. 지우면 프로젝트에서 'flutter pub get'을 다시 해야 합니다."),
            R("~/.dartServer", "Dart 분석 서버 캐시", .cache, .safe, "에디터의 Dart 코드 분석 캐시입니다. 지우면 다시 만듭니다.", action: .emptyContents),
            R("~/flutter/bin/cache", "Flutter SDK 캐시", .cache, .safe, "Flutter 엔진·도구 캐시입니다. 지우면 다음 flutter 명령 실행 때 다시 받습니다.", action: .emptyContents),
            R("~/flutter;~/development/flutter", "Flutter SDK", .developer, .caution, "Flutter 개발 도구입니다. Flutter 개발을 하지 않으면 통째로 지워도 됩니다."),
            R("~/.android/avd", "Android 에뮬레이터 기기", .virtualMachine, .caution, "Android 에뮬레이터 가상 기기입니다.",
              action: .manual("Android Studio > Device Manager에서 안 쓰는 기기를 삭제하세요.")),
            R("~/.android/cache", "Android 도구 캐시", .cache, .safe, "Android 도구 캐시입니다.", action: .emptyContents),
            R("~/.android", "Android 개발 데이터", .developer, .caution, "Android 에뮬레이터·도구 데이터입니다."),
            R("~/.espressif/dist", "ESP-IDF 다운로드 파일", .cache, .safe, "ESP32 개발 도구 설치용 압축 파일입니다. 설치 후에는 필요 없습니다.", action: .emptyContents),
            R("~/.espressif", "ESP-IDF 개발 도구", .developer, .caution, "ESP32 개발용 컴파일러·도구입니다. ESP32 개발을 하지 않으면 필요 없습니다."),
            R("~/miniconda3|anaconda3|miniforge3|mambaforge|miniforge/pkgs;~/opt/anaconda3|miniconda3/pkgs;~/.conda/pkgs", "Conda 패키지 캐시", .cache, .review,
              "Conda가 받아 둔 패키지 압축 파일과 압축 해제본입니다.",
              action: .command(title: "Conda 캐시 정리", command: "conda clean --all -y", admin: false)),
            R("~/miniconda3|anaconda3|miniforge3|mambaforge|miniforge;~/opt/anaconda3|miniconda3", "Conda 파이썬 배포판", .developer, .caution,
              "Python과 과학 계산 패키지 묶음입니다. 쓰지 않는다면 폴더를 지워 통째로 제거할 수 있습니다."),
            R("~/.pyenv/versions", "pyenv 파이썬 버전들", .developer, .caution, "설치된 Python 버전들입니다.",
              action: .manual("'pyenv versions'로 확인 후 'pyenv uninstall <버전>'으로 지우세요.")),
            R("~/.nvm/.cache", "nvm 다운로드 캐시", .cache, .safe, "Node.js 설치 파일 캐시입니다.", action: .emptyContents),
            R("~/.nvm", "nvm Node.js 버전들", .developer, .caution, "설치된 Node.js 버전들입니다.",
              action: .manual("'nvm ls'로 확인 후 'nvm uninstall <버전>'으로 지우세요.")),
            R("~/.vscode|.cursor|.windsurf|.vscode-insiders/extensions", "에디터 확장 프로그램", .developer, .caution,
              "VS Code 계열 에디터의 확장 프로그램입니다. 업데이트 후 이전 버전이 남아 있기도 합니다.",
              action: .manual("에디터의 확장 탭에서 안 쓰는 확장을 제거하세요.")),
            R("~/.vscode|.cursor|.windsurf|.vscode-insiders", "에디터 데이터", .developer, .caution, "VS Code 계열 에디터의 확장·설정입니다."),
            R("~/.codex/sessions", "Codex 대화 기록", .appData, .review, "Codex CLI의 이전 세션 기록입니다. 지우면 이전 세션을 이어서 할 수 없습니다."),
            R("~/.claude/projects", "Claude Code 대화 기록", .appData, .review, "Claude Code의 프로젝트별 세션 기록입니다. 지우면 이전 대화를 이어갈 수 없습니다."),
            R("~/.docker", "Docker 설정·CLI 데이터", .developer, .caution, "Docker CLI 설정과 플러그인입니다. 이미지·컨테이너는 Docker Desktop 가상 디스크에 있습니다."),
            R("~/.orbstack|.colima|.lima", "컨테이너용 리눅스 가상머신", .virtualMachine, .caution, "OrbStack·Colima 등이 쓰는 가상머신 데이터입니다.",
              action: .manual("해당 도구에서 'docker system prune' 등으로 정리하세요.")),
            R("~/Parallels;~/Virtual Machines.localized;**/*.pvm|*.vmwarevm|*.utm", "가상머신", .virtualMachine, .caution,
              "Parallels·VMware·UTM 가상머신입니다. 가상 디스크 안에 운영체제와 데이터가 통째로 들어 있습니다.",
              action: .manual("가상머신 앱에서 삭제하세요.")),
        ]

        // ───────── 프로젝트 빌드 산출물 (어디에 있든)
        let devExcl = ["~/Library", "~/.vscode", "~/.cursor", "~/.nvm", "~/.npm", "/usr", "/opt", "/Applications", "~/Applications", "/System", "/Library"]
        r += [
            R("**/node_modules", "Node.js 의존성 (node_modules)", .buildArtifact, .safe,
              "프로젝트가 쓰는 npm 패키지입니다. 지워도 프로젝트 폴더에서 'npm install'(또는 yarn/pnpm install)을 실행하면 다시 설치됩니다. 오래 열지 않은 프로젝트라면 지우기 좋은 대상입니다.",
              target: .dir, sibling: ["package.json"], excluding: devExcl),
            R("**/node_modules", "도구 내부 모듈 (node_modules)", .developer, .caution,
              "앱이나 도구 안에 포함된 모듈입니다. 지우면 그 도구가 동작하지 않을 수 있습니다.", target: .dir),
            R("**/.next|.nuxt|.turbo|.parcel-cache|.svelte-kit|.angular|.expo|.vite", "웹 프레임워크 빌드 캐시", .buildArtifact, .safe,
              "개발 서버·빌드가 만든 캐시입니다. 다시 빌드하면 생깁니다.", target: .dir, excluding: devExcl),
            R("**/target", "Rust 빌드 결과 (target)", .buildArtifact, .safe,
              "cargo build로 만든 결과물입니다. 'cargo clean'과 같고, 다시 빌드하면 생깁니다.", target: .dir, sibling: ["Cargo.toml"], excluding: devExcl),
            R("**/.build", "Swift 패키지 빌드 결과", .buildArtifact, .safe, "swift build로 만든 결과물입니다. 다시 빌드하면 생깁니다.",
              target: .dir, sibling: ["Package.swift"], excluding: devExcl),
            R("**/build", "Gradle·Flutter 빌드 결과", .buildArtifact, .safe, "빌드 결과물입니다. 다시 빌드하면 생깁니다.",
              target: .dir, sibling: ["build.gradle", "build.gradle.kts", "pubspec.yaml"], excluding: devExcl),
            R("**/.gradle", "프로젝트 Gradle 캐시", .buildArtifact, .safe, "프로젝트별 Gradle 캐시입니다.", target: .dir,
              sibling: ["build.gradle", "build.gradle.kts", "settings.gradle", "settings.gradle.kts", "gradlew"], excluding: devExcl),
            R("**/.dart_tool", "Dart 도구 캐시", .buildArtifact, .safe, "'flutter pub get'으로 다시 만들어집니다.", target: .dir, sibling: ["pubspec.yaml"], excluding: devExcl),
            R("**/Pods", "CocoaPods 의존성", .buildArtifact, .safe, "'pod install'로 다시 설치됩니다.", target: .dir, sibling: ["Podfile"], excluding: devExcl),
            R("**/.venv|venv|env|.env", "파이썬 가상환경", .buildArtifact, .review,
              "프로젝트용 파이썬 패키지 묶음입니다. 'python -m venv'로 새로 만들고 requirements 파일로 재설치할 수 있습니다.",
              target: .dir, child: "pyvenv.cfg", excluding: devExcl),
            R("**/__pycache__|.pytest_cache|.mypy_cache|.ruff_cache|.tox", "파이썬 캐시", .buildArtifact, .safe, "실행할 때 자동으로 다시 만들어집니다.", target: .dir, excluding: devExcl),
            R("**/DerivedData", "Xcode 빌드 캐시", .buildArtifact, .safe, "Xcode 빌드 중간 파일입니다. 다시 빌드하면 생깁니다.", target: .dir, excluding: ["~/Library"]),
            R("**/.git", "Git 저장소 기록", .developer, .keep,
              "프로젝트의 모든 커밋 이력이 들어 있습니다. 지우면 버전 기록이 사라집니다. 너무 크다면 'git gc'로 압축할 수 있습니다.", target: .dir),
        ]

        // ───────── 파일 종류 (사용자 영역에서만)
        r += [
            R("**/*.dmg|*.pkg|*.mpkg", "설치 파일 ({ext})", .installer, .review,
              "앱 설치용 파일입니다. 앱을 이미 설치했다면 지워도 됩니다.", target: .file, excluding: notUserArea),
            R("**/*.ipsw", "iPhone·iPad 펌웨어", .installer, .safe,
              "기기 업데이트·복원용으로 받은 파일입니다. 업데이트가 끝났다면 필요 없습니다.", target: .file, excluding: notUserArea),
            R("**/*.xip", "Xcode 설치 압축 파일", .installer, .review, "Xcode 설치용 압축 파일입니다. 설치했다면 필요 없습니다.", target: .file, excluding: notUserArea),
            R("**/*.iso|*.img", "디스크 이미지", .installer, .review, "운영체제 설치용 등 디스크 이미지입니다.", target: .file, excluding: notUserArea),
            R("**/*.zip|*.rar|*.7z|*.tar|*.gz|*.tgz|*.bz2|*.xz", "압축 파일 ({ext})", .archive, .review,
              "압축 파일입니다. 이미 풀어서 쓰고 있다면 원본 압축 파일은 지워도 됩니다.", target: .file, excluding: notUserArea),
            R("**/*.vmdk|*.vdi|*.qcow2|*.vhd|*.vhdx|*.hdd", "가상 디스크", .virtualMachine, .caution, "가상머신 디스크입니다. 안에 운영체제와 데이터가 통째로 들어 있습니다.", target: .file, excluding: notUserArea),
            R("**/*.sparsebundle|*.sparseimage", "디스크 이미지 묶음", .backup, .caution, "Time Machine이나 암호화 디스크 이미지일 수 있습니다. 내용을 확인하세요.", excluding: notUserArea),
            R("**/*.app", "{name} 앱", .appBundle, .review, "응용 프로그램입니다. /Applications 밖에 있다면 설치 후 남은 사본일 수 있습니다.", excluding: notUserArea),
        ]

        // ───────── 사용자 폴더
        r += [
            R("~/Downloads", "다운로드 폴더", .download, .review,
              "브라우저·메신저로 받은 파일이 쌓이는 곳입니다. 설치를 마친 .dmg·.pkg, 이미 풀어 본 압축 파일, 오래된 파일은 대부분 지워도 됩니다."),
            R("~/Desktop", "데스크탑", .userFiles, .review, "데스크탑의 파일입니다. iCloud '데스크탑 및 문서' 동기화를 켰다면 여기서 지울 때 iCloud에서도 지워집니다."),
            R("~/Documents", "문서", .userFiles, .review, "내 문서입니다. iCloud '데스크탑 및 문서' 동기화를 켰다면 여기서 지울 때 iCloud에서도 지워집니다."),
            R("~/Pictures", "사진 폴더", .image, .review, "이미지 파일 폴더입니다."),
            R("~/Movies", "동영상 폴더", .video, .review, "동영상과 동영상 편집 라이브러리가 저장됩니다."),
            R("~/Music", "음악 폴더", .audio, .review, "음악 파일과 음악 앱 보관함입니다."),
            R("~/Applications", "내 응용 프로그램", .appBundle, .review, "이 사용자만 쓰는 앱 폴더입니다."),
            R("~/Public", "공유 폴더", .userFiles, .review, "다른 사용자와 파일을 공유하는 폴더입니다."),
            R("~/.*", "숨김 폴더 ({name})", .developer, .caution,
              "명령줄 도구·개발 도구가 설정과 데이터를 저장하는 숨김 폴더입니다. 어떤 도구의 것인지 확인한 뒤 판단하세요. 그 도구를 더 이상 쓰지 않는다면 지워도 됩니다."),
            R("~/*", "{name}", .userFiles, .review,
              "홈 폴더에 직접 만든 폴더이거나 프로그램이 만든 폴더입니다. 안의 내용을 보고 판단하세요."),
            R("~", "홈 폴더", .userFiles, .keep, "내 계정의 모든 파일이 있는 곳입니다.", inherit: false),
        ]
        return r
    }
}
