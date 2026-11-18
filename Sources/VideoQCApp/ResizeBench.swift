import AppKit
import SwiftUI

/// `QCPIE_BENCH_HIDE=drawer,browser,queue,favbar,crumbs,toolbar,list,header`: parts the resize benchmark leaves out to
/// find what's slow (debug builds only; always false otherwise).
func benchHides(_ part: String) -> Bool {
    #if DEBUG
    benchHiddenParts.contains(part)
    #else
    false
    #endif
}

#if DEBUG
/// Read once: `benchHides` is called from view bodies.
private let benchHiddenParts = Set((ProcessInfo.processInfo.environment["QCPIE_BENCH_HIDE"] ?? "").split(separator: ",").map(String.init))
#endif

#if DEBUG

/// Debug-only resize benchmark: `QCPIE_RESIZE_BENCH=<output file>` (optionally `QCPIE_BENCH_FOLDER=<media folder>` for a
/// queue). Opens the Upload tab, the first Frame.io favourite and the drawer, then resizes the window and drags the
/// queue divider, timing each frame (layout + display, forced synchronously), and writes the results. Never runs
/// otherwise.
@MainActor
enum ResizeBench {
    static var output: String? { ProcessInfo.processInfo.environment["QCPIE_RESIZE_BENCH"] }
    /// `QCPIE_BENCH_TAB=player|specs|scanner|upload` (default upload), to compare tabs.
    static var tab: AppTab {
        switch ProcessInfo.processInfo.environment["QCPIE_BENCH_TAB"] {
        case "player": return .player
        case "specs": return .specs
        default: return .upload
        }
    }
    static var folder: URL? { ProcessInfo.processInfo.environment["QCPIE_BENCH_FOLDER"].map { URL(fileURLWithPath: $0) } }

    static func run() async {
        guard let output else { return }
        try? await Task.sleep(for: .seconds(4))
        // QCPIE_BENCH_FAV=<index> picks which favourite to open (default the first).
        let index = Int(ProcessInfo.processInfo.environment["QCPIE_BENCH_FAV"] ?? "") ?? 0
        let favourites = FrameIOBrowser.shared.favourites
        if favourites.indices.contains(index) { FrameIOBrowser.shared.open(favourites[index]) }
        UserDefaults.standard.set(true, forKey: "uploadLogOpen")
        try? await Task.sleep(for: .seconds(6))   // listing, thumbnails, queue
        guard let window = NSApp.windows.first(where: { $0.isVisible && $0.contentView != nil && $0.frame.width > 800 }) else {
            try? "no window".write(toFile: output, atomically: true, encoding: .utf8)
            return
        }
        // A large window (the cost grows with its size): QCPIE_BENCH_SIZE=WxH, default 1900×1200, within the screen.
        let size = (ProcessInfo.processInfo.environment["QCPIE_BENCH_SIZE"] ?? "1900x1200").split(separator: "x").compactMap { Double($0) }
        if size.count == 2, let screen = window.screen?.visibleFrame {
            let frame = NSRect(x: screen.minX, y: screen.maxY - min(size[1], screen.height),
                               width: min(size[0], screen.width), height: min(size[1], screen.height))
            window.setFrame(frame, display: true)
            try? await Task.sleep(for: .seconds(1))
        }
        let original = window.frame
        var report = ["window \(Int(original.width))×\(Int(original.height)), favourite: \(FrameIOBrowser.shared.path.last?.title ?? "-"), items: \(FrameIOBrowser.shared.items.count), queue: \(UploadQueue.shared.jobs.count)"]

        // 1. Window resize: 120 steps of 5 pt back and forth.
        var times: [Double] = []
        for step in 0..<120 {
            var frame = original
            let phase = step % 60
            frame.size.width = original.width - CGFloat(phase < 30 ? phase : 60 - phase) * 5
            let start = CACurrentMediaTime()
            window.setFrame(frame, display: true)
            window.contentView?.layoutSubtreeIfNeeded()
            window.displayIfNeeded()
            CATransaction.flush()
            times.append((CACurrentMediaTime() - start) * 1000)
        }
        window.setFrame(original, display: true)
        report.append(summary("window resize", times))

        // 2. Queue divider: 120 steps of the stored width (AppStorage hears the change at once; the forced layout updates).
        let key = "uploadPanelWidth"
        let width = UserDefaults.standard.double(forKey: key)
        times = []
        for step in 0..<120 {
            let phase = step % 60
            UserDefaults.standard.set(320 + Double(phase < 30 ? phase : 60 - phase) * 6, forKey: key)
            let start = CACurrentMediaTime()
            window.contentView?.layoutSubtreeIfNeeded()
            window.displayIfNeeded()
            CATransaction.flush()
            times.append((CACurrentMediaTime() - start) * 1000)
            try? await Task.sleep(for: .milliseconds(5))
        }
        UserDefaults.standard.set(width == 0 ? 380 : width, forKey: key)
        report.append(summary("divider drag", times))
        try? report.joined(separator: "\n").write(toFile: output, atomically: true, encoding: .utf8)
    }

