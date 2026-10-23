import Foundation
@preconcurrency import AVFoundation
import CoreMedia
import CoreVideo

// MARK: - Results

public enum StutterKind: String, Sendable {
    case repeated = "Repeated frame"
    case skipped = "Skipped frame"
    case blended = "Blended frame"
}

/// The regular pattern a frame-rate conversion leaves: repeats (slower source), skips (faster source) or blends.
public struct FrameRateMismatch: Sendable {
    public let kind: StutterKind
    /// Average spacing in frames.
    public let period: Double
    /// Share of intervals that follow the pattern (0…1).
    public let regularity: Double
    /// The frame rate the material was most likely made at (nil when it can't be told).
    public let sourceFPS: Double?
    public let fps: Double
    /// First frame of the pattern, to inspect.
    public let firstFrame: Int

    /// e.g. "23.976 → 25 fps"
    public var title: String {
        let file = FrameCheckAnalyzer.rateLabel(FrameCheckAnalyzer.snapRate(fps))
        guard let sourceFPS else { return kind == .blended ? "Frame blending in a \(file) file" : "Frame-rate mismatch" }
        return "\(FrameCheckAnalyzer.rateLabel(sourceFPS).replacingOccurrences(of: " fps", with: "")) → \(file)"
    }

    /// e.g. "1 repeated frame every 24 frames"
    public var pattern: String {
        let every = period < 1.5 ? "every frame" : "every \(Int(period.rounded())) frames"
        return "1 \(kind.rawValue.lowercased()) \(every)"
    }
}

/// Consecutive flash or Media Offline frames.
public struct FrameRun: Identifiable, Sendable {
    public let id = UUID()
    public let start: Int
    public let count: Int
    public let timecode: String
    /// Flash frames: "Black", "White" or "Solid #RRGGBB".
    public let detail: String
}

public struct FrameCheckResult: Identifiable, Sendable {
    public let id = UUID()
    public let fileURL: URL
    public let fileName: String
    public let fps: Double
    public let totalFrames: Int
    public let mismatch: FrameRateMismatch?
    public let flashFrames: [FrameRun]
    public let offline: [FrameRun]

    public var isFlagged: Bool { mismatch != nil || !flashFrames.isEmpty || !offline.isEmpty }

    /// One line for lists and notes.
    public var verdict: String {
        var parts: [String] = []
        if let mismatch { parts.append(mismatch.title) }
        if !flashFrames.isEmpty { parts.append("\(flashFrames.count) flash frame\(flashFrames.count == 1 ? "" : "s")") }
        if !offline.isEmpty { parts.append("Media Offline") }
        return parts.isEmpty ? "Clean" : parts.joined(separator: " · ")
    }
}

// MARK: - Per-frame measurements

/// Motion measures for frame i (all on a small luma image, 0…255 units).
public struct StutterFrameMetrics: Sendable {
    /// High-percentile block difference to frame i − 1: how much the picture changed (0 for a repeat).
    public var motion: Float
    /// Estimated shift in analysis pixels since frame i − 1 (median over regions), nil when the picture has no texture.
    /// Unlike `motion` it grows with distance, so a skipped frame shows as about twice the usual speed.
    public var speed: Float?
    /// For frame i − 1: |F(i−1) − avg(F(i−2), F(i))| over changing pixels, relative to |F(i−2) − F(i)|.
    /// ~0.5 for normal motion or a repeat, ~0 for a frame blended from its neighbours. Nil when too little changes.
    public var blendRatio: Float?

    public init(motion: Float, speed: Float? = nil, blendRatio: Float?) {
        self.motion = motion
        self.speed = speed
        self.blendRatio = blendRatio
    }
}

/// What a frame looks like overall (full-range Y′CbCr, 0…255): enough to tell a solid frame or a Media Offline card.
public struct FrameLook: Sendable {
    public var luma: Float
    public var cb: Float
    public var cr: Float
    /// 2nd–98th percentile range of luma: ~0 for a solid frame, ≥ 30 for almost any picture.
    public var spread: Float
    /// Larger of the Cb and Cr 2nd–98th percentile ranges.
    public var chromaSpread: Float
    /// Share of the frame in the saturated red of an NLE's offline card.
    public var redShare: Float

