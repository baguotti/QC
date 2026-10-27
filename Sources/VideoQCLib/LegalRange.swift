import Foundation
@preconcurrency import AVFoundation
import CoreGraphics
import CoreMedia
import CoreVideo

/// Broadcast-legal limits for narrow-range Y′CbCr video, in percent of the nominal range (0 % = code 16, 100 % = 235 in 8-bit).
public struct LegalRangeSpec: Sendable, Equatable {
    public let name: String
    public let lumaMin: Float
    public let lumaMax: Float
    public let rgbMin: Float
    public let rgbMax: Float
    /// A frame is flagged only when more than this share of the picture is out of range (EBU R103: 1 %).
    public let areaTolerance: Float

    /// UK delivery (DPP, BBC, ITV, Channel 4, Sky) and most of Europe.
    public static let ebuR103 = LegalRangeSpec(name: "EBU R103 (UK)", lumaMin: -1, lumaMax: 103, rgbMin: -5, rgbMax: 105, areaTolerance: 0.01)
    public static let strict = LegalRangeSpec(name: "Strict (0–100%)", lumaMin: 0, lumaMax: 100, rgbMin: 0, rgbMax: 100, areaTolerance: 0.01)
    public static let presets = [ebuR103, strict]

    public static let preferenceKey = "prefLegalRangePreset"

    public static func named(_ name: String?) -> LegalRangeSpec { presets.first { $0.name == name } ?? .ebuR103 }
    public static var current: LegalRangeSpec { named(UserDefaults.standard.string(forKey: preferenceKey)) }

    /// e.g. "Luma −1…103%, RGB −5…105%"
    public var limits: String {
        "Luma \(Self.percent(lumaMin))…\(Self.percent(lumaMax))%, RGB \(Self.percent(rgbMin))…\(Self.percent(rgbMax))%"
    }

    static func percent(_ v: Float) -> String { String(format: "%.0f", v).replacingOccurrences(of: "-", with: "−") }

    /// 8-bit code for a level in percent.
    static func code(_ percent: Float) -> Float { 16 + percent / 100 * 219 }
    static func percent(ofCode code: Float) -> Float { (code - 16) / 219 * 100 }
}

/// Y′CbCr → R′G′B′ in 8-bit narrow-range code units (16 = 0 %, 235 = 100 %).
struct LegalRangeMatrix {
    let crToR: Float, cbToB: Float, cbToG: Float, crToG: Float

    init(kr: Float, kb: Float) {
        let kg = 1 - kr - kb, s: Float = 219.0 / 224.0
        crToR = 2 * (1 - kr) * s
        cbToB = 2 * (1 - kb) * s
        cbToG = kb / kg * 2 * (1 - kb) * s
        crToG = kr / kg * 2 * (1 - kr) * s
    }

    /// Largest and smallest of R′, G′, B′ for a 2×2 luma block and its chroma sample.
    @inline(__always)
    func extremes(_ block: (UInt8, UInt8, UInt8, UInt8), cb cbCode: UInt8, cr crCode: UInt8) -> (hi: Float, lo: Float) {
        let y = Float(Int(block.0) + Int(block.1) + Int(block.2) + Int(block.3)) * 0.25
        let cb = Float(cbCode) - 128, cr = Float(crCode) - 128
        let r = y + crToR * cr, b = y + cbToB * cb, g = y - cbToG * cb - crToG * cr
        return (max(r, g, b), min(r, g, b))
    }

    /// The buffer's tagged matrix; untagged material is assumed BT.601 below 720 lines, BT.709 otherwise.
    static func of(_ buffer: CVPixelBuffer, sourceHeight: Int) -> LegalRangeMatrix {
        let tag = CVBufferCopyAttachment(buffer, kCVImageBufferYCbCrMatrixKey, nil) as? String
        switch tag {
        case String(kCVImageBufferYCbCrMatrix_ITU_R_601_4): return LegalRangeMatrix(kr: 0.299, kb: 0.114)
        case String(kCVImageBufferYCbCrMatrix_ITU_R_2020): return LegalRangeMatrix(kr: 0.2627, kb: 0.0593)
        case String(kCVImageBufferYCbCrMatrix_ITU_R_709_2): return LegalRangeMatrix(kr: 0.2126, kb: 0.0722)
        default: return sourceHeight < 720 ? LegalRangeMatrix(kr: 0.299, kb: 0.114) : LegalRangeMatrix(kr: 0.2126, kb: 0.0722)
        }
    }
}

