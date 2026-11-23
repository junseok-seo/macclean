import Charts
import MacCleanCore
import SwiftUI

struct MemoryView: View {
    @EnvironmentObject var store: AppStore
    @EnvironmentObject var memory: MemoryModel
    @State private var selection: ProcessGroup.ID?
    @State private var sortOrder = [KeyPathComparator(\ProcessGroup.memory, order: .reverse)]
    @State private var showSystem = false
    @State private var showGlossary = false

    static func segments(_ s: MemoryStats) -> [SegmentBar.Segment] {
        [
            .init(id: "app", value: Double(s.appMemory), color: Palette.blue, label: "앱 메모리 \(Fmt.memory(s.appMemory))"),
            .init(id: "wired", value: Double(s.wired), color: Palette.amber, label: "와이어드 \(Fmt.memory(s.wired))"),
            .init(id: "comp", value: Double(s.compressed), color: Palette.lavender, label: "압축됨 \(Fmt.memory(s.compressed))"),
            .init(id: "cache", value: Double(s.cached), color: Palette.slate, label: "캐시된 파일 \(Fmt.memory(s.cached))"),
        ]
    }

    var rows: [ProcessGroup] {
        memory.groups.filter { showSystem || !$0.isSystem || $0.isApp }.sorted(using: sortOrder)
    }

    var body: some View {
        let s = memory.stats
        VStack(spacing: 0) {
            PaneHeader(title: "메모리", subtitle: "지금 메모리가 부족한지, 어떤 앱이 많이 쓰는지 판단합니다") {
                Tag(text: "CPU " + (memory.cpu.map { Fmt.percent($0) } ?? "–"), color: (memory.cpu ?? 0) > 0.85 ? .orange : .secondary, icon: "cpu")
                Tag(text: "GPU " + (memory.gpu.map { Fmt.percent($0) } ?? "–"), color: (memory.gpu ?? 0) > 0.9 ? .orange : .secondary, icon: "square.stack.3d.up")
                Button { showGlossary.toggle() } label: { Label("용어 설명", systemImage: "questionmark.circle") }
                    .popover(isPresented: $showGlossary) { glossary }
            }
            Divider()
            HStack(alignment: .top, spacing: 14) {
                pressureCard(s).frame(width: 200)
                breakdownCard(s)
                chartCard(s).frame(width: 290)
            }
            .fixedSize(horizontal: false, vertical: true)
            .padding(16)

            Divider()
            HStack(spacing: 0) {
                VStack(spacing: 0) {
                    HStack {
                        Text("앱별 메모리 사용량").font(.headline)
                        Text("헬퍼·가상머신 포함").font(.caption).foregroundStyle(.secondary)
                        Spacer()
                        Toggle("시스템 프로세스 표시", isOn: $showSystem).toggleStyle(.checkbox)
                    }
                    .padding(.horizontal, 16)
                    .padding(.vertical, 8)
                    processTable
                    Text("다른 사용자·시스템 소유 프로세스 \(memory.hidden)개는 권한 때문에 표시하지 않습니다.")
                        .font(.caption).foregroundStyle(.secondary)
                        .padding(.vertical, 6)
                }
                Divider()
                ScrollView { insightsPanel.padding(16) }
                    .frame(width: 330)
            }
        }
        .onAppear { memory.detailVisible = true }
        .onDisappear { memory.detailVisible = false }
    }

