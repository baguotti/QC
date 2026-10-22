import Foundation
@preconcurrency import AVFoundation
import CoreMedia
import CoreVideo

// MARK: - Results

public enum StutterKind: String, Sendable, CaseIterable {
    case repeated = "Repeated frame"
    case skipped = "Skipped frame"
    case blended = "Blended frame"
    case timing = "Timing gap"
}

public struct StutterEvent: Identifiable, Sendable {
    public let id = UUID()
    public let frameIndex: Int
    public let timecode: String
    public let kind: StutterKind
    /// Part of a regular pattern (rate conversion) rather than a one-off.
    public let inCadence: Bool
}

/// A regular pattern of one kind of event, i.e. a frame-rate conversion.
public struct StutterCadence: Sendable {
    public let kind: StutterKind
    /// Average spacing in frames.
    public let period: Double
    /// Share of intervals that follow the pattern (0…1).
    public let regularity: Double
    /// The frame rate the material was most likely made at (nil when it can't be told).
    public let sourceFPS: Double?
    public let fps: Double

    /// e.g. "1 repeated frame every 25 frames: 24 fps material in a 25 fps file"
    public var summary: String {
        let every = period < 1.5 ? "every frame" : "every \(Int(period.rounded())) frames"
        var text = "1 \(kind.rawValue.lowercased()) \(every)"
        if let sourceFPS {
            text += ": \(StutterAnalyzer.rateLabel(sourceFPS)) material in a \(StutterAnalyzer.rateLabel(StutterAnalyzer.snapRate(fps))) file"
        } else if kind == .blended {
            text += ": frame blending (rate conversion or a retimed clip)"
        }
        return text
    }
}

public struct StutterResult: Identifiable, Sendable {
    public let id = UUID()
    public let fileURL: URL
    public let fileName: String
    public let fps: Double
    public let totalFrames: Int
    public let events: [StutterEvent]
    public let cadences: [StutterCadence]

    /// A regular pattern, or one-off repeats / timing gaps. One-off skips are too ambiguous (fast action) to flag.
    public var isFlagged: Bool { !cadences.isEmpty || events.contains { $0.kind == .repeated || $0.kind == .timing } }

    /// One line for lists and notes.
    public var verdict: String {
        if let main = cadences.first { return main.summary }
        let counts = StutterKind.allCases.compactMap { kind -> String? in
            let n = events.filter { $0.kind == kind && (kind == .repeated || kind == .timing) }.count
            return n > 0 ? "\(n) \(kind.rawValue.lowercased())\(n == 1 ? "" : "s")" : nil
        }
        return counts.isEmpty ? "Smooth" : counts.joined(separator: ", ")
    }
}

// MARK: - Per-frame measurements

/// What the scanner measures for frame i (all on a small luma image, 0…255 units).
public struct StutterFrameMetrics: Sendable {
    /// High-percentile block difference to frame i − 1: how much the picture changed (0 for a repeat).
    public var motion: Float
    /// Estimated shift in analysis pixels since frame i − 1 (median over regions), nil when the picture has no texture.
    /// Unlike `motion` it grows with distance, so a skipped frame shows as about twice the usual speed.
    public var speed: Float?
    /// For frame i − 1: |F(i−1) − avg(F(i−2), F(i))| over changing pixels, relative to |F(i−2) − F(i)|.
    /// ~0.5 for normal motion or a repeat, ~0 for a frame blended from its neighbours. Nil when too little changes.
    public var blendRatio: Float?
    /// Presentation time in seconds from the first frame.
    public var time: Double

    public init(motion: Float, speed: Float? = nil, blendRatio: Float?, time: Double) {
        self.motion = motion
        self.speed = speed
        self.blendRatio = blendRatio
        self.time = time
    }
}

// MARK: - Analysis (pure, testable)

public enum StutterAnalyzer {
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

