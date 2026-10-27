// Frame Check benchmark: renders clips with known frame-rate conversions, flash frames and Media Offline cards,
// scans them and checks the verdicts.
// scripts/FrameCheckBench/run.sh [--no-real]
import Foundation
@preconcurrency import AVFoundation
import CoreGraphics

let W = 640, H = 360

/// Wide textured strip; frames are windows into it at a horizontal position.
let texture: CGImage = {
    let tw = W * 8
    let ctx = CGContext(data: nil, width: tw, height: H, bitsPerComponent: 8, bytesPerRow: 0, space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)!
    var seed: UInt64 = 42
    func rnd() -> CGFloat { seed = seed &* 6364136223846793005 &+ 1442695040888963407; return CGFloat(seed >> 33) / CGFloat(1 << 31) }
    ctx.setFillColor(CGColor(red: 0.2, green: 0.25, blue: 0.3, alpha: 1)); ctx.fill(CGRect(x: 0, y: 0, width: tw, height: H))
    for _ in 0..<1400 {
        ctx.setFillColor(CGColor(red: rnd(), green: rnd(), blue: rnd(), alpha: 1))
        ctx.fill(CGRect(x: rnd() * CGFloat(tw), y: rnd() * CGFloat(H), width: 8 + rnd() * 60, height: 8 + rnd() * 60))
    }
    return ctx.makeImage()!
}()

/// Frame showing the texture at x (blended with a second position when `blend` is set).
func render(_ x: Double, blendWith x2: Double? = nil, weight: Double = 0, flip: Bool = false, fade: Double = 1) -> CVPixelBuffer {
    var pb: CVPixelBuffer?
    CVPixelBufferCreate(nil, W, H, kCVPixelFormatType_32BGRA, [kCVPixelBufferCGImageCompatibilityKey: true, kCVPixelBufferCGBitmapContextCompatibilityKey: true] as CFDictionary, &pb)
    let buffer = pb!
    CVPixelBufferLockBaseAddress(buffer, [])
    let ctx = CGContext(data: CVPixelBufferGetBaseAddress(buffer), width: W, height: H, bitsPerComponent: 8, bytesPerRow: CVPixelBufferGetBytesPerRow(buffer), space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue)!
    func draw(_ pos: Double) {
        let p = flip ? Double(W * 6) - pos : pos
        ctx.draw(texture, in: CGRect(x: -p, y: 0, width: Double(texture.width), height: Double(H)))
    }
    draw(x)
    if let x2, weight > 0 { ctx.setAlpha(weight); draw(x2); ctx.setAlpha(1) }
    if fade < 1 { ctx.setFillColor(CGColor(red: 0, green: 0, blue: 0, alpha: 1 - fade)); ctx.fill(CGRect(x: 0, y: 0, width: W, height: H)) }
    CVPixelBufferUnlockBaseAddress(buffer, [])
    return buffer
}

/// A solid frame, or an NLE-style Media Offline card (red with white text) when `text` is set.
func card(_ r: CGFloat, _ g: CGFloat, _ b: CGFloat, text: Bool = false) -> CVPixelBuffer {
    var pb: CVPixelBuffer?
    CVPixelBufferCreate(nil, W, H, kCVPixelFormatType_32BGRA, [kCVPixelBufferCGImageCompatibilityKey: true, kCVPixelBufferCGBitmapContextCompatibilityKey: true] as CFDictionary, &pb)
    let buffer = pb!
    CVPixelBufferLockBaseAddress(buffer, [])
    let ctx = CGContext(data: CVPixelBufferGetBaseAddress(buffer), width: W, height: H, bitsPerComponent: 8, bytesPerRow: CVPixelBufferGetBytesPerRow(buffer), space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue)!
    ctx.setFillColor(CGColor(red: r, green: g, blue: b, alpha: 1)); ctx.fill(CGRect(x: 0, y: 0, width: W, height: H))
    if text {
        ctx.setFillColor(CGColor(red: 1, green: 1, blue: 1, alpha: 1))
        for line in 0..<5 {   // lines of "text": white strokes
            for c in 0..<30 { ctx.fill(CGRect(x: 120 + c * 14, y: 90 + line * 40, width: 8, height: 18)) }
        }
    }
    CVPixelBufferUnlockBaseAddress(buffer, [])
    return buffer
}