/// Out-of-range areas of one 8-bit narrow-range 4:2:0 frame, per 2×2 luma block (one chroma sample).
///
/// Luma limits are checked on each pixel, gamut with the block's mean luma: 4:2:0 chroma is smeared wider than luma at
/// sharp edges (white text on red reads as 130 % red there). Edge transients like that and scaler or codec ringing are
/// then dropped by erosion: an out-of-range block counts only when its four neighbours are out of range too. EBU R103
/// measures through a low-pass filter for the same reason.
struct LegalRangeBlocks {
    enum Kind: UInt8 { case legal, over, under }
    let width: Int
    let blocksPerRow: Int
    var count: Int { kind.count }
    private(set) var kind: [Kind] = []
    private(set) var hi: [Float] = []
    private(set) var lo: [Float] = []
    /// Out-of-range blocks dropped by the erosion.
    private var transient: [Bool] = []

    /// Luma plane (width × height) and interleaved CbCr plane (width/2 × height/2 pairs).
    init(luma: [UInt8], chroma: [UInt8], width w: Int, height h: Int, matrix m: LegalRangeMatrix, spec: LegalRangeSpec) {
        width = w
        let cw = w / 2, ch = h / 2
        blocksPerRow = cw
        guard cw > 0, ch > 0, luma.count >= w * h, chroma.count >= w * ch else { return }
        let yLo = LegalRangeSpec.code(spec.lumaMin), yHi = LegalRangeSpec.code(spec.lumaMax)
        let cLo = LegalRangeSpec.code(spec.rgbMin), cHi = LegalRangeSpec.code(spec.rgbMax)
        kind = Array(repeating: .legal, count: cw * ch)
        hi = Array(repeating: 0, count: cw * ch)
        lo = Array(repeating: 0, count: cw * ch)
        for by in 0..<ch {
            for bx in 0..<cw {
                let b = by * cw + bx, i = 2 * by * w + 2 * bx
                let block = (luma[i], luma[i + 1], luma[i + w], luma[i + w + 1])
                let (high, low) = m.extremes(block, cb: chroma[by * w + 2 * bx], cr: chroma[by * w + 2 * bx + 1])
                hi[b] = high
                lo[b] = low
                let top = Float(max(block.0, block.1, block.2, block.3)), bottom = Float(min(block.0, block.1, block.2, block.3))
                if top > yHi || high > cHi { kind[b] = .over } else if bottom < yLo || low < cLo { kind[b] = .under }
            }
        }
        let found = kind
        var dropped = Array(repeating: false, count: cw * ch)
        func out(_ bx: Int, _ by: Int) -> Bool { bx < 0 || by < 0 || bx >= cw || by >= ch || found[by * cw + bx] != .legal }
        for by in 0..<ch {
            for bx in 0..<cw where found[by * cw + bx] != .legal {
                dropped[by * cw + bx] = !(out(bx - 1, by) && out(bx + 1, by) && out(bx, by - 1) && out(bx, by + 1))
            }
        }
        for b in kind.indices where dropped[b] { kind[b] = .legal }
        transient = dropped
    }

    func isTransient(_ b: Int) -> Bool { transient[b] }

    /// Index of the block's top-left pixel in the luma plane.
    func lumaIndex(_ b: Int) -> Int { 2 * (b / blocksPerRow) * width + 2 * (b % blocksPerRow) }
}

/// How far one frame strays outside the legal range.
public struct LegalRangeLook: Sendable {
    /// Share of the picture outside any limit.
    public var illegalShare: Float
    /// Levels (percent) exceeded by more than the tolerated share of the picture, so specks and edge ringing don't count.
    public var lumaHigh: Float
    public var lumaLow: Float
    public var rgbHigh: Float
    public var rgbLow: Float

