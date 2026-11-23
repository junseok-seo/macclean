import AppKit
import MacCleanCore
import SwiftUI

/// 개발 검증용: `MacClean --snapshot <출력폴더> [스캔할폴더]` 로 실행하면
/// 각 화면을 PNG로 저장하고 종료한다. 아무것도 삭제하지 않는다.
@MainActor
enum Snapshotter {
    static var args: [String] { CommandLine.arguments }
    static var isActive: Bool { args.contains("--snapshot") }
    static var isWindowTest: Bool { args.contains("--window-test") }

    /// `MacClean --window-test <출력폴더>`: 내려놓기·더블클릭 복귀·닫은 뒤 복귀를 확인해 기록한다.
    static func runWindowTest(_ store: AppStore) {
        let dir: URL = {
            guard let i = args.firstIndex(of: "--window-test"), i + 1 < args.count else { return URL(fileURLWithPath: NSTemporaryDirectory()) }
            return URL(fileURLWithPath: args[i + 1])
        }()
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        Task { @MainActor in
            var log: [String] = []
            let wm = WindowManager.shared
            @MainActor func state(_ label: String) {
                let sb = StatusBarController.shared
                log.append("\(label): 창보임=\(wm.isMainVisible) 창있음=\(wm.mainWindow != nil) Dock=\(NSApp.activationPolicy() == .regular) 메뉴막대='\(sb?.currentTitle ?? "(없음)")'")
            }
            try? await Task.sleep(nanoseconds: 4_000_000_000)
            state("1 시작")
            wm.minimizeClicked(nil)
            try? await Task.sleep(nanoseconds: 2_500_000_000)
            state("2 노란버튼(내려놓기)")
            StatusBarController.shared?.snapshotButton(to: dir.appendingPathComponent("statusbar.png"))
            StatusBarController.shared?.handleClick(right: false, clickCount: 1)
            StatusBarController.shared?.handleClick(right: false, clickCount: 2)
            try? await Task.sleep(nanoseconds: 2_000_000_000)
            state("3 더블클릭")
            wm.closeClicked(nil)
            try? await Task.sleep(nanoseconds: 2_000_000_000)
            state("4 빨간버튼")
            StatusBarController.shared?.handleClick(right: false, clickCount: 2)
            try? await Task.sleep(nanoseconds: 2_000_000_000)
            state("5 빨간버튼 뒤 더블클릭")
            wm.mainWindow?.close()
            try? await Task.sleep(nanoseconds: 2_000_000_000)
            state("6 창 완전히 닫기(⌘W)")
            StatusBarController.shared?.handleClick(right: false, clickCount: 2)
            try? await Task.sleep(nanoseconds: 3_500_000_000)
            state("7 완전히 닫힌 뒤 더블클릭")
            try? log.joined(separator: "\n").write(to: dir.appendingPathComponent("window-test.txt"), atomically: true, encoding: .utf8)
            NSApp.terminate(nil)
        }
    }
    static var outDir: URL {
        guard let i = args.firstIndex(of: "--snapshot"), i + 1 < args.count else { return URL(fileURLWithPath: NSTemporaryDirectory()) }
        return URL(fileURLWithPath: args[i + 1])
    }
    static var scanPath: String? {
        guard let i = args.firstIndex(of: "--snapshot"), i + 2 < args.count else { return nil }
        return args[i + 2]
    }

    static func run(_ store: AppStore) {
        try? FileManager.default.createDirectory(at: outDir, withIntermediateDirectories: true)
        store.cleanup.scan()
        if let p = scanPath { store.disk.scan(.custom(Paths.expand(p))) }
        store.apps.load()
        store.large.loadSpotlight()
        Task { @MainActor in
            for _ in 0..<240 {
                try? await Task.sleep(nanoseconds: 1_000_000_000)
                if !store.cleanup.isScanning && !store.disk.isScanning && !store.apps.isLoading && !store.large.isLoading { break }
            }
            for pane in [Pane.overview, .cleanup, .explorer, .largeFiles, .apps, .memory, .settings] {
                store.pane = pane
                if pane == .explorer, let first = store.disk.current?.children.first { store.disk.selected = first }
                if pane == .apps { }
                try? await Task.sleep(nanoseconds: 2_500_000_000)
                capture(name: pane.rawValue)
            }
            // 정리 추천에서 첫 항목 펼친 모습
            store.pane = .cleanup
            store.cleanup.collapsed.removeAll()
            try? await Task.sleep(nanoseconds: 1_500_000_000)
            capture(name: "cleanup-expanded")
            NSApp.terminate(nil)
        }
    }

    static func capture(name: String) {
        guard let window = NSApp.windows.first(where: { $0.isVisible && $0.contentView != nil && $0.frame.width > 600 }),
              let view = window.contentView?.superview ?? window.contentView,
              let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { return }
        view.cacheDisplay(in: view.bounds, to: rep)
        let data = rep.representation(using: .png, properties: [:])
        try? data?.write(to: outDir.appendingPathComponent("\(name).png"))
    }
}
