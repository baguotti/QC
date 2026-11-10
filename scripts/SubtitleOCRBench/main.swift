// Benchmark for reading burned-in subtitles (docs/research/BURNED_IN_SUBTITLES_PLAN.md): runs the app's
// BurnedSubtitleReader on a clip and scores the cues against a reference .srt (text, frame-accurate timing, speed).
// Usage: run.sh <clip> <reference.srt> [samples/s] [language] [out.srt]
import AVFoundation
import CoreMedia
import Foundation

struct Cue { var start: Double; var end: Double; var text: String; var confidence: Float = 1 }

// MARK: - .srt

func parseSRT(_ raw: String) -> [Cue] {
    func secs(_ s: Substring) -> Double {
        let p = s.trimmingCharacters(in: .whitespaces).replacingOccurrences(of: ",", with: ".").split(separator: ":")
        guard p.count == 3, let h = Double(p[0]), let m = Double(p[1]), let x = Double(p[2]) else { return 0 }
        return h * 3600 + m * 60 + x
    }
    var cues: [Cue] = []
    let blocks = raw.replacingOccurrences(of: "\r\n", with: "\n").replacingOccurrences(of: "\u{FEFF}", with: "")
        .components(separatedBy: "\n\n")
    for block in blocks {
        let lines = block.split(separator: "\n", omittingEmptySubsequences: true)
        guard let t = lines.firstIndex(where: { $0.contains("-->") }) else { continue }
        let parts = lines[t].components(separatedBy: "-->")
        guard parts.count == 2 else { continue }
        cues.append(Cue(start: secs(Substring(parts[0])), end: secs(Substring(parts[1])),
                        text: lines[(t + 1)...].joined(separator: "\n")))
    }
    return cues
}

func srtTime(_ s: Double) -> String {
    let ms = Int((s * 1000).rounded())
    return String(format: "%02d:%02d:%02d,%03d", ms / 3_600_000, ms / 60_000 % 60, ms / 1000 % 60, ms % 1000)
}

// MARK: - Text comparison

/// Lowercased, curly quotes straightened, punctuation and line breaks folded to single spaces.
func normalise(_ s: String) -> String {
    let straight = s.replacingOccurrences(of: "’", with: "'").replacingOccurrences(of: "‘", with: "'")
        .replacingOccurrences(of: "“", with: "\"").replacingOccurrences(of: "”", with: "\"").lowercased()
    let kept = straight.unicodeScalars.map { CharacterSet.alphanumerics.contains($0) || $0 == "'" ? Character($0) : " " }
    return String(kept).split(separator: " ").joined(separator: " ")
}

func levenshtein(_ a: [Character], _ b: [Character]) -> Int {
    if a.isEmpty { return b.count }
    if b.isEmpty { return a.count }
    var prev = Array(0...b.count), cur = [Int](repeating: 0, count: b.count + 1)
    for i in 1...a.count {
        cur[0] = i
        for j in 1...b.count {
            cur[j] = min(prev[j] + 1, cur[j - 1] + 1, prev[j - 1] + (a[i - 1] == b[j - 1] ? 0 : 1))
        }
        swap(&prev, &cur)
    }
    return prev[b.count]
}

func distance(_ a: String, _ b: String) -> Double {
    let x = Array(normalise(a)), y = Array(normalise(b))
    guard max(x.count, y.count) > 0 else { return 0 }
    return Double(levenshtein(x, y)) / Double(max(x.count, y.count))
}

// MARK: - Read with the app's reader (Sources/VideoQCLib/BurnedSubtitleReader.swift)

let args = CommandLine.arguments
guard args.count >= 3 else { print("usage: <clip> <reference.srt> [samples/s] [language] [out.srt]"); exit(2) }
let clip = URL(fileURLWithPath: args[1])
let reference = parseSRT((try? String(contentsOfFile: args[2], encoding: .utf8)) ?? "")
let samplesPerSecond = args.count > 3 ? Double(args[3]) ?? 4 : 4
let language = args.count > 4 ? args[4] : "en-US"
let outPath = args.count > 5 ? args[5] : nil
let asset = AVURLAsset(url: clip)
let track = try await asset.loadTracks(withMediaType: .video).first!
let fps = Double(try await track.load(.nominalFrameRate))
let duration = try await asset.load(.duration).seconds
let started = CFAbsoluteTimeGetCurrent()
let result = try await BurnedSubtitleReader().read(clip, options: .init(region: .bottom, languages: language == "auto" ? [] : [language],
                                                                        samplesPerSecond: samplesPerSecond)) { _ in }
let wall = CFAbsoluteTimeGetCurrent() - started
let found = result.cues.map { Cue(start: $0.start, end: $0.end, text: $0.text) }

// MARK: - Score against the reference

