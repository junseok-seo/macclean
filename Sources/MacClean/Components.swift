import AppKit
import MacCleanCore
import SwiftUI

extension Safety {
    var color: Color {
        switch self {
        case .safe: .green
        case .review: .blue
        case .caution: .orange
        case .keep: .red
        }
    }

    var icon: String {
        switch self {
        case .safe: "checkmark.shield.fill"
        case .review: "eye.fill"
        case .caution: "exclamationmark.triangle.fill"
        case .keep: "lock.fill"
        }
    }
}

/// 막대·범례·차트에 쓰는 채도 낮은 색 (원색 대신 부드러운 톤)
enum Palette {
    static let blue = Color(red: 0.47, green: 0.63, blue: 0.84)
    static let sky = Color(red: 0.55, green: 0.72, blue: 0.86)
    static let amber = Color(red: 0.86, green: 0.67, blue: 0.44)
    static let lavender = Color(red: 0.67, green: 0.60, blue: 0.84)
    static let sage = Color(red: 0.53, green: 0.73, blue: 0.60)
    static let teal = Color(red: 0.45, green: 0.71, blue: 0.72)
    static let rose = Color(red: 0.84, green: 0.58, blue: 0.66)
    static let sand = Color(red: 0.80, green: 0.72, blue: 0.57)
    static let coral = Color(red: 0.86, green: 0.55, blue: 0.50)
    static let slate = Color(red: 0.60, green: 0.63, blue: 0.68)
    static let track = Color.primary.opacity(0.06)

    /// 압력 단계별 색 (정상·경고·위험)
    static func pressure(_ level: Int) -> Color {
        switch level {
        case 4: coral
        case 2: amber
        default: sage
        }
    }

    /// 사용률에 따른 막대 색: 평소 파랑, 높으면 앰버
    static func usage(_ fraction: Double, warnAt: Double = 0.9) -> Color {
        fraction > warnAt ? amber : blue
    }
}

extension ItemKind {
    var color: Color {
        switch self {
        case .cache, .logs: Palette.sage
        case .buildArtifact, .developer: Palette.teal
        case .appData, .appSettings, .appBundle: Palette.blue
        case .virtualMachine, .aiModel: Palette.lavender
        case .video, .image, .audio, .media: Palette.rose
        case .download, .installer, .archive: Palette.sand
        case .backup, .cloud: Palette.sky
        case .mail, .messenger: Palette.amber
        case .system: Palette.slate
        case .trash: Palette.sand
        case .userFiles, .document, .folder, .file: Palette.teal
        }
    }
}

struct SafetyBadge: View {
    let safety: Safety
    var compact = false

    var body: some View {
        HStack(spacing: 3) {
            Image(systemName: safety.icon).imageScale(.small)
            Text(compact ? safety.shortLabel : safety.label)
        }
        .font(.caption.weight(.semibold))
        .foregroundStyle(safety.color)
        .padding(.horizontal, 7)
        .padding(.vertical, 2.5)
        .background(safety.color.opacity(0.13), in: Capsule())
        .help(safety.explanation)
        .fixedSize()
    }
}

struct Tag: View {
    let text: String
    var color: Color = .secondary
    var icon: String? = nil

    var body: some View {
        HStack(spacing: 3) {
            if let icon { Image(systemName: icon).imageScale(.small) }
            Text(text)
        }
        .font(.caption)
        .foregroundStyle(color)
        .padding(.horizontal, 6)
        .padding(.vertical, 2)
        .background(color.opacity(0.1), in: Capsule())
        .fixedSize()
    }
}

struct Card<Content: View>: View {
    var title: String? = nil
    var symbol: String? = nil
    var trailing: AnyView? = nil
    @ViewBuilder var content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            if let title {
                HStack {
                    if let symbol {
                        Label(title, systemImage: symbol).font(.headline)
                    } else {
                        Text(title).font(.headline)
                    }
                    Spacer()
                    if let trailing { trailing }
                }
            }
            content
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .topLeading)
        .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(Color(nsColor: .controlBackgroundColor)))
        .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).strokeBorder(Color.primary.opacity(0.07)))
    }
}

struct SegmentBar: View {
    struct Segment: Identifiable {
        let id: String
        let value: Double
        let color: Color
        let label: String
    }

    let segments: [Segment]
    var total: Double? = nil
    var height: CGFloat = 14