    public init(luma: Float, cb: Float = 128, cr: Float = 128, spread: Float, chromaSpread: Float = 0, redShare: Float = 0) {
        self.luma = luma
        self.cb = cb
        self.cr = cr
        self.spread = spread
        self.chromaSpread = chromaSpread
        self.redShare = redShare
    }

    var isSolid: Bool { spread <= FrameCheckAnalyzer.solidSpread && chromaSpread <= FrameCheckAnalyzer.solidSpread }
    var isOffline: Bool { redShare >= FrameCheckAnalyzer.offlineRedShare }

    /// "Black", "White" or "Solid #RRGGBB" (BT.709).
    var colorName: String {
        let neutral = abs(cb - 128) < 6 && abs(cr - 128) < 6
        if neutral && luma <= 24 { return "Black" }
        if neutral && luma >= 235 { return "White" }
        func clamp(_ v: Float) -> Int { Int(min(255, max(0, v)).rounded()) }
        let r = clamp(luma + 1.5748 * (cr - 128))
        let g = clamp(luma - 0.1873 * (cb - 128) - 0.4681 * (cr - 128))
        let b = clamp(luma + 1.8556 * (cb - 128))
        return String(format: "Solid #%02X%02X%02X", r, g, b)
    }

    /// Luma plane (width × height) and interleaved CbCr plane (width/2 × height/2).
    static func measure(luma: [UInt8], chroma: [UInt8], width: Int, height: Int) -> FrameLook {
        var lumaHist = [Int](repeating: 0, count: 256)
        var lumaSum = 0
        for v in luma { lumaHist[Int(v)] += 1; lumaSum += Int(v) }
        var cbHist = [Int](repeating: 0, count: 256), crHist = [Int](repeating: 0, count: 256)
        var cbSum = 0, crSum = 0, red = 0
        let cw = width / 2, ch = height / 2
        if chroma.count >= cw * ch * 2 {
            for y in 0..<ch {
                for x in 0..<cw {
                    let i = (y * cw + x) * 2
                    let cb = Int(chroma[i]), cr = Int(chroma[i + 1])
                    cbHist[cb] += 1; crHist[cr] += 1
                    cbSum += cb; crSum += cr
                    // Offline-card red (Premiere, Resolve, FCP): strong Cr, Cb near neutral (orange has low Cb, magenta high).
                    if cr >= 180, cb >= 70, cb <= 140, luma[(2 * y) * width + 2 * x] <= 140 { red += 1 }
                }
            }
        }
        let chromaCount = max(1, cw * ch)
        return FrameLook(luma: Float(lumaSum) / Float(max(1, luma.count)),
                         cb: Float(cbSum) / Float(chromaCount), cr: Float(crSum) / Float(chromaCount),
                         spread: percentileRange(lumaHist, total: luma.count),
                         chromaSpread: max(percentileRange(cbHist, total: chromaCount), percentileRange(crHist, total: chromaCount)),
                         redShare: Float(red) / Float(chromaCount))
    }

    private static func percentileRange(_ hist: [Int], total: Int) -> Float {
        guard total > 0 else { return 0 }
        let cut = total / 50
        var acc = 0, lo = 0, hi = 255
        for (v, n) in hist.enumerated() { acc += n; if acc > cut { lo = v; break } }
        acc = 0
        for v in stride(from: 255, through: 0, by: -1) { acc += hist[v]; if acc > cut { hi = v; break } }
        return Float(max(0, hi - lo))
    }
}

// MARK: - Analysis (pure, testable)

public enum FrameCheckAnalyzer {
    /// Below this the picture is effectively static (no motion to judge a repeat against).
    static let motionContext: Float = 2.5
    /// A repeat is (near) identical: measured real repeats ≤ 0.2, while a merely quieter frame in slow motion reads ~0.3× its
    /// neighbours, so the bar is low.
    static let repeatRatio: Float = 0.08
    static let repeatFloor: Float = 0.35
    static let skipRatio: Float = 1.7
    /// Steady movement needed to judge a skip (analysis pixels per frame).
    static let speedContext: Float = 0.75
    static let blendThreshold: Float = 0.18
    static let cutRatio: Float = 4
    static let cutMinimum: Float = 18
    /// Solid frame: luma and chroma vary by at most this much (compression noise, a faint gradient).
    static let solidSpread: Float = 12
    /// The frames either side of a flash frame must be pictures, not a fade (a dip to black is no flash frame).
    static let pictureSpread: Float = 30
    static let offlineRedShare: Float = 0.6

