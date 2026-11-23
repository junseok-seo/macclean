import AppKit
import MacCleanCore
import SwiftUI

struct CleanupView: View {
    @EnvironmentObject var store: AppStore
    @EnvironmentObject var cleanup: CleanupModel
    @AppStorage(Prefs.trashSafeItems) private var trashSafe = false
    @State private var expanded: Set<String> = []
    @State private var showConfirm = false

    var body: some View {
        VStack(spacing: 0) {
            PaneHeader(title: "정리 추천", subtitle: subtitle) {
                Button {
                    cleanup.scan()
                } label: {
                    Label("다시 검사", systemImage: "arrow.clockwise")
                }
                .disabled(cleanup.isScanning || cleanup.isCleaning)
            }
            Divider()
            if cleanup.groups.isEmpty {
                if cleanup.isScanning {
                    VStack(spacing: 14) {
                        ProgressView().controlSize(.large)
                        Text(cleanup.status).foregroundStyle(.secondary)
                        Text("캐시, 개발 도구, 다운로드, 삭제된 앱의 잔여 파일을 확인하고 있습니다. 보통 1분 안에 끝납니다.")
                            .font(.callout).foregroundStyle(.tertiary)
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else {
                    EmptyState(symbol: "sparkles", title: "정리할 항목을 찾아볼까요?",
                               message: "알려진 캐시·로그·빌드 산출물·오래된 다운로드·삭제된 앱의 잔여 파일을 찾아, 항목마다 무엇인지와 지워도 되는지를 알려 줍니다.",
                               action: ("검사 시작", { cleanup.scan() }))
                }
            } else {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 14) {
                        PermissionBanner()
                        if cleanup.isScanning {
                            HStack(spacing: 8) {
                                ProgressView().controlSize(.small)
                                Text(cleanup.status).font(.callout).foregroundStyle(.secondary)
                            }
                        }
                        legend
                        ForEach(cleanup.groups) { g in
                            CleanupGroupView(group: g, expanded: $expanded)
                        }
                    }
                    .padding(20)
                }
                bottomBar
            }
        }
        .sheet(isPresented: $showConfirm) {
            CleanupConfirmSheet { showConfirm = false }
        }
    }

    var subtitle: String {
        if let d = cleanup.scannedAt { return "마지막 검사: \(Fmt.ago(d)) · 항목을 눌러 무엇인지 확인하세요" }
        return "지워도 되는 것과 아닌 것을 나눠서 보여 줍니다"
    }

