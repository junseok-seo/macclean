import Foundation

public enum CleanupMethod: Sendable, Equatable {
    /// 폴더는 남기고 내용만 삭제
    case deleteContents([String])
    /// 항목 자체를 삭제
    case deleteItems([String])
    /// 휴지통 비우기
    case emptyTrash
    /// 명령 실행
    case command(String, admin: Bool)
    /// 직접 앱에서 정리 (안내만)
    case manual
}

public struct CleanupItem: Identifiable, Sendable {
    public let id: String
    public var title: String
    public var subtitle: String
    public var detail: String
    public var safety: Safety
    public var kind: ItemKind
    public var size: Int64
    public var method: CleanupMethod
    /// true면 휴지통을 거치지 않고 바로 삭제
    public var permanent: Bool
    public var defaultSelected: Bool
    public var lastModified: Date?
    public var appBundleID: String?
    public var revealPath: String?
    public var guidance: String?
    public var paths: [String] {
        switch method {
        case .deleteContents(let p), .deleteItems(let p): p
        default: revealPath.map { [$0] } ?? []
        }
    }
    public var isActionable: Bool { method != .manual }

    public init(id: String, title: String, subtitle: String, detail: String, safety: Safety, kind: ItemKind,
                size: Int64, method: CleanupMethod, permanent: Bool, defaultSelected: Bool,
                lastModified: Date? = nil, appBundleID: String? = nil, revealPath: String? = nil, guidance: String? = nil) {
        self.id = id; self.title = title; self.subtitle = subtitle; self.detail = detail; self.safety = safety
        self.kind = kind; self.size = size; self.method = method; self.permanent = permanent
        self.defaultSelected = defaultSelected; self.lastModified = lastModified; self.appBundleID = appBundleID
        self.revealPath = revealPath; self.guidance = guidance
    }
}

public struct CleanupGroup: Identifiable, Sendable {
    public let id: String
    public let title: String
    public let symbol: String
    public let summary: String
    public var items: [CleanupItem]
    public var totalSize: Int64 { items.filter(\.isActionable).reduce(0) { $0 + max(0, $1.size) } }
}

/// 알려진 정리 대상을 빠르게 훑어 추천 목록을 만든다.
public final class CleanupScanner: @unchecked Sendable {
    let fm = FileManager.default
    let home = Paths.home
    let apps = AppRegistry.shared

    public init() {}

    public func scan(progress: @escaping (String) -> Void) -> [CleanupGroup] {
        disableDatalessMaterialization()
        apps.ensureLoaded()
        var groups: [CleanupGroup] = []
        let steps: [(String, () -> CleanupGroup?)] = [
            ("휴지통 확인 중", trashGroup),
            ("개발 도구 캐시 확인 중", developerGroup),
            ("앱 캐시 확인 중", appCacheGroup),
            ("브라우저·웹 앱 캐시 확인 중", webCacheGroup),
            ("로그 확인 중", logsGroup),
            ("프로젝트 빌드 산출물 찾는 중", projectGroup),
            ("다운로드 폴더 확인 중", downloadsGroup),
            ("iPhone·iPad 백업 확인 중", backupsGroup),
            ("삭제된 앱의 잔여 파일 찾는 중", leftoversGroup),
            ("큰 앱 데이터 확인 중", appDataGuideGroup),
            ("시스템 항목 확인 중", systemGroup),
        ]
        for (label, step) in steps {
            progress(label)
            if var g = step() {
                g.items = g.items.filter { $0.size != 0 || !$0.isActionable || $0.method == .emptyTrash }
                g.items.sort { $0.size > $1.size }
                if !g.items.isEmpty { groups.append(g) }
            }
        }
        return groups
    }

    private func p(_ s: String) -> String { Paths.expand(s) }

    // MARK: 휴지통

    func trashGroup() -> CleanupGroup? {
        let trash = p("~/.Trash")
        let readable = (try? fm.contentsOfDirectory(atPath: trash)) != nil
        let size = readable ? DirSize.measure(Paths.children(trash)).bytes : -1
        if readable && size <= 0 { return nil }
        let item = CleanupItem(
            id: "trash", title: "휴지통 비우기",
            subtitle: readable ? "\(Paths.children(trash).count)개 항목" : "권한이 없어 크기를 확인하지 못함",
            detail: "휴지통에 넣은 파일은 비우기 전까지 계속 공간을 차지합니다. 비우면 복구할 수 없습니다.",
            safety: .safe, kind: .trash, size: size, method: .emptyTrash, permanent: true, defaultSelected: true,
            revealPath: trash)
        return CleanupGroup(id: "trash", title: "휴지통", symbol: "trash", summary: "이미 지운 파일", items: [item])
    }

    // MARK: 개발 도구

    struct Target {
        let id: String
        let title: String
        let paths: [String]
        let safety: Safety
        let detail: String
        var contents = true
        var on = true
        var permanent = true
        var kind: ItemKind = .cache
    }