    var processTable: some View {
        Table(rows, selection: $selection, sortOrder: $sortOrder) {
            TableColumn("이름", value: \.name) { g in
                HStack(spacing: 8) {
                    if let b = g.bundlePath { FileIcon(path: b, size: 18) }
                    else { Image(systemName: "gearshape").frame(width: 18).foregroundStyle(.secondary) }
                    Text(g.name).lineLimit(1)
                    if g.processCount > 1 { Text("×\(g.processCount)").font(.caption).foregroundStyle(.secondary) }
                    if g.vmMemory > 0 { Tag(text: "가상머신 \(Fmt.memory(g.vmMemory))", color: Palette.lavender, icon: "cpu") }
                }
                .help(g.note?.text ?? g.name)
            }
            .width(min: 180, ideal: 280)
            TableColumn("메모리", value: \.memory) { g in
                Text(Fmt.memory(g.memory)).monospacedDigit().fontWeight(g.memory > 1_000_000_000 ? .semibold : .regular)
            }
            .width(min: 70, ideal: 86)
            TableColumn("CPU", value: \.cpuPercent) { g in
                Text(String(format: "%.1f%%", g.cpuPercent)).monospacedDigit().foregroundStyle(.secondary)
            }
            .width(min: 50, ideal: 60)
            TableColumn("설명") { g in
                Text(g.note?.text ?? "").font(.caption).foregroundStyle(.secondary).lineLimit(2).help(g.note?.text ?? "")
            }
            .width(min: 120, ideal: 260)
            TableColumn("") { g in
                let canQuit = !ProcessKnowledge.critical.contains(g.name) && (g.note?.canQuit ?? !g.isSystem)
                HStack(spacing: 6) {
                    Button("종료") { confirmQuit(g, force: false) }.disabled(!canQuit)
                    Button("강제") { confirmQuit(g, force: true) }.disabled(!canQuit).help("응답하지 않을 때만 사용하세요")
                }
                .controlSize(.small)
            }
            .width(104)
        }
    }

    func confirmQuit(_ g: ProcessGroup, force: Bool) {
        store.ask(force ? "\(g.name) 강제 종료" : "\(g.name) 종료",
                  force ? "강제로 종료하면 저장하지 않은 작업이 사라집니다. 앱이 응답하지 않을 때만 사용하세요."
                        : "앱에 종료를 요청합니다. 저장하지 않은 작업이 있으면 앱이 저장 여부를 묻습니다. \(Fmt.memory(g.memory))가 회수됩니다.",
                  confirm: force ? "강제 종료" : "종료", destructive: force) {
            memory.quit(g, force: force)
        }
    }

    func pressureColor(_ level: Int) -> Color { Palette.pressure(level) }

    func pressureCard(_ s: MemoryStats) -> some View {
        Card(title: "메모리 압력", symbol: "gauge.with.dots.needle.50percent") {
            VStack(spacing: 8) {
                Gauge(value: Double(100 - s.availablePercent), in: 0...100) {
                    EmptyView()
                } currentValueLabel: {
                    Text(s.pressureLabel).font(.title3.weight(.bold)).foregroundStyle(pressureColor(s.pressureLevel))
                }
                .gaugeStyle(.accessoryCircularCapacity)
                .tint(pressureColor(s.pressureLevel))
                .scaleEffect(1.35)
                .frame(height: 76)
                Text("사용 가능 \(s.availablePercent)%").font(.caption).foregroundStyle(.secondary)
                Text("숫자보다 이 '압력'이 중요합니다. 초록이면 충분합니다.").font(.caption2).foregroundStyle(.tertiary)
                    .multilineTextAlignment(.center)
            }
            .frame(maxWidth: .infinity)
        }
    }

    func breakdownCard(_ s: MemoryStats) -> some View {
        Card(title: "사용 내역", symbol: "memorychip") {
            VStack(alignment: .leading, spacing: 10) {
                HStack(alignment: .firstTextBaseline) {
                    Text(Fmt.memory(s.used)).font(.system(size: 28, weight: .bold, design: .rounded)).monospacedDigit()
                    Text("/ \(Fmt.memory(s.total)) 사용 중").foregroundStyle(.secondary)
                }
                SegmentBar(segments: Self.segments(s), total: Double(s.total), height: 16)
                Grid(alignment: .leading, horizontalSpacing: 16, verticalSpacing: 4) {
                    GridRow {
                        LegendDot(color: Palette.blue, label: "앱 메모리", value: Fmt.memory(s.appMemory))
                        LegendDot(color: Palette.amber, label: "와이어드", value: Fmt.memory(s.wired))
                    }
                    GridRow {
                        LegendDot(color: Palette.lavender, label: "압축됨", value: Fmt.memory(s.compressed))
                        LegendDot(color: Palette.slate, label: "캐시된 파일", value: Fmt.memory(s.cached))
                    }
                    GridRow {
                        LegendDot(color: .primary.opacity(0.2), label: "여유", value: Fmt.memory(s.free))
                        LegendDot(color: s.swapUsed > 2_000_000_000 ? Palette.amber : .secondary, label: "스왑", value: Fmt.memory(s.swapUsed))
                    }
                }
            }
        }
    }