    /// The frame-rate mismatch, if the motion shows one: repeats or skips at a regular spacing, or a blend cycle.
    /// One-off repeats and skips (a held frame, fast action) are not a mismatch and are not reported.
    public static func mismatch(_ m: [StutterFrameMetrics], fps: Double) -> FrameRateMismatch? {
        let n = m.count
        guard n > 8, fps > 0 else { return nil }
        let motion = m.map(\.motion)

        // Scene cuts: a spike far above its neighbourhood. Events next to a cut are ignored.
        var isCut = [Bool](repeating: false, count: n)
        for i in 1..<n {
            let ref = localMedian(motion, around: i, radius: 5, excluding: nil)
            if motion[i] >= cutMinimum && motion[i] >= cutRatio * max(ref, 1) { isCut[i] = true }
        }
        func nearCut(_ i: Int) -> Bool { (max(0, i - 1)...min(n - 1, i + 1)).contains { isCut[$0] } }

        // Repeat: no change while the frames either side move (a run of still frames is a hold, not a stutter).
        var repeats: [Int] = []
        for i in 2..<(n - 1) where !nearCut(i) {
            let context = localMedian(motion, around: i, radius: 6, excluding: isCut)
            guard context >= motionContext else { continue }
            if motion[i] <= max(repeatFloor, repeatRatio * context), motion[i - 1] >= 0.5 * context, motion[i + 1] >= 0.5 * context {
                repeats.append(i)
            }
        }
        // Skip: about twice the usual shift inside a steady move (shift, not difference: difference saturates on texture).
        var skips: [Int] = []
        let speeds = m.map { $0.speed ?? -1 }
        for i in 2..<(n - 1) where !nearCut(i) && speeds[i] >= 0 && speeds[i - 1] >= 0 && speeds[i + 1] >= 0 {
            let context = localMedian(speeds, around: i, radius: 6, excluding: isCut)
            guard context >= speedContext else { continue }
            let prev = speeds[i - 1], next = speeds[i + 1]
            if speeds[i] >= skipRatio * context, prev >= 0.6 * context, prev <= 1.4 * context, next >= 0.6 * context, next <= 1.4 * context {
                skips.append(i)
            }
        }
        var found = [cadence(of: repeats, kind: .repeated, fps: fps), cadence(of: skips, kind: .skipped, fps: fps)].compactMap { $0 }
        // Blends: a frame-blending conversion mixes neighbouring frames with weights that cycle, so the blend measure
        // rises and falls with the conversion period. Single blended frames are dissolves and are not reported.
        if let period = blendPeriod(m.map(\.blendRatio), isCut: isCut) {
            let ratios = m.map { $0.blendRatio ?? 1 }
            let first = (1..<min(n, period + 1)).min { ratios[$0] < ratios[$1] }.map { $0 - 1 } ?? 0
            found.append(FrameRateMismatch(kind: .blended, period: Double(period), regularity: 1,
                                           sourceFPS: blendSource(period: period, fps: fps), fps: fps, firstFrame: first))
        }
        return found.max { $0.regularity < $1.regularity }
    }

    /// 1–2 solid frames (a few more at high frame rates) between two pictures: a black or coloured frame left in the edit.
    /// Solid frames at the very start or end, holds and dips to black are not flash frames.
    public static func flashFrames(_ looks: [FrameLook], fps: Double) -> [FrameRun] {
        let n = looks.count
        let maxRun = max(2, Int((fps / 12.5).rounded()))
        var runs: [FrameRun] = []
        var i = 1
        while i < n - 1 {
            guard looks[i].isSolid, !looks[i].isOffline else { i += 1; continue }
            var end = i
            while end + 1 < n && looks[end + 1].isSolid { end += 1 }
            if end - i + 1 <= maxRun, end + 1 < n, looks[i - 1].spread >= pictureSpread, looks[end + 1].spread >= pictureSpread {
                runs.append(FrameRun(start: i, count: end - i + 1, timecode: TimecodeFormatter.format(frameIndex: i, fps: fps),
                                     detail: looks[i].colorName))
            }
            i = end + 1
        }
        return runs
    }