/// A narrow-range Y′CbCr frame written code by code (super-whites and illegal colours survive into the file).
/// `pixel` returns (Y, Cb, Cr) for a luma position; chroma is sampled at even positions.
func yuv(_ pixel: (Int, Int) -> (UInt8, UInt8, UInt8)) -> CVPixelBuffer {
    var pb: CVPixelBuffer?
    CVPixelBufferCreate(nil, W, H, kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange, [kCVPixelBufferIOSurfacePropertiesKey: [:]] as CFDictionary, &pb)
    let buffer = pb!
    CVPixelBufferLockBaseAddress(buffer, [])
    let yp = CVPixelBufferGetBaseAddressOfPlane(buffer, 0)!.assumingMemoryBound(to: UInt8.self), ybpr = CVPixelBufferGetBytesPerRowOfPlane(buffer, 0)
    let cp = CVPixelBufferGetBaseAddressOfPlane(buffer, 1)!.assumingMemoryBound(to: UInt8.self), cbpr = CVPixelBufferGetBytesPerRowOfPlane(buffer, 1)
    for y in 0..<H {
        for x in 0..<W {
            let (l, cb, cr) = pixel(x, y)
            yp[y * ybpr + x] = l
            if y % 2 == 0 && x % 2 == 0 { cp[(y / 2) * cbpr + x] = cb; cp[(y / 2) * cbpr + x + 1] = cr }
        }
    }
    CVPixelBufferUnlockBaseAddress(buffer, [])
    CVBufferSetAttachment(buffer, kCVImageBufferYCbCrMatrixKey, kCVImageBufferYCbCrMatrix_ITU_R_709_2, .shouldPropagate)
    return buffer
}

/// A static legal picture (smooth luma ramp with mild colour) with `patch` painted over the given rectangle.
func legalPicture(_ n: Int, patch: CGRect? = nil, value: (UInt8, UInt8, UInt8) = (0, 0, 0)) -> CVPixelBuffer {
    yuv { x, y in
        if let patch, patch.contains(CGPoint(x: x, y: y)) { return value }
        return (UInt8(40 + x * 170 / W), UInt8(110 + y * 30 / H), UInt8(140 - x * 20 / W))
    }
}

/// Tagged like real deliverables (an untagged 360-line file would be read as BT.601).
let rec709: [String: Any] = [AVVideoColorPrimariesKey: AVVideoColorPrimaries_ITU_R_709_2, AVVideoTransferFunctionKey: AVVideoTransferFunction_ITU_R_709_2,
                             AVVideoYCbCrMatrixKey: AVVideoYCbCrMatrix_ITU_R_709_2]

func write(_ url: URL, fps: CMTime, frames: Int, codec: AVVideoCodecType = .h264, frame: (Int) -> CVPixelBuffer) {
    try? FileManager.default.removeItem(at: url)
    let writer = try! AVAssetWriter(outputURL: url, fileType: .mov)
    let input = AVAssetWriterInput(mediaType: .video, outputSettings: codec == .h264
        ? [AVVideoCodecKey: codec, AVVideoWidthKey: W, AVVideoHeightKey: H, AVVideoColorPropertiesKey: rec709, AVVideoCompressionPropertiesKey: [AVVideoAverageBitRateKey: 6_000_000]]
        : [AVVideoCodecKey: codec, AVVideoWidthKey: W, AVVideoHeightKey: H, AVVideoColorPropertiesKey: rec709])
    let adaptor = AVAssetWriterInputPixelBufferAdaptor(assetWriterInput: input, sourcePixelBufferAttributes: nil)
    writer.add(input); writer.startWriting(); writer.startSession(atSourceTime: .zero)
    for n in 0..<frames {
        while !input.isReadyForMoreMediaData { usleep(500) }
        adaptor.append(frame(n), withPresentationTime: CMTimeMultiply(fps, multiplier: Int32(n)))
    }
    input.markAsFinished()
    let done = DispatchSemaphore(value: 0)
    writer.finishWriting { done.signal() }
    done.wait()
}

