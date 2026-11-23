import AppKit
import MacCleanCore
import SwiftUI

// MARK: - 버전·링크

enum AppVersion {
    static var version: String {
        // 검증용: --pretend-version 1.0.0 으로 실행하면 그 버전인 척 (업데이트 알림 확인)
        let a = CommandLine.arguments
        if let i = a.firstIndex(of: "--pretend-version"), i + 1 < a.count { return a[i + 1] }
        return Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "0.0.0-dev"
    }
    static var build: String { Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "-" }
    static let repoURL = URL(string: "https://github.com/junseok-seo/macclean")!
    static let releasesURL = URL(string: "https://github.com/junseok-seo/macclean/releases")!
    static let issuesURL = URL(string: "https://github.com/junseok-seo/macclean/issues/new")!
    static let latestAPI = URL(string: "https://api.github.com/repos/junseok-seo/macclean/releases/latest")!

    /// "빌드 2026.11.23 21:50" 형태 (build.sh가 yyyyMMddHHmm으로 넣음)
    static var buildLabel: String {
        let b = build
        guard b.count == 12, Int(b) != nil else { return b }
        let c = Array(b)
        return "\(String(c[0..<4])).\(String(c[4..<6])).\(String(c[6..<8])) \(String(c[8..<10])):\(String(c[10..<12]))"
    }

    static var systemSummary: String {
        var size = 0
        sysctlbyname("machdep.cpu.brand_string", nil, &size, nil, 0)
        var buf = [CChar](repeating: 0, count: max(size, 1))
        sysctlbyname("machdep.cpu.brand_string", &buf, &size, nil, 0)
        let chip = String(cString: buf)
        let os = ProcessInfo.processInfo.operatingSystemVersion
        let mem = Fmt.memory(ProcessInfo.processInfo.physicalMemory)
        return "macOS \(os.majorVersion).\(os.minorVersion).\(os.patchVersion) · \(chip.isEmpty ? "Mac" : chip) · 메모리 \(mem)"
    }

    /// 문제 신고에 붙여 넣을 정보 (개인 정보 없음)
    static var reportText: String {
        "MacClean \(version) (빌드 \(build))\n\(systemSummary)\n전체 디스크 접근 권한: \(Permissions.hasFullDiskAccess() ? "켜짐" : "꺼짐")"
    }

    /// "v1.2.0" > "1.1.0" 인지
    static func isNewer(_ tag: String, than current: String) -> Bool {
        func parts(_ s: String) -> [Int] {
            s.trimmingCharacters(in: CharacterSet(charactersIn: "vV ")).split(separator: ".").map { Int($0.prefix { $0.isNumber }) ?? 0 }
        }
        let a = parts(tag), b = parts(current)
        for i in 0..<max(a.count, b.count) {
            let x = i < a.count ? a[i] : 0, y = i < b.count ? b[i] : 0
            if x != y { return x > y }
        }
        return false
    }

}

// MARK: - 버전 정보 창

struct AboutView: View {
    @EnvironmentObject var updates: UpdateChecker
    @State private var copied = false