    /// Runs of frames that are mostly the saturated red of a Media Offline card.
    public static func offlineRuns(_ looks: [FrameLook], fps: Double) -> [FrameRun] {
        var runs: [FrameRun] = []
        var i = 0
        while i < looks.count {
            guard looks[i].isOffline else { i += 1; continue }
            var end = i
            while end + 1 < looks.count && looks[end + 1].isOffline { end += 1 }
            runs.append(FrameRun(start: i, count: end - i + 1, timecode: TimecodeFormatter.format(frameIndex: i, fps: fps), detail: ""))
            i = end + 1
        }
        return runs
    }

    /// A regular spacing between events: at least 4 events, ≥ 60% of intervals within ±1 frame of the typical one.
    static func cadence(of frames: [Int], kind: StutterKind, fps: Double) -> FrameRateMismatch? {
        guard frames.count >= 4, let first = frames.first else { return nil }
        let intervals = zip(frames.dropFirst(), frames).map { $0 - $1 }
        var counts: [Int: Int] = [:]
        for d in intervals { counts[d, default: 0] += 1 }
        guard let mode = counts.max(by: { $0.value < $1.value || ($0.value == $1.value && $0.key > $1.key) })?.key else { return nil }
        let regular = intervals.filter { abs($0 - mode) <= 1 }
        let regularity = Double(regular.count) / Double(intervals.count)
        guard regularity >= 0.6 else { return nil }
        let period = Double(regular.reduce(0, +)) / Double(regular.count)
        let source: Double? = switch kind {
        case .repeated: period > 1 ? fps * (period - 1) / period : nil
        case .skipped: fps * (period + 1) / period
        case .blended: nil
        }
        return FrameRateMismatch(kind: kind, period: period, regularity: regularity, sourceFPS: source.map(snapRate), fps: fps, firstFrame: first)
    }

    /// The period (frames) of a regular rise and fall in the blend measure. For each candidate period P the series is
    /// detrended with a P-frame moving average (that removes the cycle's mean, leaving content trends out), then it must
    /// correlate at lag P (≥ 0.7) and anti-correlate at P / 2 (≤ −0.5; a slow trend correlates at every lag), swing by a real
    /// amount, and reach a deep blend in most of at least 3 cycles.
    static func blendPeriod(_ ratios: [Float?], isCut: [Bool]) -> Int? {
        let present = ratios.compactMap { $0 }
        guard present.count >= 30 else { return nil }
        let mean = present.reduce(0, +) / Float(present.count)
        let x = ratios.enumerated().map { i, r in (r == nil || isCut[i]) ? mean : r! }
        let n = x.count
        guard n >= 15 else { return nil }
        var prefix = [Float](repeating: 0, count: n + 1)
        for i in 0..<n { prefix[i + 1] = prefix[i] + x[i] }
        func correlation(_ y: [Float], lag: Int) -> Float {
            var num: Float = 0, a: Float = 0, b: Float = 0
            for i in 0..<(y.count - lag) {
                num += y[i] * y[i + lag]
                a += y[i] * y[i]
                b += y[i + lag] * y[i + lag]
            }
            return a > 0 && b > 0 ? num / (a * b).squareRoot() : 0
        }
        var best: (lag: Int, score: Float)?
        for lag in 5...min(60, n / 3) {
            let half = lag / 2
            var y = [Float](repeating: 0, count: n)
            for i in 0..<n {
                let lo = max(0, i - half), hi = min(n, lo + lag)
                y[i] = x[i] - (prefix[hi] - prefix[lo]) / Float(hi - lo)
            }
            let swing = (y.reduce(0) { $0 + $1 * $1 } / Float(n)).squareRoot()
            guard swing >= 0.04 else { continue }
            let atPeriod = correlation(y, lag: lag)
            let atHalf = correlation(y, lag: max(1, (lag + 1) / 2))
            // Measured: a 24 → 25 blend conversion scores 0.96 / −0.98; natural footage stays below 0.45 / −0.15.
            guard atPeriod >= 0.7, atHalf <= -0.5 else { continue }
            let score = atPeriod - atHalf
            if score > (best?.score ?? 0) { best = (lag, score) }
        }
        guard let best else { return nil }
        let values = ratios.map { $0 ?? 1 }
        let cycles = values.count / best.lag
        let deep = (0..<cycles).filter { c in values[(c * best.lag)..<((c + 1) * best.lag)].contains { $0 <= blendThreshold * 2 } }.count
        return cycles >= 3 && deep * 3 >= cycles * 2 ? best.lag : nil
    }
    
