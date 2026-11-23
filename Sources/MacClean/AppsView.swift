import AppKit
import MacCleanCore
import SwiftUI

extension InstalledApp {
    var lastUsedSort: Date { lastSeen ?? .distantPast }
}

struct AppsView: View {
    @EnvironmentObject var store: AppStore
    @EnvironmentObject var apps: AppsModel
    @State private var selection: InstalledApp.ID?
    @State private var sortOrder = [KeyPathComparator(\InstalledApp.totalSize, order: .reverse)]
    @State private var showInspector = true
    @State private var search = ""
    @State private var onlyUnused = false

    var rows: [InstalledApp] {
        apps.apps
            .filter { search.isEmpty || $0.name.localizedCaseInsensitiveContains(search) || $0.bundleID.localizedCaseInsensitiveContains(search) }
            .filter { !onlyUnused || ($0.daysUnused ?? 9999) > 180 }
            .sorted(using: sortOrder)
    }

    var body: some View {
        let list = rows
        VStack(spacing: 0) {
            PaneHeader(title: "앱 관리", subtitle: "앱 본체와 앱이 라이브러리에 쌓은 데이터를 함께 보고, 안 쓰는 앱은 찌꺼기까지 지웁니다") {
                if apps.isLoading {
                    ProgressView(value: Double(apps.measured), total: Double(max(apps.apps.count, 1)))
                        .frame(width: 120)
                    Text("크기 계산 중 \(apps.measured)/\(apps.apps.count)").font(.caption).foregroundStyle(.secondary)
                }
                Button { apps.load() } label: { Label("새로 고침", systemImage: "arrow.clockwise") }
                    .disabled(apps.isLoading)
            }
            HStack(spacing: 12) {
                TextField("앱 검색", text: $search).textFieldStyle(.roundedBorder).frame(width: 220)
                Toggle("6개월 넘게 안 쓴 앱만", isOn: $onlyUnused).toggleStyle(.checkbox)
                Spacer()
                Text("\(list.count)개 · \(Fmt.bytes(list.reduce(0) { $0 + $1.totalSize }))").foregroundStyle(.secondary).monospacedDigit()
            }
            .padding(.horizontal, 20)
            .padding(.bottom, 10)
            Divider()
            Table(list, selection: $selection, sortOrder: $sortOrder) {
                TableColumn("앱", value: \.name) { a in
                    HStack(spacing: 8) {
                        FileIcon(path: a.path, size: 24)
                        VStack(alignment: .leading, spacing: 1) {
                            Text(a.name).lineLimit(1)
                            Text(a.version.flatMap { $0.isEmpty ? nil : "버전 \($0)" } ?? a.bundleID).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                        }
                    }
                }
                .width(min: 180, ideal: 230)
                TableColumn("합계", value: \.totalSize) { a in
                    Text(a.sized ? Fmt.bytes(a.totalSize) : "…").monospacedDigit().fontWeight(.medium)
                }
                .width(min: 70, ideal: 84)
                TableColumn("앱", value: \.appSize) { a in
                    Text(a.sized ? Fmt.bytes(a.appSize) : "…").monospacedDigit().foregroundStyle(.secondary)
                }
                .width(min: 70, ideal: 84)
                TableColumn("데이터", value: \.dataSize) { a in
                    Text(a.sized ? Fmt.bytes(a.dataSize) : "…").monospacedDigit().foregroundStyle(.secondary)
                }
                .width(min: 70, ideal: 84)
                TableColumn("마지막 사용", value: \.lastUsedSort) { a in
                    HStack(spacing: 6) {
                        Text(a.isRunning ? "실행 중" : Fmt.ago(a.lastSeen)).foregroundStyle(.secondary)
                        if let d = a.daysUnused, d > 180 { Tag(text: "안 씀", color: .orange) }
                    }
                    .help(a.lastSeenSource)
                }
                .width(min: 100, ideal: 130)
            }
            .overlay {
                if apps.apps.isEmpty && apps.isLoading { ProgressView("앱 목록 불러오는 중") }
            }
        }
        .inspector(isPresented: $showInspector) {
            AppInspector(app: apps.apps.first { $0.id == selection })
                .inspectorColumnWidth(min: 300, ideal: 360, max: 480)
        }
        .toolbar {
            ToolbarItem {
                Button { showInspector.toggle() } label: { Label("정보 패널", systemImage: "sidebar.trailing") }
            }
        }
        .onAppear { apps.loadIfNeeded() }
    }
}

struct AppInspector: View {
    let app: InstalledApp?
    @EnvironmentObject var store: AppStore
    @EnvironmentObject var apps: AppsModel
    @State private var excluded: Set<String> = []