    static func measure(luma: [UInt8], chroma: [UInt8], width w: Int, height h: Int, matrix m: LegalRangeMatrix, spec: LegalRangeSpec) -> LegalRangeLook {
        let blocks = LegalRangeBlocks(luma: luma, chroma: chroma, width: w, height: h, matrix: m, spec: spec)
        let n = blocks.count * 4
        guard n > 0 else { return LegalRangeLook(illegalShare: 0, lumaHigh: 0, lumaLow: 0, rgbHigh: 0, rgbLow: 0) }
        // R′G′B′ codes run from about −270 to +530: histograms offset by 512.
        let offset = 512, bins = 1536
        var hY = [Int](repeating: 0, count: 256)
        var hMax = [Int](repeating: 0, count: bins), hMin = [Int](repeating: 0, count: bins)
        var illegal = 0
        for b in 0..<blocks.count where !blocks.isTransient(b) {
            if blocks.kind[b] != .legal { illegal += 4 }
            hMax[min(bins - 1, max(0, Int(blocks.hi[b].rounded()) + offset))] += 4
            hMin[min(bins - 1, max(0, Int(blocks.lo[b].rounded()) + offset))] += 4
            let i = blocks.lumaIndex(b)
            hY[Int(luma[i])] += 1; hY[Int(luma[i + 1])] += 1; hY[Int(luma[i + w])] += 1; hY[Int(luma[i + w + 1])] += 1
        }
        let allowed = Int(Float(n) * spec.areaTolerance)
        func top(_ hist: [Int], offset: Int) -> Float {
            var acc = 0
            for v in stride(from: hist.count - 1, through: 0, by: -1) { acc += hist[v]; if acc > allowed { return LegalRangeSpec.percent(ofCode: Float(v - offset)) } }
            return LegalRangeSpec.percent(ofCode: Float(-offset))
        }
        func bottom(_ hist: [Int], offset: Int) -> Float {
            var acc = 0
            for v in 0..<hist.count { acc += hist[v]; if acc > allowed { return LegalRangeSpec.percent(ofCode: Float(v - offset)) } }
            return LegalRangeSpec.percent(ofCode: Float(hist.count - 1 - offset))
        }
        return LegalRangeLook(illegalShare: Float(illegal) / Float(n),
                              lumaHigh: top(hY, offset: 0), lumaLow: bottom(hY, offset: 0),
                              rgbHigh: top(hMax, offset: offset), rgbLow: bottom(hMin, offset: offset))
    }
}

public enum LegalRange {

    /// Runs of frames with more than the tolerated share of the picture out of range. Flagged frames up to half a second
    /// apart join one run, so a graded shot that hovers at the limit is one finding, not dozens.
    public static func runs(_ looks: [LegalRangeLook], spec: LegalRangeSpec, fps: Double) -> [FrameRun] {
        let gap = max(1, Int((fps / 2).rounded()))
        let flagged = looks.indices.filter { looks[$0].illegalShare > spec.areaTolerance }
        var runs: [FrameRun] = []
        var i = 0
        while i < flagged.count {
            var j = i
            while j + 1 < flagged.count && flagged[j + 1] - flagged[j] <= gap { j += 1 }
            let frames = flagged[i...j].map { looks[$0] }
            let start = flagged[i]
            runs.append(FrameRun(start: start, count: flagged[j] - start + 1,
                                 timecode: TimecodeFormatter.format(frameIndex: start, fps: fps),
                                 detail: detail(frames, spec: spec)))
            i = j + 1
        }
        return runs
    }

    /// e.g. "Luma 107% · RGB 112% / −9% · 4.2% of picture"
    static func detail(_ frames: [LegalRangeLook], spec: LegalRangeSpec) -> String {
        let lumaHigh = frames.map(\.lumaHigh).max() ?? 0, lumaLow = frames.map(\.lumaLow).min() ?? 0
        let rgbHigh = frames.map(\.rgbHigh).max() ?? 0, rgbLow = frames.map(\.rgbLow).min() ?? 0
        let share = frames.map(\.illegalShare).max() ?? 0
        var parts: [String] = []
        let luma = [lumaHigh > spec.lumaMax ? lumaHigh : nil, lumaLow < spec.lumaMin ? lumaLow : nil].compactMap { $0 }
        let rgb = [rgbHigh > spec.rgbMax ? rgbHigh : nil, rgbLow < spec.rgbMin ? rgbLow : nil].compactMap { $0 }
        if !luma.isEmpty { parts.append("Luma " + luma.map { LegalRangeSpec.percent($0) + "%" }.joined(separator: " / ")) }
        if !rgb.isEmpty { parts.append("RGB " + rgb.map { LegalRangeSpec.percent($0) + "%" }.joined(separator: " / ")) }
        parts.append(String(format: "%.1f%% of picture", share * 100))
        return parts.joined(separator: " · ")
    }

    // MARK: - Zebra (Player overlay)