    /// Blending hides the direction: take whichever neighbour rate (fps × (P ± 1) / P) is a standard one.
    static func blendSource(period: Int, fps: Double) -> Double? {
        let p = Double(period)
        let candidates = [fps * (p - 1) / p, fps * (p + 1) / p].map(snapRate)
        return candidates.first { standardRates.contains($0) }
    }
    
    static let standardRates: [Double] = [12, 15, 23.976, 24, 25, 29.97, 30, 47.952, 48, 50, 59.94, 60]

    static func snapRate(_ fps: Double) -> Double {
        standardRates.min { abs($0 - fps) < abs($1 - fps) }.flatMap { abs($0 - fps) / fps < 0.025 ? $0 : nil } ?? fps
    }

    public static func rateLabel(_ fps: Double) -> String {
        if abs(fps - fps.rounded()) < 0.001 { return "\(Int(fps.rounded())) fps" }
        var text = String(format: "%.3f", fps)
        while text.hasSuffix("0") { text.removeLast() }
        return text + " fps"
    }

    private static func localMedian(_ v: [Float], around i: Int, radius: Int, excluding skip: [Bool]?) -> Float {
        var window: [Float] = []
        for j in max(0, i - radius)...min(v.count - 1, i + radius) where j != i && j > 0 && !(skip?[j] ?? false) {
            window.append(v[j])
        }
        guard !window.isEmpty else { return 0 }
        window.sort()
        return window[window.count / 2]
    }
}

// MARK: - Scanner