    private static func summary(_ name: String, _ times: [Double]) -> String {
        let sorted = times.sorted()
        let median = sorted[sorted.count / 2], p90 = sorted[Int(Double(sorted.count) * 0.9)], worst = sorted.last ?? 0
        return String(format: "%@: median %.1f ms, p90 %.1f ms, worst %.1f ms (%d frames)", name, median, p90, worst, times.count)
    }
}
#endif

#if DEBUG
/// Debug-only layout check: `QCPIE_UI_SHOTS=<folder>` (with `QCPIE_BENCH_FOLDER=<media folder>` for a queue) captures
/// every tab, with its side panels open, at the narrowest window and a wide one, at Small and Large Button Size, then
/// quits. For spotting labels that clip or truncate. Run the bare debug binary: its settings are its own (`QCpie` domain).
@MainActor
enum UIShots {
    static var output: String? { ProcessInfo.processInfo.environment["QCPIE_UI_SHOTS"] }

    struct Hooks {
        let setTab: (AppTab) -> Void
        let openPanels: () -> Void
        /// Player drawer tabs to capture beside the default one.
        let setPlayerDrawer: (PlayerDrawerTab) -> Void
        /// `QCPIE_BENCH_CROP=1`: runs Crop Match on the queue first (and waits for it), for the Scan tab's results.
        var runCropMatch: (() async -> Void)? = nil
    }

    static var cropMatch: Bool { ProcessInfo.processInfo.environment["QCPIE_BENCH_CROP"] != nil }

    static func run(_ hooks: Hooks) async {
        guard let output else { return }
        try? FileManager.default.createDirectory(atPath: output, withIntermediateDirectories: true)
        try? await Task.sleep(for: .seconds(5))
        guard let window = NSApp.windows.first(where: { $0.isVisible && $0.contentView != nil && $0.frame.width > 800 }) else { return }
        hooks.openPanels()
        if cropMatch { await hooks.runCropMatch?() }
        let original = ThemeManager.shared.buttonZoom
        for zoom in [UIButtonZoomLevel.small, .large] {
            ThemeManager.shared.buttonZoom = zoom
            for width in [1080.0, 1440.0] {
                var frame = window.frame
                frame.size = NSSize(width: width, height: 820)
                window.setFrame(frame, display: true)
                for tab in AppTab.visibleTabs {
                    hooks.setTab(tab)
                    let drawers: [PlayerDrawerTab?] = tab == .player ? [.mediaInfo, .notes, .subtitles] : [nil]
                    for drawer in drawers {
                        if let drawer { hooks.setPlayerDrawer(drawer) }
                        try? await Task.sleep(for: .milliseconds(1500))
                        capture(window, to: "\(output)/\(tab)\(drawer.map { "-\($0)" } ?? "")_\(Int(width))_\(zoom.title).png")
                    }
                }
            }
        }
        ThemeManager.shared.buttonZoom = original
        NSApp.terminate(nil)
    }

    private static func capture(_ window: NSWindow, to path: String) {
        guard let view = window.contentView, let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { return }
        view.cacheDisplay(in: view.bounds, to: rep)
        try? rep.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: path))
    }
}
#endif
