// linecore parity: runs QCpie's Swift EdgeDetector and linecore (C++) on the same frames and requires identical
// detections and segments. Synthetic cases from Tests/LineFinderScenes.swift, then every frame of the clips in the
// footage folder. premiere/linecore/tests/run.sh [footage folder, default _TEST] [--no-real] [--all] [--segments]
import Foundation
@preconcurrency import AVFoundation
import CoreVideo

var failures: [String] = []
var compared = 0

func settings(_ c: QCConfig) -> lc_settings {
    var s = lc_settings_default()
    let rgb = c.targetRGB ?? RGBColor(r: 0, g: 255, b: 0)
    s.target_r = rgb.r; s.target_g = rgb.g; s.target_b = rgb.b
    s.any_color = c.anyColor ? 1 : 0
    s.sensitivity = c.sensitivity
    s.tolerance = c.tolerance
    s.edge_depth = Int32(c.edgeDepth)
    s.min_span_ratio = c.minSpanRatio
    s.scan_splits = c.scanFullScreen ? 1 : 0
    s.report_off_color = c.reportOffColorLines ? 1 : 0
    s.persistence_frames = Int32(c.persistenceFrames)
    s.exposure_boost = c.enableExposureBoost ? 1 : 0
    s.ignore_full_black = c.ignoreFullBlackFrames ? 1 : 0
    s.highlight_expansion = c.enableHighlightExpansion ? 1 : 0
    s.ignore_full_white = c.ignoreFullWhiteFrames ? 1 : 0
    return s
}

func edge(_ e: lc_edge) -> EdgeLocation { EdgeLocation.allCases[Int(e.rawValue)] }

func describe(_ d: LineDetection) -> String {
    "\(d.edge.rawValue) t=\(d.thickness) \(d.detectedColor.hexString) span=\(d.spanRatio) α=\(d.score)\(d.isWeak ? " weak" : "")\(d.isOffColor ? " off" : "") pos=\(d.position.map(String.init) ?? "-")"
}

func describe(_ d: lc_detection) -> String {
    "\(edge(d.edge).rawValue) t=\(d.thickness) \(RGBColor(r: d.r, g: d.g, b: d.b).hexString) span=\(d.span_ratio) α=\(d.score)\(d.is_weak != 0 ? " weak" : "")\(d.is_off_color != 0 ? " off" : "") pos=\(d.position >= 0 ? String(d.position) : "-")"
}

func same(_ a: LineDetection, _ b: lc_detection) -> Bool {
    a.edge == edge(b.edge) && a.thickness == Int(b.thickness) && a.detectedColor == RGBColor(r: b.r, g: b.g, b: b.b)
        && a.spanRatio == b.span_ratio && a.score == b.score && a.isWeak == (b.is_weak != 0)
        && a.isOffColor == (b.is_off_color != 0) && (a.position ?? -1) == Int(b.position)
}

/// One linecore detector per config, scanning the buffer's clean aperture exactly as EdgeDetector does.
final class Pair {
    let config: QCConfig
    let swift = EdgeDetector()
    let c: OpaquePointer
    var out = [lc_detection](repeating: lc_detection(), count: 64)

    init(_ config: QCConfig) {
        self.config = config
        var s = settings(config)
        c = lc_detector_create(&s)
    }
    deinit { lc_detector_destroy(c) }

    func scan(_ pb: CVPixelBuffer) -> (swift: [LineDetection], c: [lc_detection]) {
        let swiftResult = swift.scanPixelBuffer(pb, config: config)
        CVPixelBufferLockBaseAddress(pb, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(pb, .readOnly) }
        let bw = CVPixelBufferGetWidth(pb), bh = CVPixelBufferGetHeight(pb), bpr = CVPixelBufferGetBytesPerRow(pb)
        var ox = 0, oy = 0, w = bw, h = bh
        let clean = CVImageBufferGetCleanRect(pb)
        if clean.width >= 1 && clean.height >= 1 {
            ox = min(bw, max(0, Int(clean.minX.rounded())))
            oy = min(bh, max(0, bh - Int(clean.maxY.rounded())))
            w = min(bw - ox, Int(clean.width.rounded()))
            h = min(bh - oy, Int(clean.height.rounded()))
        }
        let base = CVPixelBufferGetBaseAddress(pb)!.assumingMemoryBound(to: UInt8.self) + oy * bpr + ox * 4
        let n = Int(lc_detector_scan(c, base, Int32(w), Int32(h), Int32(bpr), &out, Int32(out.count)))
        return (swiftResult, Array(out.prefix(n)))
    }