func overlap(_ a: Cue, _ b: Cue) -> Double { max(0, min(a.end, b.end) - max(a.start, b.start)) }
var matchedCER: [Double] = []
var startErr: [Double] = [], endErr: [Double] = []
var recalled = 0
var wordErrors = 0
/// Same words in the same order, punctuation included (quote style and line breaks aside).
func sameWords(_ a: String, _ b: String) -> Bool {
    func fold(_ s: String) -> String {
        s.replacingOccurrences(of: "’", with: "'").replacingOccurrences(of: "‘", with: "'")
            .replacingOccurrences(of: "“", with: "\"").replacingOccurrences(of: "”", with: "\"")
            .split(whereSeparator: { $0.isWhitespace }).joined(separator: " ")
    }
    return fold(a) == fold(b)
}
var report: [String] = []
for ref in reference {
    guard let best = found.max(by: { overlap($0, ref) < overlap($1, ref) }), overlap(best, ref) > 0 else {
        report.append("MISSED  \(srtTime(ref.start))  \(ref.text.replacingOccurrences(of: "\n", with: " / "))")
        continue
    }
    let cer = distance(ref.text, best.text)
    matchedCER.append(cer)
    if cer <= 0.1 { recalled += 1 }
    if !sameWords(ref.text, best.text) { wordErrors += 1 }
    startErr.append(abs(best.start - ref.start) * fps)
    endErr.append(abs(best.end - ref.end) * fps)
    if cer > 0 {
        report.append(String(format: "CER %4.1f%%  %@\n   ref: %@\n   ocr: %@", cer * 100, srtTime(ref.start),
                             ref.text.replacingOccurrences(of: "\n", with: " / "), best.text.replacingOccurrences(of: "\n", with: " / ")))
    }
}
let extras: [Cue] = found.filter { f in !reference.contains { overlap($0, f) > 0 } }

func median(_ v: [Double]) -> Double { v.isEmpty ? .nan : v.sorted()[v.count / 2] }
func mean(_ v: [Double]) -> Double { v.isEmpty ? .nan : v.reduce(0, +) / Double(v.count) }

print("Clip: \(clip.lastPathComponent)  \(String(format: "%.2f", duration)) s at \(String(format: "%.3f", fps)) fps")
print("Sampling: \(samplesPerSecond)/s, language \(language), lower part of the picture")
print(String(format: "Time: %.1f s wall (%.1f× real time)", wall, duration / wall))
if let note = result.note { print("Note: \(note)") }
print("Marked to check: \(result.lowConfidence.count)")
print("Reference cues: \(reference.count); read: \(found.count); extra (no reference): \(extras.count)")
print(String(format: "Recall (CER ≤ 10%%): %d/%d = %.1f%%", recalled, reference.count, Double(recalled) / Double(max(1, reference.count)) * 100))
print(String(format: "Character error rate on matched cues: mean %.2f%%, median %.2f%%", mean(matchedCER) * 100, median(matchedCER) * 100))
print(String(format: "Timing error (frames): start median %.1f, mean %.1f, max %.0f; end median %.1f, mean %.1f, max %.0f",
             median(startErr), mean(startErr), startErr.max() ?? .nan, median(endErr), mean(endErr), endErr.max() ?? .nan))
if !report.isEmpty { print("\nDifferences:"); report.forEach { print($0) } }
if !extras.isEmpty { print("\nExtra cues:"); extras.forEach { print("  \(srtTime($0.start))  \($0.text.replacingOccurrences(of: "\n", with: " / "))") } }

// MARK: - Pass / fail (thresholds from the plan's go criteria)

let recall = Double(recalled) / Double(max(1, reference.count))
let onFrame = Double((startErr + endErr).filter { $0 < 0.6 }.count) / Double(max(1, startErr.count + endErr.count))
let checks: [(String, Bool)] = [
    (String(format: "cue recall %.1f%% ≥ 95%%", recall * 100), recall >= 0.95),
    (String(format: "character error rate %.2f%% ≤ 3%%", mean(matchedCER) * 100), mean(matchedCER) <= 0.03),
    ("lines with punctuation/word differences \(wordErrors) ≤ \(max(1, reference.count / 20))", wordErrors <= max(1, reference.count / 20)),
    (String(format: "boundaries on the reference frame %.1f%% ≥ 95%%", onFrame * 100), onFrame >= 0.95),
    ("extra cues \(extras.count) ≤ \(max(1, reference.count / 20))", extras.count <= max(1, reference.count / 20)),
    (String(format: "speed %.1f× ≥ 3× real time", duration / wall), duration / wall >= 3),
]
print("")
for (label, ok) in checks { print("\(ok ? "PASS" : "FAIL")  \(label)") }
print(checks.allSatisfy(\.1) ? "ALL PASSED" : "FAILED")

if let outPath {
    let srt = found.enumerated().map { "\($0.offset + 1)\n\(srtTime($0.element.start)) --> \(srtTime($0.element.end))\n\($0.element.text)\n" }
        .joined(separator: "\n")
    try? srt.write(toFile: outPath, atomically: true, encoding: .utf8)
    print("\nWrote \(outPath)")
}
