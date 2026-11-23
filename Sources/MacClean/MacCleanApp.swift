import AppKit
import MacCleanCore
import SwiftUI

final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.regular)
        disableDatalessMaterialization()
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        !UserDefaults.standard.bool(forKey: Prefs.showMenuBar)
    }

    /// 메뉴 막대로 내려놓은 상태에서 앱을 다시 열면 숨겨 둔 창을 보여 준다 (새 창을 만들지 않음)
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        if !flag, WindowManager.shared.mainWindow != nil {
            WindowManager.shared.showMain()
            return false
        }
        return true
    }
}

@main
struct MacCleanApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate
    @StateObject private var store = AppStore()
    var body: some Scene {
        WindowGroup("MacClean", id: "main") {
            ContentView()
                .injectModels(store)
                .frame(minWidth: 1060, minHeight: 680)
        }
        .defaultSize(width: 1240, height: 800)
        .commands {
            CommandGroup(replacing: .appInfo) { AboutCommand(store: store) }
            CommandGroup(replacing: .help) { HelpCommands(store: store) }
            CommandGroup(replacing: .newItem) {}
            CommandMenu("검사") {
                Button("정리 추천 다시 검사") { store.cleanup.scan(); store.pane = .cleanup }
                    .keyboardShortcut("r", modifiers: [.command])
                Button("홈 폴더 스캔") { store.disk.scan(.home); store.pane = .explorer }
                    .keyboardShortcut("s", modifiers: [.command, .shift])
            }
            CommandGroup(after: .windowSize) {
                Button("메뉴 막대로 내려놓기") { WindowManager.shared.putDown() }
                    .keyboardShortcut("m", modifiers: [.command, .option])
            }
        }


        Settings {
            SettingsView().injectModels(store).frame(width: 560).padding(20)
        }

        Window("MacClean 도움말", id: "help") {
            HelpView().injectModels(store)
        }
        .defaultSize(width: 1000, height: 760)

        Window("MacClean 정보", id: "about") {
            AboutView().injectModels(store)
        }
        .windowResizability(.contentSize)
    }
}

extension View {
    func injectModels(_ store: AppStore) -> some View {
        environmentObject(store)
            .environmentObject(store.volume)
            .environmentObject(store.permissions)
            .environmentObject(store.disk)
            .environmentObject(store.cleanup)
            .environmentObject(store.memory)
            .environmentObject(store.apps)
            .environmentObject(store.large)
            .environmentObject(store.updates)
    }
}

// MARK: - 메인 창

struct ContentView: View {
    @Environment(\.openWindow) private var openWindow
    @EnvironmentObject var store: AppStore
    @EnvironmentObject var volume: VolumeModel
    @EnvironmentObject var permissions: PermissionModel
    @EnvironmentObject var cleanup: CleanupModel
    @EnvironmentObject var memory: MemoryModel

    var body: some View {
        NavigationSplitView {
            List(selection: $store.pane) {
                ForEach([Pane.overview, .cleanup, .explorer, .largeFiles, .apps, .memory]) { p in
                    row(p).tag(p)
                }
                Section {
                    Label(Pane.settings.title, systemImage: Pane.settings.symbol).tag(Pane.settings)
                }
            }
            .navigationSplitViewColumnWidth(min: 200, ideal: 214, max: 260)
            .safeAreaInset(edge: .bottom) { SidebarFooter() }
        } detail: {
            ZStack(alignment: .top) {
                detail
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                if let t = store.toast {
                    ToastView(toast: t)
                        .padding(.top, 10)
                        .transition(.move(edge: .top).combined(with: .opacity))
                        .onTapGesture { store.toast = nil }
                }
            }
            .animation(.spring(duration: 0.3), value: store.toast)
        }
        .background(WindowAccessor { WindowManager.shared.attach($0) })
        .onAppear {
            WindowManager.shared.openMain = { openWindow(id: "main") }
            WindowManager.shared.openAux = { id in
                NSApp.activate()
                openWindow(id: id)
            }
            store.startIfNeeded()
        }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            permissions.refresh()
            volume.refresh()
        }
        .sheet(item: $store.reportSheet) { ReportView(sheet: $0) }
        .alert(store.confirm?.title ?? "", isPresented: Binding(get: { store.confirm != nil }, set: { if !$0 { store.confirm = nil } }),
               presenting: store.confirm) { req in
            Button(req.confirmLabel, role: req.destructive ? .destructive : nil) { req.action() }
            Button("취소", role: .cancel) {}
        } message: { req in
            Text(req.message)
        }
    }

    @ViewBuilder
    func row(_ p: Pane) -> some View {
        switch p {
        case .cleanup where cleanup.isScanning:
            Label(p.title, systemImage: p.symbol).badge(Text("검사 중"))
        case .cleanup where cleanup.safeTotal > 0:
            Label(p.title, systemImage: p.symbol).badge(Text(Fmt.bytes(cleanup.safeTotal)))
        case .memory:
            Label(p.title, systemImage: p.symbol).badge(Text(memory.stats.pressureLabel))
        default:
            Label(p.title, systemImage: p.symbol)
        }
    }

    @ViewBuilder
    var detail: some View {
        switch store.pane {
        case .overview: OverviewView()
        case .cleanup: CleanupView()
        case .explorer: ExplorerView()
        case .largeFiles: LargeFilesView()
        case .apps: AppsView()
        case .memory: MemoryView()
        case .settings: ScrollView { SettingsView().padding(24).frame(maxWidth: 720, alignment: .leading) }
        }
    }
}