    static let devTargets: [Target] = [
        Target(id: "xcode-dd", title: "Xcode 빌드 캐시 (DerivedData)", paths: ["~/Library/Developer/Xcode/DerivedData"], safety: .safe,
               detail: "빌드 중간 파일과 색인입니다. 다음 빌드가 한 번 느려질 뿐 자동으로 다시 만들어집니다.", kind: .buildArtifact),
        Target(id: "xcode-ds", title: "Xcode 기기 지원 파일", paths: ["~/Library/Developer/Xcode/iOS DeviceSupport", "~/Library/Developer/Xcode/watchOS DeviceSupport",
                                                                   "~/Library/Developer/Xcode/tvOS DeviceSupport", "~/Library/Developer/Xcode/visionOS DeviceSupport",
                                                                   "~/Library/Developer/Xcode/macOS DeviceSupport"], safety: .safe,
               detail: "실기기 디버깅용 심볼입니다. 기기를 다시 연결하면 필요한 버전만 다시 받습니다.", kind: .developer),
        Target(id: "xcode-prev", title: "SwiftUI 프리뷰 데이터", paths: ["~/Library/Developer/Xcode/UserData/Previews"], safety: .safe,
               detail: "프리뷰용 시뮬레이터 데이터입니다. 프리뷰를 열면 다시 만들어집니다."),
        Target(id: "sim-cache", title: "시뮬레이터 캐시", paths: ["~/Library/Developer/CoreSimulator/Caches"], safety: .safe,
               detail: "시뮬레이터 실행 캐시입니다."),
        Target(id: "xc-testdev", title: "테스트용 임시 시뮬레이터", paths: ["~/Library/Developer/XCTestDevices", "~/Library/Developer/XCPGDevices"], safety: .safe,
               detail: "테스트·플레이그라운드 실행 때 자동으로 만든 시뮬레이터입니다."),
        Target(id: "xcode-arch", title: "Xcode 아카이브", paths: ["~/Library/Developer/Xcode/Archives"], safety: .caution,
               detail: "배포용 아카이브입니다. 출시한 앱의 크래시 분석(dSYM)에 필요할 수 있으니 확인 후 지우세요. 휴지통으로 이동합니다.",
               on: false, permanent: false, kind: .developer),
        Target(id: "npm", title: "npm 캐시", paths: ["~/.npm/_cacache"], safety: .safe, detail: "npm 패키지 캐시입니다. 필요하면 다시 받습니다."),
        Target(id: "yarn", title: "Yarn 캐시", paths: ["~/Library/Caches/Yarn", "~/.yarn/berry/cache", "~/.yarn/cache"], safety: .safe, detail: "Yarn 패키지 캐시입니다."),
        Target(id: "bun", title: "Bun 캐시", paths: ["~/.bun/install/cache"], safety: .safe, detail: "Bun 패키지 캐시입니다."),
        Target(id: "pnpm-cache", title: "pnpm 메타데이터 캐시", paths: ["~/Library/Caches/pnpm"], safety: .safe, detail: "pnpm 메타데이터 캐시입니다."),
        Target(id: "pip", title: "pip 캐시", paths: ["~/Library/Caches/pip", "~/.cache/pip"], safety: .safe, detail: "pip이 받은 패키지 캐시입니다."),
        Target(id: "uv", title: "uv 캐시", paths: ["~/.cache/uv"], safety: .safe, detail: "uv 파이썬 패키지 캐시입니다."),
        Target(id: "poetry", title: "Poetry 캐시", paths: ["~/Library/Caches/pypoetry"], safety: .safe, detail: "Poetry 패키지 캐시입니다."),
        Target(id: "brew", title: "Homebrew 다운로드 캐시", paths: ["~/Library/Caches/Homebrew"], safety: .safe,
               detail: "설치할 때 받은 패키지 파일입니다. 이미 설치된 뒤에는 필요 없습니다."),
        Target(id: "gradle", title: "Gradle 캐시", paths: ["~/.gradle/caches", "~/.gradle/wrapper/dists"], safety: .safe,
               detail: "Gradle 의존성과 배포판입니다. 다음 빌드 때 다시 받습니다. (Android 빌드가 처음엔 오래 걸릴 수 있음)"),
        Target(id: "maven", title: "Maven 저장소", paths: ["~/.m2/repository"], safety: .safe, detail: "Maven 라이브러리 캐시입니다. 다음 빌드 때 다시 받습니다.", on: false),
        Target(id: "cargo", title: "Rust 크레이트 캐시", paths: ["~/.cargo/registry/cache", "~/.cargo/registry/src", "~/.cargo/git/checkouts"], safety: .safe,
               detail: "cargo가 받은 크레이트입니다. 다시 빌드하면 받습니다."),
        Target(id: "go-mod", title: "Go 모듈 캐시", paths: ["~/go/pkg/mod"], safety: .safe, detail: "Go 모듈 캐시입니다. 다시 빌드하면 받습니다."),
        Target(id: "go-build", title: "Go 빌드 캐시", paths: ["~/Library/Caches/go-build"], safety: .safe, detail: "Go 컴파일 캐시입니다."),
        Target(id: "pods", title: "CocoaPods 캐시", paths: ["~/Library/Caches/CocoaPods", "~/.cocoapods/repos"], safety: .safe, detail: "CocoaPods 캐시와 스펙 저장소입니다."),
        Target(id: "playwright", title: "Playwright 테스트 브라우저", paths: ["~/Library/Caches/ms-playwright"], safety: .safe,
               detail: "테스트용 브라우저입니다. 다음 테스트 실행 때 다시 받습니다.", on: false),
        Target(id: "puppeteer", title: "Puppeteer 브라우저", paths: ["~/.cache/puppeteer"], safety: .safe, detail: "테스트용 Chrome입니다.", on: false),
        Target(id: "jetbrains", title: "JetBrains IDE 캐시", paths: ["~/Library/Caches/JetBrains"], safety: .safe,
               detail: "IntelliJ·Android Studio 등의 색인 캐시입니다. 다음 실행 때 다시 색인합니다."),
        Target(id: "cpptools", title: "VS Code C/C++ 색인 캐시", paths: ["~/Library/Caches/vscode-cpptools"], safety: .safe,
               detail: "C/C++ 확장의 IntelliSense 캐시입니다."),
        Target(id: "node-gyp", title: "node-gyp 헤더 캐시", paths: ["~/Library/Caches/node-gyp", "~/.cache/node-gyp"], safety: .safe, detail: "네이티브 모듈 빌드용 헤더입니다."),
        Target(id: "ts", title: "TypeScript 타입 캐시", paths: ["~/Library/Caches/typescript"], safety: .safe, detail: "에디터가 받은 타입 정의 캐시입니다."),
        Target(id: "electron", title: "Electron 다운로드 캐시", paths: ["~/Library/Caches/electron", "~/Library/Caches/electron-builder"], safety: .safe,
               detail: "Electron 앱 개발용으로 받은 런타임입니다."),
        Target(id: "vsix", title: "에디터 확장 설치 파일", paths: ["~/Library/Application Support/Code/CachedExtensionVSIXs",
                                                          "~/Library/Application Support/Cursor/CachedExtensionVSIXs"], safety: .safe,
               detail: "확장 프로그램 설치·업데이트용으로 받은 파일입니다. 설치 후에는 필요 없습니다."),
        Target(id: "vscode-ws", title: "에디터 작업공간 기록", paths: ["~/Library/Application Support/Code/User/workspaceStorage",
                                                            "~/Library/Application Support/Cursor/User/workspaceStorage"], safety: .review,
               detail: "프로젝트별 편집 상태·검색 색인입니다. 지우면 열린 탭 같은 상태만 초기화됩니다.", on: false, kind: .appData),
        Target(id: "dart", title: "Dart 분석 서버 캐시", paths: ["~/.dartServer"], safety: .safe, detail: "에디터의 Dart 코드 분석 캐시입니다."),
        Target(id: "flutter-cache", title: "Flutter SDK 캐시", paths: ["~/flutter/bin/cache", "~/development/flutter/bin/cache"], safety: .safe,
               detail: "Flutter 엔진 캐시입니다. 다음 flutter 명령 실행 때 다시 받습니다 (수백 MB 다운로드).", on: false),
        Target(id: "pub", title: "Dart·Flutter 패키지 캐시", paths: ["~/.pub-cache/hosted"], safety: .review,
               detail: "Dart 패키지 캐시입니다. 지우면 각 프로젝트에서 'flutter pub get'을 다시 해야 합니다.", on: false),
        Target(id: "android-cache", title: "Android 도구 캐시", paths: ["~/.android/cache"], safety: .safe, detail: "Android 도구 캐시입니다."),
        Target(id: "arduino-staging", title: "Arduino 다운로드 파일", paths: ["~/Library/Arduino15/staging"], safety: .safe,
               detail: "보드 패키지·라이브러리 설치용 압축 파일입니다. 설치가 끝났다면 필요 없습니다."),
        Target(id: "espressif-dist", title: "ESP-IDF 다운로드 파일", paths: ["~/.espressif/dist"], safety: .safe,
               detail: "ESP32 도구 설치용 압축 파일입니다. 설치 후에는 필요 없습니다."),
        Target(id: "hf", title: "Hugging Face AI 모델", paths: ["~/.cache/huggingface"], safety: .caution,
               detail: "Python으로 받은 AI 모델입니다. 지우면 다음에 쓸 때 다시 받아야 합니다(수 GB). 휴지통으로 이동합니다.",
               contents: true, on: false, permanent: false, kind: .aiModel),
    ]

    /// 앱 캐시 그룹에서 제외할(개발 그룹이 이미 다루는) 캐시 폴더 이름
    static var claimedCacheNames: Set<String> {
        var s = Set<String>()
        for t in devTargets {
            for path in t.paths where path.hasPrefix("~/Library/Caches/") {
                s.insert(String(path.dropFirst("~/Library/Caches/".count)).components(separatedBy: "/")[0])
            }
        }
        return s
    }

