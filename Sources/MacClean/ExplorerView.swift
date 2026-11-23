import AppKit
import MacCleanCore
import SwiftUI

struct ExplorerView: View {
    @EnvironmentObject var store: AppStore
    @EnvironmentObject var disk: DiskModel
    @State private var sort: SortKey = .size
    @State private var showInspector = true

    enum SortKey: String, CaseIterable, Identifiable {
        case size = "크기순", name = "이름순", date = "수정일순"
        var id: String { rawValue }
    }

    var body: some View {
        VStack(spacing: 0) {
            PaneHeader(title: "디스크 탐색", subtitle: "폴더를 따라 들어가며 무엇이 공간을 쓰는지, 지워도 되는지 확인합니다") {
                Menu {
                    Button("홈 폴더") { disk.scan(.home) }
                    Button("전체 디스크 (/)") { disk.scan(.root) }
                    Divider()
                    Button("폴더 선택…") { disk.chooseFolder() }
                } label: {
                    Label(disk.result == nil && !disk.isScanning ? "스캔할 위치" : "스캔: \(disk.target.label)", systemImage: "scope")
                }
                .fixedSize()
                if disk.isScanning {
                    Button("중지") { disk.cancel() }
                } else if disk.result != nil {
                    Button { disk.scan() } label: { Label("다시 스캔", systemImage: "arrow.clockwise") }
                }
            }
            Divider()
            content
        }
        .inspector(isPresented: $showInspector) {
            ExplorerInspector()
                .inspectorColumnWidth(min: 300, ideal: 350, max: 480)
        }
        .toolbar {
            ToolbarItem {
                Button { showInspector.toggle() } label: { Label("정보 패널", systemImage: "sidebar.trailing") }
            }
        }
    }

