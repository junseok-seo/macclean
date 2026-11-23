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
    static var isUpdateTest: Bool { args.contains("--update-test") }
    static var outOverride: URL?

    /// `MacClean --update-test <출력폴더> [--pretend-version 1.0.0]`: GitHub 릴리스 조회 결과를 기록하고 개요·도움말·정보 창을 찍는다
    static func runUpdateTest(_ store: AppStore) {
        let dir: URL = {
            guard let i = args.firstIndex(of: "--update-test"), i + 1 < args.count else { return URL(fileURLWithPath: NSTemporaryDirectory()) }
            return URL(fileURLWithPath: args[i + 1])
        }()
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        outOverride = dir
        Task { @MainActor in
            var log: [String] = ["현재 버전: \(AppVersion.version) (빌드 \(AppVersion.buildLabel))"]
            try? await Task.sleep(nanoseconds: 1_500_000_000)
            store.updates.check(showResult: false)
            for _ in 0..<30 {
                try? await Task.sleep(nanoseconds: 500_000_000)
                if case .checking = store.updates.state { continue }
                break
            }
            switch store.updates.state {
            case .available(let r):
                log.append("결과: 새 버전 \(r.tag) · DMG \(r.dmgURL?.absoluteString ?? "없음") · 페이지 \(r.pageURL)")
                log.append("요약:\n" + UpdateChecker.summarize(r.notes))
            case .upToDate(let t): log.append("결과: 최신 (GitHub 최신 \(t))")
            case .failed(let w): log.append("결과: 실패 — \(w)")
            default: log.append("결과: \(store.updates.state)")
            }
            // 상단 메뉴 구성 기록 (앱 메뉴·도움말 메뉴)
            let menus = NSApp.mainMenu?.items ?? []
            for (i, top) in menus.enumerated() where i == 0 || top === menus.last {
                let items = top.submenu?.items.map { $0.isSeparatorItem ? "—" : $0.title } ?? []
                log.append("[\(i == 0 ? "앱 메뉴" : top.title)] " + items.joined(separator: " | "))
            }
            store.pane = .overview
            try? await Task.sleep(nanoseconds: 1_500_000_000)
            capture(name: "overview-update")
            store.helpSection = .faq
            WindowManager.shared.openAux?("help")
            try? await Task.sleep(nanoseconds: 2_500_000_000)
            captureWindow(titled: "MacClean 도움말", name: "help")
            WindowManager.shared.openAux?("about")
            try? await Task.sleep(nanoseconds: 2_000_000_000)
            captureWindow(titled: "MacClean 정보", name: "about")
            try? log.joined(separator: "\n").write(to: dir.appendingPathComponent("update-test.txt"), atomically: true, encoding: .utf8)
            NSApp.terminate(nil)
        }
    }

    static func captureWindow(titled title: String, name: String) {
        guard let window = NSApp.windows.first(where: { $0.title == title && $0.isVisible }),
              let view = window.contentView?.superview ?? window.contentView,
              let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { return }
        view.cacheDisplay(in: view.bounds, to: rep)
        try? rep.representation(using: .png, properties: [:])?.write(to: (outOverride ?? outDir).appendingPathComponent("\(name).png"))
    }

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
        try? data?.write(to: (outOverride ?? outDir).appendingPathComponent("\(name).png"))
    }
}