    /// Records a mismatch; returns true when both agree.
    @discardableResult
    func check(_ pb: CVPixelBuffer, label: String) -> (swift: [LineDetection], c: [lc_detection]) {
        let r = scan(pb)
        compared += 1
        if r.swift.count != r.c.count || !zip(r.swift, r.c).allSatisfy({ same($0, $1) }) {
            failures.append("\(label)\n    swift: \(r.swift.map(describe).joined(separator: "; "))\n    c:     \(r.c.map(describe).joined(separator: "; "))")
        }
        return r
    }
}

// MARK: 1. Synthetic cases

print("== Synthetic cases")
let variants: [(String, (QCConfig) -> QCConfig)] = [
    ("", { $0 }),
    ("+splits", { var c = $0; c.scanFullScreen = true; return c }),
    ("any colour", { var c = $0; c.anyColor = true; return c }),
    ("sens 0.9", { var c = $0; c.sensitivity = 0.9; return c }),
]
for c in LineCase.positives + LineCase.negatives + LineCase.offColor {
    let isOffColorCase = LineCase.offColor.contains { $0.name == c.name } && c.expectedEdge != nil
    let pb = c.frame().makePixelBuffer()
    for (name, variant) in variants {
        let r = Pair(variant(c.config)).check(pb, label: "synthetic: \(c.name) \(name)")
        if name.isEmpty {
            let hits = r.c.filter { $0.is_weak == 0 && $0.is_off_color == 0 }
            let verdict = isOffColorCase ? (r.c.contains { $0.is_off_color != 0 } ? "off-colour" : "WRONG") : c.expectedEdge.map { e in hits.contains { edge($0.edge) == e } ? "hit" : "MISS" } ?? (hits.isEmpty ? "clean" : "FALSE FLAG")
            print("\(c.name) → \(verdict) \(r.c.map(describe).joined(separator: "; "))")
        }
    }
}
// Padded buffer (1088 rows, clean aperture 1080) and odd row bytes.
let padded = Scenes.picture(seed: 4, width: 640, height: 360)
var paddedLine = padded
paddedLine.drawEdgeLine(.bottom, color: Scenes.green)
Pair(LineCase.greenConfig).check(paddedLine.makePixelBuffer(paddingRows: 8, paddingColor: Scenes.green), label: "synthetic: padded buffer")
print("synthetic comparisons: \(compared), mismatches: \(failures.count)")

// MARK: 2. Cost per 1080p frame (Swift vs linecore)

let pic = Scenes.picture(seed: 7, width: 1920, height: 1080).makePixelBuffer()
for (label, cfg, n) in [("edges", QCConfig(targetHex: "#00FF00"), 300), ("edges+splits", QCConfig(targetHex: "#00FF00", scanFullScreen: true), 30),
                        ("any colour", QCConfig(targetHex: "#00FF00", anyColor: true), 100), ("black", QCConfig(targetHex: "#000000", tolerance: 0.03), 300)] {
    let pair = Pair(cfg)
    var t0 = CFAbsoluteTimeGetCurrent()
    for _ in 0..<n { _ = pair.swift.scanPixelBuffer(pic, config: cfg) }
    let swiftMs = (CFAbsoluteTimeGetCurrent() - t0) / Double(n) * 1000
    CVPixelBufferLockBaseAddress(pic, .readOnly)
    let base = CVPixelBufferGetBaseAddress(pic)!.assumingMemoryBound(to: UInt8.self)
    let bpr = Int32(CVPixelBufferGetBytesPerRow(pic))
    t0 = CFAbsoluteTimeGetCurrent()
    for _ in 0..<n { _ = lc_detector_scan(pair.c, base, 1920, 1080, bpr, &pair.out, Int32(pair.out.count)) }
    let cMs = (CFAbsoluteTimeGetCurrent() - t0) / Double(n) * 1000
    CVPixelBufferUnlockBaseAddress(pic, .readOnly)
    print(String(format: "== 1080p cost (%@): swift %.2f ms, linecore %.2f ms", label, swiftMs, cMs))
}

// MARK: 3. Real footage, every frame

let args = CommandLine.arguments.dropFirst()
let root = URL(fileURLWithPath: args.first { !$0.hasPrefix("--") } ?? "_TEST")
let configs = [
    QCConfig(targetHex: "#00FF00", tolerance: 0.25),
    QCConfig(targetHex: "#000000", tolerance: 0.03),
    QCConfig(targetHex: "#FFFFFF", tolerance: 0.03),
    QCConfig(targetHex: "#00FF00", tolerance: 0.25, scanFullScreen: true),
]

