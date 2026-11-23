import AppKit
import MacCleanCore
import SwiftUI

/// GitHub 저장소의 최신 릴리스를 조회해 업데이트를 알려 준다.
/// 보내는 정보는 없고, 공개 API에서 최신 릴리스 정보만 받아 온다.
@MainActor
final class UpdateChecker: ObservableObject {
    struct Release: Equatable {
        let tag: String
        let pageURL: URL
        let dmgURL: URL?
        let notes: String
        let published: Date?
    }

    enum State: Equatable {
        case idle
        case checking
        case upToDate(String)
        case available(Release)
        case failed(String)
    }

    @Published var state: State = .idle
    @Published var lastChecked: Date? = UserDefaults.standard.object(forKey: Prefs.lastUpdateCheck) as? Date

    var available: Release? {
        if case .available(let r) = state { return r }
        return nil
    }

    /// 자동 확인: 설정이 켜져 있고 마지막 확인 뒤 하루가 지났을 때만
    func checkIfDue() {
        guard UserDefaults.standard.bool(forKey: Prefs.autoUpdateCheck) else { return }
        if let last = lastChecked, Date().timeIntervalSince(last) < 86_400 { return }
        check(showResult: false)
    }

    /// showResult: 메뉴에서 직접 눌렀을 때 결과 창을 띄운다
    func check(showResult: Bool) {
        if case .checking = state { return }
        state = .checking
        Task {
            do {
                let r = try await Self.fetchLatest()
                lastChecked = Date()
                UserDefaults.standard.set(lastChecked, forKey: Prefs.lastUpdateCheck)
                state = AppVersion.isNewer(r.tag, than: AppVersion.version) ? .available(r) : .upToDate(r.tag)
            } catch {
                state = .failed(Self.describe(error))
            }
            if showResult { presentResult() }
        }
    }

    func presentResult() {
        NSApp.activate()
        let alert = NSAlert()
        alert.icon = NSApp.applicationIconImage
        switch state {
        case .available(let r):
            alert.messageText = "새 버전 \(Self.clean(r.tag))이(가) 있습니다"
            var info = "지금 쓰는 버전: \(AppVersion.version)"
            if let d = r.published { info += "\n출시: \(Fmt.date(d))" }
            let notes = Self.summarize(r.notes)
            if !notes.isEmpty { info += "\n\n" + notes }
            info += "\n\n받은 DMG를 열어 Applications에 덮어쓰면 됩니다. 업데이트 뒤에는 전체 디스크 접근 권한을 껐다 켜 주세요."
            alert.informativeText = info
            alert.addButton(withTitle: r.dmgURL != nil ? "다운로드" : "릴리스 페이지 열기")
            alert.addButton(withTitle: "릴리스 노트 보기")
            alert.addButton(withTitle: "나중에")
            let res = alert.runModal()
            if res == .alertFirstButtonReturn { NSWorkspace.shared.open(r.dmgURL ?? r.pageURL) }
            if res == .alertSecondButtonReturn { NSWorkspace.shared.open(r.pageURL) }
        case .upToDate(let tag):
            alert.messageText = "최신 버전을 쓰고 있습니다"
            alert.informativeText = "MacClean \(AppVersion.version) — GitHub의 최신 릴리스는 \(Self.clean(tag))입니다."
            alert.addButton(withTitle: "확인")
            alert.addButton(withTitle: "릴리스 목록 보기")
            if alert.runModal() == .alertSecondButtonReturn { NSWorkspace.shared.open(AppVersion.releasesURL) }
        case .failed(let why):
            alert.alertStyle = .warning
            alert.messageText = "업데이트를 확인하지 못했습니다"
            alert.informativeText = why
            alert.addButton(withTitle: "확인")
            alert.addButton(withTitle: "릴리스 페이지 열기")
            if alert.runModal() == .alertSecondButtonReturn { NSWorkspace.shared.open(AppVersion.releasesURL) }
        case .idle, .checking:
            break
        }
    }

    // MARK: GitHub