let dir = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("FrameCheckBench", isDirectory: true)
try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
let f25 = CMTime(value: 1, timescale: 25), f24 = CMTime(value: 1, timescale: 24), f2997 = CMTime(value: 1001, timescale: 30000)
let speed = 9.0   // px per source frame

enum Expect { case clean, mismatch(StutterKind, source: Double?), flash(count: Int, detail: String), offline, legal(start: Int, detail: String) }
struct Clip { let name: String; let fps: CMTime; let frames: Int; let expect: Expect; let frame: (Int) -> CVPixelBuffer }
let clips: [Clip] = [
    Clip(name: "clean 25 fps pan", fps: f25, frames: 150, expect: .clean) { render(Double($0) * speed) },
    Clip(name: "24 → 25 (repeated frames)", fps: f25, frames: 150, expect: .mismatch(.repeated, source: 24)) { render(Double(($0 * 24) / 25) * speed) },
    Clip(name: "25 → 24 (skipped frames)", fps: f24, frames: 144, expect: .mismatch(.skipped, source: 25)) { render(Double(($0 * 25) / 24) * speed) },
    Clip(name: "30 → 25 (skipped frames)", fps: f25, frames: 150, expect: .mismatch(.skipped, source: 30)) { render(Double(($0 * 30) / 25) * speed) },
    Clip(name: "23.976 → 29.97 (pulldown repeats)", fps: f2997, frames: 180, expect: .mismatch(.repeated, source: 23.976)) { render(Double(($0 * 4) / 5) * speed) },
    Clip(name: "24 → 25 (frame blending)", fps: f25, frames: 150, expect: .mismatch(.blended, source: nil)) { n in
        let s = Double(n) * 24 / 25, k = floor(s)
        return render(k * speed, blendWith: (k + 1) * speed, weight: s - k)
    },
    Clip(name: "hold (1 s freeze) + hard cut", fps: f25, frames: 150, expect: .clean) { n in
        if n < 50 { return render(Double(n) * speed) }
        if n < 75 { return render(49 * speed) }
        if n < 100 { return render(Double(n - 25) * speed) }
        return render(Double(n) * speed, flip: true)
    },
    Clip(name: "static shot", fps: f25, frames: 100, expect: .clean) { _ in render(100) },
    Clip(name: "one-off repeat (not a mismatch)", fps: f25, frames: 150, expect: .clean) { n in render(Double(n == 80 ? 79 : n) * speed) },
    Clip(name: "black flash frame mid-shot", fps: f25, frames: 150, expect: .flash(count: 1, detail: "Black")) { n in n == 60 ? card(0, 0, 0) : render(Double(n) * speed) },
    Clip(name: "white flash frame at a cut", fps: f25, frames: 150, expect: .flash(count: 1, detail: "White")) { n in
        n < 70 ? render(Double(n) * speed) : (n == 70 ? card(1, 1, 1) : render(Double(n) * speed, flip: true))
    },
    Clip(name: "2-frame solid blue flash", fps: f25, frames: 150, expect: .flash(count: 1, detail: "Solid")) { n in (n == 90 || n == 91) ? card(0.1, 0.2, 0.9) : render(Double(n) * speed) },
    Clip(name: "dip to black + black head/tail", fps: f25, frames: 150, expect: .clean) { n in
        if n < 10 || n >= 140 { return card(0, 0, 0) }
        if (60..<64).contains(n) { return card(0, 0, 0) }
        let fade = n < 60 ? min(1, Double(60 - n) / 8) : min(1, Double(n - 63) / 8)
        return render(Double(n) * speed, fade: fade)
    },
    Clip(name: "Media Offline card (1 s)", fps: f25, frames: 150, expect: .offline) { n in (50..<75).contains(n) ? card(0.78, 0.05, 0.05, text: true) : render(Double(n) * speed) },
    Clip(name: "orange / magenta graphics (not offline)", fps: f25, frames: 100, expect: .clean) { n in
        n < 50 ? card(1, 0.5, 0, text: true) : card(1, 0, 1, text: true)
    },
    Clip(name: "super-white highlight (Y 250, 20%)", fps: f25, frames: 100, expect: .legal(start: 40, detail: "Luma 107%")) { n in
        (40..<60).contains(n) ? legalPicture(n, patch: CGRect(x: 100, y: 60, width: 256, height: 180), value: (250, 128, 128)) : legalPicture(n)
    },
    Clip(name: "super-black (Y 7, 15%)", fps: f25, frames: 100, expect: .legal(start: 10, detail: "Luma −4%")) { n in
        (10..<30).contains(n) ? legalPicture(n, patch: CGRect(x: 300, y: 100, width: 220, height: 160), value: (7, 128, 128)) : legalPicture(n)
    },
    Clip(name: "illegal colour, legal luma (RGB 126%)", fps: f25, frames: 100, expect: .legal(start: 0, detail: "RGB")) { n in
        legalPicture(n, patch: CGRect(x: 0, y: 0, width: 200, height: 120), value: (120, 30, 240))
    },
    Clip(name: "super-white speck (0.4% of picture)", fps: f25, frames: 100, expect: .clean) { n in
        legalPicture(n, patch: CGRect(x: 300, y: 150, width: 32, height: 28), value: (250, 128, 128))
    },
    Clip(name: "full-swing legal bars (0–100%)", fps: f25, frames: 100, expect: .clean) { n in
        yuv { x, _ in [(16, 128, 128), (235, 128, 128), (63, 102, 240), (219, 16, 138)][x * 4 / W] }   // black, white, red, yellow
    },
]