    @ViewBuilder
    var content: some View {
        if disk.isScanning {
            VStack(spacing: 12) {
                ProgressView().controlSize(.large)
                Text("파일 \(Fmt.count(disk.progress.files))개 · \(Fmt.bytes(disk.progress.bytes))")
                    .font(.title3.weight(.semibold)).monospacedDigit()
                Text(Paths.abbreviate(disk.progress.currentPath))
                    .font(.caption).foregroundStyle(.secondary)
                    .lineLimit(1).truncationMode(.middle)
                    .frame(maxWidth: 520)
                Text("홈 폴더 전체는 보통 1분 안팎 걸립니다. 파일 내용은 읽지 않고 크기만 셉니다.")
                    .font(.callout).foregroundStyle(.tertiary)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if let current = disk.current, let result = disk.result {
            browser(current, result)
        } else {
            VStack(spacing: 0) {
                EmptyState(symbol: "folder.badge.questionmark", title: "어디에 공간을 쓰고 있는지 살펴보세요",
                           message: "홈 폴더를 스캔하면 폴더별 용량과 함께 각 항목이 무엇이고 지워도 되는지 알려 줍니다. 숨김 폴더와 라이브러리까지 모두 포함합니다.",
                           action: ("홈 폴더 스캔", { disk.scan(.home) }))
                PermissionBanner().padding(20)
            }
        }
    }

    func browser(_ current: FileNode, _ result: ScanResult) -> some View {
        let _ = disk.revision
        let rows = sorted(current.children)
        return VStack(spacing: 0) {
            // 경로 표시줄
            HStack(spacing: 8) {
                Button { disk.up() } label: { Image(systemName: "chevron.left") }
                    .disabled(current.parent == nil)
                    .help("상위 폴더")
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 2) {
                        ForEach(current.ancestors) { n in
                            Button(n.displayName) {
                                disk.current = n
                                disk.selected = nil
                            }
                            .buttonStyle(.plain)
                            .font(.callout.weight(n === current ? .semibold : .regular))
                            .foregroundStyle(n === current ? .primary : .secondary)
                            if n !== current { Image(systemName: "chevron.right").font(.caption2).foregroundStyle(.tertiary) }
                        }
                    }
                }
                Spacer()
                Picker("정렬", selection: $sort) {
                    ForEach(SortKey.allCases) { Text($0.rawValue).tag($0) }
                }
                .labelsHidden()
                .fixedSize()
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 8)

            // 요약 + 분포 막대
            VStack(alignment: .leading, spacing: 8) {
                HStack(alignment: .firstTextBaseline, spacing: 10) {
                    Text(Fmt.bytes(current.size)).font(.title2.weight(.bold)).monospacedDigit()
                    Text("파일 \(Fmt.count(current.fileCount))개").foregroundStyle(.secondary)
                    if current.parent == nil {
                        Text("· \(String(format: "%.0f", result.duration))초 걸림 · \(Fmt.ago(result.date)) 스캔").foregroundStyle(.tertiary)
                    }
                    Spacer()
                    if current.parent == nil && !result.deniedPaths.isEmpty {
                        Tag(text: "읽지 못한 폴더 \(result.deniedPaths.count)개", color: .orange, icon: "lock")
                            .help("권한이 없어 크기에 포함되지 않았습니다. 전체 디스크 접근 권한을 켜면 포함됩니다.\n" + result.deniedPaths.prefix(15).map(Paths.abbreviate).joined(separator: "\n"))
                    }
                }
                SegmentBar(segments: segments(current, rows), total: Double(max(current.size, 1)), height: 12)
            }
            .padding(.horizontal, 16)
            .padding(.bottom, 10)

            Divider()

            List(selection: Binding(
                get: { disk.selected?.id },
                set: { id in disk.selected = rows.first { $0.id == id } })) {
                ForEach(rows) { node in
                    NodeRow(node: node, parentSize: current.size, revision: disk.revision)
                        .tag(node.id)
                }
                if current.smallFilesCount > 0 {
                    HStack(spacing: 10) {
                        Image(systemName: "doc.on.doc").frame(width: 20).foregroundStyle(.secondary)
                        Text("작은 파일 \(Fmt.count(current.smallFilesCount))개 (각 1MB 미만)").foregroundStyle(.secondary)
                        Spacer()
                        Text(Fmt.bytes(current.smallFilesSize)).monospacedDigit().foregroundStyle(.secondary)
                            .frame(width: 76, alignment: .trailing)
                        Spacer().frame(width: 128)
                    }
                    .selectionDisabled()
                }
            }
            .listStyle(.inset)
            .contextMenu(forSelectionType: FileNode.ID.self) { ids in
                if let id = ids.first, let node = rows.first(where: { $0.id == id }) {
                    if node.isDirectory { Button("열기") { disk.open(node) } }
                    Button("Finder에서 보기") { Finder.reveal(node.path) }
                    Button("경로 복사") { Finder.copy(node.path) }
                    Divider()
                    Button("휴지통으로 이동", role: .destructive) { ExplorerActions.confirmTrash(node, disk: disk, store: store) }
                        .disabled(Deleter.isProtected(node.path) || PathKnowledge.shared.insight(for: node.path, isDirectory: node.isDirectory).safety == .keep)
                }
            } primaryAction: { ids in
                if let id = ids.first, let node = rows.first(where: { $0.id == id }) {
                    if node.isDirectory && !node.isPackage { disk.open(node) } else { Finder.reveal(node.path) }
                }
            }
            .overlay {
                if rows.isEmpty && current.smallFilesCount == 0 {
                    Text(current.accessDenied ? "권한이 없어 이 폴더를 읽지 못했습니다" : "비어 있는 폴더입니다").foregroundStyle(.secondary)
                }
            }
        }
    }

    func sorted(_ nodes: [FileNode]) -> [FileNode] {
        switch sort {
        case .size: nodes
        case .name: nodes.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
        case .date: nodes.sorted { $0.newest > $1.newest }
        }
    }

    func segments(_ current: FileNode, _ rows: [FileNode]) -> [SegmentBar.Segment] {
        let top = current.children.prefix(12)
        var segs = top.map { n in
            SegmentBar.Segment(id: "\(n.id.hashValue)", value: Double(n.size),
                               color: PathKnowledge.shared.insight(for: n.path, isDirectory: n.isDirectory).kind.color,
                               label: "\(n.name) · \(Fmt.bytes(n.size))")
        }
        let rest = current.size - top.reduce(0) { $0 + $1.size }
        if rest > 0 { segs.append(.init(id: "rest", value: Double(rest), color: .gray.opacity(0.5), label: "기타 \(Fmt.bytes(rest))")) }
        return segs
    }
}