    func developerGroup() -> CleanupGroup? {
        var items: [CleanupItem] = parallelMap(Self.devTargets) { t -> CleanupItem? in
            let paths = t.paths.map(self.p).filter { Paths.exists($0) }
            guard !paths.isEmpty else { return nil }
            let info = DirSize.measure(paths)
            guard info.bytes > 1_000_000 else { return nil }
            return CleanupItem(id: "dev-" + t.id, title: t.title, subtitle: paths.map(Paths.abbreviate).joined(separator: ", "),
                               detail: t.detail, safety: t.safety, kind: t.kind, size: info.bytes,
                               method: t.contents ? .deleteContents(paths) : .deleteItems(paths),
                               permanent: t.permanent, defaultSelected: t.on, lastModified: info.newestDate, revealPath: paths.first)
        }.compactMap { $0 }

        // 사용 불가 시뮬레이터
        if Paths.exists(p("~/Library/Developer/CoreSimulator/Devices")) {
            let r = Shell.run("xcrun simctl list devices unavailable -j", timeout: 30)
            if r.status == 0, let data = r.output.data(using: .utf8),
               let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
               let devices = json["devices"] as? [String: [[String: Any]]] {
                let dataPaths = devices.values.flatMap { $0 }.compactMap { $0["dataPath"] as? String }.map { Paths.parent($0) }
                if !dataPaths.isEmpty {
                    let size = DirSize.measure(dataPaths).bytes
                    items.append(CleanupItem(id: "dev-simctl", title: "사용 불가 시뮬레이터 \(dataPaths.count)개",
                                             subtitle: "xcrun simctl delete unavailable",
                                             detail: "설치된 Xcode에서 더 이상 지원하지 않는 런타임의 시뮬레이터 기기입니다. 쓸 수 없는 기기이므로 지워도 됩니다.",
                                             safety: .safe, kind: .developer, size: size,
                                             method: .command("xcrun simctl delete unavailable", admin: false),
                                             permanent: true, defaultSelected: true))
                }
            }
            // 전체 시뮬레이터 기기 크기 안내
            let devicesDir = p("~/Library/Developer/CoreSimulator/Devices")
            let total = DirSize.measure(devicesDir).bytes
            if total > 2_000_000_000 {
                items.append(CleanupItem(id: "dev-sim-all", title: "시뮬레이터 기기 전체", subtitle: Paths.abbreviate(devicesDir),
                                         detail: "모든 시뮬레이터 기기와 그 안의 앱 데이터입니다. 자주 쓰지 않는 기기는 Xcode > Window > Devices and Simulators에서 지우세요.",
                                         safety: .caution, kind: .developer, size: total, method: .manual, permanent: false,
                                         defaultSelected: false, revealPath: devicesDir,
                                         guidance: "Xcode > Window > Devices and Simulators > Simulators 탭에서 기기를 우클릭해 삭제하세요. 모두 초기화하려면 터미널에서 'xcrun simctl erase all'을 사용합니다."))
            }
        }

        // Conda
        let condaPkgs = ["~/miniconda3/pkgs", "~/anaconda3/pkgs", "~/miniforge3/pkgs", "~/mambaforge/pkgs", "~/opt/anaconda3/pkgs", "~/opt/miniconda3/pkgs"]
            .map(p).filter { Paths.exists($0) }
        if let pkgs = condaPkgs.first {
            let condaBin = Paths.parent(pkgs) + "/bin/conda"
            let size = DirSize.measure(condaPkgs).bytes
            if size > 50_000_000 {
                items.append(CleanupItem(id: "dev-conda", title: "Conda 패키지 캐시", subtitle: condaPkgs.map(Paths.abbreviate).joined(separator: ", "),
                                         detail: "Conda가 받아 둔 패키지 압축 파일과 안 쓰는 패키지입니다. 'conda clean --all'로 환경에서 쓰는 것은 남기고 정리합니다. (표시된 크기는 최대치)",
                                         safety: .safe, kind: .cache, size: size,
                                         method: Paths.exists(condaBin) ? .command("'\(condaBin)' clean --all -y", admin: false) : .manual,
                                         permanent: true, defaultSelected: false, revealPath: pkgs,
                                         guidance: "터미널에서 'conda clean --all'을 실행하세요."))
            }
        }

        // Docker — 위험도가 다른 두 가지로 나눈다. 볼륨(DB 등 데이터)은 어느 쪽도 지우지 않는다.
        let dockerDir = p("~/Library/Containers/com.docker.docker")
        if Paths.exists(dockerDir) {
            let disk = DirSize.measure(dockerDir).bytes
            var byType: [String: Int64] = [:]
            var running = false
            if Shell.which("docker") != nil {
                let r = Shell.run("docker system df --format '{{.Type}}|{{.Reclaimable}}'", timeout: 15)
                if r.status == 0 {
                    running = true
                    for line in r.output.split(separator: "\n") {
                        let parts = line.split(separator: "|", maxSplits: 1).map(String.init)
                        if parts.count == 2 { byType[parts[0]] = Self.parseDockerSize(parts[1]) }
                    }
                }
            }
            if running {
                let cache = (byType["Build Cache"] ?? 0) + (byType["Containers"] ?? 0)
                if cache > 50_000_000 {
                    items.append(CleanupItem(
                        id: "dev-docker-cache", title: "Docker 빌드 캐시·멈춘 컨테이너",
                        subtitle: "docker builder prune · container prune",
                        detail: "이미지를 빌드할 때 쌓인 캐시와 멈춘 컨테이너를 지웁니다. 이미지와 볼륨(데이터)은 그대로 둡니다. 다음 빌드가 처음 한 번 느려질 뿐입니다.",
                        safety: .safe, kind: .buildArtifact, size: min(cache, disk),
                        method: .command("docker container prune -f && docker builder prune -af", admin: false),
                        permanent: true, defaultSelected: true, revealPath: dockerDir))
                }
                let images = byType["Images"] ?? 0
                if images > 50_000_000 {
                    items.append(CleanupItem(
                        id: "dev-docker-images", title: "사용하지 않는 Docker 이미지 전부",
                        subtitle: "docker image prune -af · 실행 중인 컨테이너가 쓰지 않는 이미지",
                        detail: "지금 실행 중인 컨테이너가 쓰지 않는 이미지를 모두 지웁니다. 받은 이미지는 다시 받아야 하고, 직접 빌드한 이미지는 소스에서 다시 빌드해야 합니다. 볼륨(데이터)은 지우지 않습니다. 이미지별로 고르려면 Docker Desktop의 Images 탭을 쓰세요.",
                        safety: .caution, kind: .virtualMachine, size: min(images, disk),
                        method: .command("docker image prune -af", admin: false),
                        permanent: true, defaultSelected: false, revealPath: dockerDir))
                }
                let volumes = byType["Local Volumes"] ?? 0
                if volumes > 1_000_000_000 {
                    items.append(CleanupItem(
                        id: "dev-docker-volumes", title: "Docker 볼륨 (데이터)",
                        subtitle: "컨테이너가 쓰지 않는 볼륨 \(Fmt.bytes(volumes))",
                        detail: "데이터베이스, 다운로드한 AI 모델 같은 컨테이너 데이터입니다. 지우면 되살릴 수 없어 MacClean은 지우지 않습니다.",
                        safety: .keep, kind: .virtualMachine, size: volumes, method: .manual, permanent: false,
                        defaultSelected: false, revealPath: dockerDir,
                        guidance: "필요 없는 볼륨만 골라 지우려면 Docker Desktop > Volumes 탭을 쓰세요. 이름 없는(익명) 볼륨만 지우려면 터미널에서 'docker volume prune'을 실행합니다."))
                }
            } else {
                items.append(CleanupItem(
                    id: "dev-docker", title: "Docker 디스크", subtitle: "Docker 디스크 \(Fmt.bytes(disk)) · Docker가 실행 중이 아니라 정리 가능량 미확인",
                    detail: "Docker 이미지·컨테이너·볼륨이 들어 있는 가상 디스크입니다. Docker Desktop을 실행한 뒤 다시 검사하면 빌드 캐시와 이미지를 나눠서 정리할 수 있습니다.",
                    safety: .caution, kind: .virtualMachine, size: disk, method: .manual, permanent: false,
                    defaultSelected: false, revealPath: dockerDir,
                    guidance: "Docker Desktop을 실행한 뒤 '다시 검사'를 누르세요."))
            }
        }

        guard !items.isEmpty else { return nil }
        return CleanupGroup(id: "dev", title: "개발 도구", symbol: "hammer", summary: "다시 받거나 다시 빌드하면 되는 캐시", items: items)
    }