    var body: some View {
        GeometryReader { geo in
            let sum = max(total ?? segments.reduce(0) { $0 + $1.value }, 1)
            HStack(spacing: 0) {
                ForEach(segments) { s in
                    Rectangle()
                        .fill(s.color.opacity(0.9))
                        .frame(width: max(0, geo.size.width * s.value / sum))
                        .overlay(alignment: .trailing) { Rectangle().fill(.background.opacity(0.3)).frame(width: 1) }
                        .help(s.label)
                }
                Spacer(minLength: 0)
            }
        }
        .frame(height: height)
        .background(Palette.track)
        .clipShape(RoundedRectangle(cornerRadius: height / 3, style: .continuous))
    }
}

struct LegendDot: View {
    let color: Color
    let label: String
    var value: String? = nil

    var body: some View {
        HStack(spacing: 5) {
            Circle().fill(color).frame(width: 8, height: 8)
            Text(label).foregroundStyle(.secondary)
            if let value { Text(value).monospacedDigit() }
        }
        .font(.caption)
    }
}

struct SizeBar: View {
    let fraction: Double
    var color: Color = Palette.blue

    var body: some View {
        GeometryReader { geo in
            ZStack(alignment: .leading) {
                Capsule().fill(Palette.track)
                Capsule().fill(color.opacity(0.85)).frame(width: max(2, geo.size.width * min(max(fraction, 0), 1)))
            }
        }
        .frame(height: 6)
    }
}

final class IconCache {
    static let shared = IconCache()
    private let cache = NSCache<NSString, NSImage>()

    func icon(_ path: String) -> NSImage {
        if let i = cache.object(forKey: path as NSString) { return i }
        let i = NSWorkspace.shared.icon(forFile: path)
        cache.setObject(i, forKey: path as NSString)
        return i
    }
}

struct FileIcon: View {
    let path: String
    var size: CGFloat = 18

    var body: some View {
        Image(nsImage: IconCache.shared.icon(path))
            .resizable()
            .interpolation(.high)
            .frame(width: size, height: size)
    }
}

struct EmptyState: View {
    let symbol: String
    let title: String
    let message: String
    var action: (label: String, run: () -> Void)? = nil

    var body: some View {
        VStack(spacing: 14) {
            Image(systemName: symbol)
                .font(.system(size: 46, weight: .light))
                .foregroundStyle(.secondary)
            Text(title).font(.title2.weight(.semibold))
            Text(message)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 460)
            if let action {
                Button(action.label, action: action.run)
                    .buttonStyle(.borderedProminent)
                    .controlSize(.large)
                    .padding(.top, 4)
            }
        }
        .padding(40)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

struct PaneHeader<Trailing: View>: View {
    let title: String
    let subtitle: String
    @ViewBuilder var trailing: Trailing

    var body: some View {
        HStack(alignment: .center, spacing: 12) {
            VStack(alignment: .leading, spacing: 3) {
                Text(title).font(.title2.weight(.bold))
                Text(subtitle).font(.callout).foregroundStyle(.secondary)
            }
            Spacer()
            trailing
        }
        .padding(.horizontal, 20)
        .padding(.top, 16)
        .padding(.bottom, 12)
    }
}

/// 전체 디스크 접근 권한 안내 배너
struct PermissionBanner: View {
    @EnvironmentObject var permissions: PermissionModel

