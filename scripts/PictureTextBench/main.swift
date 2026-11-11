// Check Subs & Graphics (PictureTextScanner) on real deliverables with known answers (expected.txt): every file
// classified right and at least 5x real time overall. Files that aren't there (an unmounted drive) are skipped.
import AVFoundation
import Foundation

let root = URL(fileURLWithPath: CommandLine.arguments[1])
let lines = try String(contentsOf: root.appendingPathComponent("scripts/PictureTextBench/expected.txt"), encoding: .utf8)
    .split(separator: "\n").map(String.init).filter { !$0.hasPrefix("#") && !$0.isEmpty }
var failures = 0, checked = 0
var mediaSeconds = 0.0, wallSeconds = 0.0
for line in lines {
    let parts = line.split(separator: "|").map { $0.trimmingCharacters(in: .whitespaces) }
    let url = parts[0].hasPrefix("/") ? URL(fileURLWithPath: parts[0]) : root.appendingPathComponent(parts[0])
    guard FileManager.default.fileExists(atPath: url.path) else { print("SKIP  \(url.lastPathComponent) (not there)"); continue }
    let duration = (try? await AVURLAsset(url: url).load(.duration).seconds) ?? 0
    let t0 = CFAbsoluteTimeGetCurrent()
    let r = await PictureTextScanner.check(url)
    let dt = CFAbsoluteTimeGetCurrent() - t0
    if parts[1] != "n/a" { mediaSeconds += duration; wallSeconds += dt }
    checked += 1
    let subsOK = parts[1] == "any" || (parts[1] == "yes") == r.subtitlesLikely
    let gfxOK = parts[2] == "any" || (parts[2] == "yes") == r.hasGraphics
    // "n/a": audio or a still, nothing to check.
    let ok = parts[1] == "n/a" ? r.isUnavailable : subsOK && gfxOK && !r.isUnreadable && !r.isUnavailable
    if !ok { failures += 1 }
    print("\(ok ? "PASS" : "FAIL")  \(url.lastPathComponent): subs \(r.subtitlesLikely ? "yes" : "no"), graphics \(r.hasGraphics ? r.graphics.map(\.text).joined(separator: " · ") : "none") (\(String(format: "%.1f", duration / max(0.001, dt)))×)")
}
let speed = mediaSeconds / max(0.001, wallSeconds)
let speedOK = speed >= 5
print(String(format: "\n%@  speed %.1f× real time over %d files (≥ 5×)", speedOK ? "PASS" : "FAIL", speed, checked))
print(failures == 0 && speedOK && checked > 0 ? "ALL PASSED" : "FAILED")