    static func parseDockerSize(_ s: String) -> Int64 {
        // "2.315GB (45%)" 또는 "0B"
        let token = s.split(separator: " ").first.map(String.init) ?? ""
        let units: [(String, Double)] = [("TB", 1e12), ("GB", 1e9), ("MB", 1e6), ("kB", 1e3), ("KB", 1e3), ("B", 1)]
        for (u, m) in units where token.hasSuffix(u) {
            if let v = Double(token.dropLast(u.count)) { return Int64(v * m) }
        }
        return 0
    }

    // MARK: 앱 캐시

    func appCacheGroup() -> CleanupGroup? {
        let cachesDir = p("~/Library/Caches")
        let excluded: Set<String> = Self.claimedCacheNames.union([
            "CloudKit", "com.apple.bird", "com.apple.nsurlsessiond", "com.apple.containermanagerd", "FamilyCircle",
            "com.apple.HomeKit", "com.apple.homed", "com.apple.ap.adprivacyd", "com.apple.akd", "Bundle.main",
            Bundle.main.bundleIdentifier ?? "com.macclean.app", "com.macclean.app",
        ])
        var entries: [(path: String, key: String, container: Bool)] = Paths.children(cachesDir)
            .filter { !excluded.contains(Paths.name($0)) }
            .map { ($0, Paths.name($0), false) }
        // 샌드박스 앱 캐시
        for c in Paths.children(p("~/Library/Containers")) {
            let cache = c + "/Data/Library/Caches"
            if Paths.isDirectory(cache) { entries.append((cache, Paths.name(c), true)) }
        }
        let sized = parallelMap(entries) { e in (e, DirSize.measure(e.path)) }
        var items: [CleanupItem] = []
        var small: [String] = []
        var smallSize: Int64 = 0
        for (e, info) in sized {
            let match = apps.resolve(e.key)
            if match.isOrphan { continue } // 잔여 파일 그룹에서 다룸
            if info.bytes < 5_000_000 {
                if info.bytes > 0 { small.append(e.path); smallSize += info.bytes }
                continue
            }
            let name = apps.displayName(for: e.key)
            let isDir = Paths.isDirectory(e.path)
            let isApple = e.key.lowercased().hasPrefix("com.apple.")
            items.append(CleanupItem(
                id: "cache-" + e.path, title: "\(name) 캐시", subtitle: Paths.abbreviate(e.path),
                detail: "앱이 속도를 위해 임시로 저장해 둔 데이터입니다. 지워도 앱이 필요할 때 다시 만듭니다. 앱이 실행 중이면 종료 후 지우는 것이 좋습니다."
                    + (isApple ? " (macOS 기본 앱의 캐시는 시스템이 보호해서 일부가 지워지지 않을 수 있습니다.)" : ""),
                safety: .safe, kind: .cache, size: info.bytes,
                method: isDir ? .deleteContents([e.path]) : .deleteItems([e.path]),
                permanent: true, defaultSelected: true, lastModified: info.newestDate,
                appBundleID: match.app?.bundleID, revealPath: e.path))
        }
        if smallSize > 1_000_000 {
            let dirs = small.filter { Paths.isDirectory($0) }
            let files = small.filter { !Paths.isDirectory($0) }
            items.append(CleanupItem(id: "cache-small", title: "기타 작은 캐시 \(small.count)개", subtitle: "5MB 미만 캐시 모음",
                                     detail: "여러 앱의 작은 캐시입니다.", safety: .safe, kind: .cache, size: smallSize,
                                     method: files.isEmpty ? .deleteContents(dirs) : .deleteItems(files + dirs.flatMap { Paths.children($0) }),
                                     permanent: true, defaultSelected: true))
        }
        guard !items.isEmpty else { return nil }
        return CleanupGroup(id: "caches", title: "앱 캐시", symbol: "bolt.horizontal.circle", summary: "앱이 다시 만드는 임시 데이터", items: items)
    }

    // MARK: 브라우저·Electron 앱 캐시

    static let webCacheNames: Set<String> = ["Cache", "Code Cache", "GPUCache", "CachedData", "DawnCache", "DawnGraphiteCache",
                                             "DawnWebGPUCache", "GrShaderCache", "GraphiteDawnCache", "ShaderCache",
                                             "component_crx_cache", "extensions_crx_cache"]

    func webCacheGroup() -> CleanupGroup? {
        let base = p("~/Library/Application Support")
        var found: [String: [String]] = [:]
        guard let c = strdup(base) else { return nil }
        defer { free(c) }
        var argv: [UnsafeMutablePointer<CChar>?] = [c, nil]
        guard let fts = fts_open(&argv, FTS_PHYSICAL | FTS_NOCHDIR | FTS_XDEV, nil) else { return nil }
        defer { fts_close(fts) }
        let skipTop: Set<String> = ["MobileSync", "Steam", "FileProvider", "Autodesk", "AddressBook", "Knowledge", "CallHistoryDB"]
        while let e = fts_read(fts) {
            let ent = e.pointee
            guard Int32(ent.fts_info) == FTS_D else { continue }
            let level = Int(ent.fts_level)
            if level == 0 { continue }
            let path = String(cString: ent.fts_path)
            let name = Paths.name(path)
            let rel = path.dropFirst(base.count + 1).split(separator: "/").map(String.init)
            if level == 1 && (skipTop.contains(name) || name.hasPrefix("com.apple.")) { _ = fts_set(fts, e, FTS_SKIP); continue }
            if level > 6 || name == "node_modules" || name.hasSuffix(".app") { _ = fts_set(fts, e, FTS_SKIP); continue }
            let parentName = rel.count >= 2 ? rel[rel.count - 2] : ""
            let isCache = (level >= 2 && Self.webCacheNames.contains(name))
                || (parentName == "Service Worker" && (name == "CacheStorage" || name == "ScriptCache"))
            if isCache {
                var key = rel[0]
                if key == "Google" || key == "Microsoft" || key == "BraveSoftware" || key == "Naver", rel.count > 1 { key = rel[0] + "/" + rel[1] }
                found[key, default: []].append(path)
                _ = fts_set(fts, e, FTS_SKIP)
            }
        }
        let keyed = Array(found).filter { !self.apps.resolve($0.key.components(separatedBy: "/")[0]).isOrphan }
        let items: [CleanupItem] = parallelMap(keyed) { (key, paths) -> CleanupItem? in
            let info = DirSize.measure(paths)
            guard info.bytes > 5_000_000 else { return nil }
            let display: String
            switch key {
            case "Google/Chrome": display = "Google Chrome"
            case "Microsoft/Edge", "Microsoft Edge": display = "Microsoft Edge"
            case "BraveSoftware/Brave-Browser": display = "Brave"
            case "Naver/Whale": display = "네이버 웨일"
            default: display = self.apps.displayName(for: key.components(separatedBy: "/")[0])
            }
            let match = self.apps.resolve(key.components(separatedBy: "/")[0])
            return CleanupItem(id: "web-" + key, title: "\(display) 웹 캐시", subtitle: "캐시 폴더 \(paths.count)개 · " + Paths.abbreviate(base + "/" + key),
                               detail: "Chrome 엔진(Chromium/Electron) 기반 앱이 만든 캐시입니다: 페이지 캐시, 코드 캐시, GPU 셰이더 캐시, 오프라인 저장소. 로그인·설정·기록은 지워지지 않습니다. 앱을 종료한 뒤 지우는 것이 좋습니다.",
                               safety: .safe, kind: .cache, size: info.bytes, method: .deleteContents(paths), permanent: true,
                               defaultSelected: true, lastModified: info.newestDate, appBundleID: match.app?.bundleID, revealPath: base + "/" + key)
        }.compactMap { $0 }
        guard !items.isEmpty else { return nil }
        return CleanupGroup(id: "web", title: "브라우저·웹 기반 앱 캐시", symbol: "globe", summary: "Chrome, VS Code, Slack, Discord 등의 캐시", items: items)
    }