struct SidebarFooter: View {
    @EnvironmentObject var volume: VolumeModel

    var body: some View {
        if let v = volume.stats {
            VStack(alignment: .leading, spacing: 6) {
                HStack {
                    Image(systemName: "internaldrive")
                    Text("Macintosh HD").font(.caption.weight(.semibold))
                    Spacer()
                }
                SizeBar(fraction: v.usedFraction, color: Palette.usage(v.usedFraction))
                Text("\(Fmt.bytes(v.free)) 남음 / \(Fmt.bytes(v.total))")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
            }
            .padding(12)
        }
    }
}

// MARK: - 메뉴 막대

struct MenuBarView: View {
    @EnvironmentObject var updates: UpdateChecker
    @EnvironmentObject var store: AppStore
    @EnvironmentObject var volume: VolumeModel
    @EnvironmentObject var memory: MemoryModel
    @EnvironmentObject var cleanup: CleanupModel

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                Text("MacClean").font(.headline)
                Spacer()
                Text("숫자를 더블클릭하면 창이 열려요").font(.caption2).foregroundStyle(.secondary)
            }
            if let v = volume.stats {
                VStack(alignment: .leading, spacing: 5) {
                    HStack {
                        Label("디스크", systemImage: "internaldrive")
                        Spacer()
                        Text("\(Fmt.bytes(v.free)) 남음").monospacedDigit()
                    }
                    .font(.callout)
                    SizeBar(fraction: v.usedFraction, color: Palette.usage(v.usedFraction))
                }
            }
            VStack(alignment: .leading, spacing: 5) {
                HStack {
                    Label("메모리", systemImage: "memorychip")
                    Spacer()
                    Text("\(Fmt.memory(memory.stats.used)) / \(Fmt.memory(memory.stats.total))").monospacedDigit()
                }
                .font(.callout)
                SizeBar(fraction: memory.stats.usedFraction, color: pressureColor)
                Text("메모리 압력: \(memory.stats.pressureLabel) · 스왑 \(Fmt.memory(memory.stats.swapUsed))")
                    .font(.caption).foregroundStyle(.secondary)
            }
            HStack(spacing: 16) {
                loadGauge("CPU", "cpu", memory.cpu)
                loadGauge("GPU", "square.stack.3d.up", memory.gpu)
            }
            if cleanup.safeTotal > 0 {
                Label("안전하게 정리 가능: \(Fmt.bytes(cleanup.safeTotal))", systemImage: "sparkles")
                    .font(.callout).foregroundStyle(Palette.sage)
            }
            if let r = updates.available {
                Button { updates.presentResult() } label: {
                    Label("새 버전 \(UpdateChecker.clean(r.tag)) 업데이트 가능", systemImage: "arrow.down.circle.fill")
                }
                .buttonStyle(.link)
            }
            Divider()
            HStack {
                Button("MacClean 열기") { WindowManager.shared.showMain() }
                .buttonStyle(.borderedProminent)
                Spacer()
                Button("종료") { NSApp.terminate(nil) }
            }
        }
        .padding(16)
        .frame(width: 300)
        .onAppear { volume.refresh() }
    }

    func loadGauge(_ label: String, _ icon: String, _ value: Double?) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack {
                Label(label, systemImage: icon)
                Spacer()
                Text(value.map { Fmt.percent($0) } ?? "–").monospacedDigit()
            }
            .font(.callout)
            SizeBar(fraction: value ?? 0, color: Palette.usage(value ?? 0, warnAt: 0.85))
        }
    }

    var pressureColor: Color { Palette.pressure(memory.stats.pressureLevel) }
}

// MARK: - 설정

struct SettingsView: View {
    @EnvironmentObject var permissions: PermissionModel
    @AppStorage(Prefs.trashSafeItems) private var trashSafeItems = false
    @AppStorage(Prefs.showMenuBar) private var showMenuBar = true
    @AppStorage(Prefs.autoScan) private var autoScan = true
    @AppStorage(Prefs.minimizeToMenuBar) private var minimizeToMenuBar = true
    @AppStorage(Prefs.alwaysShowStats) private var alwaysShowStats = false
    @AppStorage(Prefs.autoUpdateCheck) private var autoUpdateCheck = true
    @EnvironmentObject var updates: UpdateChecker