    var body: some View {
        VStack(spacing: 14) {
            Image(nsImage: NSApp.applicationIconImage)
                .resizable()
                .frame(width: 96, height: 96)
            VStack(spacing: 4) {
                Text("MacClean").font(.title.weight(.bold))
                Text("버전 \(AppVersion.version)").font(.title3).foregroundStyle(.secondary)
                Text("빌드 \(AppVersion.buildLabel)").font(.caption).foregroundStyle(.tertiary)
            }
            .textSelection(.enabled)
            Text("맥 저장공간과 메모리를 '어디에 뭐가 있고, 지워도 되는지'\n판정해서 보여 주는 도구")
                .font(.callout)
                .multilineTextAlignment(.center)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            UpdateStatusRow()
                .frame(minHeight: 30)

            Divider()

            Grid(alignment: .leading, horizontalSpacing: 12, verticalSpacing: 6) {
                GridRow {
                    Text("시스템").foregroundStyle(.secondary)
                    Text(AppVersion.systemSummary).textSelection(.enabled)
                }
                GridRow {
                    Text("라이선스").foregroundStyle(.secondary)
                    Text("MIT (오픈 소스)")
                }
                GridRow {
                    Text("개인정보").foregroundStyle(.secondary)
                    Text("모든 분석은 이 Mac 안에서만 합니다. 파일 내용은 읽지 않습니다. 업데이트 확인 때만 GitHub에서 최신 릴리스 정보를 받아 오며, 이 Mac의 정보는 보내지 않습니다.")
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .font(.callout)
            .frame(maxWidth: .infinity, alignment: .leading)

            HStack(spacing: 10) {
                Button { NSWorkspace.shared.open(AppVersion.repoURL) } label: { Label("GitHub", systemImage: "chevron.left.forwardslash.chevron.right") }
                Button { NSWorkspace.shared.open(AppVersion.releasesURL) } label: { Label("릴리스 노트", systemImage: "list.bullet.rectangle") }
                Button {
                    Finder.copy(AppVersion.reportText)
                    copied = true
                    DispatchQueue.main.asyncAfter(deadline: .now() + 2) { copied = false }
                } label: { Label(copied ? "복사됨" : "정보 복사", systemImage: copied ? "checkmark" : "doc.on.doc") }
                    .help("문제를 신고할 때 붙여 넣을 버전·시스템 정보를 복사합니다")
            }

            Text("© 2026 junseok-seo · MIT License").font(.caption).foregroundStyle(.tertiary)
        }
        .padding(24)
        .frame(width: 420)
    }

}

// MARK: - 메뉴 명령

/// 앱 메뉴의 "MacClean 정보"와 "업데이트 확인…"
struct AboutCommand: View {
    let store: AppStore
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        Button("MacClean 정보") {
            NSApp.activate()
            openWindow(id: "about")
        }
        Button("업데이트 확인…") { store.updates.check(showResult: true) }
    }
}

/// 상단 메뉴 막대의 '도움말' 메뉴
struct HelpCommands: View {
    let store: AppStore
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        Button("MacClean 도움말") { open(.start) }
            .keyboardShortcut("?", modifiers: .command)
        Divider()
        ForEach(HelpSection.allCases.filter { $0 != .start && $0 != .report }) { section in
            Button(section.title) { open(section) }
        }
        Divider()
        Button("업데이트 확인…") { store.updates.check(showResult: true) }
        Button("MacClean 정보") {
            NSApp.activate()
            openWindow(id: "about")
        }
        Button("GitHub 저장소 열기") { NSWorkspace.shared.open(AppVersion.repoURL) }
        Button("문제 신고하기…") {
            Finder.copy(AppVersion.reportText)
            NSWorkspace.shared.open(AppVersion.issuesURL)
        }
    }

    func open(_ section: HelpSection) {
        store.helpSection = section
        NSApp.activate()
        openWindow(id: "help")
    }
}

// MARK: - 도움말 창

enum HelpSection: String, CaseIterable, Identifiable {
    case start, badges, panes, menubar, deletion, faq, shortcuts, report
    var id: String { rawValue }
    var title: String {
        switch self {
        case .start: "처음 시작하기"
        case .badges: "판정 배지 읽는 법"
        case .panes: "화면별 안내"
        case .menubar: "메뉴 막대로 내려놓기"
        case .deletion: "지운 파일은 어디로 가나요"
        case .faq: "자주 묻는 질문"
        case .shortcuts: "단축키"
        case .report: "문제 신고"
        }
    }
    var symbol: String {
        switch self {
        case .start: "flag.checkered"
        case .badges: "checkmark.shield"
        case .panes: "rectangle.3.group"
        case .menubar: "menubar.arrow.up.rectangle"
        case .deletion: "trash"
        case .faq: "questionmark.bubble"
        case .shortcuts: "keyboard"
        case .report: "ladybug"
        }
    }
}