    // MARK: 로그

    func logsGroup() -> CleanupGroup? {
        var items: [CleanupItem] = []
        let logs = p("~/Library/Logs")
        let info = DirSize.measure(logs)
        if info.bytes > 1_000_000 {
            items.append(CleanupItem(id: "logs-user", title: "앱 로그·진단 보고서", subtitle: "~/Library/Logs",
                                     detail: "앱이 남긴 동작 기록과 충돌 보고서입니다. 문제 해결용이며 지워도 됩니다.",
                                     safety: .safe, kind: .logs, size: info.bytes, method: .deleteContents([logs]),
                                     permanent: true, defaultSelected: true, lastModified: info.newestDate, revealPath: logs))
        }
        let crash = p("~/Library/Application Support/CrashReporter")
        let ci = DirSize.measure(crash)
        if ci.bytes > 1_000_000 {
            items.append(CleanupItem(id: "logs-crash", title: "충돌 보고 기록", subtitle: Paths.abbreviate(crash),
                                     detail: "앱 충돌 기록입니다.", safety: .safe, kind: .logs, size: ci.bytes,
                                     method: .deleteContents([crash]), permanent: true, defaultSelected: true, revealPath: crash))
        }
        let mailDl = p("~/Library/Containers/com.apple.mail/Data/Library/Mail Downloads")
        let mi = DirSize.measure(mailDl)
        if mi.bytes > 1_000_000 {
            items.append(CleanupItem(id: "mail-dl", title: "메일 첨부파일 임시 사본", subtitle: Paths.abbreviate(mailDl),
                                     detail: "Mail에서 첨부파일을 열 때 만든 사본입니다. 원본은 메일에 그대로 있습니다.",
                                     safety: .safe, kind: .cache, size: mi.bytes, method: .deleteContents([mailDl]),
                                     permanent: true, defaultSelected: true, revealPath: mailDl))
        }
        guard !items.isEmpty else { return nil }
        return CleanupGroup(id: "logs", title: "로그·임시 파일", symbol: "doc.text.magnifyingglass", summary: "문제 해결용 기록", items: items)
    }

    // MARK: 프로젝트 빌드 산출물

    struct ArtifactSpec {
        let names: Set<String>
        let manifests: [String]
        let childMarker: String?
        let label: String
        let safety: Safety
        let howTo: String
    }

    static let artifactSpecs: [ArtifactSpec] = [
        ArtifactSpec(names: ["node_modules"], manifests: ["package.json"], childMarker: nil, label: "Node.js 의존성", safety: .safe,
                     howTo: "프로젝트 폴더에서 npm install (또는 yarn / pnpm install)"),
        ArtifactSpec(names: [".next", ".nuxt", ".turbo", ".svelte-kit", ".parcel-cache", ".angular", ".expo"], manifests: ["package.json"], childMarker: nil,
                     label: "웹 빌드 캐시", safety: .safe, howTo: "개발 서버를 실행하거나 다시 빌드"),
        ArtifactSpec(names: ["target"], manifests: ["Cargo.toml"], childMarker: nil, label: "Rust 빌드 결과", safety: .safe, howTo: "cargo build"),
        ArtifactSpec(names: [".build"], manifests: ["Package.swift"], childMarker: nil, label: "Swift 빌드 결과", safety: .safe, howTo: "swift build"),
        ArtifactSpec(names: ["build"], manifests: ["build.gradle", "build.gradle.kts", "pubspec.yaml"], childMarker: nil, label: "빌드 결과", safety: .safe, howTo: "다시 빌드"),
        ArtifactSpec(names: [".gradle"], manifests: ["settings.gradle", "settings.gradle.kts", "build.gradle", "build.gradle.kts", "gradlew"], childMarker: nil,
                     label: "Gradle 프로젝트 캐시", safety: .safe, howTo: "다시 빌드"),
        ArtifactSpec(names: [".dart_tool"], manifests: ["pubspec.yaml"], childMarker: nil, label: "Dart 도구 캐시", safety: .safe, howTo: "flutter pub get"),
        ArtifactSpec(names: ["Pods"], manifests: ["Podfile"], childMarker: nil, label: "CocoaPods 의존성", safety: .safe, howTo: "pod install"),
        ArtifactSpec(names: [".venv", "venv"], manifests: [], childMarker: "pyvenv.cfg", label: "파이썬 가상환경", safety: .review,
                     howTo: "python -m venv .venv 후 pip install -r requirements.txt"),
    ]

    func projectGroup() -> CleanupGroup? {
        let skipTop: Set<String> = ["Library", "Pictures", "Music", "Movies", ".Trash", "Applications", "Public", ".npm", ".cache",
                                    ".gradle", ".m2", ".cargo", ".rustup", ".nvm", ".pyenv", ".android", ".vscode", ".cursor",
                                    ".docker", ".orbstack", ".pub-cache", ".dartServer", ".espressif", ".conda", ".local",
                                    "anaconda3", "miniconda3", "miniforge3", "flutter", "go", ".codex", ".claude", ".yarn", ".bun"]
        var found: [(path: String, spec: ArtifactSpec, project: String)] = []
        guard let c = strdup(home) else { return nil }
        defer { free(c) }
        var argv: [UnsafeMutablePointer<CChar>?] = [c, nil]
        guard let fts = fts_open(&argv, FTS_PHYSICAL | FTS_NOCHDIR | FTS_XDEV, nil) else { return nil }
        defer { fts_close(fts) }
        let allNames = Set(Self.artifactSpecs.flatMap(\.names))
        while let e = fts_read(fts) {
            let ent = e.pointee
            guard Int32(ent.fts_info) == FTS_D else { continue }
            let level = Int(ent.fts_level)
            if level == 0 { continue }
            let path = String(cString: ent.fts_path)
            let name = Paths.name(path)
            if level == 1 && (skipTop.contains(name) || (name.hasPrefix(".") && name != ".config")) { _ = fts_set(fts, e, FTS_SKIP); continue }
            if level > 8 || name == ".git" || name.hasSuffix(".app") || name.hasSuffix(".photoslibrary") || name.hasSuffix(".xcarchive") {
                _ = fts_set(fts, e, FTS_SKIP); continue
            }
            if let st = ent.fts_statp?.pointee, (st.st_flags & 0x4000_0000) != 0 { _ = fts_set(fts, e, FTS_SKIP); continue }
            guard allNames.contains(name) else { continue }
            let parent = Paths.parent(path)
            for spec in Self.artifactSpecs where spec.names.contains(name) {
                let ok: Bool
                if let marker = spec.childMarker { ok = Paths.exists(path + "/" + marker) }
                else { ok = spec.manifests.contains { Paths.exists(parent + "/" + $0) } }
                if ok {
                    found.append((path, spec, parent))
                    _ = fts_set(fts, e, FTS_SKIP)
                    break
                }
            }
        }
        let items: [CleanupItem] = parallelMap(found) { f -> CleanupItem? in
            let info = DirSize.measure(f.path)
            guard info.bytes > 20_000_000 else { return nil }
            // 프로젝트 최근 작업일: 매니페스트·프로젝트 폴더 수정일 중 최신
            let candidates = [f.project] + f.spec.manifests.map { f.project + "/" + $0 } + [f.project + "/.git/index", f.project + "/.git/HEAD"]
            let touched = candidates.compactMap { Paths.modificationDate($0) }.max()
            let days = Fmt.days(since: touched) ?? 0
            let projectName = Paths.name(f.project)
            return CleanupItem(
                id: "proj-" + f.path, title: "\(projectName) · \(Paths.name(f.path))",
                subtitle: "\(f.spec.label) · 프로젝트 마지막 작업 \(Fmt.ago(touched))",
                detail: "'\(Paths.abbreviate(f.project))' 프로젝트의 \(f.spec.label)입니다. 지워도 '\(f.spec.howTo)'로 다시 만들 수 있습니다."
                    + (days > 90 ? " 이 프로젝트는 \(days)일 동안 작업하지 않아 지우기 좋은 대상입니다." : " 최근 작업한 프로젝트이므로 지우면 다음 실행 전에 다시 설치해야 합니다."),
                safety: f.spec.safety, kind: .buildArtifact, size: info.bytes, method: .deleteItems([f.path]),
                permanent: true, defaultSelected: f.spec.safety == .safe && days > 90, lastModified: touched, revealPath: f.path)
        }.compactMap { $0 }
        guard !items.isEmpty else { return nil }
        return CleanupGroup(id: "projects", title: "프로젝트 빌드 산출물", symbol: "shippingbox",
                            summary: "node_modules 등 다시 설치할 수 있는 폴더 (오래된 프로젝트만 기본 선택)", items: items)
    }