struct NodeRow: View {
    let node: FileNode
    let parentSize: Int64
    let revision: Int

    var body: some View {
        let ins = PathKnowledge.shared.insight(for: node.path, isDirectory: node.isDirectory)
        HStack(spacing: 10) {
            FileIcon(path: node.path, size: 20)
            VStack(alignment: .leading, spacing: 1) {
                HStack(spacing: 5) {
                    Text(node.name).lineLimit(1).truncationMode(.middle)
                    if node.accessDenied {
                        Image(systemName: "lock.fill").font(.caption).foregroundStyle(.orange).help("권한이 없어 읽지 못한 폴더")
                    }
                    if ins.isOrphan { Image(systemName: "puzzlepiece.extension").font(.caption).foregroundStyle(.orange).help("삭제된 앱의 잔여물로 보입니다") }
                }
                Text(ins.title).font(.caption).foregroundStyle(.secondary).lineLimit(1)
            }
            Spacer(minLength: 8)
            SafetyBadge(safety: ins.safety, compact: true)
            SizeBar(fraction: Double(node.size) / Double(max(parentSize, 1)), color: ins.kind.color)
                .frame(width: 100)
            Text(Fmt.bytes(node.size)).monospacedDigit().frame(width: 76, alignment: .trailing)
            Text(Fmt.ago(node.modifiedDate))
                .font(.caption).foregroundStyle(.secondary)
                .frame(width: 70, alignment: .trailing)
                .lineLimit(1)
        }
        .padding(.vertical, 3)
    }
}

enum ExplorerActions {
    @MainActor
    static func confirmTrash(_ node: FileNode, disk: DiskModel, store: AppStore) {
        let ins = PathKnowledge.shared.insight(for: node.path, isDirectory: node.isDirectory)
        var msg = "'\(node.name)' (\(Fmt.bytes(node.size)))을(를) 휴지통으로 옮깁니다. 휴지통에서 되살릴 수 있습니다."
        if ins.safety >= .caution { msg += "\n\n⚠️ \(ins.safety.label): \(ins.safety.explanation)" }
        store.ask("휴지통으로 이동할까요?", msg, confirm: "휴지통으로 이동") {
            disk.delete(node, permanent: false)
        }
    }

    @MainActor
    static func confirmEmpty(_ node: FileNode, permanent: Bool, disk: DiskModel, store: AppStore) {
        let msg = "'\(node.name)' 폴더는 남기고 안의 내용 \(Fmt.bytes(node.size))를 " + (permanent ? "바로 삭제합니다. 캐시처럼 다시 만들어지는 데이터라 되살릴 필요가 없습니다." : "휴지통으로 옮깁니다.")
        store.ask("내용을 비울까요?", msg, confirm: permanent ? "비우기" : "휴지통으로 이동") {
            disk.emptyContents(node, permanent: permanent)
        }
    }
}

struct ExplorerInspector: View {
    @EnvironmentObject var store: AppStore
    @EnvironmentObject var disk: DiskModel
    @AppStorage(Prefs.trashSafeItems) private var trashSafe = false