    public static func analyze(_ m: [StutterFrameMetrics], fps: Double) -> (events: [StutterEvent], cadences: [StutterCadence]) {
        let n = m.count
        guard n > 8, fps > 0 else { return ([], []) }
        let motion = m.map(\.motion)

        // Scene cuts: a spike far above its neighbourhood. Events next to a cut are ignored.
        var isCut = [Bool](repeating: false, count: n)
        for i in 1..<n {
            let ref = localMedian(motion, around: i, radius: 5, excluding: nil)
            if motion[i] >= cutMinimum && motion[i] >= cutRatio * max(ref, 1) { isCut[i] = true }
        }
        func nearCut(_ i: Int) -> Bool { (max(0, i - 1)...min(n - 1, i + 1)).contains { isCut[$0] } }

        var raw: [(Int, StutterKind)] = []
        for i in 2..<(n - 1) where !nearCut(i) {
            let context = localMedian(motion, around: i, radius: 6, excluding: isCut)
            guard context >= motionContext else { continue }
            let prev = motion[i - 1], next = motion[i + 1]
            // Repeat: no change while the frames either side move (a run of still frames is a hold, not a stutter).
            if motion[i] <= max(repeatFloor, repeatRatio * context), prev >= 0.5 * context, next >= 0.5 * context {
                raw.append((i, .repeated))
                continue
            }
        }
        // Skip: about twice the usual shift inside a steady move (shift, not difference: difference saturates on texture).
        let speeds = m.map { $0.speed ?? -1 }
        for i in 2..<(n - 1) where !nearCut(i) && speeds[i] >= 0 && speeds[i - 1] >= 0 && speeds[i + 1] >= 0 {
            let context = localMedian(speeds, around: i, radius: 6, excluding: isCut)
            guard context >= speedContext else { continue }
            let prev = speeds[i - 1], next = speeds[i + 1]
            if speeds[i] >= skipRatio * context, prev >= 0.6 * context, prev <= 1.4 * context, next >= 0.6 * context, next <= 1.4 * context {
                raw.append((i, .skipped))
            }
        }
        // Blends: a frame-blending conversion mixes neighbouring frames with weights that cycle, so the blend measure
        // rises and falls with the conversion period. Single blended frames are dissolves and are not reported.
        var blendCadence: StutterCadence?
        if let period = blendPeriod(m.map(\.blendRatio), isCut: isCut) {
            blendCadence = StutterCadence(kind: .blended, period: Double(period), regularity: 1,
                                          sourceFPS: blendSource(period: period, fps: fps), fps: fps)
            let ratios = m.map { $0.blendRatio ?? 1 }
            // One event per cycle, at its most blended frame.
            for start in Swift.stride(from: 0, to: n, by: period) {
                let range = start..<min(n, start + period)
                if let best = range.min(by: { ratios[$0] < ratios[$1] }), ratios[best] <= blendThreshold * 2, best > 0 {
                    raw.append((best - 1, .blended))
                }
            }
        }
        // Timing: gaps between presentation times more than half a frame off.
        let frameDuration = 1 / fps
        for i in 1..<n {
            let delta = m[i].time - m[i - 1].time
            if delta > 1.5 * frameDuration || delta < 0.5 * frameDuration { raw.append((i, .timing)) }
        }

        struct EventKey: Hashable { let frame: Int; let kind: StutterKind }
        var cadences: [StutterCadence] = []
        var inCadence = Set<EventKey>()
        for kind in [StutterKind.repeated, .skipped] {
            let frames = raw.filter { $0.1 == kind }.map(\.0).sorted()
            guard let cadence = cadence(of: frames, kind: kind, fps: fps) else { continue }
            cadences.append(cadence)
            frames.forEach { inCadence.insert(EventKey(frame: $0, kind: kind)) }
        }
        if let blendCadence {
            cadences.append(blendCadence)
            raw.filter { $0.1 == .blended }.forEach { inCadence.insert(EventKey(frame: $0.0, kind: .blended)) }
        }
        cadences.sort { $0.regularity > $1.regularity }
        let events = raw.sorted { $0.0 < $1.0 }.map { frame, kind in
            StutterEvent(frameIndex: frame, timecode: TimecodeFormatter.format(frameIndex: frame, fps: fps),
                         kind: kind, inCadence: inCadence.contains(EventKey(frame: frame, kind: kind)))
        }
        return (events, cadences)
    }

