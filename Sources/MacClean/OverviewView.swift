import MacCleanCore
import SwiftUI

struct OverviewView: View {
    @EnvironmentObject var store: AppStore
    @EnvironmentObject var volume: VolumeModel
    @EnvironmentObject var cleanup: CleanupModel
    @EnvironmentObject var memory: MemoryModel

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Mac 상태 한눈에 보기").font(.largeTitle.weight(.bold))
                    Text("어디에 무엇이 있는지, 지워도 되는지를 판정해서 보여 줍니다.")
                        .foregroundStyle(.secondary)
                }
                PermissionBanner()
                HStack(alignment: .top, spacing: 16) {
                    diskCard
                    memoryCard
                }
                reclaimCard
                biggestCard
            }
            .padding(24)
        }
    }

    // MARK: 디스크

    var diskCard: some View {
        Card(title: "디스크", symbol: "internaldrive") {
            if let v = volume.stats {
                VStack(alignment: .leading, spacing: 10) {
                    HStack(alignment: .firstTextBaseline) {
                        Text(Fmt.bytes(v.free)).font(.system(size: 34, weight: .bold, design: .rounded)).monospacedDigit()
                        Text("남음").foregroundStyle(.secondary)
                        Spacer()
                        Text(Fmt.percent(v.usedFraction) + " 사용").foregroundStyle(v.usedFraction > 0.9 ? .orange : .secondary)
                    }
                    SegmentBar(segments: [
                        .init(id: "used", value: Double(v.used - v.purgeable), color: Palette.usage(v.usedFraction), label: "사용 중"),
                        .init(id: "purge", value: Double(v.purgeable), color: Palette.slate, label: "퍼지 가능"),
                    ], total: Double(v.total), height: 16)
                    HStack(spacing: 14) {
                        LegendDot(color: Palette.usage(v.usedFraction), label: "사용", value: Fmt.bytes(v.used))
                        LegendDot(color: Palette.slate, label: "퍼지 가능", value: Fmt.bytes(v.purgeable))
                        LegendDot(color: .primary.opacity(0.15), label: "전체", value: Fmt.bytes(v.total))
                    }
                    if v.usedFraction > 0.9 {
                        Label("여유 공간이 10% 미만입니다. macOS 업데이트, 스왑, 앱 캐시에 쓸 공간이 부족해 느려질 수 있습니다.", systemImage: "exclamationmark.triangle.fill")
                            .font(.callout).foregroundStyle(.orange)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    if v.purgeable > 500_000_000 {
                        Text("'퍼지 가능'은 iCloud 사본·Time Machine 스냅샷처럼 공간이 부족해지면 macOS가 자동으로 비우는 공간입니다.")
                            .font(.caption).foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
            } else {
                ProgressView()
            }
        }
    }

    // MARK: 메모리

    var memoryCard: some View {
        let s = memory.stats
        return Card(title: "메모리", symbol: "memorychip") {
            VStack(alignment: .leading, spacing: 10) {
                HStack(alignment: .firstTextBaseline) {
                    Text(Fmt.memory(s.used)).font(.system(size: 34, weight: .bold, design: .rounded)).monospacedDigit()
                    Text("/ \(Fmt.memory(s.total)) 사용").foregroundStyle(.secondary)
                    Spacer()
                    Tag(text: "압력 \(s.pressureLabel)", color: pressureColor(s.pressureLevel), icon: "gauge.with.dots.needle.50percent")
                }
                SegmentBar(segments: MemoryView.segments(s), total: Double(s.total), height: 16)
                HStack(spacing: 14) {
                    LegendDot(color: Palette.blue, label: "앱", value: Fmt.memory(s.appMemory))
                    LegendDot(color: Palette.amber, label: "와이어드", value: Fmt.memory(s.wired))
                    LegendDot(color: Palette.lavender, label: "압축", value: Fmt.memory(s.compressed))
                    LegendDot(color: Palette.slate, label: "캐시", value: Fmt.memory(s.cached))
                }
                if let first = memory.insights.first {
                    Label(first.text, systemImage: first.icon)
                        .font(.callout).foregroundStyle(first.color)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Button("메모리 자세히 보기") { store.pane = .memory }.buttonStyle(.link)
            }
        }
    }

    func pressureColor(_ level: Int) -> Color { Palette.pressure(level) }

    // MARK: 정리 가능

    var reclaimCard: some View {
        Card(title: "정리할 수 있는 공간", symbol: "sparkles",
             trailing: AnyView(Button(cleanup.isScanning ? "검사 중…" : "다시 검사") { cleanup.scan() }.disabled(cleanup.isScanning))) {
            if cleanup.isScanning && cleanup.groups.isEmpty {
                HStack(spacing: 10) {
                    ProgressView().controlSize(.small)
                    Text(cleanup.status).foregroundStyle(.secondary)
                }
                .padding(.vertical, 8)
            } else if cleanup.groups.isEmpty {
                Text("검사를 실행하면 캐시, 빌드 산출물, 오래된 다운로드, 삭제된 앱의 잔여 파일을 찾아 줍니다.")
                    .foregroundStyle(.secondary)
            } else {
                VStack(alignment: .leading, spacing: 12) {
                    HStack(alignment: .firstTextBaseline, spacing: 20) {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(Fmt.bytes(cleanup.safeTotal)).font(.system(size: 30, weight: .bold, design: .rounded)).foregroundStyle(Palette.sage).monospacedDigit()
                            Text("바로 지워도 안전").font(.caption).foregroundStyle(.secondary)
                        }
                        VStack(alignment: .leading, spacing: 2) {
                            Text(Fmt.bytes(max(0, cleanup.actionableTotal - cleanup.safeTotal))).font(.system(size: 30, weight: .bold, design: .rounded)).foregroundStyle(Palette.blue).monospacedDigit()
                            Text("확인 후 정리 가능").font(.caption).foregroundStyle(.secondary)
                        }
                        Spacer()
                        Button {
                            store.pane = .cleanup
                        } label: {
                            Label("정리 추천 보기", systemImage: "arrow.right")
                        }
                        .buttonStyle(.borderedProminent)
                        .controlSize(.large)
                    }
                    let groups = cleanup.groups.filter { $0.totalSize > 0 }.sorted { $0.totalSize > $1.totalSize }
                    let maxSize = Double(groups.first?.totalSize ?? 1)
                    VStack(spacing: 7) {
                        ForEach(groups) { g in
                            HStack(spacing: 10) {
                                Image(systemName: g.symbol).frame(width: 18).foregroundStyle(.secondary)
                                Text(g.title).frame(width: 190, alignment: .leading).lineLimit(1)
                                SizeBar(fraction: Double(g.totalSize) / maxSize, color: Palette.teal)
                                Text(Fmt.bytes(g.totalSize)).monospacedDigit().frame(width: 80, alignment: .trailing)
                            }
                            .font(.callout)
                        }
                    }
                }
            }
        }
    }

    // MARK: 가장 큰 항목

    var biggestCard: some View {
        let items = cleanup.allItems.filter { $0.size > 500_000_000 }.sorted { $0.size > $1.size }.prefix(8)
        return Card(title: "공간을 가장 많이 차지하는 것", symbol: "chart.bar.doc.horizontal") {
            if items.isEmpty {
                Text(cleanup.isScanning ? "검사 중입니다…" : "검사 결과가 없습니다. 더 자세히 보려면 '디스크 탐색'에서 홈 폴더를 스캔하세요.")
                    .foregroundStyle(.secondary)
            } else {
                VStack(spacing: 0) {
                    ForEach(Array(items)) { it in
                        HStack(spacing: 12) {
                            Image(systemName: it.kind.symbol).foregroundStyle(it.kind.color).frame(width: 22)
                            VStack(alignment: .leading, spacing: 2) {
                                Text(it.title).lineLimit(1)
                                Text(it.subtitle).font(.caption).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
                            }
                            Spacer()
                            SafetyBadge(safety: it.safety, compact: true)
                            Text(Fmt.bytes(it.size)).monospacedDigit().frame(width: 84, alignment: .trailing).font(.callout.weight(.medium))
                        }
                        .padding(.vertical, 7)
                        Divider()
                    }
                }
                HStack {
                    Text("폴더 단위로 직접 살펴보려면 디스크 탐색을 쓰세요.").font(.caption).foregroundStyle(.secondary)
                    Spacer()
                    Button("디스크 탐색 열기") { store.pane = .explorer }.buttonStyle(.link)
                }
            }
        }
    }
}
