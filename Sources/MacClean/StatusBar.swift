import AppKit
import MacCleanCore
import SwiftUI

/// 메인 창 내려놓기(메뉴 막대로 숨기기)와 다시 열기
@MainActor
final class WindowManager: NSObject {
    static let shared = WindowManager()

    weak var mainWindow: NSWindow?
    /// SwiftUI openWindow — 창을 닫아 없어졌을 때 새로 연다
    var openMain: (() -> Void)?

    var putDownEnabled: Bool {
        let d = UserDefaults.standard
        return d.bool(forKey: Prefs.showMenuBar) && d.bool(forKey: Prefs.minimizeToMenuBar)
    }

    var isMainVisible: Bool {
        guard let w = mainWindow else { return false }
        return w.isVisible && !w.isMiniaturized && !NSApp.isHidden
    }

    func attach(_ window: NSWindow) {
        mainWindow = window
        if let b = window.standardWindowButton(.miniaturizeButton), b.action != #selector(minimizeClicked(_:)) {
            b.target = self
            b.action = #selector(minimizeClicked(_:))
            b.toolTip = "메뉴 막대로 내려놓기"
        }
        if let b = window.standardWindowButton(.closeButton), b.action != #selector(closeClicked(_:)) {
            b.target = self
            b.action = #selector(closeClicked(_:))
        }
    }

    @objc func minimizeClicked(_ sender: Any?) {
        if putDownEnabled { putDown() } else { mainWindow?.miniaturize(sender) }
    }

    /// 빨간 버튼: 메뉴 막대를 쓰는 동안에는 창을 없애지 않고 숨겨 둔다 (더블클릭하면 그대로 다시 나타남)
    @objc func closeClicked(_ sender: Any?) {
        if UserDefaults.standard.bool(forKey: Prefs.showMenuBar) {
            mainWindow?.orderOut(nil)
            StatusBarController.shared?.render()
        } else {
            mainWindow?.performClose(sender)
        }
    }

    private func findMainWindow() -> NSWindow? {
        NSApp.windows.first { $0.identifier?.rawValue.hasPrefix("main") == true && $0.contentView != nil }
    }

    /// 창과 Dock 아이콘을 숨기고 메뉴 막대 수치만 남긴다
    func putDown() {
        mainWindow?.orderOut(nil)
        NSApp.setActivationPolicy(.accessory)
        StatusBarController.shared?.render()
    }

    func showMain() {
        NSApp.setActivationPolicy(.regular)
        NSApp.activate()
        if let w = mainWindow ?? findMainWindow() {
            attach(w)
            if w.isMiniaturized { w.deminiaturize(nil) }
            w.makeKeyAndOrderFront(nil)
        } else {
            // 창이 완전히 닫혀 없어진 경우: 새로 만들고, 생길 때까지 몇 번 확인해 앞으로 가져온다
            openMain?()
            for delay in [0.2, 0.6, 1.2, 2.0] {
                DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
                    guard let self, let w = self.mainWindow ?? self.findMainWindow() else { return }
                    self.attach(w)
                    if !w.isVisible { w.makeKeyAndOrderFront(nil) }
                    StatusBarController.shared?.render()
                }
            }
        }
        StatusBarController.shared?.render()
    }
}

/// SwiftUI 뷰가 올라간 NSWindow를 알려 준다
struct WindowAccessor: NSViewRepresentable {
    let onWindow: (NSWindow) -> Void

    func makeNSView(context: Context) -> NSView {
        let v = NSView()
        DispatchQueue.main.async { if let w = v.window { onWindow(w) } }
        return v
    }

    func updateNSView(_ v: NSView, context: Context) {
        DispatchQueue.main.async { if let w = v.window { onWindow(w) } }
    }
}

/// 메뉴 막대의 디스크·메모리·CPU·GPU 수치
@MainActor
final class StatusBarController: NSObject {
    static var shared: StatusBarController?

    private let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
    private let store: AppStore
    private let popover = NSPopover()
    private var timer: Timer?
    private var pendingClick: DispatchWorkItem?
    private var lastDiskRefresh = Date.distantPast

    static func install(_ store: AppStore) {
        guard shared == nil else { return }
        shared = StatusBarController(store: store)
    }