func clips() -> [URL] {
    guard let e = FileManager.default.enumerator(at: root, includingPropertiesForKeys: [.fileSizeKey]) else { return [] }
    return e.compactMap { $0 as? URL }
        .filter { ["mp4", "mov"].contains($0.pathExtension.lowercased()) }
        .filter { args.contains("--all") || ((try? $0.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0) < 500_000_000 }
        .sorted { $0.path < $1.path }
}

func checkClip(_ url: URL) async {
    let asset = AVURLAsset(url: url)
    guard let track = try? await asset.loadTracks(withMediaType: .video).first, let reader = try? AVAssetReader(asset: asset) else {
        failures.append("real: can't open \(url.lastPathComponent)")
        return
    }
    let output = AVAssetReaderTrackOutput(track: track, outputSettings: [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA])
    output.alwaysCopiesSampleData = false
    reader.add(output)
    reader.startReading()
    let pairs = configs.map(Pair.init)
    var swiftFrames = [[FrameError]](repeating: [], count: configs.count)
    let segmenters = configs.map { lc_segmenter_create(Int32($0.persistenceFrames))! }
    defer { segmenters.forEach { lc_segmenter_destroy($0) } }
    var frame = 0
    let before = failures.count
    while let sample = output.copyNextSampleBuffer() {
        autoreleasepool {
            guard let pb = CMSampleBufferGetImageBuffer(sample) else { return }
            for (i, pair) in pairs.enumerated() {
                let r = pair.check(pb, label: "real: \(url.lastPathComponent) frame \(frame) \(pair.config.targetHex)\(pair.config.scanFullScreen ? " +splits" : "")")
                if !r.swift.isEmpty { swiftFrames[i].append(FrameError(frameIndex: frame, timecode: "", detections: r.swift)) }
                lc_segmenter_add(segmenters[i], Int64(frame), r.c, Int32(r.c.count))
            }
        }
        frame += 1
    }
    var segmentCount = 0
    for (i, config) in configs.enumerated() {
        let swiftSegments = VideoQCResult(fileURL: url, fileName: "", resolution: "", fps: 25, totalFrames: frame, durationSeconds: 0,
                                          errorFrames: LineHysteresis.filter(swiftFrames[i], minRun: config.persistenceFrames)).glitchSegments
        var out = [lc_segment](repeating: lc_segment(), count: 4096)
        let n = Int(lc_segmenter_finish(segmenters[i], &out, Int32(out.count)))
        let cSegments = Array(out.prefix(n))
        segmentCount += n
        if args.contains("--segments") {
            for c in cSegments {
                print("    \(config.targetHex)\(config.scanFullScreen ? " +splits" : "") \(edge(c.edge).rawValue) \(c.start_frame)–\(c.end_frame) " +
                      "t=\(c.avg_thickness) \(RGBColor(r: c.r, g: c.g, b: c.b).hexString)\(c.is_off_color != 0 ? " off" : "")\(c.position >= 0 ? " pos=\(c.position)" : "")")
            }
        }
        let match = swiftSegments.count == n && zip(swiftSegments, cSegments).allSatisfy { s, c in
            s.startFrame == Int(c.start_frame) && s.endFrame == Int(c.end_frame) && s.edge == edge(c.edge)
                && s.avgThickness == Int(c.avg_thickness) && s.detectedColor == RGBColor(r: c.r, g: c.g, b: c.b)
                && s.isOffColor == (c.is_off_color != 0) && (s.position ?? -1) == Int(c.position)
        }
        if !match {
            failures.append("real segments: \(url.lastPathComponent) \(config.targetHex): swift \(swiftSegments.map { "\($0.edge.rawValue) \($0.startFrame)–\($0.endFrame)" }) c \(cSegments.map { "\(edge($0.edge).rawValue) \($0.start_frame)–\($0.end_frame)" })")
        }
    }
    print("\(failures.count == before ? "OK  " : "DIFF") \(url.path.replacingOccurrences(of: root.path + "/", with: "")): \(frame) frames, \(segmentCount) segments")
}

if !args.contains("--no-real"), FileManager.default.fileExists(atPath: root.path) {
    print("== Real footage (\(root.path), every frame × \(configs.count) configs)")
    let sem = DispatchSemaphore(value: 0)
    Task {
        for url in clips() { await checkClip(url) }
        sem.signal()
    }
    sem.wait()
}

print("== \(compared) frame comparisons")
if failures.isEmpty {
    print("ALL PASSED")
} else {
    print("FAILED (\(failures.count)):")
    failures.prefix(40).forEach { print("- \($0)") }
    exit(1)
}