    var legend: some View {
        HStack(spacing: 14) {
            ForEach(Safety.allCases, id: \.self) { s in
                HStack(spacing: 4) {
                    SafetyBadge(safety: s, compact: true)
                    Text(s.explanation).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                }
                .help(s.explanation)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    var bottomBar: some View {
        HStack(spacing: 14) {
            if cleanup.isCleaning {
                ProgressView().controlSize(.small)
                Text(cleanup.status).foregroundStyle(.secondary).lineLimit(1)
                Spacer()
            } else {
                VStack(alignment: .leading, spacing: 2) {
                    Text("\(cleanup.selectedItems.count)개 선택 · \(Fmt.bytes(cleanup.selectedSize))")
                        .font(.headline).monospacedDigit()
                    Text(trashSafe ? "모든 항목을 휴지통으로 옮깁니다" : "'안전' 캐시는 바로 삭제, 나머지는 휴지통으로 옮깁니다")
                        .font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                Button("선택 해제") { cleanup.selected.removeAll() }
                    .disabled(cleanup.selected.isEmpty)
                Button {
                    showConfirm = true
                } label: {
                    Label("선택 항목 정리", systemImage: "sparkles")
                        .padding(.horizontal, 6)
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
                .disabled(cleanup.selectedItems.isEmpty || cleanup.isScanning)
            }
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 12)
        .background(.bar)
        .overlay(alignment: .top) { Divider() }
    }
}

struct CleanupGroupView: View {
    let group: CleanupGroup
    @Binding var expanded: Set<String>
    @EnvironmentObject var cleanup: CleanupModel

    var body: some View {
        let collapsed = cleanup.collapsed.contains(group.id)
        let actionable = group.items.filter(\.isActionable)
        let bulk = actionable.filter { $0.safety < .caution }
        let selCount = actionable.filter { cleanup.selected.contains($0.id) }.count
        let bulkSel = bulk.filter { cleanup.selected.contains($0.id) }.count
        let manualSize = group.items.filter { !$0.isActionable }.reduce(Int64(0)) { $0 + max(0, $1.size) }

        VStack(spacing: 0) {
            HStack(spacing: 10) {
                Image(systemName: "chevron.right")
                    .font(.caption.weight(.bold))
                    .foregroundStyle(.secondary)
                    .rotationEffect(.degrees(collapsed ? 0 : 90))
                    .frame(width: 12)
                if !bulk.isEmpty {
                    Toggle("", isOn: Binding(
                        get: { bulkSel == bulk.count && bulkSel > 0 },
                        set: { cleanup.setGroup(group, on: $0) }))
                        .toggleStyle(.checkbox)
                        .labelsHidden()
                        .help("'안전'·'확인' 항목만 한꺼번에 선택합니다. '주의' 항목은 하나씩 직접 고르세요.")
                } else if !actionable.isEmpty {
                    Image(systemName: "hand.raised").foregroundStyle(.secondary).frame(width: 16)
                        .help("'주의' 항목만 있는 그룹이라 하나씩 직접 골라야 합니다")
                }
                Image(systemName: group.symbol).foregroundStyle(Color.accentColor).frame(width: 20)
                VStack(alignment: .leading, spacing: 1) {
                    Text(group.title).font(.headline)
                    Text(group.summary).font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                if selCount > 0 {
                    Text("\(selCount)/\(actionable.count)개 선택").font(.caption).foregroundStyle(.secondary)
                }
                Text(actionable.isEmpty ? "직접 정리 \(Fmt.bytes(manualSize))" : Fmt.bytes(group.totalSize))
                    .font(.headline).monospacedDigit()
                    .foregroundStyle(actionable.isEmpty ? .secondary : .primary)
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 11)
            .contentShape(Rectangle())
            .onTapGesture {
                withAnimation(.easeInOut(duration: 0.15)) {
                    if collapsed { cleanup.collapsed.remove(group.id) } else { cleanup.collapsed.insert(group.id) }
                }
            }

            if !collapsed {
                Divider()
                ForEach(group.items) { item in
                    CleanupItemRow(item: item, isExpanded: expanded.contains(item.id)) {
                        if expanded.contains(item.id) { expanded.remove(item.id) } else { expanded.insert(item.id) }
                    }
                    if item.id != group.items.last?.id { Divider().padding(.leading, 64) }
                }
            }
        }
        .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(Color(nsColor: .controlBackgroundColor)))
        .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).strokeBorder(Color.primary.opacity(0.07)))
    }
}

struct CleanupItemRow: View {
    let item: CleanupItem
    let isExpanded: Bool
    let toggleExpand: () -> Void
    @EnvironmentObject var cleanup: CleanupModel

    var body: some View {
        let running = item.appBundleID.map { !NSRunningApplication.runningApplications(withBundleIdentifier: $0).isEmpty } ?? false
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 10) {
                Group {
                    if item.isActionable {
                        Toggle("", isOn: Binding(get: { cleanup.selected.contains(item.id) }, set: { _ in cleanup.toggle(item) }))
                            .toggleStyle(.checkbox)
                            .labelsHidden()
                    } else {
                        Image(systemName: "hand.point.up.left").foregroundStyle(.secondary)
                            .help("직접 지우면 위험해서 안내만 합니다")
                    }
                }
                .frame(width: 22)
                .padding(.leading, 22)
                Image(systemName: item.kind.symbol).foregroundStyle(item.kind.color).frame(width: 20)
                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: 6) {
                        Text(item.title).lineLimit(1)
                        if running { Tag(text: "실행 중", color: .orange, icon: "play.circle") }
                        if item.isActionable && !item.permanent { Tag(text: "휴지통", color: .secondary, icon: "trash") }
                        if case .command(_, let admin) = item.method { Tag(text: admin ? "명령·암호 필요" : "명령 실행", color: .secondary, icon: "terminal") }
                    }
                    Text(item.subtitle).font(.caption).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
                }
                Spacer(minLength: 12)
                SafetyBadge(safety: item.safety, compact: true)
                Text(item.size < 0 ? "미확인" : Fmt.bytes(item.size))
                    .monospacedDigit()
                    .foregroundStyle(item.size < 0 ? .secondary : .primary)
                    .frame(width: 84, alignment: .trailing)
                Button(action: toggleExpand) {
                    Image(systemName: isExpanded ? "chevron.up.circle.fill" : "info.circle")
                }
                .buttonStyle(.borderless)
                .help("자세히")
                if let p = item.revealPath {
                    Button { Finder.reveal(p) } label: { Image(systemName: "magnifyingglass") }
                        .buttonStyle(.borderless)
                        .help("Finder에서 보기")
                }
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 8)
            .contentShape(Rectangle())
            .onTapGesture(perform: toggleExpand)

            if isExpanded {
                VStack(alignment: .leading, spacing: 10) {
                    Text(item.detail)
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                        .textSelection(.enabled)
                    if running {
                        Label("이 앱이 실행 중입니다. 종료한 뒤 정리하면 더 확실하게 지워집니다.", systemImage: "exclamationmark.triangle")
                            .font(.callout).foregroundStyle(.orange)
                    }
                    if let g = item.guidance {
                        Label { Text(g).fixedSize(horizontal: false, vertical: true) } icon: { Image(systemName: "hand.point.right") }
                            .font(.callout)
                            .padding(10)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .background(Color.accentColor.opacity(0.08), in: RoundedRectangle(cornerRadius: 8))
                    }
                    if case .command(let cmd, _) = item.method {
                        HStack {
                            Text(cmd).font(.system(.caption, design: .monospaced)).textSelection(.enabled)
                            Button { Finder.copy(cmd) } label: { Image(systemName: "doc.on.doc") }.buttonStyle(.borderless).help("명령 복사")
                        }
                        .padding(8)
                        .background(Color.primary.opacity(0.05), in: RoundedRectangle(cornerRadius: 6))
                    }
                    let paths = item.paths
                    if !paths.isEmpty {
                        VStack(alignment: .leading, spacing: 3) {
                            ForEach(paths.prefix(10), id: \.self) { p in
                                HStack(spacing: 6) {
                                    Image(systemName: "folder").font(.caption).foregroundStyle(.secondary)
                                    Text(Paths.abbreviate(p)).font(.caption).lineLimit(1).truncationMode(.middle).textSelection(.enabled)
                                    Button("보기") { Finder.reveal(p) }.buttonStyle(.link).font(.caption)
                                }
                            }
                            if paths.count > 10 { Text("외 \(paths.count - 10)개 위치").font(.caption).foregroundStyle(.secondary) }
                        }
                    }
                    if let d = item.lastModified {
                        Text("마지막 변경: \(Fmt.date(d)) (\(Fmt.ago(d)))").font(.caption).foregroundStyle(.secondary)
                    }
                }
                .padding(.leading, 98)
                .padding(.trailing, 20)
                .padding(.bottom, 12)
            }
        }
    }
}