    // MARK: 다운로드

    func downloadsGroup() -> CleanupGroup? {
        let dir = p("~/Downloads")
        let url = URL(fileURLWithPath: dir)
        let keys: [URLResourceKey] = [.isDirectoryKey, .addedToDirectoryDateKey, .contentModificationDateKey, .isPackageKey]
        guard let entries = try? fm.contentsOfDirectory(at: url, includingPropertiesForKeys: keys, options: [.skipsHiddenFiles]) else { return nil }
        let installers: Set<String> = ["dmg", "pkg", "mpkg", "iso", "xip", "ipsw"]
        let archives: Set<String> = ["zip", "rar", "7z", "tar", "gz", "tgz", "bz2", "xz"]
        let items: [CleanupItem] = parallelMap(entries) { u -> CleanupItem? in
            let v = try? u.resourceValues(forKeys: Set(keys))
            let added = v?.addedToDirectoryDate ?? v?.contentModificationDate
            let days = Fmt.days(since: added) ?? 0
            let ext = u.pathExtension.lowercased()
            let size = DirSize.measure(u.path).bytes
            var on = false
            var safety: Safety = .review
            var reason: String
            if installers.contains(ext) {
                reason = ext == "ipsw" ? "기기 펌웨어 파일" : "설치 파일"
                on = days >= 7
                if ext == "ipsw" { safety = .safe }
            } else if archives.contains(ext) {
                guard days >= 30 else { return nil }
                reason = "압축 파일"
            } else if ext == "app" {
                guard days >= 3 else { return nil }
                reason = "앱 사본"
            } else {
                guard days >= 180, size >= 50_000_000 else { return nil }
                reason = (v?.isDirectory ?? false) && !(v?.isPackage ?? false) ? "오래된 폴더" : "오래된 큰 파일"
            }
            guard size > 0 else { return nil }
            let explain: String
            switch reason {
            case "설치 파일": explain = "앱 설치용 파일입니다. 이미 설치했다면 필요 없습니다."
            case "기기 펌웨어 파일": explain = "iPhone·iPad 업데이트·복원용 파일입니다. 업데이트가 끝났다면 필요 없습니다."
            case "앱 사본":
                let installed = Paths.exists("/Applications/" + u.lastPathComponent)
                explain = installed ? "같은 이름의 앱이 이미 /Applications에 설치되어 있습니다. 다운로드 폴더의 이 사본은 필요 없습니다."
                                    : "다운로드 폴더에 있는 앱입니다. 계속 쓸 앱이라면 /Applications로 옮기고, 아니면 지우세요."
                if installed { on = true }
            case "압축 파일": explain = "받은 지 \(days)일 지난 압축 파일입니다. 이미 풀어서 쓰고 있다면 원본은 지워도 됩니다."
            default: explain = "받은 지 \(days)일이 지난 큰 항목입니다. 필요한지 확인 후 지우세요."
            }
            return CleanupItem(id: "dl-" + u.path, title: u.lastPathComponent, subtitle: "\(reason) · \(Fmt.ago(added)) 받음",
                               detail: explain + " 휴지통으로 이동하므로 되살릴 수 있습니다.",
                               safety: safety, kind: installers.contains(ext) ? .installer : (archives.contains(ext) ? .archive : (ext == "app" ? .appBundle : .download)),
                               size: size, method: .deleteItems([u.path]), permanent: false, defaultSelected: on,
                               lastModified: added, revealPath: u.path)
        }.compactMap { $0 }
        guard !items.isEmpty else { return nil }
        return CleanupGroup(id: "downloads", title: "다운로드 폴더", symbol: "arrow.down.circle",
                            summary: "설치 파일, 오래된 압축 파일·큰 파일 (휴지통으로 이동)", items: items)
    }

    // MARK: 기기 백업

    func backupsGroup() -> CleanupGroup? {
        let dir = p("~/Library/Application Support/MobileSync/Backup")
        let backups = Paths.children(dir).filter { Paths.isDirectory($0) }
        guard !backups.isEmpty else { return nil }
        let items: [CleanupItem] = parallelMap(backups) { b in
            let plist = NSDictionary(contentsOfFile: b + "/Info.plist")
            let device = plist?["Device Name"] as? String ?? plist?["Display Name"] as? String ?? "알 수 없는 기기"
            let product = plist?["Product Type"] as? String ?? ""
            let date = plist?["Last Backup Date"] as? Date ?? Paths.modificationDate(b)
            let ios = plist?["Product Version"] as? String
            let size = DirSize.measure(b).bytes
            return CleanupItem(id: "backup-" + b, title: "\(device) 백업",
                               subtitle: [product, ios.map { "iOS \($0)" }, "마지막 백업 \(Fmt.ago(date))"].compactMap { $0 }.filter { !$0.isEmpty }.joined(separator: " · "),
                               detail: "Finder로 만든 기기 로컬 백업입니다. 기기를 잃어버리거나 초기화했을 때 복원에 필요합니다. 더 이상 쓰지 않는 기기이거나 iCloud 백업을 쓴다면 지워도 됩니다. 휴지통으로 이동합니다.",
                               safety: .caution, kind: .backup, size: size, method: .deleteItems([b]), permanent: false,
                               defaultSelected: false, lastModified: date, revealPath: b)
        }
        return CleanupGroup(id: "backups", title: "iPhone·iPad 백업", symbol: "iphone", summary: "기기 로컬 백업 (직접 판단 필요)", items: items)
    }

    // MARK: 삭제된 앱의 잔여 파일