    /// A regular spacing between events: at least 4 events, ≥ 60% of intervals within ±1 frame of the typical one.
    static func cadence(of frames: [Int], kind: StutterKind, fps: Double) -> StutterCadence? {
        guard frames.count >= 4 else { return nil }
        let intervals = zip(frames.dropFirst(), frames).map { $0 - $1 }
        var counts: [Int: Int] = [:]
        for d in intervals { counts[d, default: 0] += 1 }
        guard let mode = counts.max(by: { $0.value < $1.value || ($0.value == $1.value && $0.key > $1.key) })?.key else { return nil }
        let regular = intervals.filter { abs($0 - mode) <= 1 }
        let regularity = Double(regular.count) / Double(intervals.count)
        guard regularity >= 0.6 else { return nil }
        let period = Double(regular.reduce(0, +)) / Double(regular.count)
        var source: Double?
        switch kind {
        case .repeated: source = period > 1 ? fps * (period - 1) / period : nil
        case .skipped: source = fps * (period + 1) / period
        default: source = nil
        }
        return StutterCadence(kind: kind, period: period, regularity: regularity, sourceFPS: source.map(snapRate), fps: fps)
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

/// Decodes each file at a small size (hardware-scaled, luma only) and measures motion and blends per frame.
public actor StutterScanner {
    private let cancellation = CancellationState()

    public init() {}

    public nonisolated func cancel() { cancellation.cancel() }

    public struct ScanProgress: Sendable {
        public let fileIndex: Int
        public let totalFiles: Int
        public let fileName: String
        public let frame: Int
        public let totalFrames: Int
    }

    public func scanBatch(_ urls: [URL], progress: @escaping @Sendable (ScanProgress) -> Void) async -> [StutterResult] {
        cancellation.reset()
        var results: [StutterResult] = []
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
                     progress: (@Sendable (ScanProgress) -> Void)?) async -> StutterResult? {
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
        var firstTime: CMTime?
        var lastProgress = CFAbsoluteTimeGetCurrent()
        while let sample = output.copyNextSampleBuffer() {
            if cancellation?.isCancelled == true { reader.cancelReading(); return nil }
            guard let buffer = CMSampleBufferGetImageBuffer(sample) else { continue }
            let pts = CMSampleBufferGetPresentationTimeStamp(sample)
            if firstTime == nil { firstTime = pts }
            let luma = lumaPlane(buffer, width: w, height: h)
            frames.append(luma)
            if frames.count > 3 { frames.removeFirst() }

            let motion = frames.count >= 2 ? blockMotion(frames[frames.count - 2], frames[frames.count - 1], width: w, height: h) : 0
            let blend = frames.count == 3 ? blendRatio(frames[0], frames[1], frames[2]) : nil
            let profiles = RegionProfiles(luma, width: w, height: h)
            let speed = previousProfiles.flatMap { profiles.shift(from: $0) }
            previousProfiles = profiles
            metrics.append(StutterFrameMetrics(motion: motion, speed: speed, blendRatio: blend,
                                               time: CMTimeGetSeconds(CMTimeSubtract(pts, firstTime ?? pts))))
            let now = CFAbsoluteTimeGetCurrent()
            if now - lastProgress > 0.2 {   // ≤ 5 Hz: progress re-renders the window
                lastProgress = now
                progress?(ScanProgress(fileIndex: fileIndex, totalFiles: totalFiles, fileName: url.lastPathComponent,
                                   frame: metrics.count, totalFrames: max(estimatedFrames, metrics.count)))
            }
        }
        let analysis = StutterAnalyzer.analyze(metrics, fps: fps)
        return StutterResult(fileURL: url, fileName: url.lastPathComponent, fps: fps, totalFrames: metrics.count,
                             events: analysis.events, cadences: analysis.cadences)
    }

    private static func lumaPlane(_ buffer: CVPixelBuffer, width: Int, height: Int) -> [UInt8] {
        CVPixelBufferLockBaseAddress(buffer, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(buffer, .readOnly) }
        let bw = min(width, CVPixelBufferGetWidthOfPlane(buffer, 0))
        let bh = min(height, CVPixelBufferGetHeightOfPlane(buffer, 0))
        guard let base = CVPixelBufferGetBaseAddressOfPlane(buffer, 0) else { return [] }
        let bpr = CVPixelBufferGetBytesPerRowOfPlane(buffer, 0)
        var out = [UInt8](repeating: 0, count: width * height)
        out.withUnsafeMutableBytes { dst in
            for y in 0..<bh {
                memcpy(dst.baseAddress! + y * width, base + y * bpr, bw)
            }
        }
        return out
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
