import AppKit
import MacCleanCore
import SwiftUI

enum Pane: String, CaseIterable, Identifiable {
    case overview, cleanup, explorer, largeFiles, apps, memory, settings
    var id: String { rawValue }
    var title: String {
        switch self {
        case .overview: "개요"
        case .cleanup: "정리 추천"
        case .explorer: "디스크 탐색"
        case .largeFiles: "대용량 파일"
        case .apps: "앱 관리"
        case .memory: "메모리"
        case .settings: "설정"
        }
    }
    var symbol: String {
        switch self {
        case .overview: "gauge.with.dots.needle.50percent"
        case .cleanup: "sparkles"
        case .explorer: "folder.badge.gearshape"
        case .largeFiles: "doc.text.below.ecg"
        case .apps: "square.grid.2x2"
        case .memory: "memorychip"
        case .settings: "gearshape"
        }
    }
}

struct Toast: Identifiable, Equatable {
    let id = UUID()
    let text: String
    let isError: Bool
}

struct ReportSheet: Identifiable {
    let id = UUID()
    let title: String
    let report: DeletionReport
}

struct ConfirmRequest: Identifiable {
    let id = UUID()
    let title: String
    let message: String
    let confirmLabel: String
    let destructive: Bool
    let action: () -> Void
}

enum Prefs {
    static let trashSafeItems = "trashSafeItems"
    static let showMenuBar = "showMenuBar"
    static let autoScan = "autoScanOnLaunch"
    static let didScanOnce = "didScanOnce"
    static let minimizeToMenuBar = "minimizeToMenuBar"
    static let alwaysShowStats = "alwaysShowStats"
    static let autoUpdateCheck = "autoUpdateCheck"
    static let lastUpdateCheck = "lastUpdateCheck"
}

// MARK: - 루트

@MainActor
final class AppStore: ObservableObject {
    let volume = VolumeModel()
    let permissions = PermissionModel()
    let disk = DiskModel()
    let cleanup = CleanupModel()
    let memory = MemoryModel()
    let apps = AppsModel()
    let large = LargeFilesModel()
    let updates = UpdateChecker()

    @Published var pane: Pane = .overview
    @Published var helpSection: HelpSection? = .start
    @Published var toast: Toast?
    @Published var reportSheet: ReportSheet?
    @Published var confirm: ConfirmRequest?
    private var started = false

    init() {
        UserDefaults.standard.register(defaults: [Prefs.showMenuBar: true, Prefs.autoScan: true, Prefs.trashSafeItems: false,
                                                  Prefs.minimizeToMenuBar: true, Prefs.alwaysShowStats: false,
                                                  Prefs.autoUpdateCheck: true])
        disk.store = self
        cleanup.store = self
        apps.store = self
        large.store = self
        memory.store = self
        memory.start()
    }

    func startIfNeeded() {
        guard !started else { return }
        started = true
        volume.refresh()
        permissions.refresh()
        StatusBarController.install(self)
        if Snapshotter.isWindowTest { Snapshotter.runWindowTest(self); return }
        if Snapshotter.isUpdateTest { Snapshotter.runUpdateTest(self); return }
        if Snapshotter.isActive { Snapshotter.run(self); return }
        updates.checkIfDue()
        // 권한 없이 처음 실행하면 폴더마다 허용 창이 연달아 뜨므로, 권한이 있거나 한 번 직접 검사한 뒤에만 자동 검사
        let d = UserDefaults.standard
        if d.bool(forKey: Prefs.autoScan) && (permissions.fullDiskAccess || d.bool(forKey: Prefs.didScanOnce)) { cleanup.scan() }
    }

    func show(_ text: String, error: Bool = false) {
        let t = Toast(text: text, isError: error)
        toast = t
        DispatchQueue.main.asyncAfter(deadline: .now() + 5) { [weak self] in
            if self?.toast == t { self?.toast = nil }
        }
    }