    func leftoversGroup() -> CleanupGroup? {
        let locations: [(String, String)] = [
            ("~/Library/Application Support", "앱 데이터"), ("~/Library/Containers", "샌드박스 데이터"),
            ("~/Library/Group Containers", "앱 그룹 데이터"), ("~/Library/Caches", "캐시"),
            ("~/Library/Preferences", "설정 파일"), ("~/Library/Saved Application State", "창 상태"),
            ("~/Library/HTTPStorages", "웹 저장소"), ("~/Library/WebKit", "웹뷰 데이터"),
            ("~/Library/Application Scripts", "스크립트"), ("~/Library/LaunchAgents", "자동 실행 항목"),
        ]
        var byID: [String: [(path: String, label: String)]] = [:]
        for (dir, label) in locations {
            for path in Paths.children(p(dir)) {
                let name = Paths.name(path)
                if case .notInstalled(let id) = apps.resolve(name) {
                    byID[id.lowercased(), default: []].append((path, label))
                }
            }
        }
        let entries = Array(byID)
        var smallPaths: [String] = []
        var smallSize: Int64 = 0
        var items: [CleanupItem] = []
        let measured = parallelMap(entries) { (id, list) in (id, list, DirSize.measure(list.map(\.path))) }
        for (id, list, info) in measured {
            if info.bytes < 500_000 {
                smallPaths += list.map(\.path); smallSize += info.bytes
                continue
            }
            let original = AppRegistry.cleanIdentifier(Paths.name(list[0].path))
            let labels = Array(Set(list.map(\.label))).sorted().joined(separator: ", ")
            items.append(CleanupItem(
                id: "orphan-" + id, title: "\(AppRegistry.guessName(original)) 잔여 파일", subtitle: "\(original) · \(labels)",
                detail: "'\(original)' 앱을 이 Mac에서 찾지 못했습니다. 앱을 지운 뒤 남은 데이터일 가능성이 높습니다. 다시 설치할 앱이라면 남겨 두세요 (재설치하면 이전 설정·데이터가 그대로 이어집니다). 휴지통으로 이동합니다.\n\n위치:\n" + list.map { "• " + Paths.abbreviate($0.path) }.joined(separator: "\n"),
                safety: .review, kind: .appData, size: info.bytes, method: .deleteItems(list.map(\.path)), permanent: false,
                defaultSelected: false, lastModified: info.newestDate, revealPath: list[0].path))
        }
        if !smallPaths.isEmpty && smallSize > 0 {
            items.append(CleanupItem(id: "orphan-small", title: "작은 잔여 파일 \(smallPaths.count)개", subtitle: "설정 파일 등 500KB 미만",
                                     detail: "삭제된 앱이 남긴 작은 설정·상태 파일입니다. 공간 확보 효과는 작습니다. 휴지통으로 이동합니다.\n\n" + smallPaths.prefix(40).map { "• " + Paths.abbreviate($0) }.joined(separator: "\n"),
                                     safety: .review, kind: .appSettings, size: smallSize, method: .deleteItems(smallPaths), permanent: false, defaultSelected: false))
        }
        guard !items.isEmpty else { return nil }
        return CleanupGroup(id: "leftovers", title: "삭제된 앱의 잔여 파일", symbol: "puzzlepiece.extension",
                            summary: "설치된 앱이 없는데 남아 있는 데이터 (확인 후 선택)", items: items)
    }

    // MARK: 직접 정리해야 하는 큰 데이터 (안내)

    struct Guide {
        let id: String
        let title: String
        let paths: [String]
        let kind: ItemKind
        let detail: String
        let guidance: String
    }

    func appDataGuideGroup() -> CleanupGroup? {
        var guides: [Guide] = [
            Guide(id: "kakao", title: "카카오톡", paths: ["~/Library/Containers/com.kakao.KakaoTalkMac"], kind: .messenger,
                  detail: "대화 기록과 주고받은 사진·동영상·파일 캐시입니다. 폴더를 직접 지우면 대화가 사라질 수 있습니다.",
                  guidance: "카카오톡 > 설정 > 채팅에서 캐시 데이터 삭제 등 저장공간 관리 메뉴를 사용하세요."),
            Guide(id: "telegram", title: "텔레그램", paths: ["~/Library/Group Containers/6N38VWS5BX.ru.keepcoder.Telegram", "~/Library/Application Support/Telegram Desktop"],
                  kind: .messenger, detail: "대화와 미디어 캐시입니다.", guidance: "설정 > 데이터 및 저장소 > 저장 공간 사용량에서 캐시를 지우세요."),
            Guide(id: "line", title: "LINE", paths: ["~/Library/Containers/jp.naver.line.mac"], kind: .messenger,
                  detail: "대화와 미디어 캐시입니다.", guidance: "LINE > 설정 > 대화에서 데이터·캐시를 삭제하세요."),
            Guide(id: "whatsapp", title: "WhatsApp", paths: ["~/Library/Group Containers/group.net.whatsapp.WhatsApp.shared", "~/Library/Containers/net.whatsapp.WhatsApp"],
                  kind: .messenger, detail: "대화와 미디어입니다.", guidance: "WhatsApp > 설정 > 저장 공간 및 데이터에서 관리하세요."),
            Guide(id: "teams", title: "Microsoft Teams", paths: ["~/Library/Containers/com.microsoft.teams2"], kind: .messenger,
                  detail: "Teams 데이터와 캐시입니다.", guidance: "Teams를 종료한 뒤 Teams 설정의 캐시 지우기 기능을 사용하세요."),
            Guide(id: "messages", title: "iMessage 첨부파일", paths: ["~/Library/Messages"], kind: .messenger,
                  detail: "메시지로 주고받은 사진·동영상입니다. 직접 지우면 대화에서 깨진 첨부로 보입니다.",
                  guidance: "시스템 설정 > 일반 > 저장 공간 > 메시지에서 큰 첨부를 지우거나, 메시지 > 설정에서 '메시지 보관'을 1년으로 바꾸세요."),
            Guide(id: "mail", title: "Mail 보관함", paths: ["~/Library/Mail"], kind: .mail,
                  detail: "메일과 첨부파일입니다. 직접 지우면 메일이 손상됩니다.",
                  guidance: "Mail에서 큰 첨부가 있는 메일을 지우세요. 받은 편지함을 크기순으로 정렬하면 찾기 쉽습니다."),
            Guide(id: "claude-vm", title: "Claude 앱 가상머신 이미지", paths: ["~/Library/Application Support/Claude/vm_bundles"], kind: .virtualMachine,
                  detail: "Claude 데스크톱 앱이 코드 실행·에이전트 기능에 쓰는 가상머신 이미지입니다.",
                  guidance: "해당 기능을 쓰지 않는다면 Claude 앱을 종료한 뒤 이 폴더를 지울 수 있습니다. 기능을 다시 쓰면 다시 받습니다."),
            Guide(id: "fusion", title: "Autodesk Fusion", paths: ["~/Library/Application Support/Autodesk/webdeploy"], kind: .appBundle,
                  detail: "Fusion 프로그램 본체입니다 (/Applications가 아니라 이곳에 설치됨).", guidance: "Fusion을 쓰지 않는다면 Autodesk 제거 도구로 삭제하세요."),
            Guide(id: "android-avd", title: "Android 에뮬레이터 기기", paths: ["~/.android/avd"], kind: .virtualMachine,
                  detail: "Android 에뮬레이터 가상 기기입니다.", guidance: "Android Studio > Device Manager에서 안 쓰는 기기를 삭제하세요."),
            Guide(id: "android-sdk", title: "Android SDK", paths: ["~/Library/Android/sdk"], kind: .developer,
                  detail: "Android 플랫폼·시스템 이미지·빌드 도구입니다.", guidance: "Android Studio > Settings > SDK Manager에서 안 쓰는 플랫폼과 시스템 이미지를 체크 해제하세요."),
            Guide(id: "arduino", title: "Arduino 보드 패키지", paths: ["~/Library/Arduino15/packages"], kind: .developer,
                  detail: "설치된 보드 코어와 컴파일러 툴체인입니다.", guidance: "Arduino IDE > 보드 매니저에서 안 쓰는 보드를 제거하세요."),
            Guide(id: "espressif", title: "ESP-IDF 툴체인", paths: ["~/.espressif/tools"], kind: .developer,
                  detail: "ESP32 개발용 컴파일러입니다. 여러 버전이 쌓이기도 합니다.", guidance: "ESP32 개발을 하지 않으면 ~/.espressif 폴더를 통째로 지워도 됩니다."),
            Guide(id: "vscode-ext", title: "에디터 확장 프로그램", paths: ["~/.vscode/extensions", "~/.cursor/extensions"], kind: .developer,
                  detail: "VS Code·Cursor 확장입니다. 업데이트 후 이전 버전이 남아 쌓이기도 합니다.", guidance: "에디터의 확장 탭에서 안 쓰는 확장을 제거하세요."),
            Guide(id: "conda-dist", title: "Anaconda/Miniconda", paths: ["~/anaconda3", "~/miniconda3", "~/miniforge3", "~/opt/anaconda3"], kind: .developer,
                  detail: "Python 배포판과 가상환경입니다.", guidance: "'conda env list'로 환경을 확인하고 'conda env remove -n <이름>'으로 안 쓰는 환경을 지우세요. Anaconda를 안 쓰면 폴더째 지워도 됩니다."),
            Guide(id: "ollama", title: "Ollama AI 모델", paths: ["~/.ollama/models"], kind: .aiModel,
                  detail: "로컬 AI 모델입니다.", guidance: "'ollama list'로 확인 후 'ollama rm <모델명>'으로 삭제하세요."),
            Guide(id: "steam", title: "Steam 게임", paths: ["~/Library/Application Support/Steam/steamapps"], kind: .appData,
                  detail: "설치한 게임 파일입니다.", guidance: "Steam 라이브러리에서 게임 우클릭 > 관리 > 제거."),
            Guide(id: "icloud", title: "iCloud Drive (로컬 사본)", paths: ["~/Library/Mobile Documents"], kind: .cloud,
                  detail: "iCloud Drive 파일의 로컬 사본입니다. 여기서 지우면 모든 기기에서 지워집니다.",
                  guidance: "Finder에서 큰 파일을 우클릭 > '다운로드 항목 제거'를 고르면 iCloud에는 남기고 Mac 공간만 확보합니다. 시스템 설정 > Apple 계정 > iCloud > 'Mac 저장 공간 최적화'도 켜 두세요."),
            Guide(id: "sim-runtimes", title: "시뮬레이터 런타임 (iOS 등)", paths: ["/Library/Developer/CoreSimulator/Images", "/Library/Developer/CoreSimulator/Volumes"], kind: .developer,
                  detail: "시뮬레이터용 OS 이미지입니다. 버전마다 수 GB입니다.",
                  guidance: "Xcode > Settings > Components에서 안 쓰는 플랫폼·런타임을 삭제하세요."),
            Guide(id: "aerial", title: "에어리얼 배경화면·화면보호기", paths: ["/Library/Application Support/com.apple.idleassetsd/Customer"], kind: .media,
                  detail: "움직이는 배경화면 동영상입니다.", guidance: "시스템 설정 > 배경화면에서 받은 에어리얼 항목을 우클릭해 삭제하세요."),
            Guide(id: "garageband", title: "GarageBand·Logic 사운드", paths: ["/Library/Application Support/GarageBand", "/Library/Application Support/Logic", "/Library/Audio/Apple Loops"],
                  kind: .media, detail: "악기·루프 사운드 라이브러리입니다.", guidance: "음악 작업을 하지 않으면 GarageBand를 지우고 이 폴더들도 지울 수 있습니다 (관리자 권한 필요)."),
        ]
        // 사진 보관함
        for pic in Paths.children(p("~/Pictures")) where pic.hasSuffix(".photoslibrary") {
            guides.append(Guide(id: "photos-" + pic, title: "사진 보관함 (\(Paths.name(pic)))", paths: [pic], kind: .media,
                                detail: "사진 앱 라이브러리입니다. Finder에서 직접 건드리면 손상됩니다.",
                                guidance: "사진 앱에서 필요 없는 사진·동영상을 지우고 '최근 삭제된 항목'도 비우세요. iCloud 사진을 쓴다면 사진 > 설정 > iCloud > 'Mac 저장 공간 최적화'를 켜세요."))
        }
        let items: [CleanupItem] = parallelMap(guides) { g -> CleanupItem? in
            let paths = g.paths.map(self.p).filter { Paths.exists($0) }
            guard !paths.isEmpty else { return nil }
            let info = DirSize.measure(paths)
            guard info.bytes >= 300_000_000 else { return nil }
            return CleanupItem(id: "guide-" + g.id, title: g.title, subtitle: paths.map(Paths.abbreviate).joined(separator: ", "),
                               detail: g.detail, safety: .keep, kind: g.kind, size: info.bytes, method: .manual, permanent: false,
                               defaultSelected: false, lastModified: info.newestDate, revealPath: paths.first, guidance: g.guidance)
        }.compactMap { $0 }
        guard !items.isEmpty else { return nil }
        return CleanupGroup(id: "guides", title: "앱에서 직접 정리할 큰 데이터", symbol: "hand.point.up.left",
                            summary: "직접 지우면 위험하지만 해당 앱에서 줄일 수 있는 항목", items: items)
    }

