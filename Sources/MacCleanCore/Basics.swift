import Foundation

// MARK: - 경로 도우미

public enum Paths {
    public static let home: String = NSHomeDirectory()

    /// "~/Library" 같은 경로를 절대 경로로 바꾼다.
    public static func expand(_ p: String) -> String {
        if p == "~" { return home }
        if p.hasPrefix("~/") { return home + String(p.dropFirst(1)) }
        return p
    }

    /// 홈 폴더 아래 경로를 "~/..." 형태로 줄인다.
    public static func abbreviate(_ p: String) -> String {
        if p == home { return "~" }
        if p.hasPrefix(home + "/") { return "~" + p.dropFirst(home.count) }
        return p
    }

    public static func exists(_ p: String) -> Bool {
        FileManager.default.fileExists(atPath: p)
    }

    public static func isDirectory(_ p: String) -> Bool {
        var isDir: ObjCBool = false
        return FileManager.default.fileExists(atPath: p, isDirectory: &isDir) && isDir.boolValue
    }

    public static func children(_ dir: String) -> [String] {
        ((try? FileManager.default.contentsOfDirectory(atPath: dir)) ?? [])
            .filter { $0 != ".DS_Store" && $0 != ".localized" }
            .map { dir + "/" + $0 }
    }

    public static func name(_ p: String) -> String { (p as NSString).lastPathComponent }
    public static func parent(_ p: String) -> String { (p as NSString).deletingLastPathComponent }
    public static func ext(_ p: String) -> String { (p as NSString).pathExtension.lowercased() }

    public static func modificationDate(_ p: String) -> Date? {
        (try? FileManager.default.attributesOfItem(atPath: p))?[.modificationDate] as? Date
    }
}

// MARK: - 포맷

public enum Fmt {
    static let byteFormatter: ByteCountFormatter = {
        let f = ByteCountFormatter()
        f.countStyle = .file
        f.allowedUnits = [.useKB, .useMB, .useGB, .useTB]
        return f
    }()

    static let relative: RelativeDateTimeFormatter = {
        let f = RelativeDateTimeFormatter()
        f.locale = Locale(identifier: "ko_KR")
        f.unitsStyle = .full
        return f
    }()

    static let dateFormatter: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "ko_KR")
        f.dateFormat = "yyyy.MM.dd"
        return f
    }()

    public static func bytes(_ v: Int64) -> String {
        if v < 0 { return "크기 미확인" }
        if v == 0 { return "0 KB" }
        return byteFormatter.string(fromByteCount: v)
    }

    public static func bytes(_ v: UInt64) -> String { bytes(Int64(clamping: v)) }

    static let memoryFormatter: ByteCountFormatter = {
        let f = ByteCountFormatter()
        f.countStyle = .memory
        f.allowedUnits = [.useKB, .useMB, .useGB]
        return f
    }()

    /// 메모리는 Apple 표기처럼 1024 단위 (24GB Mac이 24GB로 보이도록)
    public static func memory(_ v: UInt64) -> String {
        v == 0 ? "0 MB" : memoryFormatter.string(fromByteCount: Int64(clamping: v))
    }

    public static func ago(_ d: Date?) -> String {
        guard let d else { return "기록 없음" }
        if abs(d.timeIntervalSinceNow) < 60 { return "방금" }
        return relative.localizedString(for: d, relativeTo: Date())
    }

    public static func date(_ d: Date?) -> String {
        guard let d else { return "-" }
        return dateFormatter.string(from: d)
    }

    public static func count(_ n: Int) -> String {
        NumberFormatter.localizedString(from: NSNumber(value: n), number: .decimal)
    }

    public static func days(since d: Date?) -> Int? {
        guard let d else { return nil }
        return Int(Date().timeIntervalSince(d) / 86400)
    }

    public static func percent(_ v: Double) -> String {
        String(format: "%.0f%%", v * 100)
    }
}

// MARK: - 판정 모델

/// 지워도 되는지에 대한 판정 단계
public enum Safety: Int, Comparable, CaseIterable, Sendable {
    case safe = 0
    case review = 1
    case caution = 2
    case keep = 3

    public static func < (a: Safety, b: Safety) -> Bool { a.rawValue < b.rawValue }

    public var label: String {
        switch self {
        case .safe: "삭제해도 안전"
        case .review: "확인 후 삭제"
        case .caution: "주의 필요"
        case .keep: "삭제 금지"
        }
    }

    public var shortLabel: String {
        switch self {
        case .safe: "안전"
        case .review: "확인"
        case .caution: "주의"
        case .keep: "보존"
        }
    }