    /// 삭제 결과를 알리고, 실패가 있으면 상세 시트를 띄운다.
    func finished(_ report: DeletionReport, title: String) {
        volume.refresh()
        PathKnowledge.shared.invalidate()
        var parts: [String] = []
        if report.freedBytes > 0 { parts.append("\(Fmt.bytes(report.freedBytes)) 확보") }
        if report.trashedBytes > 0 { parts.append("\(Fmt.bytes(report.trashedBytes)) 휴지통으로 이동") }
        if parts.isEmpty && report.removedCount > 0 { parts.append("\(report.removedCount)개 항목 처리") }
        if !report.failures.isEmpty { parts.append("\(report.failures.count)개 실패") }
        show(parts.isEmpty ? "변경된 항목이 없습니다" : parts.joined(separator: " · "), error: !report.failures.isEmpty && report.removedCount == 0)
        if !report.failures.isEmpty || !report.commandOutputs.isEmpty {
            reportSheet = ReportSheet(title: title, report: report)
        }
    }

    func ask(_ title: String, _ message: String, confirm label: String, destructive: Bool = true, action: @escaping () -> Void) {
        confirm = ConfirmRequest(title: title, message: message, confirmLabel: label, destructive: destructive, action: action)
    }
}

// MARK: - 디스크 용량·권한

@MainActor
final class VolumeModel: ObservableObject {
    @Published var stats: VolumeStats?

    func refresh() {
        Task.detached(priority: .utility) {
            let s = VolumeStats.read()
            await MainActor.run { self.stats = s }
        }
    }
}

@MainActor
final class PermissionModel: ObservableObject {
    @Published var fullDiskAccess = true

    func refresh() { fullDiskAccess = Permissions.hasFullDiskAccess() }

    func openSettings() { NSWorkspace.shared.open(Permissions.fullDiskAccessSettingsURL) }
}

// MARK: - 디스크 탐색

@MainActor
final class DiskModel: ObservableObject {
    enum Target: Hashable {
        case home, root, custom(String)
        var path: String {
            switch self {
            case .home: Paths.home
            case .root: "/"
            case .custom(let p): p
            }
        }
        var label: String {
            switch self {
            case .home: "홈 폴더"
            case .root: "전체 디스크"
            case .custom(let p): Paths.name(p)
            }
        }
    }

    weak var store: AppStore?
    @Published var target: Target = .home
    @Published var isScanning = false
    @Published var progress = ScanProgress()
    @Published var result: ScanResult?
    @Published var current: FileNode?
    @Published var selected: FileNode?
    @Published var revision = 0
    @Published var busy = false
    private var scanner: DiskScanner?

    func scan(_ newTarget: Target? = nil) {
        if let newTarget { target = newTarget }
        scanner?.cancel()
        let s = DiskScanner()
        scanner = s
        isScanning = true
        progress = ScanProgress()
        result = nil
        current = nil
        selected = nil
        let root = target.path
        Task.detached(priority: .userInitiated) {
            let r = s.scan(root: root) { p in Task { @MainActor in self.progress = p } }
            await MainActor.run {
                guard self.scanner === s else { return }
                self.isScanning = false
                if let r {
                    self.result = r
                    self.current = r.root
                    self.store?.large.merge(scan: r)
                } else if !s.isCancelled {
                    self.store?.show("스캔하지 못했습니다", error: true)
                }
            }
        }
    }

    func cancel() {
        scanner?.cancel()
        scanner = nil
        isScanning = false
    }