struct CleanupConfirmSheet: View {
    @EnvironmentObject var cleanup: CleanupModel
    @AppStorage(Prefs.trashSafeItems) private var trashSafe = false
    let close: () -> Void

    var body: some View {
        let items = cleanup.selectedItems
        let commands = items.filter { if case .command = $0.method { return true }; return false }
        let trashEmpty = items.filter { $0.method == .emptyTrash }
        let files = items.filter { if case .command = $0.method { return false }; return $0.method != .emptyTrash }
        let permanent = files.filter { $0.permanent && !trashSafe }
        let toTrash = files.filter { !$0.permanent || trashSafe }
        let running = cleanup.runningApps(in: items)
        let risky = items.filter { $0.safety >= .caution }

        VStack(alignment: .leading, spacing: 14) {
            Text("\(items.count)개 항목을 정리할까요?").font(.title2.weight(.bold))
            VStack(alignment: .leading, spacing: 8) {
                if !permanent.isEmpty {
                    summary("bolt.fill", .green, "바로 삭제 (되돌릴 수 없음)", permanent)
                }
                if !toTrash.isEmpty {
                    summary("trash", .blue, "휴지통으로 이동 (되살릴 수 있음)", toTrash)
                }
                if !trashEmpty.isEmpty {
                    summary("trash.slash", .red, "휴지통 비우기 (되돌릴 수 없음)", trashEmpty)
                }
                if !commands.isEmpty {
                    summary("terminal", .purple, "명령 실행" + (commands.contains { if case .command(_, true) = $0.method { return true }; return false } ? " (관리자 암호 필요)" : ""), commands)
                }
            }
            if !running.isEmpty {
                Label("실행 중인 앱: \(running.joined(separator: ", ")). 앱이 쓰고 있는 캐시는 일부 지워지지 않거나 앱이 잠시 다시 불러올 수 있습니다. 가능하면 앱을 종료한 뒤 정리하세요.",
                      systemImage: "exclamationmark.triangle.fill")
                    .font(.callout).foregroundStyle(.orange)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if !risky.isEmpty {
                Label("'주의' 항목 \(risky.count)개가 포함되어 있습니다: \(risky.map(\.title).prefix(4).joined(separator: ", "))\(risky.count > 4 ? " 등" : ""). 정말 필요 없는지 확인하세요.",
                      systemImage: "exclamationmark.octagon")
                    .font(.callout).foregroundStyle(.orange)
                    .fixedSize(horizontal: false, vertical: true)
            }
            List(items) { it in
                HStack {
                    Image(systemName: it.kind.symbol).foregroundStyle(it.kind.color).frame(width: 18)
                    Text(it.title).lineLimit(1)
                    Spacer()
                    SafetyBadge(safety: it.safety, compact: true)
                    Text(it.size < 0 ? "미확인" : Fmt.bytes(it.size)).monospacedDigit().frame(width: 80, alignment: .trailing)
                }
            }
            .frame(height: 220)
            HStack {
                Text("합계 \(Fmt.bytes(cleanup.selectedSize))").font(.headline).monospacedDigit()
                Spacer()
                Button("취소", action: close).keyboardShortcut(.cancelAction)
                Button {
                    close()
                    cleanup.clean()
                } label: {
                    Text("정리 시작").padding(.horizontal, 8)
                }
                .buttonStyle(.borderedProminent)
                .keyboardShortcut(.defaultAction)
            }
        }
        .padding(22)
        .frame(width: 620)
    }

    func summary(_ icon: String, _ color: Color, _ label: String, _ list: [CleanupItem]) -> some View {
        HStack {
            Image(systemName: icon).foregroundStyle(color).frame(width: 20)
            Text(label)
            Spacer()
            Text("\(list.count)개 · \(Fmt.bytes(list.reduce(0) { $0 + max(0, $1.size) }))").monospacedDigit().foregroundStyle(.secondary)
        }
        .font(.callout)
    }
}
