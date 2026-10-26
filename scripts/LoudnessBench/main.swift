// Loudness benchmark: renders known signals with ffmpeg, measures them with LoudnessMeter and compares with
// ffmpeg's ebur128 (true peak on). Then reports real clips from _TEST against ffmpeg.
// scripts/LoudnessBench/run.sh [--no-real]
import Foundation
@preconcurrency import AVFoundation

let work = URL(fileURLWithPath: CommandLine.arguments[1])
let skipReal = CommandLine.arguments.contains("--no-real")

@discardableResult
func ffmpeg(_ args: [String]) -> String {
    let p = Process()
    p.executableURL = URL(fileURLWithPath: "/opt/homebrew/bin/ffmpeg")
    p.arguments = ["-hide_banner", "-nostats"] + args
    let pipe = Pipe()
    p.standardError = pipe
    p.standardOutput = FileHandle.nullDevice
    try! p.run()
    let data = pipe.fileHandleForReading.readDataToEndOfFile()
    p.waitUntilExit()
    return String(decoding: data, as: UTF8.self)
}

struct Reference { var integrated: Double?; var range: Double?; var truePeak: Double? }

func reference(_ url: URL) -> Reference {
    let out = ffmpeg(["-i", url.path, "-map", "0:a:0", "-af", "ebur128=peak=true", "-f", "null", "-"])
    guard let summary = out.range(of: "Summary:") else { return Reference() }
    let tail = String(out[summary.upperBound...])
    func value(_ label: String) -> Double? {
        guard let r = tail.range(of: label + ":") else { return nil }
        let rest = tail[r.upperBound...].trimmingCharacters(in: .whitespaces)
        return Double(rest.split(separator: " ").first.map(String.init) ?? "")
    }
    return Reference(integrated: value("I"), range: value("LRA"), truePeak: value("Peak"))
}

func measure(_ url: URL) async -> (DeliverablesInspector.AudioLevels, Double) {
    let start = Date()
    let r = await DeliverablesInspector.extractAudioLevels(for: url)
    return (r, Date().timeIntervalSince(start))
}

var failures = 0
func check(_ name: String, _ ok: Bool, _ detail: String) {
    print("\(ok ? "  ok  " : "  FAIL") \(name): \(detail)")
    if !ok { failures += 1 }
}

func fmt(_ v: Double?) -> String { v.map { String(format: "%.2f", $0) } ?? "nil" }

/// (name, ffmpeg lavfi source + filters, channel layout, expected notes substring or nil)
let cases: [(String, [String], String?)] = [
    ("5.1 AAC loud LFE + surrounds (channel order)", ["-f", "lavfi", "-i", "anoisesrc=c=pink:d=15:r=48000:a=0.1:seed=6", "-af", "pan=5.1|FL=0.3*c0|FR=0.3*c0|FC=0.2*c0|LFE=c0|BL=0.8*c0|BR=0.8*c0", "-c:a", "aac", "-b:a", "384k"], nil),
    ("5.1 silent LFE", ["-f", "lavfi", "-i", "anoisesrc=c=pink:d=10:r=48000:a=0.1:seed=7", "-af", "pan=5.1|FL=c0|FR=0.9*c0|FC=0.7*c0|LFE=0*c0|BL=0.5*c0|BR=0.4*c0"], nil),
    ("short clip 0.3 s", ["-f", "lavfi", "-i", "sine=f=1000:d=0.3:r=48000"], nil),
    ("sine 1k -23 dBFS stereo 48k", ["-f", "lavfi", "-i", "sine=f=1000:d=20:r=48000", "-af", "volume=-23dB+0.0dB,volume=3.0103dB,pan=stereo|c0=c0|c1=c0"], "Dual mono"),
    ("sine 1k -18 dBFS mono 44.1k", ["-f", "lavfi", "-i", "sine=f=1000:d=12:r=44100", "-af", "volume=-14.9897dB"], nil),
    ("pink noise stereo", ["-f", "lavfi", "-i", "anoisesrc=c=pink:d=30:r=48000:a=0.2:seed=1", "-f", "lavfi", "-i", "anoisesrc=c=pink:d=30:r=48000:a=0.2:seed=2", "-filter_complex", "[0][1]amerge=inputs=2"], nil),
    ("loud/quiet sections (LRA)", ["-f", "lavfi", "-i", "anoisesrc=c=pink:d=40:r=48000:a=0.3:seed=3", "-af", "volume='if(lt(mod(t,20),10),1,0.1)':eval=frame,pan=stereo|c0=c0|c1=0.9*c0"], nil),
    ("inter-sample peak (fs/4 sine, 45°)", ["-f", "lavfi", "-i", "aevalsrc=0.5*sin(2*PI*12000*t+PI/4)|-0.5*sin(2*PI*12000*t+PI/4):s=48000:d=5"], "Out of phase"),
    ("5.1 noise", ["-f", "lavfi", "-i", "anoisesrc=c=pink:d=15:r=48000:a=0.1:seed=4", "-af", "pan=5.1|FL=c0|FR=0.8*c0|FC=0.5*c0|LFE=0.9*c0|BL=0.3*c0|BR=0.2*c0"], nil),
    ("silent right channel", ["-f", "lavfi", "-i", "anoisesrc=c=pink:d=10:r=48000:a=0.2:seed=5", "-af", "pan=stereo|c0=c0|c1=0*c0"], "Right channel silent"),
    ("silence", ["-f", "lavfi", "-i", "anullsrc=r=48000:cl=stereo", "-t", "5"], nil),
]