struct HelpView: View {
    @EnvironmentObject var store: AppStore
    @EnvironmentObject var permissions: PermissionModel
    @State private var openFAQ: Set<Int> = []

    var body: some View {
        ScrollViewReader { proxy in
            HStack(spacing: 0) {
                List(selection: Binding(get: { store.helpSection }, set: { store.helpSection = $0 })) {
                    ForEach(HelpSection.allCases) { s in
                        Label(s.title, systemImage: s.symbol).tag(s as HelpSection?)
                    }
                }
                .listStyle(.sidebar)
                .frame(width: 210)
                Divider()
                content
            }
            .onAppear { scroll(proxy, store.helpSection) }
            .onChange(of: store.helpSection) { _, s in scroll(proxy, s) }
        }
        .frame(minWidth: 820, minHeight: 600)
    }

    func scroll(_ proxy: ScrollViewProxy, _ s: HelpSection?) {
        guard let s else { return }
        if s == .faq { openFAQ = Set(Self.faq.indices) }
        DispatchQueue.main.async { withAnimation(.easeInOut(duration: 0.25)) { proxy.scrollTo(s, anchor: .top) } }
    }

    var content: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                HStack(alignment: .firstTextBaseline) {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("도움말").font(.largeTitle.weight(.bold))
                        Text("MacClean 버전 \(AppVersion.version) · 무엇을 지워도 되는지 판단을 돕는 도구입니다").foregroundStyle(.secondary)
                    }
                    Spacer()
                    Button { NSWorkspace.shared.open(AppVersion.repoURL) } label: { Label("GitHub", systemImage: "arrow.up.right.square") }
                }

                Group { Card(title: "처음 시작하기", symbol: "flag.checkered") {
                    VStack(alignment: .leading, spacing: 10) {
                        step(1, "전체 디스크 접근 권한 켜기",
                             "시스템 설정 > 개인정보 보호 및 보안 > 전체 디스크 접근 권한에서 MacClean을 켜고 앱을 다시 여세요. 휴지통·메일·다른 앱 데이터까지 정확히 셉니다.",
                             action: permissions.fullDiskAccess ? nil : ("설정 열기", { permissions.openSettings() }),
                             done: permissions.fullDiskAccess)
                        step(2, "개요에서 상태 보기", "디스크 여유, 메모리 압력, 정리할 수 있는 공간을 한눈에 봅니다.", action: ("개요 열기", { WindowManager.shared.showMain(); store.pane = .overview }))
                        step(3, "정리 추천에서 '안전' 항목 정리",
                             "기본으로 체크된 것은 모두 '안전'(다시 만들어지는 캐시·로그·빌드 산출물)입니다. 항목을 누르면 무엇인지 설명이 나옵니다.",
                             action: ("정리 추천 열기", { WindowManager.shared.showMain(); store.pane = .cleanup }))
                        step(4, "디스크 탐색으로 큰 폴더 살펴보기",
                             "홈 폴더를 스캔하고 큰 폴더를 따라 들어가세요. 오른쪽 패널이 무엇인지, 지워도 되는지 알려 줍니다.",
                             action: ("디스크 탐색 열기", { WindowManager.shared.showMain(); store.pane = .explorer }))
                    }
                } }
                .id(HelpSection.start)

                Group { Card(title: "판정 배지 읽는 법", symbol: "checkmark.shield") {
                    VStack(alignment: .leading, spacing: 10) {
                        ForEach(Safety.allCases, id: \.self) { s in
                            HStack(alignment: .top, spacing: 12) {
                                SafetyBadge(safety: s).frame(width: 110, alignment: .leading)
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(s.explanation).fixedSize(horizontal: false, vertical: true)
                                    Text(handling(s)).font(.caption).foregroundStyle(.secondary)
                                }
                            }
                            .font(.callout)
                        }
                        Text("'추정' 표시는 확인된 규칙이 없어 이름·확장자로 짐작한 것이고, '삭제된 앱'은 설치된 앱이 없는데 남아 있는 데이터입니다.")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                } }
                .id(HelpSection.badges)

                Group { Card(title: "화면별 안내", symbol: "rectangle.3.group") {
                    VStack(alignment: .leading, spacing: 10) {
                        paneRow(.overview, "디스크·메모리 상태와 정리 가능한 공간, 가장 큰 항목을 보여 줍니다.")
                        paneRow(.cleanup, "알려진 정리 대상을 그룹별로 찾아 줍니다. 그룹 체크박스는 '안전'·'확인'만 고르고, '주의' 항목은 하나씩 직접 골라야 합니다. ⌘R로 다시 검사합니다.")
                        paneRow(.explorer, "폴더별 용량을 따라 들어갑니다. 행을 더블클릭하면 폴더 안으로, 오른쪽 패널에서 비우기·휴지통·Finder 보기를 합니다.")
                        paneRow(.largeFiles, "큰 파일을 크기·마지막으로 연 날·종류로 거릅니다. '지워도 될 만한 것' 필터가 편리합니다.")
                        paneRow(.apps, "앱 크기와 앱이 남긴 데이터, 마지막 사용일을 봅니다. 앱을 지울 때 남은 데이터도 함께 휴지통으로 보낼 수 있습니다.")
                        paneRow(.memory, "메모리 압력과 앱별 사용량(헬퍼·가상머신 포함)을 보고, 많이 쓰는 앱을 종료합니다.")
                    }
                } }
                .id(HelpSection.panes)

                Group { Card(title: "메뉴 막대로 내려놓기", symbol: "menubar.arrow.up.rectangle") {
                    VStack(alignment: .leading, spacing: 6) {
                        bullet("창의 노란 버튼(또는 ⌥⌘M)을 누르면 창과 Dock 아이콘이 사라지고 메뉴 막대에 디스크·메모리·CPU·GPU 사용률이 표시됩니다.")
                        bullet("숫자를 더블클릭하면 창이 다시 열립니다. 한 번 클릭하면 요약, 우클릭하면 메뉴가 나옵니다.")
                        bullet("숫자가 앰버색으로 바뀌면 주의할 상태입니다: 디스크 90% 이상, 메모리 압력 경고 이상, CPU 85% 이상.")
                        bullet("메모리 %가 높아도 메모리 압력이 정상이면 괜찮습니다. macOS가 남는 메모리를 캐시로 쓰기 때문입니다.")
                    }
                } }
                .id(HelpSection.menubar)

                Group { Card(title: "지운 파일은 어디로 가나요", symbol: "trash") {
                    VStack(alignment: .leading, spacing: 6) {
                        bullet("'안전' 항목(캐시·로그·빌드 산출물)은 바로 삭제해서 즉시 공간이 생깁니다. 설정에서 휴지통으로 보내도록 바꿀 수 있습니다.")
                        bullet("그 밖의 항목(다운로드, 잔여 파일, 백업, 대용량 파일, 앱)은 휴지통으로 옮깁니다. 휴지통에서 되살릴 수 있고, 휴지통을 비워야 공간이 생깁니다.")
                        bullet("홈 폴더, ~/Library, 문서·다운로드 같은 기본 폴더 자체와 키체인·시스템 영역은 아예 지우지 못하게 막혀 있습니다.")
                    }
                } }
                .id(HelpSection.deletion)

                Group { Card(title: "자주 묻는 질문", symbol: "questionmark.bubble") {
                    VStack(alignment: .leading, spacing: 4) {
                        ForEach(Array(Self.faq.enumerated()), id: \.offset) { i, qa in
                            DisclosureGroup(isExpanded: Binding(get: { openFAQ.contains(i) },
                                                                set: { if $0 { openFAQ.insert(i) } else { openFAQ.remove(i) } })) {
                                Text(qa.1)
                                    .font(.callout).foregroundStyle(.secondary)
                                    .fixedSize(horizontal: false, vertical: true)
                                    .textSelection(.enabled)
                                    .padding(.vertical, 4)
                                    .frame(maxWidth: .infinity, alignment: .leading)
                            } label: {
                                Text(qa.0).font(.callout.weight(.medium))
                            }
                            if i < Self.faq.count - 1 { Divider() }
                        }
                    }
                } }
                .id(HelpSection.faq)

                Group { Card(title: "단축키", symbol: "keyboard") {
                    Grid(alignment: .leading, horizontalSpacing: 18, verticalSpacing: 6) {
                        shortcut("⌘R", "정리 추천 다시 검사")
                        shortcut("⇧⌘S", "홈 폴더 스캔")
                        shortcut("⌥⌘M", "메뉴 막대로 내려놓기")
                        shortcut("메뉴 막대 숫자 더블클릭", "창 다시 열기")
                        shortcut("⌘,", "설정")
                        shortcut("⌘?", "도움말")
                        shortcut("MacClean 메뉴 > 업데이트 확인…", "GitHub 최신 릴리스 확인")
                    }
                    .font(.callout)
                } }
                .id(HelpSection.shortcuts)

                Group { Card(title: "문제가 있나요?", symbol: "ladybug") {
                    HStack(alignment: .center) {
                        Text("GitHub에 알려 주세요. '문제 신고하기'를 누르면 버전·시스템 정보가 복사되니 내용에 붙여 넣으면 됩니다. (파일 목록 등 개인 정보는 포함되지 않습니다)")
                            .font(.callout).foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                        Spacer()
                        Button("문제 신고하기") {
                            Finder.copy(AppVersion.reportText)
                            NSWorkspace.shared.open(AppVersion.issuesURL)
                        }
                        .buttonStyle(.borderedProminent)
                    }
                } }
                .id(HelpSection.report)
            }
            .padding(24)
            .frame(maxWidth: 860, alignment: .leading)
        }
    }

    static let faq: [(String, String)] = [
        ("지웠는데 여유 공간이 늘지 않아요",
         "• 휴지통으로 옮긴 항목은 휴지통을 비워야 공간이 생깁니다.\n• Time Machine 로컬 스냅샷이 지운 파일을 붙잡고 있을 수 있습니다. 정리 추천 > 시스템에서 정리하거나 잠시 기다리면 macOS가 비웁니다.\n• Docker 디스크(Docker.raw)는 이미지를 지워도 몇 분 뒤에 줄어듭니다.\n• 개요의 '퍼지 가능' 공간은 필요할 때 macOS가 자동으로 비우는 공간입니다."),
        ("macOS 저장 공간 설정의 '시스템 데이터'가 너무 커요",
         "'시스템 데이터'에는 앱 캐시, 로그, 가상머신(Docker 등), 시뮬레이터, Time Machine 스냅샷처럼 다른 분류에 들지 않는 것이 모두 들어갑니다. 디스크 탐색에서 홈 폴더를 스캔한 뒤 ~/Library를 따라 들어가면 무엇이 큰지 볼 수 있습니다."),
        ("캐시를 지워도 문제가 없나요?",
         "앱이 필요할 때 다시 만듭니다. 다만 다음 실행이 처음 한 번 느릴 수 있고, 실행 중인 앱의 캐시는 일부가 지워지지 않을 수 있으니 가능하면 앱을 종료하고 정리하세요. 로그인 정보나 설정은 캐시에 들어 있지 않습니다."),
        ("'삭제된 앱의 잔여 파일'은 정말 지워도 되나요?",
         "설치된 앱을 찾지 못한 데이터입니다. 앱을 다시 설치할 계획이 없다면 지워도 됩니다. 다시 설치하면 이전 설정·데이터를 이어 쓸 수 있으니 그럴 계획이라면 남겨 두세요. 휴지통으로 옮기므로 되살릴 수 있습니다."),
        ("메모리 사용량이 80%가 넘어요",
         "메모리 압력이 '정상'(초록)이면 괜찮습니다. macOS는 남는 메모리를 파일 캐시로 써서 빠르게 하므로 사용량 숫자는 원래 높게 나옵니다. 압력이 '경고'나 '위험'이면 메모리 화면에서 많이 쓰는 앱을 종료하세요."),
        ("Docker 이미지를 지웠어요. 어떻게 되돌리나요?",
         "받은 이미지는 docker pull 또는 docker compose pull로, 직접 만든 이미지는 docker compose build로 다시 만들 수 있습니다. 볼륨(데이터베이스, 받은 모델 등)은 MacClean이 지우지 않으므로 그대로 남아 있습니다."),
        ("앱을 업데이트했더니 권한이 꺼진 것처럼 보여요",
         "공증하지 않은 앱이라 업데이트하면 macOS가 다른 앱으로 인식합니다. 시스템 설정 > 개인정보 보호 및 보안 > 전체 디스크 접근 권한에서 MacClean을 껐다 켜거나, 목록에서 빼고 다시 추가하세요."),
        ("처음 열 때 '확인되지 않은 개발자' 경고가 떠요",
         "시스템 설정 > 개인정보 보호 및 보안 아래쪽의 '그래도 열기'를 누르세요. 또는 터미널에서 xattr -dr com.apple.quarantine /Applications/MacClean.app 를 실행하세요."),
        ("업데이트는 어떻게 하나요?",
         "MacClean 메뉴 > 업데이트 확인…을 누르면 GitHub 저장소의 최신 릴리스와 비교합니다. 새 버전이 있으면 '다운로드'로 DMG를 받아 열고 Applications에 덮어쓰세요. 하루 한 번 자동으로도 확인하며(설정에서 끌 수 있음), 새 버전이 있으면 개요 화면과 메뉴 막대 요약에 표시됩니다."),
        ("인터넷으로 정보를 보내나요?",
         "아니요. 모든 분석은 이 Mac 안에서 하고, 파일 내용은 읽지 않고 크기와 날짜만 봅니다. 업데이트 확인 때만 GitHub의 공개 릴리스 정보를 받아 오며, 이 Mac의 정보는 보내지 않습니다."),
    ]

    func handling(_ s: Safety) -> String {
        switch s {
        case .safe: "기본으로 선택되고, 정리하면 바로 삭제됩니다."
        case .review: "내용을 보고 고르세요. 정리하면 휴지통으로 갑니다."
        case .caution: "하나씩 직접 골라야 합니다. 정리하면 휴지통으로 갑니다."
        case .keep: "지우기 버튼이 없습니다. 안내된 앱·설정에서 정리하세요."
        }
    }

    func step(_ n: Int, _ title: String, _ text: String, action: (String, () -> Void)? = nil, done: Bool = false) -> some View {
        HStack(alignment: .top, spacing: 12) {
            ZStack {
                Circle().fill(done ? Palette.sage : Palette.blue.opacity(0.9)).frame(width: 24, height: 24)
                if done { Image(systemName: "checkmark").font(.caption.weight(.bold)).foregroundStyle(.white) }
                else { Text("\(n)").font(.callout.weight(.bold)).foregroundStyle(.white) }
            }
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.callout.weight(.semibold))
                Text(text).font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
            Spacer()
            if let action { Button(action.0, action: action.1) }
        }
    }

    func paneRow(_ p: Pane, _ text: String) -> some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: p.symbol).frame(width: 22).foregroundStyle(Palette.blue)
            VStack(alignment: .leading, spacing: 2) {
                Text(p.title).font(.callout.weight(.semibold))
                Text(text).font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
            Spacer()
            Button("열기") { store.pane = p; WindowManager.shared.showMain() }.buttonStyle(.link)
        }
    }

    func bullet(_ text: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Text("•").foregroundStyle(.secondary)
            Text(text).font(.callout).fixedSize(horizontal: false, vertical: true)
        }
    }

    func shortcut(_ keys: String, _ what: String) -> some View {
        GridRow {
            Text(keys)
                .font(.system(.callout, design: .rounded).weight(.medium))
                .padding(.horizontal, 7).padding(.vertical, 2)
                .background(Palette.track, in: RoundedRectangle(cornerRadius: 5))
            Text(what).foregroundStyle(.secondary)
        }
    }
}
