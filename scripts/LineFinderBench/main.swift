// Line Finder benchmark: runs with the Command Line Tools only (no Xcode / swift-testing).
// scripts/LineFinderBench/run.sh [--no-real]
import Foundation
@preconcurrency import AVFoundation
import CoreVideo

var failures: [String] = []
func describe(_ d: [LineDetection]) -> String {
    d.map { "\($0.edge.rawValue) t=\($0.thickness) α=\(String(format: "%.2f", $0.score))\($0.isWeak ? " weak" : "")\($0.isOffColor ? " OFF" : "") span=\(String(format: "%.2f", $0.spanRatio))" }.joined(separator: ", ")
}

// MARK: 1. Synthetic cases (v1 vs v2)
let detector = EdgeDetector()
let legacy = LegacyEdgeDetector()
print("== Synthetic cases\ncase | expected | v1 | v2 | v2 detail")
for c in LineCase.positives + LineCase.negatives {
    let buf = c.frame().makePixelBuffer()
    let all = detector.scanPixelBuffer(buf, config: c.config)
    let target = all.filter { !$0.isWeak && !$0.isOffColor }
    let old = legacy.scanPixelBuffer(buf, config: c.config).filter { !$0.isWeak }
    func verdict(_ d: [LineDetection]) -> String {
        if let e = c.expectedEdge { return d.contains { $0.edge == e } ? "hit" : "MISS" }
        return d.isEmpty ? "clean" : "FALSE FLAG"
    }
    let v = verdict(target)
    if v == "MISS" || v == "FALSE FLAG" { failures.append("synthetic: \(c.name) → \(v)") }
    print("\(c.name) | \(c.expectedEdge?.rawValue ?? "none") | \(verdict(old)) | \(v) | \(describe(all))")
}
for c in LineCase.offColor {
    let all = detector.scanPixelBuffer(c.frame().makePixelBuffer(), config: c.config)
    let ok = all.contains { $0.edge == c.expectedEdge && $0.isOffColor && $0.isWeak } && !all.contains { !$0.isOffColor }
    if !ok { failures.append("off-colour: \(c.name)") }
    print("\(c.name) (off-colour) | \(c.expectedEdge?.rawValue ?? "none") | - | \(ok ? "off-colour" : "WRONG") | \(describe(all))")
}

// MARK: 2. Cost per 1080p frame
let pic = Scenes.picture(seed: 7, width: 1920, height: 1080).makePixelBuffer()
for (label, cfg, n) in [("edges", QCConfig(targetHex: "#00FF00"), 200), ("edges+splits", QCConfig(targetHex: "#00FF00", scanFullScreen: true), 20), ("any colour", QCConfig(targetHex: "#00FF00", anyColor: true), 50)] {
    let t0 = CFAbsoluteTimeGetCurrent()
    for _ in 0..<n { _ = detector.scanPixelBuffer(pic, config: cfg) }
    print(String(format: "== 1080p cost (%@): %.2f ms/frame", label, (CFAbsoluteTimeGetCurrent() - t0) / Double(n) * 1000))
}

// MARK: 3. Real footage ground truth (local _TEST folder, skipped when absent)
enum Expect { case target, offColor, notTarget }
struct Truth { let file: String; let target: String; let edge: EdgeLocation; let seconds: ClosedRange<Double>; let expect: Expect; let note: String }
let truths: [Truth] = [
    Truth(file: "CK/Clean/CK_FA26_HOME_30Sec_16x9_E6.0_CLEAN.mp4", target: "#000000", edge: .right, seconds: 6.6...8.4, expect: .target, note: "2 px black line, right edge"),
    Truth(file: "CK/MP4/CK_HOME26_30sec_16x9_E3.0.mp4", target: "#00FF00", edge: .left, seconds: 14.2...15.8, expect: .target, note: "green line, left edge"),
    Truth(file: "CK/MP4/CK_HOME26_30sec_16x9_E3.0.mp4", target: "#00FF00", edge: .right, seconds: 6.6...8.4, expect: .target, note: "green line, right edge"),
    Truth(file: "CK/MP4/CK_HOME26_30sec_16x9_E3.0.mp4", target: "#FFFFFF", edge: .left, seconds: 14.2...15.8, expect: .notTarget, note: "green line must not pass as white"),
    Truth(file: "O&O/06/CK_FA26_BTW_O&O_06sec_16x9_E1.0.mp4", target: "#00FF00", edge: .left, seconds: 3.1...3.4, expect: .offColor, note: "grey 1 px column: off-colour, not green"),
]
let root = URL(fileURLWithPath: CommandLine.arguments.dropFirst().first { !$0.hasPrefix("--") } ?? "_TEST")
if !CommandLine.arguments.contains("--no-real"), FileManager.default.fileExists(atPath: root.path) {
    print("== Real footage (\(root.path))")
    let sem = DispatchSemaphore(value: 0)
    Task {
        var cache: [String: VideoQCResult] = [:]
        for t in truths {
            let url = root.appendingPathComponent(t.file)
            guard FileManager.default.fileExists(atPath: url.path) else { print("skip (missing): \(t.file)"); continue }
            let bw = QCConfig(targetHex: t.target).isBlackDetection || QCConfig(targetHex: t.target).isWhiteDetection
            let key = t.file + t.target
            let result: VideoQCResult
            if let cached = cache[key] { result = cached } else {
                result = await VideoScanner().scanSingleVideo(url: url, config: QCConfig(targetHex: t.target, tolerance: bw ? 0.03 : 0.25), fileIndex: 1, totalFiles: 1, flaggedSoFar: 0)
                cache[key] = result
            }
            let fps = max(1, result.fps)
            let range = Int(t.seconds.lowerBound * fps)...Int(t.seconds.upperBound * fps)
            let hits = result.glitchSegments.filter { $0.edge == t.edge && $0.startFrame <= range.upperBound && $0.endFrame >= range.lowerBound }
            let ok: Bool
            switch t.expect {
            case .target: ok = hits.contains { !$0.isOffColor }
            case .offColor: ok = hits.contains { $0.isOffColor } && !hits.contains { !$0.isOffColor }
            case .notTarget: ok = !hits.contains { !$0.isOffColor }
            }
            if !ok { failures.append("real: \(t.note) (\(t.file), \(t.target))") }
            print("\(ok ? "PASS" : "FAIL") \(t.note) [\(t.target)] → \(hits.map { "\($0.edge.rawValue) \($0.startTimecode)–\($0.endTimecode)\($0.isOffColor ? " off-colour" : "")" }.joined(separator: "; "))")
        }
        sem.signal()
    }
    sem.wait()
}

print(failures.isEmpty ? "\nALL PASSED" : "\nFAILURES:\n" + failures.joined(separator: "\n"))
exit(failures.isEmpty ? 0 : 1)