    func chooseFolder() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.prompt = "스캔"
        panel.message = "용량을 분석할 폴더를 고르세요"
        if panel.runModal() == .OK, let url = panel.url { scan(.custom(url.path)) }
    }

    func open(_ node: FileNode) {
        guard node.isDirectory, !node.children.isEmpty || node.smallFilesCount > 0 else { return }
        current = node
        selected = nil
    }

    func up() {
        guard let c = current, let p = c.parent else { return }
        current = p
        selected = c
    }

    /// 탐색기에서 항목 삭제 (안전 항목·캐시는 설정에 따라 바로 삭제, 그 외 휴지통)
    func delete(_ node: FileNode, permanent: Bool) {
        busy = true
        let path = node.path
        let size = node.size
        Task.detached(priority: .userInitiated) {
            let r = Deleter.remove(path, permanent: permanent, knownSize: size)
            await MainActor.run {
                self.busy = false
                if r.failures.isEmpty {
                    if self.selected === node { self.selected = nil }
                    node.detachFromParent()
                    self.revision += 1
                }
                self.store?.finished(r, title: "삭제 결과")
            }
        }
    }

    func emptyContents(_ node: FileNode, permanent: Bool) {
        busy = true
        let path = node.path
        Task.detached(priority: .userInitiated) {
            let r = Deleter.removeContents(of: path, permanent: permanent)
            let remaining = DirSize.measure(path).bytes
            await MainActor.run {
                self.busy = false
                node.markEmptied(remaining: remaining)
                self.revision += 1
                self.store?.finished(r, title: "비우기 결과")
            }
        }
    }

    func runCommand(_ title: String, _ command: String, admin: Bool) {
        busy = true
        Task.detached(priority: .userInitiated) {
            let r = admin ? Shell.runAdmin(command) : Shell.run(command)
            await MainActor.run {
                self.busy = false
                var rep = DeletionReport()
                let out = r.output.trimmingCharacters(in: .whitespacesAndNewlines)
                if r.status == 0 { rep.removedCount = 1; rep.commandOutputs = ["✓ \(command)\n\(String(out.suffix(1500)))"] }
                else { rep.failures = [DeletionFailure(path: command, reason: out.isEmpty ? "실패 (코드 \(r.status))" : String(out.suffix(500)))] }
                self.store?.finished(rep, title: title)
            }
        }
    }
}

// MARK: - 정리 추천

@MainActor
final class CleanupModel: ObservableObject {
    weak var store: AppStore?
    @Published var groups: [CleanupGroup] = []
    @Published var selected: Set<String> = []
    @Published var collapsed: Set<String> = []
    @Published var isScanning = false
    @Published var isCleaning = false
    @Published var status = ""
    @Published var scannedAt: Date?

    var allItems: [CleanupItem] { groups.flatMap(\.items) }
    var selectedItems: [CleanupItem] { allItems.filter { selected.contains($0.id) && $0.isActionable } }
    var selectedSize: Int64 { selectedItems.reduce(0) { $0 + max(0, $1.size) } }
    var safeTotal: Int64 { allItems.filter { $0.safety == .safe && $0.isActionable }.reduce(0) { $0 + max(0, $1.size) } }
    var actionableTotal: Int64 { allItems.filter(\.isActionable).reduce(0) { $0 + max(0, $1.size) } }

    func scan() {
        guard !isScanning, !isCleaning else { return }
        UserDefaults.standard.set(true, forKey: Prefs.didScanOnce)
        isScanning = true
        status = "검사 준비 중"
        Task.detached(priority: .userInitiated) {
            let groups = CleanupScanner().scan { msg in Task { @MainActor in self.status = msg } }
            await MainActor.run {
                self.groups = groups
                self.selected = Set(groups.flatMap(\.items).filter { $0.defaultSelected && $0.isActionable }.map(\.id))
                self.collapsed = Set(groups.filter { ["guides", "leftovers", "projects", "downloads", "backups"].contains($0.id) }.map(\.id))
                self.isScanning = false
                self.scannedAt = Date()
                self.status = ""
            }
        }
    }

    func toggle(_ item: CleanupItem) {
        if selected.contains(item.id) { selected.remove(item.id) } else { selected.insert(item.id) }
    }

