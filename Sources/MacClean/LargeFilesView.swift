import MacCleanCore
import SwiftUI

extension LargeFile {
    var modifiedSort: Date { modified ?? .distantPast }
    var openedSort: Date { lastOpened ?? modified ?? .distantPast }
}

struct LargeFilesView: View {
    @EnvironmentObject var store: AppStore
    @EnvironmentObject var large: LargeFilesModel
    @EnvironmentObject var disk: DiskModel
    @State private var selection = Set<String>()
    @State private var sortOrder = [KeyPathComparator(\LargeFile.size, order: .reverse)]
    @State private var minSize: Int64 = 100_000_000
    @State private var age = 0
    @State private var kind = "all"

    var filtered: [LargeFile] {
        large.files.filter { f in
            guard f.size >= minSize else { return false }
            if age > 0, let d = Fmt.days(since: f.lastOpened ?? f.modified), d < age { return false }
            if kind != "all" {
                let k = PathKnowledge.shared.insight(for: f.path, isDirectory: false).kind
                switch kind {
                case "video": if k != .video { return false }
                case "installer": if ![.installer, .archive].contains(k) { return false }
                case "vm": if ![.virtualMachine, .aiModel].contains(k) { return false }
                case "deletable": if PathKnowledge.shared.insight(for: f.path, isDirectory: false).safety > .review { return false }
                default: break
                }
            }
            return true
        }
        .sorted(using: sortOrder)
    }

    var body: some View {
        let rows = filtered
        VStack(spacing: 0) {
            PaneHeader(title: "대용량 파일", subtitle: large.includesLibrary
                       ? "디스크 탐색 결과와 Spotlight 검색을 합친 목록입니다"
                       : "Spotlight로 찾은 목록입니다. 라이브러리·숨김 폴더까지 보려면 디스크 탐색에서 홈 폴더를 스캔하세요") {
                if large.isLoading { ProgressView().controlSize(.small) }
                Button { large.loadSpotlight() } label: { Label("새로 고침", systemImage: "arrow.clockwise") }
                if !large.includesLibrary {
                    Button("홈 폴더 스캔") { disk.scan(.home); store.pane = .explorer }
                }
            }
            HStack(spacing: 14) {
                Picker("최소 크기", selection: $minSize) {
                    Text("50 MB 이상").tag(Int64(50_000_000))
                    Text("100 MB 이상").tag(Int64(100_000_000))
                    Text("500 MB 이상").tag(Int64(500_000_000))
                    Text("1 GB 이상").tag(Int64(1_000_000_000))
                }
                .fixedSize()
                Picker("사용", selection: $age) {
                    Text("전체 기간").tag(0)
                    Text("3개월 넘게 안 씀").tag(90)
                    Text("6개월 넘게 안 씀").tag(180)
                    Text("1년 넘게 안 씀").tag(365)
                }
                .fixedSize()
                Picker("종류", selection: $kind) {
                    Text("모든 종류").tag("all")
                    Text("지워도 될 만한 것").tag("deletable")
                    Text("동영상").tag("video")
                    Text("설치·압축 파일").tag("installer")
                    Text("가상머신·AI 모델").tag("vm")
                }
                .fixedSize()
                Spacer()
                Text("\(rows.count)개 · \(Fmt.bytes(rows.reduce(0) { $0 + $1.size }))").foregroundStyle(.secondary).monospacedDigit()
            }
            .padding(.horizontal, 20)
            .padding(.bottom, 10)
            Divider()

            Table(rows, selection: $selection, sortOrder: $sortOrder) {
                TableColumn("이름", value: \.name) { f in
                    HStack(spacing: 8) {
                        FileIcon(path: f.path, size: 20)
                        VStack(alignment: .leading, spacing: 1) {
                            Text(f.name).lineLimit(1).truncationMode(.middle)
                            Text(f.location).font(.caption).foregroundStyle(.secondary).lineLimit(1).truncationMode(.head)
                        }
                    }
                }
                .width(min: 240, ideal: 360)
                TableColumn("크기", value: \.size) { f in
                    Text(Fmt.bytes(f.size)).monospacedDigit()
                }
                .width(min: 70, ideal: 84)
                TableColumn("무엇인가요") { f in
                    let ins = PathKnowledge.shared.insight(for: f.path, isDirectory: false)
                    HStack(spacing: 6) {
                        SafetyBadge(safety: ins.safety, compact: true)
                        Text(ins.title).lineLimit(1).help(ins.detail)
                    }
                }
                .width(min: 160, ideal: 240)
                TableColumn("수정일", value: \.modifiedSort) { f in
                    Text(Fmt.date(f.modified)).foregroundStyle(.secondary).monospacedDigit()
                }
                .width(min: 70, ideal: 84)
                TableColumn("마지막으로 연 날", value: \.openedSort) { f in
                    let days = Fmt.days(since: f.lastOpened)
                    Text(f.lastOpened == nil ? "기록 없음" : Fmt.ago(f.lastOpened))
                        .foregroundStyle((days ?? 0) > 365 ? .orange : .secondary)
                }
                .width(min: 80, ideal: 100)
            }
            .contextMenu(forSelectionType: String.self) { ids in
                Button("Finder에서 보기") { ids.first.map(Finder.reveal) }
                Button("경로 복사") { Finder.copy(ids.joined(separator: "\n")) }
                Divider()
                Button("휴지통으로 이동", role: .destructive) { confirmTrash(ids) }
            } primaryAction: { ids in
                ids.first.map(Finder.reveal)
            }
            .overlay {
                if rows.isEmpty && !large.isLoading {
                    Text(large.files.isEmpty ? "찾은 파일이 없습니다" : "조건에 맞는 파일이 없습니다").foregroundStyle(.secondary)
                }
            }

            HStack {
                if let f = rows.first(where: { selection.contains($0.id) }), selection.count == 1 {
                    let ins = PathKnowledge.shared.insight(for: f.path, isDirectory: false)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(ins.title).font(.callout.weight(.semibold))
                        Text(ins.detail).font(.caption).foregroundStyle(.secondary).lineLimit(2)
                    }
                } else {
                    Text("\(selection.count)개 선택 · \(Fmt.bytes(large.files.filter { selection.contains($0.id) }.reduce(0) { $0 + $1.size }))")
                        .font(.callout).monospacedDigit()
                }
                Spacer()
                Button("Finder에서 보기") { selection.first.map(Finder.reveal) }.disabled(selection.isEmpty)
                Button("휴지통으로 이동", role: .destructive) { confirmTrash(selection) }
                    .buttonStyle(.borderedProminent)
                    .disabled(selection.isEmpty)
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 10)
            .background(.bar)
        }
        .onAppear { large.loadIfNeeded() }
    }

    func confirmTrash(_ ids: Set<String>) {
        let files = large.files.filter { ids.contains($0.id) }
        guard !files.isEmpty else { return }
        let risky = files.filter { PathKnowledge.shared.insight(for: $0.path, isDirectory: false).safety >= .caution }
        var msg = "\(files.count)개 파일(\(Fmt.bytes(files.reduce(0) { $0 + $1.size })))을 휴지통으로 옮깁니다."
        if !risky.isEmpty {
            msg += "\n\n⚠️ '주의' 이상 항목이 \(risky.count)개 있습니다: " + risky.prefix(3).map(\.name).joined(separator: ", ")
                + ". 앱 데이터나 가상 디스크일 수 있으니 확인하세요."
        }
        store.ask("휴지통으로 이동할까요?", msg, confirm: "휴지통으로 이동") {
            large.trash(ids)
            selection.subtract(ids)
        }
    }
}