/// Decodes each file once at a small size (hardware-scaled 4:2:0) and measures motion, blends and each frame's look.
public actor FrameCheckScanner {
    private let cancellation = CancellationState()

    public init() {}

    public nonisolated func cancel() { cancellation.cancel() }

    public struct ScanProgress: Sendable {
        public let fileIndex: Int
        public let totalFiles: Int
        public let fileName: String
        public let frame: Int
        public let totalFrames: Int
        /// Frames analysed per second.
        public let speed: Double
    }

    public func scanBatch(_ urls: [URL], progress: @escaping @Sendable (ScanProgress) -> Void) async -> [FrameCheckResult] {
        cancellation.reset()
        var results: [FrameCheckResult] = []
        for (index, url) in urls.enumerated() {
            guard !cancellation.isCancelled else { break }
            if let result = await Self.scan(url, fileIndex: index + 1, totalFiles: urls.count, cancellation: cancellation, progress: progress) {
                results.append(result)
            }
        }
        return results
    }

    /// Long side of the analysed image: enough to see a 1-frame repeat in a slow pan, cheap to compare.
    static let analysisSize = 192

    static func scan(_ url: URL, fileIndex: Int, totalFiles: Int, cancellation: CancellationState?,
                     progress: (@Sendable (ScanProgress) -> Void)?) async -> FrameCheckResult? {
        let asset = AVURLAsset(url: url)
        guard let track = try? await asset.loadTracks(withMediaType: .video).first,
              let reader = try? AVAssetReader(asset: asset) else { return nil }
        let natural = (try? await track.load(.naturalSize)) ?? CGSize(width: 1920, height: 1080)
        let nominal = Double((try? await track.load(.nominalFrameRate)) ?? 25)
        let fps = nominal > 0 ? nominal : 25
        let duration = CMTimeGetSeconds((try? await asset.load(.duration)) ?? .zero)
        let estimatedFrames = max(1, Int((duration * fps).rounded()))

        let longSide = max(natural.width, natural.height, 1)
        let w = max(16, Int(CGFloat(analysisSize) * natural.width / longSide) & ~1)
        let h = max(16, Int(CGFloat(analysisSize) * natural.height / longSide) & ~1)
        let output = AVAssetReaderTrackOutput(track: track, outputSettings: [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_420YpCbCr8BiPlanarFullRange,
            kCVPixelBufferWidthKey as String: w,
            kCVPixelBufferHeightKey as String: h
        ])
        output.alwaysCopiesSampleData = false
        guard reader.canAdd(output) else { return nil }
        reader.add(output)
        guard reader.startReading() else { return nil }

        var frames: [[UInt8]] = []   // last three luma images
        var previousProfiles: RegionProfiles?
        var metrics: [StutterFrameMetrics] = []
        var looks: [FrameLook] = []
        let start = CFAbsoluteTimeGetCurrent()
        var lastProgress = start
        while let sample = output.copyNextSampleBuffer() {
            if cancellation?.isCancelled == true { reader.cancelReading(); return nil }
            guard let buffer = CMSampleBufferGetImageBuffer(sample) else { continue }
            let (luma, chroma) = planes(buffer, width: w, height: h)
            looks.append(FrameLook.measure(luma: luma, chroma: chroma, width: w, height: h))
            frames.append(luma)
            if frames.count > 3 { frames.removeFirst() }

            let motion = frames.count >= 2 ? blockMotion(frames[frames.count - 2], frames[frames.count - 1], width: w, height: h) : 0
            let blend = frames.count == 3 ? blendRatio(frames[0], frames[1], frames[2]) : nil
            let profiles = RegionProfiles(luma, width: w, height: h)
            let speed = previousProfiles.flatMap { profiles.shift(from: $0) }
            previousProfiles = profiles
            metrics.append(StutterFrameMetrics(motion: motion, speed: speed, blendRatio: blend))
            let now = CFAbsoluteTimeGetCurrent()
            if now - lastProgress > 0.2 {   // ≤ 5 Hz: progress re-renders the window
                lastProgress = now
                progress?(ScanProgress(fileIndex: fileIndex, totalFiles: totalFiles, fileName: url.lastPathComponent,
                                       frame: metrics.count, totalFrames: max(estimatedFrames, metrics.count),
                                       speed: Double(metrics.count) / max(0.001, now - start)))
            }
        }
        return FrameCheckResult(fileURL: url, fileName: url.lastPathComponent, fps: fps, totalFrames: metrics.count,
                                mismatch: FrameCheckAnalyzer.mismatch(metrics, fps: fps),
                                flashFrames: FrameCheckAnalyzer.flashFrames(looks, fps: fps),
                                offline: FrameCheckAnalyzer.offlineRuns(looks, fps: fps))
    }

    /// Copies the luma plane (width × height) and the interleaved CbCr plane (width/2 × height/2 pairs).
    private static func planes(_ buffer: CVPixelBuffer, width: Int, height: Int) -> ([UInt8], [UInt8]) {
        CVPixelBufferLockBaseAddress(buffer, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(buffer, .readOnly) }
        func copy(plane: Int, rowBytes: Int, rows: Int) -> [UInt8] {
            var out = [UInt8](repeating: 0, count: rowBytes * rows)
            guard let base = CVPixelBufferGetBaseAddressOfPlane(buffer, plane) else { return out }
            let bpr = CVPixelBufferGetBytesPerRowOfPlane(buffer, plane)
            let n = min(rows, CVPixelBufferGetHeightOfPlane(buffer, plane))
            let bytes = min(rowBytes, bpr)
            out.withUnsafeMutableBytes { dst in
                for y in 0..<n { memcpy(dst.baseAddress! + y * rowBytes, base + y * bpr, bytes) }
            }
            return out
        }
        return (copy(plane: 0, rowBytes: width, rows: height), copy(plane: 1, rowBytes: width, rows: height / 2))
    }

    /// 90th percentile of 8×8 block mean absolute differences: a small moving object still counts as motion.
    static func blockMotion(_ a: [UInt8], _ b: [UInt8], width: Int, height: Int) -> Float {
        guard a.count == b.count, a.count == width * height else { return 0 }
        let block = 8
        var values: [Float] = []
        values.reserveCapacity((width / block) * (height / block))
        for by in Swift.stride(from: 0, to: height - block + 1, by: block) {
            for bx in Swift.stride(from: 0, to: width - block + 1, by: block) {
                var sum = 0
                for y in by..<(by + block) {
                    let row = y * width
                    for x in bx..<(bx + block) { sum += abs(Int(a[row + x]) - Int(b[row + x])) }
                }
                values.append(Float(sum) / Float(block * block))
            }
        }
        guard !values.isEmpty else { return 0 }
        values.sort()
        return values[min(values.count - 1, values.count * 9 / 10)]
    }

    /// |mid − avg(prev, next)| / |prev − next| over pixels that change between prev and next.
    static func blendRatio(_ prev: [UInt8], _ mid: [UInt8], _ next: [UInt8]) -> Float? {
        guard prev.count == mid.count, mid.count == next.count, !prev.isEmpty else { return nil }
        var changing = 0
        var span = 0
        var deviation = 0
        for i in 0..<prev.count {
            let p = Int(prev[i]), q = Int(next[i])
            let d = abs(p - q)
            guard d >= 16 else { continue }
            changing += 1
            span += d
            deviation += abs(2 * Int(mid[i]) - p - q)   // 2× |mid − avg|
        }
        guard changing >= prev.count / 50, span > 0 else { return nil }
        return Float(deviation) / Float(2 * span)
    }
}