    private init(store: AppStore) {
        self.store = store
        super.init()
        if let b = item.button {
            b.target = self
            b.action = #selector(clicked(_:))
            b.sendAction(on: [.leftMouseUp, .rightMouseUp])
        }
        popover.behavior = .transient
        popover.contentViewController = NSHostingController(rootView: MenuBarView().injectModels(store))
        timer = Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.tick() }
        }
        NotificationCenter.default.addObserver(forName: UserDefaults.didChangeNotification, object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor in self?.render() }
        }
        for name in [NSWindow.didMiniaturizeNotification, NSWindow.didDeminiaturizeNotification, NSWindow.willCloseNotification,
                     NSApplication.didHideNotification, NSApplication.didUnhideNotification] {
            NotificationCenter.default.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                DispatchQueue.main.async { self?.render() }
            }
        }
        render()
    }

    private func tick() {
        if Date().timeIntervalSince(lastDiskRefresh) > 30 {
            lastDiskRefresh = Date()
            store.volume.refresh()
        }
        render()
    }

    var showsNumbers: Bool {
        !WindowManager.shared.isMainVisible || UserDefaults.standard.bool(forKey: Prefs.alwaysShowStats)
    }

    func render() {
        item.isVisible = UserDefaults.standard.bool(forKey: Prefs.showMenuBar)
        guard let button = item.button else { return }
        let m = store.memory
        if showsNumbers {
            button.image = nil
            button.attributedTitle = Self.title(disk: store.volume.stats, memory: m.stats, cpu: m.cpu, gpu: m.gpu)
        } else {
            button.attributedTitle = NSAttributedString(string: "")
            let img = NSImage(systemSymbolName: "internaldrive", accessibilityDescription: "MacClean")
            img?.isTemplate = true
            button.image = img
        }
        var tip = "MacClean — 더블클릭하면 창 열기"
        if let v = store.volume.stats { tip += "\n디스크: \(Fmt.bytes(v.free)) 남음 (\(Fmt.percent(v.usedFraction)) 사용)" }
        tip += "\n메모리: \(Fmt.memory(m.stats.used)) / \(Fmt.memory(m.stats.total)), 압력 \(m.stats.pressureLabel)"
        button.toolTip = tip
    }

    /// 메뉴 막대 문자열: "디스크 95%  메모리 18.7G  CPU 23%  GPU 18%"
    static func title(disk: VolumeStats?, memory: MemoryStats, cpu: Double?, gpu: Double?) -> NSAttributedString {
        let s = NSMutableAttributedString()
        // 굵은 흰 글씨 대신 보통 굵기·한 톤 낮춘 색으로 차분하게
        let labelFont = NSFont.systemFont(ofSize: 10, weight: .regular)
        let valueFont = NSFont.monospacedDigitSystemFont(ofSize: 12, weight: .regular)
        // 메뉴 막대가 밝은지 어두운지에 따라 그릴 때마다 정해지는 색 (고정된 흰색·검은색 대신)
        func dyn(dark: NSColor, light: NSColor) -> NSColor {
            NSColor(name: nil) { ap in
                ap.bestMatch(from: [.darkAqua, .vibrantDark, .aqua, .vibrantLight]).map { $0 == .darkAqua || $0 == .vibrantDark } == true ? dark : light
            }
        }
        let valueColor = dyn(dark: NSColor(white: 0.90, alpha: 1), light: NSColor(white: 0.18, alpha: 1))
        let labelColor = dyn(dark: NSColor(white: 0.62, alpha: 1), light: NSColor(white: 0.42, alpha: 1))
        let sepColor = dyn(dark: NSColor(white: 0.42, alpha: 1), light: NSColor(white: 0.66, alpha: 1))
        let warnColor = dyn(dark: NSColor(srgbRed: 0.93, green: 0.72, blue: 0.48, alpha: 1),
                            light: NSColor(srgbRed: 0.76, green: 0.48, blue: 0.20, alpha: 1))
        func add(_ label: String, _ value: String, warn: Bool) {
            if s.length > 0 { s.append(NSAttributedString(string: "  ·  ", attributes: [.font: labelFont, .foregroundColor: sepColor])) }
            s.append(NSAttributedString(string: label + " ", attributes: [.font: labelFont, .foregroundColor: labelColor, .baselineOffset: 0.5]))
            s.append(NSAttributedString(string: value, attributes: [.font: valueFont, .foregroundColor: warn ? warnColor : valueColor]))
        }
        // 자릿수가 바뀌어도 폭이 흔들리지 않도록 숫자 폭 공백(U+2007)으로 채운다
        func pct(_ v: Double?) -> String {
            guard let v else { return "\u{2007}\u{2007}–" }
            let n = Int((v * 100).rounded())
            let t = "\(n)%"
            return String(repeating: "\u{2007}", count: max(0, 3 - String(n).count)) + t
        }
        add("디스크", disk.map { pct($0.usedFraction) } ?? "–", warn: (disk?.usedFraction ?? 0) > 0.9)
        add("메모리", String(format: "%.1fG", Double(memory.used) / 1_073_741_824), warn: memory.pressureLevel >= 2)
        add("CPU", pct(cpu), warn: (cpu ?? 0) > 0.85)
        add("GPU", pct(gpu), warn: (gpu ?? 0) > 0.9)
        return s
    }

    @objc private func clicked(_ sender: NSStatusBarButton) {
        guard let e = NSApp.currentEvent else { return }
        let right = e.type == .rightMouseUp || e.modifierFlags.contains(.control)
        handleClick(right: right, clickCount: e.clickCount)
    }

    /// 한 번: 요약 팝오버 / 두 번: 창 다시 열기 / 우클릭: 메뉴
    func handleClick(right: Bool, clickCount: Int) {
        if right { showMenu(); return }
        if clickCount >= 2 {
            pendingClick?.cancel()
            pendingClick = nil
            if popover.isShown { popover.performClose(nil) }
            WindowManager.shared.showMain()
            return
        }
        let work = DispatchWorkItem { [weak self] in self?.togglePopover() }
        pendingClick = work
        DispatchQueue.main.asyncAfter(deadline: .now() + NSEvent.doubleClickInterval, execute: work)
    }

    private func togglePopover() {
        pendingClick = nil
        guard let b = item.button else { return }
        if popover.isShown {
            popover.performClose(nil)
        } else {
            store.volume.refresh()
            popover.show(relativeTo: b.bounds, of: b, preferredEdge: .minY)
            popover.contentViewController?.view.window?.makeKey()
        }
    }

    private func showMenu() {
        let menu = NSMenu()
        func add(_ title: String, _ pane: Pane?) {
            let mi = NSMenuItem(title: title, action: #selector(menuOpen(_:)), keyEquivalent: "")
            mi.target = self
            mi.representedObject = pane?.rawValue
            menu.addItem(mi)
        }
        add("MacClean 열기", nil)
        add("정리 추천", .cleanup)
        add("메모리", .memory)
        menu.addItem(.separator())
        let quit = NSMenuItem(title: "MacClean 종료", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        menu.addItem(quit)
        if let b = item.button {
            menu.popUp(positioning: nil, at: NSPoint(x: 0, y: b.bounds.height + 4), in: b)
        }
    }

    @objc private func menuOpen(_ sender: NSMenuItem) {
        if let raw = sender.representedObject as? String, let pane = Pane(rawValue: raw) { store.pane = pane }
        WindowManager.shared.showMain()
    }

    /// 검증용: 메뉴 막대 버튼 모습을 PNG로
    func snapshotButton(to url: URL) {
        // 메뉴 막대 버튼과 같은 방식(뷰가 자기 외형으로 그림)으로, 밝은·어두운 메뉴 막대를 각각 재현한다
        let title = Self.title(disk: store.volume.stats, memory: store.memory.stats, cpu: store.memory.cpu, gpu: store.memory.gpu)
        let w = ceil(title.size().width) + 32, h: CGFloat = 26
        let container = NSView(frame: NSRect(x: 0, y: 0, width: w, height: h * 2))
        for (i, name) in [NSAppearance.Name.aqua, .darkAqua].enumerated() {
            let bg = NSView(frame: NSRect(x: 0, y: CGFloat(i) * h, width: w, height: h))
            bg.wantsLayer = true
            bg.layer?.backgroundColor = (name == .darkAqua ? NSColor(white: 0.17, alpha: 1) : NSColor(white: 0.94, alpha: 1)).cgColor
            bg.appearance = NSAppearance(named: name)
            let label = NSTextField(labelWithAttributedString: title)
            label.sizeToFit()
            label.frame.origin = NSPoint(x: 16, y: (h - label.frame.height) / 2)
            bg.addSubview(label)
            container.addSubview(bg)
        }
        guard let rep = container.bitmapImageRepForCachingDisplay(in: container.bounds) else { return }
        container.cacheDisplay(in: container.bounds, to: rep)
        try? rep.representation(using: .png, properties: [:])?.write(to: url)
    }

    var currentTitle: String { item.button?.attributedTitle.string ?? "" }
}