    /// 그룹 전체 선택은 '안전'·'확인' 항목만. '주의' 항목은 하나씩 직접 골라야 한다.
    func setGroup(_ g: CleanupGroup, on: Bool) {
        for it in g.items where it.isActionable && (it.safety < .caution || !on) {
            if on { selected.insert(it.id) } else { selected.remove(it.id) }
        }
    }

    func runningApps(in items: [CleanupItem]) -> [String] {
        let ids = Set(items.compactMap(\.appBundleID))
        return ids.compactMap { id in
            NSRunningApplication.runningApplications(withBundleIdentifier: id).first?.localizedName
        }.sorted()
    }

    func clean() {
        let items = selectedItems
        guard !items.isEmpty else { return }
        let forceTrash = UserDefaults.standard.bool(forKey: Prefs.trashSafeItems)
        isCleaning = true
        Task.detached(priority: .userInitiated) {
            let report = CleanupScanner.execute(items, forceTrash: forceTrash) { msg in Task { @MainActor in self.status = msg } }
            await MainActor.run {
                let done = Set(items.map(\.id))
                self.groups = self.groups.compactMap { g in
                    var g = g
                    g.items.removeAll { done.contains($0.id) }
                    return g.items.isEmpty ? nil : g
                }
                self.selected.subtract(done)
                self.isCleaning = false
                self.status = ""
                self.store?.finished(report, title: "정리 결과")
                self.store?.disk.result.map { _ in self.store?.show("디스크 탐색 결과는 다시 스캔하면 갱신됩니다") }
            }
        }
    }
}

// MARK: - 메모리

@MainActor
final class MemoryModel: ObservableObject {
    struct Point: Identifiable {
        let id = UUID()
        let time: Date
        let used: Double
        let swap: Double
        let pressure: Int
    }

    weak var store: AppStore?
    @Published var stats = MemoryReader.read()
    @Published var groups: [ProcessGroup] = []
    @Published var hidden = 0
    @Published var history: [Point] = []
    @Published var purging = false
    /// 전체 CPU·GPU 사용률 (0~1)
    @Published var cpu: Double?
    @Published var gpu: Double?
    var detailVisible = false { didSet { if detailVisible { tick() } } }
    private var timer: Timer?
    private let sampler = ProcessSampler()
    private let cpuSampler = CPULoadSampler()
    private var sampling = false