    var body: some View {
        let _ = disk.revision
        if let node = disk.selected ?? disk.current {
            let ins = PathKnowledge.shared.insight(for: node.path, isDirectory: node.isDirectory)
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    HStack(alignment: .top, spacing: 12) {
                        FileIcon(path: node.path, size: 44)
                        VStack(alignment: .leading, spacing: 3) {
                            Text(node.parent == nil ? Paths.abbreviate(node.name) : node.name)
                                .font(.headline).lineLimit(3)
                            Text(Paths.abbreviate(node.path))
                                .font(.caption).foregroundStyle(.secondary)
                                .textSelection(.enabled)
                                .lineLimit(4)
                        }
                    }
                    Grid(alignment: .leading, horizontalSpacing: 14, verticalSpacing: 6) {
                        GridRow {
                            Text("크기").foregroundStyle(.secondary)
                            Text(Fmt.bytes(node.size)).monospacedDigit().fontWeight(.semibold)
                        }
                        if node.isDirectory {
                            GridRow {
                                Text("파일 수").foregroundStyle(.secondary)
                                Text("\(Fmt.count(node.fileCount))개").monospacedDigit()
                            }
                        }
                        GridRow {
                            Text("마지막 변경").foregroundStyle(.secondary)
                            VStack(alignment: .leading, spacing: 1) {
                                Text("\(Fmt.date(node.modifiedDate)) (\(Fmt.ago(node.modifiedDate)))")
                                if let d = Fmt.days(since: node.modifiedDate), d > 365 {
                                    Text("1년 넘게 바뀌지 않았습니다").font(.caption).foregroundStyle(.orange)
                                } else if let d = Fmt.days(since: node.modifiedDate), d > 180 {
                                    Text("6개월 넘게 바뀌지 않았습니다").font(.caption).foregroundStyle(.orange)
                                }
                            }
                        }
                    }
                    .font(.callout)

                    Divider()
                    InsightCard(insight: ins)
                    Divider()
                    actions(node, ins)

                    if node.accessDenied {
                        Label("권한이 없어 이 폴더 안을 읽지 못했습니다. 실제 크기는 더 클 수 있습니다. 설정에서 전체 디스크 접근 권한을 켜세요.", systemImage: "lock")
                            .font(.callout).foregroundStyle(.orange)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                .padding(16)
            }
        } else {
            Text("항목을 선택하면\n무엇인지 알려 드립니다")
                .multilineTextAlignment(.center)
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    @ViewBuilder
    func actions(_ node: FileNode, _ ins: Insight) -> some View {
        let protected = Deleter.isProtected(node.path) || node.parent == nil
        VStack(alignment: .leading, spacing: 8) {
            Text("할 수 있는 일").font(.headline)
            if ins.safety == .keep {
                Label("직접 지우지 않는 것이 좋습니다. 위 안내대로 해당 앱이나 시스템 설정에서 정리하세요.", systemImage: "hand.raised")
                    .font(.callout).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            } else {
                switch ins.action {
                case .emptyContents where node.isDirectory && node.size > 0:
                    let permanent = ins.safety == .safe && !trashSafe
                    Button {
                        ExplorerActions.confirmEmpty(node, permanent: permanent, disk: disk, store: store)
                    } label: {
                        Label(permanent ? "내용 비우기 (바로 삭제)" : "내용 비우기 (휴지통)", systemImage: "wind")
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(disk.busy || Deleter.isProtected(node.path + "/x"))
                case .command(let title, let command, let admin):
                    Button {
                        store.ask(title, "다음 명령을 실행합니다:\n\n\(command)" + (admin ? "\n\n관리자 암호를 묻습니다." : ""), confirm: "실행", destructive: false) {
                            disk.runCommand(title, command, admin: admin)
                        }
                    } label: {
                        Label(title, systemImage: "terminal").frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(disk.busy)
                    Text(command).font(.system(.caption, design: .monospaced)).foregroundStyle(.secondary).textSelection(.enabled)
                default:
                    EmptyView()
                }
                if !protected {
                    Button(role: .destructive) {
                        ExplorerActions.confirmTrash(node, disk: disk, store: store)
                    } label: {
                        Label("휴지통으로 이동", systemImage: "trash").frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .disabled(disk.busy)
                }
            }
            HStack {
                Button { Finder.reveal(node.path) } label: { Label("Finder에서 보기", systemImage: "magnifyingglass") }
                Button { Finder.copy(node.path) } label: { Label("경로 복사", systemImage: "doc.on.doc") }
            }
            if node.isDirectory && node !== disk.current && !node.children.isEmpty {
                Button { disk.open(node) } label: { Label("이 폴더 안으로", systemImage: "arrow.down.right.circle") }
                    .buttonStyle(.link)
            }
            if disk.busy { ProgressView().controlSize(.small) }
        }
    }
}