    var body: some View {
        VStack(alignment: .leading, spacing: 22) {
            Text("설정").font(.title2.weight(.bold))

            GroupBox {
                VStack(alignment: .leading, spacing: 10) {
                    HStack {
                        Image(systemName: permissions.fullDiskAccess ? "checkmark.seal.fill" : "exclamationmark.triangle.fill")
                            .foregroundStyle(permissions.fullDiskAccess ? .green : .orange)
                        Text(permissions.fullDiskAccess ? "전체 디스크 접근 권한이 켜져 있습니다" : "전체 디스크 접근 권한이 꺼져 있습니다")
                            .font(.headline)
                        Spacer()
                        Button("시스템 설정 열기") { permissions.openSettings() }
                    }
                    Text("휴지통, 메일, 메시지, 다른 앱의 데이터 폴더를 분석하려면 필요합니다. 켠 뒤에는 MacClean을 다시 실행하세요. 파일 내용은 읽지 않고 크기와 날짜만 확인합니다.")
                        .font(.callout).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .padding(6)
            } label: { Text("권한") }

            GroupBox {
                VStack(alignment: .leading, spacing: 10) {
                    Toggle("'안전' 항목도 휴지통으로 보내기", isOn: $trashSafeItems)
                    Text(trashSafeItems
                         ? "모든 항목을 휴지통으로 옮깁니다. 되살릴 수 있지만 휴지통을 비워야 공간이 확보됩니다."
                         : "캐시·로그처럼 다시 만들어지는 '안전' 항목은 바로 삭제해 즉시 공간을 확보합니다. 그 밖의 항목(다운로드, 잔여 파일, 백업 등)은 항상 휴지통으로 옮겨 되살릴 수 있습니다.")
                        .font(.callout).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                    Divider()
                    Toggle("실행할 때 정리 추천 자동 검사", isOn: $autoScan)
                }
                .padding(6)
            } label: { Text("정리 방식") }

            GroupBox {
                VStack(alignment: .leading, spacing: 10) {
                    Toggle("메뉴 막대에 MacClean 표시", isOn: $showMenuBar)
                    Toggle("노란 버튼(최소화)을 누르면 메뉴 막대로 내려놓기", isOn: $minimizeToMenuBar)
                        .disabled(!showMenuBar)
                    Toggle("창이 열려 있을 때도 메뉴 막대에 수치 표시", isOn: $alwaysShowStats)
                        .disabled(!showMenuBar)
                    Text("내려놓으면 창과 Dock 아이콘이 사라지고 메뉴 막대에 '디스크 · 메모리 · CPU · GPU' 사용률이 퍼센트로 표시됩니다. 숫자를 더블클릭하면 창이 다시 열리고, 한 번 클릭하면 요약, 우클릭하면 메뉴가 나옵니다. (단축키 ⌥⌘M)")
                        .font(.callout).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .padding(6)
            } label: { Text("메뉴 막대") }

            GroupBox {
                VStack(alignment: .leading, spacing: 8) {
                    row("checkmark.shield.fill", .green, "안전", "캐시·로그·빌드 산출물처럼 지워도 자동으로 다시 만들어지는 것")
                    row("eye.fill", .blue, "확인", "내가 받거나 만든 파일, 삭제된 앱의 잔여물. 보고 판단")
                    row("exclamationmark.triangle.fill", .orange, "주의", "앱 데이터·백업. 지우면 기록·설정이 사라짐")
                    row("lock.fill", .red, "보존", "직접 지우면 손상되는 것. 해당 앱에서 정리")
                }
                .padding(6)
            } label: { Text("판정 기준") }

            GroupBox {
                VStack(alignment: .leading, spacing: 10) {
                    HStack {
                        Text("MacClean \(AppVersion.version)").font(.headline)
                        Text("빌드 \(AppVersion.buildLabel)").font(.caption).foregroundStyle(.secondary)
                        Spacer()
                        Button("버전 정보") { WindowManager.shared.openAux?("about") }
                    }
                    UpdateStatusRow()
                    Toggle("하루에 한 번 자동으로 업데이트 확인", isOn: $autoUpdateCheck)
                    Text("GitHub 저장소(junseok-seo/macclean)의 최신 릴리스와 비교합니다. 공개 릴리스 정보를 받아 오기만 하고 이 Mac의 정보는 보내지 않습니다."
                         + (updates.lastChecked.map { " 마지막 확인: \(Fmt.ago($0))." } ?? ""))
                        .font(.callout).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .padding(6)
            } label: { Text("버전·업데이트") }

            Text("모든 분석은 이 Mac 안에서만 이뤄집니다. 파일 내용은 읽지 않습니다.")
                .font(.caption).foregroundStyle(.secondary)
        }
    }

    func row(_ icon: String, _ color: Color, _ title: String, _ text: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Image(systemName: icon).foregroundStyle(color).frame(width: 18)
            Text(title).font(.callout.weight(.semibold)).frame(width: 34, alignment: .leading)
            Text(text).font(.callout).foregroundStyle(.secondary)
        }
    }
}