    func start() {
        guard timer == nil else { return }
        tick()
        timer = Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.tick() }
        }
    }

    func tick() {
        let s = MemoryReader.read()
        stats = s
        cpu = cpuSampler.sample() ?? cpu
        gpu = GPULoad.read()
        history.append(Point(time: Date(), used: Double(s.used) / 1_073_741_824, swap: Double(s.swapUsed) / 1_073_741_824, pressure: s.pressureLevel))
        if history.count > 150 { history.removeFirst(history.count - 150) }
        guard detailVisible, !sampling else { return }
        sampling = true
        let sampler = self.sampler
        Task.detached(priority: .utility) {
            let (g, h) = sampler.sample()
            await MainActor.run {
                self.groups = g
                self.hidden = h
                self.sampling = false
            }
        }
    }

    func quit(_ g: ProcessGroup, force: Bool) {
        if ProcessControl.quit(g, force: force) {
            store?.show("\(g.name)\(force ? " 강제 종료" : " 종료 요청")")
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { self.tick() }
        } else {
            store?.show("\(g.name)을(를) 종료하지 못했습니다 (권한이 없거나 시스템 프로세스)", error: true)
        }
    }

    func purge() {
        purging = true
        let before = stats.cached
        Task.detached(priority: .userInitiated) {
            let (ok, out) = ProcessControl.purge()
            await MainActor.run {
                self.purging = false
                self.tick()
                if ok {
                    let after = self.stats.cached
                    self.store?.show("파일 캐시 \(Fmt.memory(before > after ? before - after : 0)) 비움")
                } else if !out.contains("-128") {
                    self.store?.show("메모리 정리를 실행하지 못했습니다", error: true)
                }
            }
        }
    }

    /// 지금 상태에 대한 해석과 권장 사항
    var insights: [(icon: String, color: Color, text: String)] {
        var list: [(String, Color, String)] = []
        let s = stats
        let gb = 1_073_741_824.0
        switch s.pressureLevel {
        case 4: list.append(("exclamationmark.octagon.fill", Palette.coral, "메모리 압력이 '위험'입니다. 지금 많이 쓰는 앱을 종료하지 않으면 앱이 강제로 종료되거나 매우 느려질 수 있습니다."))
        case 2: list.append(("exclamationmark.triangle.fill", Palette.amber, "메모리 압력이 '경고'입니다. macOS가 메모리를 압축하고 스왑을 쓰는 중이라 느려질 수 있습니다."))
        default: list.append(("checkmark.circle.fill", Palette.sage, "메모리 압력이 '정상'입니다. 사용량 숫자가 높아 보여도 macOS가 남는 메모리를 캐시로 활용하는 것이므로 걱정하지 않아도 됩니다."))
        }
        if Double(s.swapUsed) > 2 * gb {
            list.append(("arrow.left.arrow.right.circle.fill", Palette.amber, "스왑 \(Fmt.memory(s.swapUsed))를 쓰고 있습니다. 과거에 메모리가 부족했던 흔적이며, 부족한 상태가 계속되면 디스크 쓰기가 늘고 느려집니다. 재시동하면 비워집니다."))
        }
        let vms = groups.filter { $0.vmMemory > 1_000_000_000 }
        for g in vms.prefix(2) {
            list.append(("cpu", Palette.lavender, "\(g.name)이(가) 실행한 가상머신이 \(Fmt.memory(g.vmMemory))를 통째로 차지하고 있습니다. 지금 쓰지 않는다면 \(g.name)을(를) 종료하면 바로 회수됩니다."))
        }
        if let top = groups.first(where: { !$0.isSystem && $0.vmMemory == 0 }), Double(top.memory) > 2 * gb {
            list.append(("chart.bar.fill", Palette.blue, "\(top.name)이(가) 프로세스 \(top.processCount)개로 \(Fmt.memory(top.memory))를 쓰고 있어 가장 많습니다."))
        }
        let browserProcs = groups.filter { $0.name.contains("Chrome") || $0.name.contains("Whale") || $0.name.contains("Edge") }.reduce(0) { $0 + $1.processCount }
        if browserProcs > 30 {
            list.append(("macwindow.on.rectangle", Palette.blue, "브라우저 프로세스가 \(browserProcs)개입니다. 탭과 확장 프로그램마다 메모리를 쓰므로 안 보는 탭을 닫으면 줄어듭니다."))
        }
        return list
    }
}

// MARK: - 앱 관리

@MainActor
final class AppsModel: ObservableObject {
    weak var store: AppStore?
    @Published var apps: [InstalledApp] = []
    @Published var isLoading = false
    @Published var measured = 0
    @Published var busy = false
    private var loaded = false

    func loadIfNeeded() { if !loaded { load() } }

    func load() {
        loaded = true
        isLoading = true
        measured = 0
        Task.detached(priority: .userInitiated) {
            let list = AppScanner.listApps()
            await MainActor.run { self.apps = list }
            DispatchQueue.concurrentPerform(iterations: list.count) { i in
                let m = AppScanner.measure(list[i])
                Task { @MainActor in
                    if let idx = self.apps.firstIndex(where: { $0.id == m.id }) { self.apps[idx] = m }
                    self.measured += 1
                    if self.measured >= self.apps.count { self.isLoading = false }
                }
            }
            if list.isEmpty { await MainActor.run { self.isLoading = false } }
        }
    }