    public var explanation: String {
        switch self {
        case .safe: "지워도 앱이 필요할 때 자동으로 다시 만들거나 다시 받는 데이터입니다."
        case .review: "내가 만들거나 받은 파일일 수 있습니다. 내용을 확인하고 필요 없으면 지우세요."
        case .caution: "앱 데이터·설정이 들어 있어 지우면 기록, 로그인, 설정이 사라질 수 있습니다."
        case .keep: "시스템이나 앱 동작에 필요하거나 직접 지우면 손상됩니다. 해당 앱 안에서 정리하세요."
        }
    }
}

public enum ItemKind: String, Sendable, CaseIterable {
    case cache, logs, developer, buildArtifact, appData, appBundle, appSettings
    case userFiles, document, video, image, audio, media, download, installer, archive
    case backup, mail, messenger, cloud, virtualMachine, aiModel, system, trash, folder, file

    public var label: String {
        switch self {
        case .cache: "캐시"
        case .logs: "로그"
        case .developer: "개발 도구"
        case .buildArtifact: "빌드 산출물"
        case .appData: "앱 데이터"
        case .appBundle: "응용 프로그램"
        case .appSettings: "앱 설정"
        case .userFiles: "내 파일"
        case .document: "문서"
        case .video: "동영상"
        case .image: "이미지"
        case .audio: "오디오"
        case .media: "미디어 보관함"
        case .download: "다운로드"
        case .installer: "설치 파일"
        case .archive: "압축 파일"
        case .backup: "백업"
        case .mail: "메일"
        case .messenger: "메신저"
        case .cloud: "클라우드"
        case .virtualMachine: "가상머신"
        case .aiModel: "AI 모델"
        case .system: "시스템"
        case .trash: "휴지통"
        case .folder: "폴더"
        case .file: "파일"
        }
    }

    public var symbol: String {
        switch self {
        case .cache: "bolt.horizontal.circle"
        case .logs: "doc.text.magnifyingglass"
        case .developer: "hammer"
        case .buildArtifact: "shippingbox"
        case .appData: "tray.full"
        case .appBundle: "app.dashed"
        case .appSettings: "slider.horizontal.3"
        case .userFiles: "person.crop.square"
        case .document: "doc.richtext"
        case .video: "film"
        case .image: "photo"
        case .audio: "music.note"
        case .media: "photo.on.rectangle.angled"
        case .download: "arrow.down.circle"
        case .installer: "opticaldiscdrive"
        case .archive: "doc.zipper"
        case .backup: "externaldrive.badge.timemachine"
        case .mail: "envelope"
        case .messenger: "bubble.left.and.bubble.right"
        case .cloud: "icloud"
        case .virtualMachine: "cpu"
        case .aiModel: "brain"
        case .system: "gearshape.2"
        case .trash: "trash"
        case .folder: "folder"
        case .file: "doc"
        }
    }
}

public enum SuggestedAction: Sendable, Equatable {
    case none
    /// 항목 자체를 휴지통으로
    case trash
    /// 폴더는 남기고 안의 내용만 지움
    case emptyContents
    /// 터미널 명령으로 정리
    case command(title: String, command: String, admin: Bool)
    /// 해당 앱에서 직접 정리하도록 안내
    case manual(String)
}

public struct Insight: Sendable {
    public var title: String
    public var detail: String
    public var consequence: String?
    public var kind: ItemKind
    public var safety: Safety
    public var action: SuggestedAction
    public var appName: String?
    public var appBundleID: String?
    public var appPath: String?
    public var isOrphan: Bool = false
    public var inherited: Bool = false
    /// 규칙으로 확인된 판정인지(false면 이름·확장자 기반 추정)
    public var confident: Bool = true

    public init(title: String, detail: String, consequence: String? = nil, kind: ItemKind, safety: Safety,
                action: SuggestedAction = .none, confident: Bool = true) {
        self.title = title
        self.detail = detail
        self.consequence = consequence
        self.kind = kind
        self.safety = safety
        self.action = action
        self.confident = confident
    }
}

// MARK: - 동시성 도우미

final class Locked<T>: @unchecked Sendable {
    private var value: T
    private let lock = NSLock()
    init(_ v: T) { value = v }
    func get() -> T { lock.lock(); defer { lock.unlock() }; return value }
    func mutate<R>(_ f: (inout T) -> R) -> R { lock.lock(); defer { lock.unlock() }; return f(&value) }
}

func parallelMap<T, R>(_ items: [T], _ transform: (T) -> R) -> [R] {
    if items.isEmpty { return [] }
    var results = [R?](repeating: nil, count: items.count)
    let lock = NSLock()
    DispatchQueue.concurrentPerform(iterations: items.count) { i in
        let r = transform(items[i])
        lock.lock(); results[i] = r; lock.unlock()
    }
    return results.map { $0! }
}
