import AppKit
import AVFoundation
import VideoToolbox
import VideoQCLib
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
                // QCPIE_SHOTS_HEIGHT: a taller window, to see further down a page.
                frame.size = NSSize(width: width, height: ProcessInfo.processInfo.environment["QCPIE_SHOTS_HEIGHT"].flatMap(Double.init) ?? 820)
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

/// Debug-only LUT check: `QCPIE_LUT_CHECK=<folder> QCPIE_LUT_CLIP=<video> QCPIE_LUT_NAME=<LUT>` loads the clip into
/// slot A with the LUT and saves, at each step (LUT on, off, on again, with EV, playing), what the viewport's still
/// layer shows and the video output's frame (`_output`: what the display link presents; a hidden window never ticks
/// it, so the still layer only follows when the window is on screen), plus the exported screenshot. Then quits.
@MainActor
enum LUTCheck {
    static var output: String? { ProcessInfo.processInfo.environment["QCPIE_LUT_CHECK"] }

    static func run(engine: PlayerEngine) async {
        guard let output, let clip = ProcessInfo.processInfo.environment["QCPIE_LUT_CLIP"],
              let name = ProcessInfo.processInfo.environment["QCPIE_LUT_NAME"] else { return }
        try? FileManager.default.createDirectory(atPath: output, withIntermediateDirectories: true)
        let url = URL(fileURLWithPath: clip)
        // As from the queue menu: the clip is loaded first, then given the LUT.
        LUTLibrary.shared.assign(nil, to: [url])
        try? await Task.sleep(for: .seconds(3))
        NSApp.activate(ignoringOtherApps: true)
        NSApp.windows.first { $0.frame.width > 800 }?.orderFrontRegardless()
        // QCPIE_LUT_AUTOPLAY: the clip plays as it loads (queue Auto) and gets its LUT while playing.
        let autoplay = ProcessInfo.processInfo.environment["QCPIE_LUT_AUTOPLAY"] != nil
        engine.loadVideo(url: url, into: .slotA, initialSeekFrame: 12, autoplay: autoplay, forceAutoplay: autoplay)
        try? await Task.sleep(for: .seconds(autoplay ? 1.5 : 4))
        LUTLibrary.shared.assign(name, to: [url])
        engine.lutAssignmentsChanged([url])
        try? await Task.sleep(for: .seconds(2))
        if autoplay { engine.pause(); try? await Task.sleep(for: .seconds(1)) }
        func save(_ label: String) {
            guard let view = NSApp.windows.compactMap({ $0.contentView.flatMap(find) }).first else { return }
            var image: CGImage? = nil
            if let contents = view.debugStillContentsA {
                if CFGetTypeID(contents as CFTypeRef) == CGImage.typeID { image = (contents as! CGImage) }
                else if CFGetTypeID(contents as CFTypeRef) == CVPixelBufferGetTypeID() {
                    VTCreateCGImageFromCVPixelBuffer(contents as! CVPixelBuffer, options: nil, imageOut: &image)
                }
            }
            write(image, to: "\(output)/\(label).png")
            // What the display link would present (it doesn't tick while the window is hidden).
            if let out = engine.slotA.videoOutput {
                var shown = CMTime.invalid
                if let pb = out.copyPixelBuffer(forItemTime: engine.slotA.player.currentTime(), itemTimeForDisplay: &shown) {
                    var cg: CGImage?
                    VTCreateCGImageFromCVPixelBuffer(pb, options: nil, imageOut: &cg)
                    write(cg, to: "\(output)/\(label)_output.png")
                }
            }
            let state = "\(label): box=\(engine.slotA.lut.value?.name ?? "nil") comp=\(engine.slotA.player.currentItem?.videoComposition != nil) playing=\(engine.isPlaying) visible=\(NSApp.windows.contains { $0.occlusionState.contains(.visible) && $0.frame.width > 800 }) t=\(CMTimeGetSeconds(engine.slotA.player.currentTime()))\n"
            if let h = FileHandle(forWritingAtPath: "\(output)/log.txt") { h.seekToEndOfFile(); h.write(Data(state.utf8)); try? h.close() }
            else { try? state.write(toFile: "\(output)/log.txt", atomically: true, encoding: .utf8) }
        }
        if ProcessInfo.processInfo.environment["QCPIE_DRAW_CHECK"] != nil {
            // Note drawings: strokes go into a note on this frame (saved: it writes the clip's notes file).
            func grab(_ label: String) {
                guard let window = NSApp.windows.first(where: { $0.frame.width > 800 }) else { return }
                let task = Process()
                task.executableURL = URL(fileURLWithPath: "/usr/sbin/screencapture")
                task.arguments = ["-x", "-o", "-l", "\(window.windowNumber)", "\(output)/\(label).png"]
                try? task.run()
                task.waitUntilExit()
            }
            engine.activeNotesURL = url
            engine.activeNotes = []
            engine.toggleDrawMode()
            let circle = (0...40).flatMap { i -> [Double] in
                let a = Double(i) / 40 * 2 * .pi
                return [0.5 + 0.15 * cos(a), 0.45 + 0.2 * sin(a)]
            }
            // As the viewport does on mouse-up: each stroke goes into this frame's note (the first one creates it).
            engine.onStrokeFinished?(circle)
            engine.onStrokeFinished?([0.1, 0.1, 0.3, 0.3])
            try? await Task.sleep(for: .seconds(1))
            grab("d1_drawing")
            let log = "notes=\(engine.activeNotes.count) strokes=\(engine.activeNotes.first?.drawing?.count ?? 0) frame=\(engine.activeNotes.first?.frameIndex ?? -1) current=\(engine.currentFrame)\n"
            try? log.write(toFile: "\(output)/draw.txt", atomically: true, encoding: .utf8)
            engine.stepFrames(count: 5, forward: true)
            try? await Task.sleep(for: .seconds(1))
            grab("d1b_other_frame")
            engine.stepFrames(count: 5, forward: false)
            try? await Task.sleep(for: .seconds(1))
            grab("d1c_back")
            // Drawn on frame 17 meanwhile and back on 12: 12's strokes go into its note, not a new one.
            engine.stepFrames(count: 5, forward: true)
            try? await Task.sleep(for: .milliseconds(500))
            engine.onStrokeFinished?([0.7, 0.7, 0.8, 0.8])
            engine.stepFrames(count: 5, forward: false)
            try? await Task.sleep(for: .milliseconds(500))
            engine.onStrokeFinished?([0.6, 0.2, 0.7, 0.3])
            let notes12 = engine.activeNotes.filter { $0.frameIndex == engine.currentFrame }
            let log2 = "after revisit: notes=\(engine.activeNotes.count) on12=\(notes12.count) strokes12=\(notes12.first?.drawing?.count ?? 0)\n"
            if let h = FileHandle(forWritingAtPath: "\(output)/draw.txt") { h.seekToEndOfFile(); h.write(Data(log2.utf8)); try? h.close() }
            engine.play()
            try? await Task.sleep(for: .milliseconds(300))
            let log3 = "after play: drawing=\(engine.isDrawingNote)\n"
            if let h = FileHandle(forWritingAtPath: "\(output)/draw.txt") { h.seekToEndOfFile(); h.write(Data(log3.utf8)); try? h.close() }
            engine.pause()
            engine.toggleDrawMode()
            engine.endDrawing()
            try? await Task.sleep(for: .seconds(1))
            grab("d2_saved_note")
            engine.play()
            try? await Task.sleep(for: .milliseconds(400))
            grab("d3_playing")
            NSApp.terminate(nil)
            return
        }
        save("1_paused_lut")
        engine.showLUTs = false
        try? await Task.sleep(for: .seconds(2))
        save("2_paused_off")
        engine.showLUTs = true
        try? await Task.sleep(for: .seconds(2))
        save("3_paused_on_again")
        engine.exposureEV = 1
        try? await Task.sleep(for: .seconds(2))
        save("4_paused_lut_ev1")
        engine.exposureEV = 0
        // Scrub: the AVPlayerLayer is on screen, so capture the window itself.
        func grabWindow(_ label: String) {
            guard let window = NSApp.windows.first(where: { $0.frame.width > 800 }) else { return }
            let task = Process()
            task.executableURL = URL(fileURLWithPath: "/usr/sbin/screencapture")
            task.arguments = ["-x", "-o", "-l", "\(window.windowNumber)", "\(output)/\(label)_window.png"]
            try? task.run()
            task.waitUntilExit()
        }
        grabWindow("4b_paused_window")
        // The first frames of a drag: the scrub layer is revealed as the drag starts.
        engine.startScrubbing()
        engine.scrubTo(progress: 0.3)
        grabWindow("4c_scrub_start")
        try? await Task.sleep(for: .milliseconds(150))
        grabWindow("4d_scrub_150ms")
        for step in 0..<90 {
            engine.scrubTo(progress: 0.5 + 0.45 * sin(Double(step) / 6))
            try? await Task.sleep(for: .milliseconds(8))
        }
        engine.scrubTo(progress: 0.3)
        try? await Task.sleep(for: .milliseconds(600))
        grabWindow("4e_scrub_held")
        engine.showLUTs = false
        try? await Task.sleep(for: .milliseconds(600))
        engine.scrubTo(progress: 0.3001)
        try? await Task.sleep(for: .milliseconds(600))
        grabWindow("4f_scrub_held_off")
        engine.showLUTs = true
        engine.endScrubbing(at: 0.75)
        try? await Task.sleep(for: .seconds(1))
        engine.seek(toTime: CMTime(value: 0, timescale: 25))
        engine.play()
        try? await Task.sleep(for: .milliseconds(500))
        save("5_playing_lut")
        engine.pause()
        try? await Task.sleep(for: .seconds(1))
        write(await engine.captureCompositedScreenshotImage(), to: "\(output)/6_screenshot.png")
        NSApp.terminate(nil)
    }

    private static func find(_ view: NSView) -> PlayerContainerNSView? {
        if let v = view as? PlayerContainerNSView { return v }
        for sub in view.subviews { if let v = find(sub) { return v } }
        return nil
    }

    private static func write(_ image: CGImage?, to path: String) {
        guard let image else { try? "none".write(toFile: path + ".txt", atomically: true, encoding: .utf8); return }
        try? NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: path))
    }
}
#endif