    var body: some View {
        if let app {
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    HStack(spacing: 12) {
                        FileIcon(path: app.path, size: 52)
                        VStack(alignment: .leading, spacing: 3) {
                            Text(app.name).font(.title3.weight(.semibold))
                            Text(app.bundleID).font(.caption).foregroundStyle(.secondary).textSelection(.enabled)
                            HStack(spacing: 4) {
                                if app.isAppStore { Tag(text: "App Store", color: .blue) }
                                if AppRegistry.shared.isRunning(bundleID: app.bundleID) { Tag(text: "실행 중", color: .orange) }
                            }
                        }
                    }
                    Grid(alignment: .leading, horizontalSpacing: 14, verticalSpacing: 6) {
                        GridRow { Text("앱 크기").foregroundStyle(.secondary); Text(app.sized ? Fmt.bytes(app.appSize) : "계산 중").monospacedDigit() }
                        GridRow { Text("관련 데이터").foregroundStyle(.secondary); Text(app.sized ? Fmt.bytes(app.dataSize) : "계산 중").monospacedDigit() }
                        GridRow { Text("합계").foregroundStyle(.secondary); Text(app.sized ? Fmt.bytes(app.totalSize) : "계산 중").monospacedDigit().fontWeight(.semibold) }
                        GridRow {
                            Text("마지막 사용").foregroundStyle(.secondary)
                            VStack(alignment: .leading, spacing: 1) {
                                Text(app.isRunning ? "지금 실행 중" : (app.lastSeen.map { "\(Fmt.date($0)) (\(Fmt.ago($0)))" } ?? "기록 없음"))
                                if !app.isRunning && app.lastSeen != nil { Text("기준: \(app.lastSeenSource)").font(.caption).foregroundStyle(.secondary) }
                            }
                        }
                    }
                    .font(.callout)

                    verdict(app)

                    if !app.related.isEmpty {
                        Text("앱이 남긴 데이터").font(.headline)
                        VStack(spacing: 6) {
                            ForEach(app.related) { r in
                                HStack(spacing: 8) {
                                    Toggle("", isOn: Binding(get: { !excluded.contains(r.path) },
                                                             set: { on in if on { excluded.remove(r.path) } else { excluded.insert(r.path) } }))
                                        .toggleStyle(.checkbox).labelsHidden()
                                    VStack(alignment: .leading, spacing: 1) {
                                        Text(r.label).font(.callout)
                                        Text(Paths.abbreviate(r.path)).font(.caption).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
                                    }
                                    Spacer()
                                    Text(Fmt.bytes(r.size)).font(.callout).monospacedDigit()
                                    Button { Finder.reveal(r.path) } label: { Image(systemName: "magnifyingglass") }.buttonStyle(.borderless)
                                }
                            }
                        }
                        Text("앱 데이터를 지우면 설정·로그인·기록이 사라집니다. 나중에 다시 설치할 수도 있다면 데이터 체크를 풀고 앱만 지우세요.")
                            .font(.caption).foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    } else if app.sized {
                        Text("라이브러리에서 이 앱의 데이터를 찾지 못했습니다.").font(.callout).foregroundStyle(.secondary)
                    }

                    let relatedPaths = app.related.map(\.path).filter { !excluded.contains($0) }
                    let relatedSize = app.related.filter { !excluded.contains($0.path) }.reduce(0) { $0 + $1.size }
                    Button(role: .destructive) {
                        store.ask("\(app.name)을(를) 삭제할까요?",
                                  "앱(\(Fmt.bytes(app.appSize)))" + (relatedPaths.isEmpty ? "" : "과 관련 데이터 \(relatedPaths.count)곳(\(Fmt.bytes(relatedSize)))") + "을 휴지통으로 옮깁니다. 실행 중이면 먼저 종료합니다. 관리자 권한이 필요한 앱은 암호를 물을 수 있습니다.",
                                  confirm: "삭제") {
                            apps.uninstall(app, related: relatedPaths)
                        }
                    } label: {
                        Label("앱 삭제 (휴지통으로)", systemImage: "trash").frame(maxWidth: .infinity)
                    }
                    .controlSize(.large)
                    .disabled(!app.sized || apps.busy)
                    if apps.busy { ProgressView().controlSize(.small) }
                    Button { Finder.reveal(app.path) } label: { Label("Finder에서 보기", systemImage: "magnifyingglass") }
                        .buttonStyle(.link)
                }
                .padding(16)
            }
            .onChange(of: app.id) { excluded = [] }
        } else {
            Text("앱을 선택하면 남긴 데이터와\n삭제 방법을 보여 드립니다")
                .multilineTextAlignment(.center)
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    @ViewBuilder
    func verdict(_ app: InstalledApp) -> some View {
        let days = app.daysUnused
        let (icon, color, text): (String, Color, String) = {
            if let d = days, d > 365 { return ("exclamationmark.circle.fill", .orange, "1년 넘게 쓰지 않았습니다. 필요 없다면 삭제를 고려하세요.") }
            if let d = days, d > 180 { return ("exclamationmark.circle", .orange, "6개월 넘게 쓰지 않았습니다.") }
            if app.isWebAppShim { return ("globe", .secondary, "브라우저에서 만든 웹 앱 바로가기입니다. 실제 데이터는 브라우저에 있습니다.") }
            if days == nil { return ("questionmark.circle", .secondary, "사용 기록이 없습니다. 설치 후 한 번도 열지 않았을 수 있습니다.") }
            return ("checkmark.circle", .green, "최근에 사용한 앱입니다.")
        }()
        Label(text, systemImage: icon)
            .font(.callout).foregroundStyle(color)
            .fixedSize(horizontal: false, vertical: true)
    }
}