    // MARK: 시스템

    func systemGroup() -> CleanupGroup? {
        var items: [CleanupItem] = []
        let r = Shell.run("tmutil listlocalsnapshots /", timeout: 15)
        let snaps = r.output.split(separator: "\n").filter { $0.contains("com.apple.TimeMachine") }
        if !snaps.isEmpty {
            items.append(CleanupItem(
                id: "tm-snapshots", title: "Time Machine 로컬 스냅샷 \(snaps.count)개", subtitle: "관리자 암호 필요",
                detail: "Time Machine이 백업 디스크가 연결되지 않았을 때 만들어 두는 스냅샷입니다. macOS는 공간이 부족해지면 이것부터 자동으로 지우므로 보통은 그대로 둬도 됩니다. 큰 파일을 지웠는데 여유 공간이 늘지 않는다면 이 스냅샷이 원인일 수 있습니다.",
                safety: .review, kind: .backup, size: -1,
                method: .command("tmutil thinlocalsnapshots / 999999999999 4", admin: true),
                permanent: true, defaultSelected: false))
        }
        guard !items.isEmpty else { return nil }
        return CleanupGroup(id: "system", title: "시스템", symbol: "gearshape.2", summary: "macOS가 관리하는 항목", items: items)
    }

    // MARK: 실행

    public static func execute(_ items: [CleanupItem], forceTrash: Bool, progress: @escaping (String) -> Void) -> DeletionReport {
        var report = DeletionReport()
        for item in items {
            progress("\(item.title) 정리 중…")
            let permanent = item.permanent && !forceTrash
            switch item.method {
            case .deleteContents(let dirs):
                for d in dirs { report.merge(Deleter.removeContents(of: d, permanent: permanent)) }
            case .deleteItems(let paths):
                for p in paths { report.merge(Deleter.remove(p, permanent: permanent)) }
            case .emptyTrash:
                let trash = Paths.expand("~/.Trash")
                if (try? FileManager.default.contentsOfDirectory(atPath: trash)) != nil {
                    var r = Deleter.removeContents(of: trash, permanent: true)
                    if !r.failures.isEmpty {
                        let (ok, _) = Deleter.emptyTrashWithFinder()
                        if ok { r.failures.removeAll(); r.freedBytes = max(r.freedBytes, item.size) }
                    }
                    report.merge(r)
                } else {
                    let (ok, out) = Deleter.emptyTrashWithFinder()
                    if ok { report.removedCount += 1; report.freedBytes += max(0, item.size) }
                    else { report.failures.append(DeletionFailure(path: trash, reason: "Finder로 휴지통을 비우지 못했습니다: \(out)")) }
                }
            case .command(let cmd, let admin):
                let r = admin ? Shell.runAdmin(cmd) : Shell.run(cmd)
                let out = r.output.trimmingCharacters(in: .whitespacesAndNewlines)
                if r.status == 0 {
                    report.removedCount += 1
                    report.freedBytes += max(0, item.size)
                    report.commandOutputs.append("✓ \(cmd)" + (out.isEmpty ? "" : "\n" + String(out.suffix(600))))
                } else {
                    report.failures.append(DeletionFailure(path: cmd, reason: out.isEmpty ? "명령 실패 (코드 \(r.status))" : String(out.suffix(300))))
                }
            case .manual:
                break
            }
        }
        // 지우지 못한 크기만큼 빼기 위해 실패 항목을 측정하지는 않는다(대부분 작음). 대신 실패 목록을 보여준다.
        return report
    }
}