    func chartCard(_ s: MemoryStats) -> some View {
        Card(title: "최근 5분", symbol: "chart.xyaxis.line") {
            Chart(memory.history) { p in
                AreaMark(x: .value("시간", p.time), y: .value("사용", p.used))
                    .foregroundStyle(Palette.blue.opacity(0.22))
                LineMark(x: .value("시간", p.time), y: .value("사용", p.used), series: .value("종류", "사용"))
                    .foregroundStyle(Palette.blue)
                LineMark(x: .value("시간", p.time), y: .value("스왑", p.swap), series: .value("종류", "스왑"))
                    .foregroundStyle(Palette.amber)
            }
            .chartYScale(domain: 0...(Double(s.total) / 1_073_741_824))
            .chartYAxis { AxisMarks(position: .leading) { v in AxisGridLine(); AxisValueLabel { if let d = v.as(Double.self) { Text("\(Int(d))GB") } } } }
            .chartXAxis(.hidden)
            .frame(height: 110)
            HStack(spacing: 12) {
                LegendDot(color: Palette.blue, label: "사용")
                LegendDot(color: Palette.amber, label: "스왑")
            }
        }
    }

    var insightsPanel: some View {
        VStack(alignment: .leading, spacing: 12) {
            Label("지금 상태 해석", systemImage: "lightbulb").font(.headline)
            ForEach(Array(memory.insights.enumerated()), id: \.offset) { _, i in
                Label { Text(i.text).fixedSize(horizontal: false, vertical: true) } icon: { Image(systemName: i.icon).foregroundStyle(i.color) }
                    .font(.callout)
            }
            Divider()
            Label("메모리 정리 (purge)", systemImage: "wind").font(.headline)
            Text("캐시된 파일만 비웁니다. macOS는 캐시를 필요할 때 즉시 내주므로 보통 효과가 없고, 비운 뒤 잠시 느려질 수 있습니다. 메모리가 부족하다면 왼쪽 목록에서 많이 쓰는 앱을 종료하는 것이 확실합니다.")
                .font(.caption).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            Button {
                memory.purge()
            } label: {
                if memory.purging { ProgressView().controlSize(.small) } else { Text("메모리 정리 실행 (관리자 암호)") }
            }
            .disabled(memory.purging)
        }
    }

    var glossary: some View {
        VStack(alignment: .leading, spacing: 10) {
            term(Palette.blue, "앱 메모리", "실행 중인 앱이 직접 쓰는 메모리입니다. 앱을 종료하면 돌아옵니다.")
            term(Palette.amber, "와이어드", "macOS 커널과 드라이버가 고정해서 쓰는 메모리입니다. 압축하거나 내보낼 수 없습니다.")
            term(Palette.lavender, "압축됨", "한동안 안 쓴 메모리를 압축해 공간을 아낀 것입니다. 디스크(스왑)보다 훨씬 빠릅니다.")
            term(Palette.slate, "캐시된 파일", "최근에 연 파일을 기억해 둔 것입니다. 다른 앱이 필요하면 즉시 내주므로 사실상 여유 공간입니다.")
            term(.secondary, "스왑", "메모리가 부족해 디스크로 내보낸 것입니다. 많고 계속 늘어나면 메모리가 부족하다는 뜻입니다.")
            term(Palette.sage, "메모리 압력", "위 숫자들을 종합한 실제 부족 정도입니다. 초록(정상)이면 사용량이 높아 보여도 문제없습니다.")
        }
        .padding(16)
        .frame(width: 380)
    }

    func term(_ color: Color, _ title: String, _ text: String) -> some View {
        HStack(alignment: .top, spacing: 8) {
            Circle().fill(color).frame(width: 9, height: 9).padding(.top, 5)
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.callout.weight(.semibold))
                Text(text).font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
        }
    }
}