    func uninstall(_ app: InstalledApp, related: [String]) {
        busy = true
        Task.detached(priority: .userInitiated) {
            let r = AppScanner.uninstall(app, related: related)
            await MainActor.run {
                self.busy = false
                if !r.failures.contains(where: { $0.path == app.path }) {
                    self.apps.removeAll { $0.id == app.id }
                }
                self.store?.finished(r, title: "\(app.name) 삭제 결과")
            }
        }
    }
}

// MARK: - 대용량 파일

struct LargeFile: Identifiable, Hashable {
    var id: String { path }
    let path: String
    let size: Int64
    let modified: Date?
    var lastOpened: Date?
    var name: String { Paths.name(path) }
    var location: String { Paths.abbreviate(Paths.parent(path)) }
}

@MainActor
final class LargeFilesModel: ObservableObject {
    weak var store: AppStore?
    @Published var files: [LargeFile] = []
    @Published var isLoading = false
    @Published var includesLibrary = false
    private var loaded = false

    func loadIfNeeded() { if !loaded { loadSpotlight() } }

    /// Spotlight로 100MB 이상 파일을 빠르게 찾는다 (라이브러리·숨김 폴더는 색인되지 않음)
    func loadSpotlight() {
        loaded = true
        isLoading = true
        Task.detached(priority: .userInitiated) {
            let r = Shell.run("mdfind -onlyin \"$HOME\" 'kMDItemFSSize >= 52428800'", timeout: 60)
            let paths = r.output.split(separator: "\n").map(String.init).filter { !$0.isEmpty }
            let files: [LargeFile] = paths.compactMap { p in
                var st = stat()
                guard lstat(p, &st) == 0, (st.st_mode & S_IFMT) == S_IFREG else { return nil }
                return LargeFile(path: p, size: Int64(st.st_blocks) * 512,
                                 modified: Date(timeIntervalSince1970: TimeInterval(st.st_mtimespec.tv_sec)),
                                 lastOpened: AppRegistry.lastUsedDate(p))
            }
            await MainActor.run {
                self.mergeFiles(files)
                self.isLoading = false
            }
        }
    }

    func merge(scan: ScanResult) {
        let list = scan.largeFiles.map { n in
            LargeFile(path: n.path, size: n.size, modified: n.modifiedDate, lastOpened: nil)
        }
        if scan.root.path == Paths.home || scan.root.path == "/" { includesLibrary = true }
        mergeFiles(list)
        Task.detached(priority: .utility) {
            let withDates = list.map { f -> LargeFile in var f = f; f.lastOpened = AppRegistry.lastUsedDate(f.path); return f }
            await MainActor.run { self.mergeFiles(withDates) }
        }
    }

    private func mergeFiles(_ new: [LargeFile]) {
        var dict = Dictionary(files.map { ($0.path, $0) }, uniquingKeysWith: { a, _ in a })
        for f in new {
            if var old = dict[f.path] {
                if f.lastOpened != nil { old.lastOpened = f.lastOpened }
                dict[f.path] = old
            } else {
                dict[f.path] = f
            }
        }
        files = dict.values.sorted { $0.size > $1.size }
    }

    func trash(_ ids: Set<String>) {
        let targets = files.filter { ids.contains($0.id) }
        Task.detached(priority: .userInitiated) {
            var report = DeletionReport()
            for f in targets { report.merge(Deleter.remove(f.path, permanent: false, knownSize: f.size)) }
            let failed = Set(report.failures.map(\.path))
            let final = report
            await MainActor.run {
                self.files.removeAll { ids.contains($0.id) && !failed.contains($0.path) }
                self.store?.finished(final, title: "대용량 파일 삭제 결과")
            }
        }
    }
}

// MARK: - 공용 동작

enum Finder {
    static func reveal(_ path: String) {
        let url = URL(fileURLWithPath: path)
        if FileManager.default.fileExists(atPath: path) {
            NSWorkspace.shared.activateFileViewerSelecting([url])
        } else {
            NSWorkspace.shared.open(url.deletingLastPathComponent())
        }
    }

    static func copy(_ text: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }
}