print("Synthetic cases (ours vs ffmpeg ebur128)")
for (name, args, note) in cases {
    let isAAC = args.contains("aac")
    let url = work.appendingPathComponent(name.replacingOccurrences(of: " ", with: "_").replacingOccurrences(of: "/", with: "-") + (isAAC ? ".m4a" : ".wav"))
    ffmpeg(["-y"] + args + (isAAC ? [] : ["-c:a", "pcm_f32le"]) + [url.path])
    let ref = reference(url)
    let (levels, seconds) = await measure(url)
    guard let m = levels.loudness else { check(name, false, "no measurement"); continue }
    var ok = true
    if name == "silence" {
        ok = m.integrated == nil && levels.isMute
    } else {
        if name.hasPrefix("short") {
            // ffmpeg reports −70 for clips under one 400 ms block; −18 dBFS 1 kHz sine, mono → −21.0 LUFS.
            ok = ok && m.integrated.map { abs($0 - -21.0) <= 0.3 } == true && !levels.isMute
        } else if let ri = ref.integrated, let i = m.integrated { ok = ok && abs(ri - i) <= 0.1 } else { ok = false }
        // ffmpeg over-reads this one (−5.4); the exact true peak is 0.5 (−6.02 dB) with samples at 0.354.
        if name.hasPrefix("inter-sample") { ok = ok && abs(m.truePeak - 20 * log10(0.5)) <= 0.3 }
        // Lossy: Apple's and ffmpeg's AAC decoders produce slightly different samples (LFE especially).
        else if let rt = ref.truePeak { ok = ok && abs(rt - m.truePeak) <= (isAAC ? 0.75 : 0.5) }
        if !name.hasPrefix("short"), let rl = ref.range, let l = m.range { ok = ok && abs(rl - l) <= 0.5 }
    }
    if let note { ok = ok && m.channelNotes.contains { $0.contains(note) } } else if name != "silence" { ok = ok && m.channelNotes.isEmpty }
    check(name, ok, "I \(fmt(m.integrated)) / \(fmt(ref.integrated))  TP \(fmt(m.truePeak)) / \(fmt(ref.truePeak))  LRA \(fmt(m.range)) / \(fmt(ref.range))  \(m.channelNotes)  \(String(format: "%.2fs", seconds))")
}

if !skipReal {
    print("\nReal clips (_TEST, first audio track)")
    let root = URL(fileURLWithPath: "_TEST")
    let exts: Set<String> = ["mov", "mp4", "m4v", "wav", "mp3", "aif", "aiff", "m4a"]
    var files: [URL] = []
    for case let u as URL in FileManager.default.enumerator(at: root, includingPropertiesForKeys: nil)?.allObjects ?? []
    where exts.contains(u.pathExtension.lowercased()) { files.append(u) }
    for url in files.sorted(by: { $0.path < $1.path }).prefix(12) {
        let (levels, seconds) = await measure(url)
        guard let m = levels.loudness else { print("   --   \(url.lastPathComponent): \(levels.levelString)"); continue }
        let ref = reference(url)
        var ok = true
        if let ri = ref.integrated, let i = m.integrated { ok = abs(ri - i) <= 0.2 }
        if let rt = ref.truePeak { ok = ok && abs(rt - m.truePeak) <= 0.5 }
        check(url.lastPathComponent, ok, "I \(fmt(m.integrated)) / \(fmt(ref.integrated))  TP \(fmt(m.truePeak)) / \(fmt(ref.truePeak))  LRA \(fmt(m.range)) / \(fmt(ref.range))  \(m.channelNotes)  \(String(format: "%.2fs", seconds))")
    }
}

print(failures == 0 ? "\nALL PASSED" : "\n\(failures) FAILED")
exit(failures == 0 ? 0 : 1)