    var body: some View {
        if !permissions.fullDiskAccess {
            HStack(alignment: .top, spacing: 12) {
                Image(systemName: "lock.shield").font(.title2).foregroundStyle(.orange)
                VStack(alignment: .leading, spacing: 4) {
                    Text("전체 디스크 접근 권한을 켜면 더 정확해집니다").font(.headline)
                    Text("권한이 없으면 휴지통, 메일, 메시지, 다른 앱의 데이터 폴더 크기를 읽지 못해 일부가 빠지고, 폴더마다 접근 허용 창이 뜰 수 있습니다. 시스템 설정 > 개인정보 보호 및 보안 > 전체 디스크 접근 권한에서 MacClean을 켜고 앱을 다시 실행하세요.")
                        .font(.callout).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer()
                VStack(spacing: 6) {
                    Button("설정 열기") { permissions.openSettings() }
                        .buttonStyle(.borderedProminent)
                    Button("다시 확인") { permissions.refresh() }
                        .buttonStyle(.link).font(.caption)
                }
            }
            .padding(14)
            .background(RoundedRectangle(cornerRadius: 12).fill(Color.orange.opacity(0.09)))
            .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(Color.orange.opacity(0.3)))
        }
    }
}

/// 판정 설명 카드 (탐색기·대용량 파일 공용)
struct InsightCard: View {
    let insight: Insight

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 6) {
                SafetyBadge(safety: insight.safety)
                Tag(text: insight.kind.label, color: insight.kind.color, icon: insight.kind.symbol)
                if insight.isOrphan { Tag(text: "삭제된 앱", color: .orange, icon: "puzzlepiece.extension") }
                if !insight.confident { Tag(text: "추정", color: .secondary, icon: "questionmark.circle") }
            }
            Text(insight.title).font(.title3.weight(.semibold)).fixedSize(horizontal: false, vertical: true)
            if let app = insight.appName {
                HStack(spacing: 6) {
                    if let p = insight.appPath { FileIcon(path: p, size: 16) }
                    Text("소속 앱: \(app)").font(.callout)
                    if let id = insight.appBundleID, AppRegistry.shared.isRunning(bundleID: id) {
                        Tag(text: "실행 중", color: .orange, icon: "play.circle")
                    }
                }
            }
            Text(insight.detail)
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
                .textSelection(.enabled)
            if let c = insight.consequence {
                Label { Text("지우면: " + c) } icon: { Image(systemName: "arrow.uturn.backward.circle") }
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if case .manual(let text) = insight.action {
                Label { Text(text).fixedSize(horizontal: false, vertical: true) } icon: { Image(systemName: "hand.point.right") }
                    .font(.callout)
                    .padding(10)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(Color.accentColor.opacity(0.08), in: RoundedRectangle(cornerRadius: 8))
            }
        }
    }
}

/// 결과 토스트
struct ToastView: View {
    let toast: Toast

    var body: some View {
        Label(toast.text, systemImage: toast.isError ? "exclamationmark.triangle.fill" : "checkmark.circle.fill")
            .font(.callout.weight(.medium))
            .foregroundStyle(toast.isError ? .orange : .green)
            .padding(.horizontal, 14)
            .padding(.vertical, 9)
            .background(.regularMaterial, in: Capsule())
            .shadow(color: .black.opacity(0.15), radius: 8, y: 3)
    }
}

/// 삭제·명령 결과 상세
struct ReportView: View {
    let sheet: ReportSheet
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text(sheet.title).font(.title2.weight(.bold))
            let r = sheet.report
            HStack(spacing: 18) {
                stat("바로 확보", Fmt.bytes(r.freedBytes), .green)
                stat("휴지통으로 이동", Fmt.bytes(r.trashedBytes), .blue)
                stat("실패", "\(r.failures.count)개", r.failures.isEmpty ? .secondary : .orange)
            }
            if r.trashedBytes > 0 {
                Text("휴지통으로 옮긴 항목은 휴지통을 비워야 실제 공간이 확보됩니다.")
                    .font(.callout).foregroundStyle(.secondary)
            }
            if !r.commandOutputs.isEmpty {
                Text("실행한 명령").font(.headline)
                ScrollView {
                    Text(r.commandOutputs.joined(separator: "\n\n"))
                        .font(.system(.caption, design: .monospaced))
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .textSelection(.enabled)
                }
                .frame(maxHeight: 160)
                .padding(8)
                .background(Color.primary.opacity(0.05), in: RoundedRectangle(cornerRadius: 8))
            }
            if !r.failures.isEmpty {
                Text("지우지 못한 항목").font(.headline)
                Text("대부분 macOS가 보호하는 파일이거나 실행 중인 앱이 사용 중인 파일입니다. 그대로 둬도 문제없습니다.")
                    .font(.callout).foregroundStyle(.secondary)
                List(r.failures.prefix(300)) { f in
                    VStack(alignment: .leading, spacing: 2) {
                        Text(Paths.abbreviate(f.path)).font(.callout).lineLimit(1).truncationMode(.middle)
                        Text(f.reason).font(.caption).foregroundStyle(.secondary)
                    }
                }
                .frame(minHeight: 160)
            }
            HStack {
                Spacer()
                Button("닫기") { dismiss() }.keyboardShortcut(.defaultAction)
            }
        }
        .padding(22)
        .frame(width: 620)
        .frame(minHeight: 260)
    }

    func stat(_ label: String, _ value: String, _ color: Color) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(label).font(.caption).foregroundStyle(.secondary)
            Text(value).font(.title3.weight(.semibold)).foregroundStyle(color).monospacedDigit()
        }
    }
}