var failures: [String] = []
let sem = DispatchSemaphore(value: 0)
Task {
    print("== Synthetic conversions")
    for clip in clips {
        let url = dir.appendingPathComponent(clip.name.replacingOccurrences(of: "/", with: "-") + ".mov")
        write(url, fps: clip.fps, frames: clip.frames, frame: clip.frame)
        let t0 = CFAbsoluteTimeGetCurrent()
        guard let r = await FrameCheckScanner.scan(url, fileIndex: 1, totalFiles: 1, cancellation: nil, progress: nil) else { failures.append("\(clip.name): scan failed"); continue }
        let dt = CFAbsoluteTimeGetCurrent() - t0
        let ok: Bool
        switch clip.expect {
        case .clean: ok = !r.isFlagged
        case .legal(let start, let detail):
            ok = r.legalRange.count == 1 && abs(r.legalRange[0].start - start) <= 1 && r.legalRange[0].detail.contains(detail)
                && r.mismatch == nil && r.flashFrames.isEmpty && r.offline.isEmpty
        case .mismatch(let kind, let source):
            ok = r.mismatch.map { $0.kind == kind && (source == nil || abs(($0.sourceFPS ?? 0) - source!) < 0.01) } ?? false
                && r.flashFrames.isEmpty && r.offline.isEmpty
        case .flash(let count, let detail):
            ok = r.flashFrames.count == count && r.flashFrames.allSatisfy { $0.detail.hasPrefix(detail) } && r.mismatch == nil && r.offline.isEmpty
        case .offline: ok = r.offline.count == 1 && r.flashFrames.isEmpty
        }
        if !ok { failures.append(clip.name) }
        let details = (r.flashFrames.map { "flash \($0.detail)@\($0.timecode)" } + r.offline.map { "offline@\($0.timecode)×\($0.count)" }
                       + r.legalRange.map { "legal@\($0.timecode)×\($0.count) \($0.detail)" }).joined(separator: ", ")
        print("\(ok ? "PASS" : "FAIL") \(clip.name) → \(r.verdict)\(r.mismatch.map { " (\($0.pattern))" } ?? "") [\(details)] (\(String(format: "%.0f", Double(r.totalFrames) / dt)) fps)")
    }
    print("== Zebra frame accuracy (Player overlay decode)")
    for (name, codec) in [("H.264 long GOP", AVVideoCodecType.h264), ("ProRes", AVVideoCodecType.proRes422)] {
        let url = dir.appendingPathComponent("zebra \(name).mov")
        write(url, fps: f25, frames: 75, codec: codec) { n in yuv { _, _ in (UInt8(40 + n * 2), 128, 128) } }
        var wrong: [Int] = []
        let t0 = CFAbsoluteTimeGetCurrent()
        for n in [0, 1, 12, 37, 38, 60, 74] {
            let frame = await LegalRange.decodeFrame(url: url, time: CMTime(seconds: (Double(n) + 0.5) / 25, preferredTimescale: 600_000), fps: 25, maxSide: 1920)
            if let frame, abs(Int(frame.luma[frame.luma.count / 2]) - (40 + n * 2)) <= 1 { continue }
            wrong.append(n)
        }
        let ms = (CFAbsoluteTimeGetCurrent() - t0) / 7 * 1000
        if !wrong.isEmpty { failures.append("zebra \(name): wrong frame for \(wrong)") }
        print("\(wrong.isEmpty ? "PASS" : "FAIL") zebra decode \(name) (\(String(format: "%.0f", ms)) ms/frame)")
    }
    let highlight = dir.appendingPathComponent("super-white highlight (Y 250, 20%).mov")
    let t1 = CFAbsoluteTimeGetCurrent()
    let mask = await LegalRange.zebraImage(url: highlight, time: CMTime(seconds: 45.5 / 25, preferredTimescale: 600_000), fps: 25, spec: .ebuR103)
    let clean = await LegalRange.zebraImage(url: highlight, time: CMTime(seconds: 10.5 / 25, preferredTimescale: 600_000), fps: 25, spec: .ebuR103)
    let zebraOK = mask?.width == W && clean?.width == 1
    if !zebraOK { failures.append("zebra image") }
    print("\(zebraOK ? "PASS" : "FAIL") zebra image: flagged frame \(mask?.width ?? 0)×\(mask?.height ?? 0), legal frame \(clean?.width ?? 0) px (\(String(format: "%.0f", (CFAbsoluteTimeGetCurrent() - t1) / 2 * 1000)) ms each)")
    if !CommandLine.arguments.contains("--no-real") {
        let root = URL(fileURLWithPath: "_TEST")
        if FileManager.default.fileExists(atPath: root.path) {
            print("== Real footage (_TEST): reported, not pass/fail")
            if let first = VideoScanner.findMediaFiles(in: root).first(where: { QCUtilities.mediaKind(of: $0) == .video }) {
                let t0 = CFAbsoluteTimeGetCurrent()
                for n in [10, 60, 110] { _ = await LegalRange.zebraImage(url: first, time: CMTime(seconds: (Double(n) + 0.5) / 25, preferredTimescale: 600_000), fps: 25, spec: .ebuR103) }
                print("zebra mask, real footage: \(String(format: "%.0f", (CFAbsoluteTimeGetCurrent() - t0) / 3 * 1000)) ms per frame (\(first.lastPathComponent))")
            }
            for url in VideoScanner.findMediaFiles(in: root) where QCUtilities.mediaKind(of: url) == .video && url.lastPathComponent.hasPrefix("LNEH") == false {
                let t0 = CFAbsoluteTimeGetCurrent()
                guard let r = await FrameCheckScanner.scan(url, fileIndex: 1, totalFiles: 1, cancellation: nil, progress: nil) else { continue }
                let speed = Double(r.totalFrames) / (CFAbsoluteTimeGetCurrent() - t0)
                let details = (r.flashFrames.map { "flash \($0.detail)@\($0.timecode)" } + r.offline.map { "offline@\($0.timecode)" }
                               + r.legalRange.map { "legal@\($0.timecode)×\($0.count) \($0.detail)" }).prefix(4).joined(separator: ", ")
                print("\(r.isFlagged ? "FLAG" : "ok  ") \(url.lastPathComponent) [\(String(format: "%.2f", r.fps)) fps, \(String(format: "%.0f", speed)) fps scan] → \(r.verdict)\(r.mismatch.map { " (\($0.pattern))" } ?? "")\(details.isEmpty ? "" : " | " + details)")
            }
        }
    }
    sem.signal()
}
sem.wait()
print(failures.isEmpty ? "\nALL PASSED" : "\nFAILURES:\n" + failures.joined(separator: "\n"))
exit(failures.isEmpty ? 0 : 1)