/// Column and row brightness profiles of a 4×3 grid of regions. Comparing them between frames gives each region's
/// horizontal and vertical shift (1-D search, sub-pixel), a cheap global-motion estimate.
struct RegionProfiles {
    static let columns = 4, rows = 3, search = 24
    var horizontal: [[Float]] = []   // per region: mean of each column
    var vertical: [[Float]] = []     // per region: mean of each row
    
    init(_ luma: [UInt8], width: Int, height: Int) {
        guard luma.count == width * height else { return }
        let rw = width / Self.columns, rh = height / Self.rows
        for ry in 0..<Self.rows {
            for rx in 0..<Self.columns {
                var cols = [Float](repeating: 0, count: rw)
                var rowsProfile = [Float](repeating: 0, count: rh)
                for y in 0..<rh {
                    let row = (ry * rh + y) * width + rx * rw
                    var rowSum = 0
                    for x in 0..<rw {
                        let v = Int(luma[row + x])
                        cols[x] += Float(v)
                        rowSum += v
                    }
                    rowsProfile[y] = Float(rowSum) / Float(rw)
                }
                horizontal.append(cols.map { $0 / Float(rh) })
                vertical.append(rowsProfile)
            }
        }
    }
    
    /// Median shift magnitude over regions with enough texture, nil when none has any.
    func shift(from previous: RegionProfiles) -> Float? {
        guard horizontal.count == previous.horizontal.count else { return nil }
        var shifts: [Float] = []
        for r in 0..<horizontal.count {
            guard let dx = Self.offset(previous.horizontal[r], horizontal[r]),
                  let dy = Self.offset(previous.vertical[r], vertical[r]) else { continue }
            shifts.append((dx * dx + dy * dy).squareRoot())
        }
        guard shifts.count >= 3 else { return nil }
        shifts.sort()
        return shifts[shifts.count / 2]
    }
    
    /// Best shift of `b` against `a` (mean absolute difference over the overlap), refined with a parabola.
    static func offset(_ a: [Float], _ b: [Float]) -> Float? {
        let n = a.count
        let range = min(search, n / 3)
        guard range >= 2 else { return nil }
        // Flat profiles carry no position information.
        let mean = a.reduce(0, +) / Float(n)
        let spread = a.reduce(0) { $0 + abs($1 - mean) } / Float(n)
        guard spread >= 2 else { return nil }
        var costs = [Float](repeating: .infinity, count: 2 * range + 1)
        for s in -range...range {
            var sum: Float = 0
            var count = 0
            for i in max(0, -s)..<min(n, n - s) {
                sum += abs(a[i] - b[i + s])
                count += 1
            }
            costs[s + range] = sum / Float(max(1, count))
        }
        guard let bestIndex = costs.indices.min(by: { costs[$0] < costs[$1] }) else { return nil }
        var shift = Float(bestIndex - range)
        if bestIndex > 0 && bestIndex < costs.count - 1 {
            let l = costs[bestIndex - 1], c = costs[bestIndex], r = costs[bestIndex + 1]
            let denom = l - 2 * c + r
            if denom > 0 { shift += 0.5 * (l - r) / denom }
        }
        return abs(shift)
    }
}