    /// Decodes the frame shown at `time` (frame centre) in narrow-range 4:2:0, hardware-scaled to at most `maxSide`.
    static func decodeFrame(url: URL, time: CMTime, fps: Double, maxSide: Int) async -> (luma: [UInt8], chroma: [UInt8], width: Int, height: Int, matrix: LegalRangeMatrix)? {
        let asset = AVURLAsset(url: url)
        guard let track = try? await asset.loadTracks(withMediaType: .video).first,
              let natural = try? await track.load(.naturalSize), natural.width > 0, natural.height > 0,
              let reader = try? AVAssetReader(asset: asset) else { return nil }
        let scale = min(1, CGFloat(maxSide) / max(natural.width, natural.height))
        let w = max(2, Int(natural.width * scale) & ~1), h = max(2, Int(natural.height * scale) & ~1)
        let frameDuration = CMTime(seconds: 1 / max(1, fps), preferredTimescale: 600_000)
        reader.timeRange = CMTimeRange(start: CMTimeSubtract(time, frameDuration), duration: CMTimeMultiply(frameDuration, multiplier: 2))
        let output = AVAssetReaderTrackOutput(track: track, outputSettings: [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange,
            kCVPixelBufferWidthKey as String: w,
            kCVPixelBufferHeightKey as String: h
        ])
        output.alwaysCopiesSampleData = false
        guard reader.canAdd(output) else { return nil }
        reader.add(output)
        guard reader.startReading() else { return nil }
        defer { reader.cancelReading() }
        // The range starts a frame early (decode lands on frame boundaries): keep the sample whose display interval holds `time`.
        var chosen: CVPixelBuffer?
        while let sample = output.copyNextSampleBuffer() {
            if Task.isCancelled { return nil }
            guard let buffer = CMSampleBufferGetImageBuffer(sample) else { continue }
            let pts = CMSampleBufferGetPresentationTimeStamp(sample)
            chosen = buffer
            if CMTimeCompare(CMTimeAdd(pts, frameDuration), time) > 0 { break }
        }
        guard let buffer = chosen else { return nil }
        let (luma, chroma) = FrameCheckScanner.planes(buffer, width: w, height: h)
        return (luma, chroma, w, h, LegalRangeMatrix.of(buffer, sourceHeight: Int(natural.height)))
    }

    /// Diagonal stripes over the out-of-range areas of the frame at `time` (the blocks the scan counts): red above the
    /// limits, blue below.
    /// Same orientation as the video output's buffers (the Player's still layer). Nil when the frame can't be decoded.
    public static func zebraImage(url: URL, time: CMTime, fps: Double, spec: LegalRangeSpec, maxSide: Int = 1920) async -> CGImage? {
        guard let frame = await decodeFrame(url: url, time: time, fps: fps, maxSide: maxSide), !Task.isCancelled else { return nil }
        let w = frame.width, h = frame.height
        let blocks = LegalRangeBlocks(luma: frame.luma, chroma: frame.chroma, width: w, height: h, matrix: frame.matrix, spec: spec)
        let period = max(6, (w / 200) & ~1)
        let over: UInt32 = 0xE0_26_26_E0, under: UInt32 = 0x26_70_E0_E0   // premultiplied 0xRRGGBBAA
        var pixels = [UInt32](repeating: 0, count: w * h)
        var any = false
        for b in 0..<blocks.count where blocks.kind[b] != .legal {
            let color = blocks.kind[b] == .over ? over : under
            let i = blocks.lumaIndex(b)
            let x = i % w, y = i / w
            for dy in 0...1 {
                for dx in 0...1 where (x + dx + y + dy) % period < period / 2 { pixels[i + dy * w + dx] = color }
            }
            any = true
        }
        guard any else { return emptyImage }
        let data = pixels.withUnsafeBytes { Data($0) }
        guard let provider = CGDataProvider(data: data as CFData) else { return nil }
        return CGImage(width: w, height: h, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: w * 4,
                       space: CGColorSpaceCreateDeviceRGB(),
                       bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue | CGBitmapInfo.byteOrder32Little.rawValue),
                       provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent)
    }

    /// A fully legal frame: one transparent pixel.
    private static let emptyImage: CGImage? = {
        let ctx = CGContext(data: nil, width: 1, height: 1, bitsPerComponent: 8, bytesPerRow: 4, space: CGColorSpaceCreateDeviceRGB(),
                            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
        return ctx?.makeImage()
    }()
}