    static func fetchLatest() async throws -> Release {
        var req = URLRequest(url: AppVersion.latestAPI, timeoutInterval: 12)
        req.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        req.setValue("MacClean/\(AppVersion.version)", forHTTPHeaderField: "User-Agent")
        let (data, resp) = try await URLSession.shared.data(for: req)
        let code = (resp as? HTTPURLResponse)?.statusCode ?? 0
        guard code == 200 else { throw UpdateError.http(code) }
        struct Asset: Decodable { let name: String; let browser_download_url: String }
        struct R: Decodable {
            let tag_name: String
            let html_url: String
            let body: String?
            let published_at: String?
            let assets: [Asset]
            let draft: Bool?
            let prerelease: Bool?
        }
        let r = try JSONDecoder().decode(R.self, from: data)
        let dmg = r.assets.first { $0.name.lowercased().hasSuffix(".dmg") }.flatMap { URL(string: $0.browser_download_url) }
        let date = r.published_at.flatMap { ISO8601DateFormatter().date(from: $0) }
        return Release(tag: r.tag_name, pageURL: URL(string: r.html_url) ?? AppVersion.releasesURL,
                       dmgURL: dmg, notes: r.body ?? "", published: date)
    }

    enum UpdateError: Error {
        case http(Int)
    }

    static func describe(_ error: Error) -> String {
        if case UpdateError.http(let code) = error {
            switch code {
            case 404: return "아직 등록된 릴리스가 없습니다."
            case 403, 429: return "GitHub 요청 한도에 걸렸습니다. 잠시 뒤 다시 시도하세요."
            default: return "GitHub 응답 오류 (\(code))"
            }
        }
        if let u = error as? URLError {
            switch u.code {
            case .notConnectedToInternet, .networkConnectionLost: return "인터넷에 연결되어 있지 않습니다."
            case .timedOut: return "응답이 없어 시간이 초과됐습니다."
            default: return "네트워크 오류: \(u.localizedDescription)"
            }
        }
        return error.localizedDescription
    }

    static func clean(_ tag: String) -> String {
        tag.hasPrefix("v") || tag.hasPrefix("V") ? String(tag.dropFirst()) : tag
    }

    /// 릴리스 노트에서 '변경 사항' 부분만 짧게
    static func summarize(_ notes: String) -> String {
        var lines = notes.components(separatedBy: .newlines)
        if let i = lines.firstIndex(where: { $0.contains("변경") || $0.lowercased().contains("change") }) {
            lines = Array(lines[(i + 1)...])
        }
        var out: [String] = []
        for l in lines {
            let t = l.trimmingCharacters(in: .whitespaces)
            if t.hasPrefix("## ") && !out.isEmpty { break }
            if t.isEmpty || t.hasPrefix("#") { continue }
            out.append(t.replacingOccurrences(of: "**", with: "").replacingOccurrences(of: "`", with: ""))
            if out.count >= 6 { break }
        }
        let text = out.joined(separator: "\n")
        return text.count > 600 ? String(text.prefix(600)) + "…" : text
    }
}

/// 업데이트 상태 한 줄 (버전 정보 창·설정 공용)
struct UpdateStatusRow: View {
    @EnvironmentObject var updates: UpdateChecker

    var body: some View {
        switch updates.state {
        case .idle:
            Button { updates.check(showResult: false) } label: { Label("업데이트 확인", systemImage: "arrow.triangle.2.circlepath") }
        case .checking:
            HStack(spacing: 8) { ProgressView().controlSize(.small); Text("GitHub 릴리스 확인 중…").foregroundStyle(.secondary) }
        case .upToDate(let tag):
            HStack(spacing: 10) {
                Label("최신 버전입니다 (GitHub 최신: \(UpdateChecker.clean(tag)))", systemImage: "checkmark.circle.fill").foregroundStyle(Palette.sage)
                Button("다시 확인") { updates.check(showResult: false) }.buttonStyle(.link)
            }
        case .available(let r):
            HStack(spacing: 10) {
                Label("새 버전 \(UpdateChecker.clean(r.tag))이 있습니다", systemImage: "arrow.down.circle.fill").foregroundStyle(Palette.blue)
                Button("자세히") { updates.presentResult() }.buttonStyle(.borderedProminent)
            }
        case .failed(let why):
            HStack(spacing: 10) {
                Label(why, systemImage: "exclamationmark.triangle").foregroundStyle(Palette.amber).lineLimit(2)
                Button("다시 시도") { updates.check(showResult: false) }
            }
        }
    }
}
