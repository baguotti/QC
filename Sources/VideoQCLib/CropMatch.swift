import Foundation
import AVFoundation
import Accelerate
import CoreGraphics

// MARK: - Results

/// One shot of a cutdown, found (or not) in the master, and whether its framing is the master's.
public struct CropMatchShot: Identifiable, Sendable, Equatable {
    public enum Verdict: Sendable, Equatable {
        /// The same framing as the master (within a pixel).
        case same
        /// Moved and/or scaled against the master.
        case reframed
        /// No part of the master looks like it (another take, a new shot, an end card).
        case notInMaster
        /// Paired, but the framing couldn't be measured (a plain or very dark picture) or the pairing is doubtful.
        case uncertain(String)
    }

    public let id: Int
    /// Cutdown frames, inclusive.
    public let start: Int
    public let end: Int
    /// The master frames it was paired with (inclusive), nil when not in the master.
    public let masterStart: Int?
    public let masterEnd: Int?
    /// How alike the paired frames are (0…1), for the pairing's confidence.
    public let likeness: Float
    public var verdict: Verdict
    /// Where the cutdown's frame centre sits in the master, in master pixels (+x right, +y down). Zero for the same crop.
    public var shift: CGPoint = .zero
    /// Cutdown framing size against the master's: above 1 is tighter (zoomed in).
    public var scale: Double = 1
    /// The frame pair the verdict comes from (the one with the largest difference), for opening in the Player.
    public var measuredCutdownFrame: Int?
    public var measuredMasterFrame: Int?
    /// The master frames advance this much per cutdown frame on average (1: same speed).
    public var speed: Double = 1
    /// For a punch-in found by the zoomed search: where to start measuring (scale, and the window centre's offset from
    /// the master's centre as a fraction of its width and height).
    var hintScale: Double?
    var hintX: Double = 0
    var hintY: Double = 0

    public var frameCount: Int { end - start + 1 }

    /// The cutdown's frame inside the master's, as a fraction of the master frame (0…1, top-left origin): where the
    /// crop sits. The whole frame for the same framing.
    public func cropRect(masterSize: CGSize) -> CGRect {
        guard masterSize.width > 0, masterSize.height > 0, scale > 0 else { return CGRect(x: 0, y: 0, width: 1, height: 1) }
        let w = 1 / scale, h = 1 / scale
        return CGRect(x: 0.5 + shift.x / masterSize.width - w / 2, y: 0.5 + shift.y / masterSize.height - h / 2, width: w, height: h)
    }

    /// The master footage's Scale (%) and Position in a sequence of the master's size that would give this framing:
    /// what an editor types to reproduce it (or compares with the clip's Motion settings). Measured: 106.5 %, position
    /// 1021 × 540 read 106.7 %, 1020.7 × 540.2.
    public func editValues(masterSize: CGSize) -> (scale: Double, x: Double, y: Double) {
        (scale * 100, masterSize.width / 2 - shift.x * scale, masterSize.height / 2 - shift.y * scale)
    }
}

public struct CropMatchResult: Identifiable, Sendable {
    public var id: URL { fileURL }
    public let fileURL: URL
    public let fileName: String
    public let fps: Double
    public let totalFrames: Int
    public let masterFps: Double
    public let shots: [CropMatchShot]
    public let readError: String?
    /// Not compared, and why (another shape than the master's).
    public var skipped: String?

    public var reframedCount: Int { shots.filter { $0.verdict == .reframed }.count }
    public var missingCount: Int { shots.filter { $0.verdict == .notInMaster }.count }
    public var uncertainCount: Int { shots.filter { if case .uncertain = $0.verdict { return true }; return false }.count }
    public var isFlagged: Bool { skipped == nil && (readError != nil || reframedCount + missingCount + uncertainCount > 0) }
}

/// A Crop Match run: the master the cutdowns were compared with, and each cutdown's result.
public struct CropMatchRun: Sendable {
    /// Tells runs apart cheaply (views compare it instead of the results).
    public let id = UUID()
    public let master: URL
    public let masterName: String
    public var masterSize: CGSize = .zero
    public var masterFps: Double = 25
    public var masterFrames: Int = 0
    public let results: [CropMatchResult]
}

// MARK: - Matcher

/// Checks that every shot of a set of cutdowns is framed exactly like the same shot in their master.
///
/// 1. Each file is decoded once at low resolution into a per-frame fingerprint (a blurred 16 px luma image, zero-mean
///    and unit-length, so comparing two is a correlation: brightness and contrast changes don't count, small reframes
///    barely do).
/// 2. Each cutdown is aligned to the master frame by frame (`align`): a best path through the master that moves on a
///    frame at a time, may hold or skip (retimes), jumps at cuts, and can leave the master for pictures that aren't in it.
/// 3. The path splits the cutdown into shots; for each, a few frame pairs are decoded at 384 px and the framing is
///    measured (`CropAligner`): scale and shift, to a fraction of a pixel.
public actor CropMatcher {
    public struct Progress: Sendable {
        public let fileIndex: Int
        public let totalFiles: Int
        public let fileName: String
        /// "Reading" while fingerprinting, "Measuring" while comparing framing.
        public let phase: String
        public let fraction: Double
    }

    private let cancellation = CancellationState()

    public init() {}

    public nonisolated func cancel() { cancellation.cancel() }

    /// Matches every other video against `master` (nil: the longest of `files`). Videos of another shape than the
    /// master's (aspect ratio off by more than 1 %) are listed as not compared. Results come back longest first.
    public func run(master chosen: URL?, files all: [URL], progress: @escaping @Sendable (Progress) -> Void) async -> CropMatchRun? {
        var shapes: [URL: (duration: Double, aspect: Double)] = [:]
        for url in all {
            let asset = AVURLAsset(url: url)
            let duration = CMTimeGetSeconds((try? await asset.load(.duration)) ?? .zero)
            var aspect = 0.0
            if let track = try? await asset.loadTracks(withMediaType: .video).first,
               let size = try? await track.load(.naturalSize), let transform = try? await track.load(.preferredTransform) {
                let oriented = size.applying(transform)
                if oriented.height != 0 { aspect = abs(Double(oriented.width / oriented.height)) }
            }
            shapes[url] = (duration.isFinite ? duration : 0, aspect)
        }
        guard let master = chosen ?? all.max(by: { (shapes[$0]?.duration ?? 0) < (shapes[$1]?.duration ?? 0) }) else { return nil }
        let masterAspect = shapes[master]?.aspect ?? 0
        let others = all.filter { $0 != master }
        let cutdowns = others.filter { url in
            let aspect = shapes[url]?.aspect ?? 0
            return masterAspect == 0 || aspect == 0 || abs(aspect / masterAspect - 1) <= 0.01
        }
        let skipped = others.filter { !cutdowns.contains($0) }.map { url in
            var result = CropMatchResult(fileURL: url, fileName: url.lastPathComponent, fps: 0, totalFrames: 0, masterFps: 0, shots: [], readError: nil)
            result.skipped = "Another shape (\(Self.ratio(shapes[url]?.aspect ?? 0)) against the master's \(Self.ratio(masterAspect))): not compared"
            return result
        }
        let (compared, masterPrints) = await compare(master: master, cutdowns: cutdowns, progress: progress)
        let byURL = Dictionary((compared + skipped).map { ($0.fileURL, $0) }, uniquingKeysWith: { a, _ in a })
        // Longest first (a 30 s, then its 15, 10, 06 s), files not compared last.
        let ordered = others.sorted { a, b in
            let compareA = byURL[a]?.skipped == nil, compareB = byURL[b]?.skipped == nil
            if compareA != compareB { return compareA }
            return (shapes[a]?.duration ?? 0) > (shapes[b]?.duration ?? 0)
        }
        var run = CropMatchRun(master: master, masterName: master.lastPathComponent, results: ordered.compactMap { byURL[$0] })
        if let masterPrints {
            run.masterSize = masterPrints.naturalSize
            run.masterFps = masterPrints.fps
            run.masterFrames = masterPrints.count
        }
        return run
    }

    /// "1:1", "16:9", "9:16", "4:5", or the ratio as a decimal.
    static func ratio(_ aspect: Double) -> String {
        for (w, h) in [(1, 1), (16, 9), (9, 16), (4, 5), (5, 4), (4, 3), (3, 4), (2, 1), (1, 2)] where abs(aspect - Double(w) / Double(h)) < 0.01 {
            return "\(w):\(h)"
        }
        return String(format: "%.2f:1", aspect)
    }

    private func compare(master: URL, cutdowns: [URL], progress: @escaping @Sendable (Progress) -> Void) async -> ([CropMatchResult], Fingerprints?) {
        guard !cutdowns.isEmpty else { return ([], nil) }
        let files = [master] + cutdowns
        let total = files.count
        // Read two at a time, like the other checks (one decode stream leaves the hardware decoder half idle).
        let prints = await withTaskGroup(of: (Int, Fingerprints).self) { group in
            var next = 0
            func add() {
                guard next < files.count else { return }
                let index = next
                next += 1
                let url = files[index]
                let cancellation = cancellation
                group.addTask {
                    (index, await Fingerprints.read(url, keepLuma: index == 0, cancellation: cancellation) { fraction in
                        progress(Progress(fileIndex: index + 1, totalFiles: total, fileName: url.lastPathComponent, phase: "Reading", fraction: fraction))
                    })
                }
            }
            add(); add()
            var out = [Int: Fingerprints]()
            for await (index, print) in group {
                out[index] = print
                add()
            }
            return out
        }
        guard var masterPrints = prints[0] else { return ([], nil) }
        var results: [CropMatchResult] = []
        // Built once, only if some cutdown has a shot to look for (summed-area tables of the whole master).
        var punchIns: PunchInIndex?
        for (offset, url) in cutdowns.enumerated() {
            if cancellation.isCancelled { break }
            let index = offset + 1
            guard let cut = prints[index] else { continue }
            if let error = masterPrints.error ?? cut.error {
                results.append(CropMatchResult(fileURL: url, fileName: url.lastPathComponent, fps: cut.fps, totalFrames: cut.count,
                                               masterFps: masterPrints.fps, shots: [], readError: masterPrints.error.map { "Master: \($0)" } ?? error))
                continue
            }
            progress(Progress(fileIndex: index + 1, totalFiles: total, fileName: url.lastPathComponent, phase: "Measuring", fraction: 0))
            var path = Self.align(cutdown: cut, master: masterPrints)
            var shots = Self.shots(from: path, cutdown: cut, master: masterPrints)
            if shots.contains(where: { $0.verdict == .notInMaster && $0.frameCount >= 3 }) {
                if punchIns == nil { punchIns = PunchInIndex(masterPrints) }
                if let punchIns { Self.findPunchIns(&shots, path: &path, cutdown: cut, index: punchIns) }
            }
            shots = await measure(shots, path: path, cutdown: url, cutFps: cut.fps, master: master, masterPrints: masterPrints) { fraction in
                progress(Progress(fileIndex: index + 1, totalFiles: total, fileName: url.lastPathComponent, phase: "Measuring", fraction: fraction))
            }
            // Stopped part-way: its unmeasured shots would read as framed like the master. Left out.
            if cancellation.isCancelled { break }
            // A 1–2 frame shot too plain to measure (a white flash in a montage) isn't worth a row to check.
            shots.removeAll { $0.frameCount < 3 && $0.verdict == .uncertain(FramingMeasurer.tooPlain) }
            shots = Self.merged(shots)
            results.append(CropMatchResult(fileURL: url, fileName: url.lastPathComponent, fps: cut.fps, totalFrames: cut.count,
                                           masterFps: masterPrints.fps, shots: shots, readError: nil))
        }
        masterPrints.luma = []   // only the punch-in search needs it
        return (results, masterPrints)
    }

    /// Measures every shot's framing in up to 4 lanes at once (each its own readers; the search is CPU-bound and the
    /// decodes are short), keeping their order.
    private func measure(_ shots: [CropMatchShot], path: [Int?], cutdown: URL, cutFps: Double, master: URL, masterPrints: Fingerprints,
                         progress: @escaping @Sendable (Double) -> Void) async -> [CropMatchShot] {
        let lanes = min(4, shots.count)
        guard lanes > 0 else { return shots }
        let done = Counter()
        let cancellation = cancellation
        let (masterFps, masterSize, masterCount) = (masterPrints.fps, masterPrints.naturalSize, masterPrints.count)
        return await withTaskGroup(of: [(Int, CropMatchShot)].self) { group in
            for lane in 0..<lanes {
                group.addTask {
                    let measurer = FramingMeasurer(cutdown: cutdown, master: master, cutdownFps: cutFps, masterFps: masterFps, masterSize: masterSize)
                    var out: [(Int, CropMatchShot)] = []
                    for i in Swift.stride(from: lane, to: shots.count, by: lanes) {
                        if cancellation.isCancelled { break }
                        out.append((i, await measurer.measure(shots[i], path: path, masterCount: masterCount)))
                        progress(Double(done.increment()) / Double(shots.count))
                    }
                    return out
                }
            }
            var measured = shots
            for await lane in group { for (i, shot) in lane { measured[i] = shot } }
            return measured
        }
    }

    // MARK: Alignment

    /// Path costs (a frame's cost is 1 − its correlation with the master frame it's paired with, 0…2).
    public struct AlignCosts: Sendable {
        /// Holding a master frame (slow motion, a freeze).
        public var hold: Float = 0.12
        /// Skipping one or two master frames (speed-ups).
        public var skip: Float = 0.08
        public var skipTwo: Float = 0.2
        /// Jumping elsewhere in the master (a cut).
        public var jump: Float = 0.8
        /// A frame not in the master costs this: frames correlating under ~0.55 with every master frame leave it
        /// (between a different shot's ≤ 0.46 and a reframed one's ≥ 0.84).
        public var notInMaster: Float = 0.45
        public init() {}
    }

    /// The master frame each cutdown frame shows (nil: not in the master), by the cheapest path (Viterbi over the
    /// master's frames, plus one "not in the master" state).
    public static func align(cutdown: Fingerprints, master: Fingerprints, costs: AlignCosts = AlignCosts()) -> [Int?] {
        let n = cutdown.count, m = master.count, d = Fingerprints.dimension
        guard n > 0 else { return [] }
        guard m > 0 else { return Array(repeating: nil, count: n) }
        var prev = [Float](repeating: 0, count: m)
        var cur = [Float](repeating: 0, count: m)
        var likeness = [Float](repeating: 0, count: m)
        // Per cell how it was reached: 1 next frame, 2 hold, 3 skip one, 4 skip two, 5 jump (from the previous row's
        // best), 6 from "not in master"; 0 start.
        var back = [UInt8](repeating: 0, count: n * m)
        var bestOfRow = [Int](repeating: 0, count: n)
        var noneBack = [UInt8](repeating: 0, count: n)   // 0 stayed out, 1 left the master from the row's best
        var prevNone: Float = 0
        let none = costs.notInMaster
        master.vectors.withUnsafeBufferPointer { masterVectors in
            cutdown.vectors.withUnsafeBufferPointer { cutVectors in
                for i in 0..<n {
                    // Correlations of this cutdown frame with every master frame: one matrix-vector product.
                    vDSP_mmul(masterVectors.baseAddress!, 1, cutVectors.baseAddress! + i * d, 1, &likeness, 1,
                              vDSP_Length(m), 1, vDSP_Length(d))
                    if i == 0 {
                        for j in 0..<m { cur[j] = 1 - likeness[j] }
                        prevNone = none
                    } else {
                        var bestValue: Float = .infinity
                        var bestIndex = 0
                        for j in 0..<m where prev[j] < bestValue { bestValue = prev[j]; bestIndex = j }
                        bestOfRow[i - 1] = bestIndex
                        let jumpFrom = min(bestValue, prevNone)
                        let jumpCode: UInt8 = bestValue <= prevNone ? 5 : 6
                        for j in 0..<m {
                            var cost = jumpFrom + costs.jump
                            var code = jumpCode
                            if j >= 1, prev[j - 1] < cost { cost = prev[j - 1]; code = 1 }
                            if prev[j] + costs.hold < cost { cost = prev[j] + costs.hold; code = 2 }
                            if j >= 2, prev[j - 2] + costs.skip < cost { cost = prev[j - 2] + costs.skip; code = 3 }
                            if j >= 3, prev[j - 3] + costs.skipTwo < cost { cost = prev[j - 3] + costs.skipTwo; code = 4 }
                            cur[j] = cost + 1 - likeness[j]
                            back[i * m + j] = code
                        }
                        // Leaving the master costs half a jump; staying out costs nothing more than the frame.
                        if bestValue + costs.jump / 2 < prevNone {
                            prevNone = bestValue + costs.jump / 2 + none
                            noneBack[i] = 1
                        } else {
                            prevNone += none
                        }
                    }
                    swap(&prev, &cur)
                }
            }
        }
        // Trace back from the cheapest end.
        var path = [Int?](repeating: nil, count: n)
        var bestEnd = 0
        for j in 0..<m where prev[j] < prev[bestEnd] { bestEnd = j }
        var state: Int? = prev[bestEnd] <= prevNone ? bestEnd : nil
        var i = n - 1
        while i >= 0 {
            path[i] = state
            guard i > 0 else { break }
            if let j = state {
                switch back[i * m + j] {
                case 1: state = j - 1
                case 2: state = j
                case 3: state = j - 2
                case 4: state = j - 3
                case 5: state = bestOfRow[i - 1]
                default: state = nil
                }
            } else {
                state = noneBack[i] == 1 ? bestOfRow[i - 1] : nil
            }
            i -= 1
        }
        return path
    }

    /// A cutdown shot not found in the master may be a punch-in on it (a tighter crop than the frame-wide fingerprints
    /// survive). Its middle frame is compared with crops of every master frame at 1.3–3× and positions across the
    /// frame (each crop fingerprinted from the master's kept luma through a summed-area table); a strong match (≥ 0.9,
    /// far stricter than the main pairing: thousands of crops, and smooth pictures at 3× correlate easily) pairs the
    /// shot at the same speed, and measuring starts from that crop (and must confirm it: `FramingMeasurer.punchInFit`).
    static func findPunchIns(_ shots: inout [CropMatchShot], path: inout [Int?], cutdown: Fingerprints, index: PunchInIndex) {
        let g = Fingerprints.grid
        for i in shots.indices where shots[i].verdict == .notInMaster && shots[i].frameCount >= 3 {
            let shot = shots[i]
            let middle = (shot.start + shot.end) / 2
            let target = Array(cutdown.vectors[(middle * g * g)..<((middle + 1) * g * g)])
            guard target.contains(where: { $0 != 0 }), let best = index.bestCrop(for: target) else { continue }
            for k in shot.start...shot.end { path[k] = min(index.frames - 1, max(0, best.frame + k - middle)) }
            var paired = CropMatchShot(id: shot.id, start: shot.start, end: shot.end, masterStart: path[shot.start],
                                       masterEnd: path[shot.end], likeness: best.likeness, verdict: .same)
            paired.hintScale = best.scale
            paired.hintX = best.x
            paired.hintY = best.y
            shots[i] = paired
        }
    }

    /// Neighbouring shots that carry straight on in the master with the same framing are one edit (the master cuts
    /// there too, or a montage): one row, starting at the first.
    static func merged(_ shots: [CropMatchShot]) -> [CropMatchShot] {
        var out: [CropMatchShot] = []
        for shot in shots {
            if let last = out.last, last.end + 1 == shot.start, let lastEnd = last.masterEnd, let nextStart = shot.masterStart,
               (1...3).contains(nextStart - lastEnd), last.verdict == shot.verdict, last.verdict == .same || last.verdict == .reframed,
               abs(last.scale / shot.scale - 1) <= 0.003, hypot(last.shift.x - shot.shift.x, last.shift.y - shot.shift.y) <= 2 {
                var joined = CropMatchShot(id: last.id, start: last.start, end: shot.end, masterStart: last.masterStart,
                                           masterEnd: shot.masterEnd, likeness: min(last.likeness, shot.likeness), verdict: last.verdict)
                joined.shift = last.shift
                joined.scale = last.scale
                joined.measuredCutdownFrame = last.measuredCutdownFrame
                joined.measuredMasterFrame = last.measuredMasterFrame
                joined.speed = Double((shot.masterEnd ?? 0) - (last.masterStart ?? 0)) / Double(max(1, shot.end - last.start))
                out[out.count - 1] = joined
            } else {
                var next = CropMatchShot(id: out.count, start: shot.start, end: shot.end, masterStart: shot.masterStart,
                                     masterEnd: shot.masterEnd, likeness: shot.likeness, verdict: shot.verdict)
                next.shift = shot.shift
                next.scale = shot.scale
                next.measuredCutdownFrame = shot.measuredCutdownFrame
                next.measuredMasterFrame = shot.measuredMasterFrame
                next.speed = shot.speed
                out.append(next)
            }
        }
        return out
    }

    /// Splits the aligned cutdown into shots: a new shot where the path jumps, leaves or rejoins the master, or the
    /// cutdown cuts (two neighbouring frames that don't correlate). Shots under 3 frames (dissolve frames, a flash)
    /// are left out.
    static func shots(from path: [Int?], cutdown: Fingerprints, master: Fingerprints) -> [CropMatchShot] {
        guard !path.isEmpty else { return [] }
        var bounds: [Range<Int>] = []
        var start = 0
        for i in 1..<max(1, path.count) {
            let continues: Bool
            switch (path[i - 1], path[i]) {
            // Two pictures not in the master stay one section only without a cut between them (a punch-in after an
            // absent shot must be searched on its own).
            case (nil, nil): continues = cutdown.likeness(i - 1, i) > 0.5
            case let (a?, b?): continues = b - a >= 0 && b - a <= 3 && cutdown.likeness(i - 1, i) > 0.5
            default: continues = false
            }
            if !continues { bounds.append(start..<i); start = i }
        }
        bounds.append(start..<path.count)
        var shots: [CropMatchShot] = []
        for range in bounds {
            let paired = range.compactMap { i in path[i].map { (i, $0) } }
            // Under 3 frames: kept only when it pairs strongly (a fast montage's 2-frame shots); otherwise a dissolve,
            // a flash or a stray frame, not a shot.
            if range.count < 3 {
                guard paired.count == range.count,
                      paired.map({ cutdown.likeness(with: master, $0.0, $0.1) }).allSatisfy({ $0 >= 0.9 }) else { continue }
            }
            if paired.isEmpty {
                shots.append(CropMatchShot(id: shots.count, start: range.lowerBound, end: range.upperBound - 1, masterStart: nil,
                                           masterEnd: nil, likeness: 0, verdict: .notInMaster))
                continue
            }
            let likeness = paired.map { cutdown.likeness(with: master, $0.0, $0.1) }.reduce(0, +) / Float(paired.count)
            var shot = CropMatchShot(id: shots.count, start: range.lowerBound, end: range.upperBound - 1,
                                     masterStart: paired.first?.1, masterEnd: paired.last?.1, likeness: likeness,
                                     verdict: likeness < 0.6 ? .uncertain("Pairing doubtful") : .same)
            shot.speed = paired.count > 1 ? Double(paired.last!.1 - paired.first!.1) / Double(paired.count - 1) : 1
            shots.append(shot)
        }
        return shots
    }
}

// MARK: - Punch-in search

/// Every master frame's summed-area table (from its kept 8-bit luma), so any crop's fingerprint costs a box sum per
/// cell. Crops: 1.3, 1.6, 2, 2.5 and 3× at positions a tenth of the crop apart; their cell bounds are worked out once
/// per crop, then every master frame is tried (every second one: the measuring window of ±4 finds the exact frame).
final class PunchInIndex: @unchecked Sendable {
    let frames: Int
    private let w: Int
    private let h: Int
    private let tables: [Float]
    private let stride: Int

    init?(_ master: Fingerprints) {
        let (w, h, frames) = (master.lumaWidth, master.lumaHeight, master.count)
        guard w > 0, h > 0, frames > 0, master.luma.count == w * h * frames else { return nil }
        let stride = (w + 1) * (h + 1)
        (self.w, self.h, self.frames, self.stride) = (w, h, frames, stride)
        var tables = [Float](repeating: 0, count: stride * frames)
        master.luma.withUnsafeBufferPointer { luma in
            for f in 0..<frames {
                let t = f * stride, l = f * w * h
                for y in 0..<h {
                    var row: Float = 0
                    for x in 0..<w {
                        row += Float(luma[l + y * w + x])
                        tables[t + (y + 1) * (w + 1) + x + 1] = tables[t + y * (w + 1) + x + 1] + row
                    }
                }
            }
        }
        self.tables = tables
    }

    /// The master frame and crop whose fingerprint correlates best with `target`, if ≥ 0.9.
    func bestCrop(for target: [Float]) -> (likeness: Float, frame: Int, scale: Double, x: Double, y: Double)? {
        let g = Fingerprints.grid
        var best: (likeness: Float, frame: Int, scale: Double, x: Double, y: Double)?
        var cells = [Float](repeating: 0, count: g * g)
        // Per cell: its table corners (top-left, top-right, bottom-left, bottom-right) and area.
        var bounds = [(Int, Int, Int, Int, Float)](repeating: (0, 0, 0, 0, 1), count: g * g)
        let row = w + 1
        tables.withUnsafeBufferPointer { tables in
            for zoom in [1.3, 1.6, 2.0, 2.5, 3.0] {
                let cw = Double(w) / zoom, ch = Double(h) / zoom
                let stepX = max(1.0, cw / 10), stepY = max(1.0, ch / 10)
                var oy = 0.0
                while oy + ch <= Double(h) + 0.01 {
                    var ox = 0.0
                    while ox + cw <= Double(w) + 0.01 {
                        for gy in 0..<g {
                            let y0 = Int(oy + ch * Double(gy) / Double(g)), y1 = min(h, max(y0 + 1, Int(oy + ch * Double(gy + 1) / Double(g))))
                            for gx in 0..<g {
                                let x0 = Int(ox + cw * Double(gx) / Double(g)), x1 = min(w, max(x0 + 1, Int(ox + cw * Double(gx + 1) / Double(g))))
                                bounds[gy * g + gx] = (y0 * row + x0, y0 * row + x1, y1 * row + x0, y1 * row + x1,
                                                       Float(max(1, (x1 - x0) * (y1 - y0))))
                            }
                        }
                        for f in Swift.stride(from: 0, to: frames, by: 2) {
                            let t = f * stride
                            for k in 0..<(g * g) {
                                let b = bounds[k]
                                cells[k] = (tables[t + b.3] - tables[t + b.1] - tables[t + b.2] + tables[t + b.0]) / b.4
                            }
                            var mean: Float = 0
                            vDSP_meanv(cells, 1, &mean, vDSP_Length(cells.count))
                            var negative = -mean
                            vDSP_vsadd(cells, 1, &negative, &cells, 1, vDSP_Length(cells.count))
                            var energy: Float = 0
                            vDSP_svesq(cells, 1, &energy, vDSP_Length(cells.count))
                            guard energy > 1e-6 else { continue }
                            var dot: Float = 0
                            vDSP_dotpr(cells, 1, target, 1, &dot, vDSP_Length(cells.count))
                            let likeness = dot / sqrt(energy)
                            if likeness >= 0.9, likeness > (best?.likeness ?? 0) {
                                best = (likeness, f, zoom, (ox + cw / 2) / Double(w) - 0.5, (oy + ch / 2) / Double(h) - 0.5)
                            }
                        }
                        ox += stepX
                    }
                    oy += stepY
                }
            }
        }
        return best
    }
}

/// A count shared by tasks.
final class Counter: @unchecked Sendable {
    private let lock = NSLock()
    private var value = 0
    func increment() -> Int { lock.withLock { value += 1; return value } }
}

// MARK: - Fingerprints

/// One small, normalised luma image per frame.
public struct Fingerprints: Sendable {
    /// Long side of the fingerprint grid. Measured on natural-spectrum pictures: at 16 the same shot moved 15 % and
    /// zoomed 10 % still correlates ≥ 0.84 while different shots stay ≤ 0.46 (24: 0.81 / 0.43; 8: 0.87 / 0.49).
    static let grid = 16
    static let dimension = grid * grid

    public var fps: Double = 25
    public var naturalSize: CGSize = CGSize(width: 1080, height: 1080)
    /// `count` vectors of `dimension` floats, zero-mean and unit-length (all zeros for a blank frame).
    public var vectors: [Float] = []
    /// The ~96 px luma images themselves (8-bit, as decoded), kept for the master only: the punch-in search crops them.
    var luma: [UInt8] = []
    var lumaWidth = 0
    var lumaHeight = 0
    public var error: String?
    public var count: Int { vectors.count / Self.dimension }

    public init() {}

    /// Builds fingerprints from luma images (`width` × `height`, row-major, any scale), for tests and the reader.
    public init(lumaFrames: [[Float]], width: Int, height: Int, fps: Double = 25) {
        self.fps = fps
        for frame in lumaFrames { append(frame, width: width, height: height) }
    }

    /// Correlation of frames `a` and `b` of this file.
    func likeness(_ a: Int, _ b: Int) -> Float { likeness(with: self, a, b) }

    func likeness(with other: Fingerprints, _ a: Int, _ b: Int) -> Float {
        let d = Self.dimension
        var dot: Float = 0
        vectors.withUnsafeBufferPointer { x in
            other.vectors.withUnsafeBufferPointer { y in
                vDSP_dotpr(x.baseAddress! + a * d, 1, y.baseAddress! + b * d, 1, &dot, vDSP_Length(d))
            }
        }
        return dot
    }

    /// Box-averages the image onto a `grid` × `grid` square (whatever its shape: cutdowns share the master's), then
    /// removes the mean and scales to unit length.
    mutating func append(_ luma: [Float], width: Int, height: Int) {
        let g = Self.grid
        var cells = [Float](repeating: 0, count: g * g)
        var counts = [Float](repeating: 0, count: g * g)
        for y in 0..<height {
            let gy = min(g - 1, y * g / height)
            for x in 0..<width {
                let gx = min(g - 1, x * g / width)
                cells[gy * g + gx] += luma[y * width + x]
                counts[gy * g + gx] += 1
            }
        }
        for k in cells.indices { cells[k] /= max(1, counts[k]) }
        var mean: Float = 0
        vDSP_meanv(cells, 1, &mean, vDSP_Length(cells.count))
        var negative = -mean
        vDSP_vsadd(cells, 1, &negative, &cells, 1, vDSP_Length(cells.count))
        var energy: Float = 0
        vDSP_svesq(cells, 1, &energy, vDSP_Length(cells.count))
        // A blank frame (black, a flat colour) carries nothing to pair on: all zeros, so it pairs with nothing.
        if energy / Float(cells.count) < 1e-5 {
            cells = [Float](repeating: 0, count: cells.count)
        } else {
            var scale = 1 / sqrt(energy)
            vDSP_vsmul(cells, 1, &scale, &cells, 1, vDSP_Length(cells.count))
        }
        vectors += cells
    }

    /// Decodes every frame of `url` at ~96 px (hardware-scaled, luma plane only).
    static func read(_ url: URL, keepLuma: Bool = false, cancellation: CancellationState, progress: @Sendable (Double) -> Void) async -> Fingerprints {
        var prints = Fingerprints()
        let asset = AVURLAsset(url: url)
        guard let track = try? await asset.loadTracks(withMediaType: .video).first,
              let reader = try? AVAssetReader(asset: asset) else {
            prints.error = ProVideoFormats.openError(for: url)
            return prints
        }
        let loaded = (try? await track.load(.naturalSize)) ?? .zero
        let transform = (try? await track.load(.preferredTransform)) ?? .identity
        let oriented = loaded.applying(transform)
        let natural = CGSize(width: abs(oriented.width), height: abs(oriented.height))
        prints.naturalSize = natural.width >= 1 && natural.height >= 1 && natural.width < 100_000 ? natural : CGSize(width: 1080, height: 1080)
        prints.fps = FrameRate.counting(nominal: Double((try? await track.load(.nominalFrameRate)) ?? 25))
        let duration = CMTimeGetSeconds((try? await asset.load(.duration)) ?? .zero)
        let expected = max(1, Int(((duration.isFinite ? duration : 0) * prints.fps).rounded()))
        let size = CGSize(width: max(1, loaded.width), height: max(1, loaded.height))
        let longSide = max(size.width, size.height)
        let w = max(16, Int(96 * size.width / longSide) & ~1)
        let h = max(16, Int(96 * size.height / longSide) & ~1)
        let output = AVAssetReaderTrackOutput(track: track, outputSettings: [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange,
            kCVPixelBufferWidthKey as String: w,
            kCVPixelBufferHeightKey as String: h
        ])
        output.alwaysCopiesSampleData = false
        guard reader.canAdd(output) else { prints.error = "Couldn't decode the video"; return prints }
        reader.add(output)
        guard reader.startReading() else {
            prints.error = reader.error?.localizedDescription ?? "Couldn't start decoding"
            return prints
        }
        var frames = 0
        while let sample = output.copyNextSampleBuffer() {
            if cancellation.isCancelled { reader.cancelReading(); break }
            guard let buffer = CMSampleBufferGetImageBuffer(sample) else { continue }
            let (luma, _) = FrameCheckScanner.planes(buffer, width: w, height: h)
            var values = [Float](repeating: 0, count: luma.count)
            vDSP_vfltu8(luma, 1, &values, 1, vDSP_Length(luma.count))
            prints.append(values, width: w, height: h)
            if keepLuma {
                prints.luma += luma
                prints.lumaWidth = w
                prints.lumaHeight = h
            }
            frames += 1
            if frames % 25 == 0 { progress(min(1, Double(frames) / Double(expected))) }
        }
        if reader.status == .failed, frames == 0 { prints.error = reader.error?.localizedDescription ?? "Decoding failed" }
        progress(1)
        return prints
    }
}

// MARK: - Framing

/// Decodes chosen frame pairs at measuring size and measures the cutdown's framing against the master's.
/// One lane of measuring: its own pair of frame readers (an image generator isn't shared between tasks), opened once
/// for all the shots it measures.
final class FramingMeasurer: @unchecked Sendable {
    let masterSize: CGSize
    private let w: Int
    private let h: Int
    private let cutReader: FrameReader
    private let masterReader: FrameReader

    init(cutdown: URL, master: URL, cutdownFps: Double, masterFps: Double, masterSize: CGSize) {
        self.masterSize = masterSize
        let landscape = masterSize.width >= masterSize.height
        w = landscape ? Self.measureSize : max(48, Int(Double(Self.measureSize) * masterSize.width / max(1, masterSize.height)))
        h = landscape ? max(48, Int(Double(Self.measureSize) * masterSize.height / max(1, masterSize.width))) : Self.measureSize
        cutReader = FrameReader(url: cutdown, fps: cutdownFps, width: w, height: h)
        masterReader = FrameReader(url: master, fps: masterFps, width: w, height: h)
    }

    /// Long side of the measured images.
    static let measureSize = 384
    static let tooPlain = "Too plain to measure"

    /// How far either side of the path's pairing to look for the exact master frame: fingerprints are blurred (they
    /// must survive reframes) and can't tell neighbouring frames of a slow shot apart.
    static let pairingWindow = 4
    /// Scores this close count as a tie.
    static let tie: Float = 0.001
    /// The same picture framed right correlates above ~0.95 (compression aside); below this the pair isn't trusted.
    static let minimumFit: Float = 0.8
    /// A punch-in found by the zoomed search must fit at least this well, on frames agreeing on its scale within 3 %;
    /// otherwise it was a chance likeness and the shot stays "not in the master".
    static let punchInFit: Float = 0.9

    func measure(_ shot: CropMatchShot, path: [Int?], masterCount: Int) async -> CropMatchShot {
        guard shot.verdict == .same else { return shot }
        var shot = shot
        // A few frames inside the shot, away from its ends (dissolves, motion blur at a cut).
        let picks = Set([0.3, 0.5, 0.7].map { shot.start + Int(Double(shot.frameCount - 1) * $0) })
            .sorted().compactMap { i in path[i].map { (i, $0) } }
        var masterImages: [Int: [Float]] = [:]
        var measures: [(cut: Int, master: Int, framing: CropAligner.Framing, ambiguous: Bool)] = []
        for (c, m) in picks {
            guard let a = await cutReader.gray(c) else { continue }
            // The exact master frame: the one in the window that fits best once framed.
            var options: [(m: Int, pyramid: CropAligner.Pyramid, coarse: CropAligner.Candidate)] = []
            // A punch-in: start from the crop the zoomed search found (in coarse-level pixels).
            var anchor: CropAligner.Candidate? = shot.hintScale.map { scale in
                let coarse = CropAligner.coarseSize(width: w, height: h)
                return CropAligner.Candidate(value: 0, scale: scale, dx: shot.hintX * Double(coarse.w), dy: shot.hintY * Double(coarse.h))
            }
            // The path's own frame first, searched in full; its neighbours near the framing it found.
            let window = max(0, m - Self.pairingWindow)...min(masterCount - 1, m + Self.pairingWindow)
            for candidate in [m] + window.filter({ $0 != m }) where candidate >= 0 && candidate < masterCount {
                if masterImages[candidate] == nil { masterImages[candidate] = await masterReader.gray(candidate) }
                guard let b = masterImages[candidate],
                      let pyramid = CropAligner.pyramid(cutdown: a, master: b, width: w, height: h) else { continue }
                let coarse = CropAligner.coarse(pyramid, near: anchor)
                if anchor == nil { anchor = coarse }
                options.append((candidate, pyramid, coarse))
            }
            // Refine the three best at the coarse level (refining is the costly part).
            let refined = options.sorted { $0.coarse.value > $1.coarse.value }.prefix(3)
                .map { (m: $0.m, framing: CropAligner.refine($0.pyramid, from: $0.coarse)) }
            guard let best = refined.max(by: { $0.framing.score < $1.framing.score }) else { continue }
            // Even the best framing fits poorly: these aren't the same picture (a wrong pairing, or graphics over it).
            if !best.framing.tooPlain && best.framing.score < Self.minimumFit {
                measures.append((c, best.m, best.framing, true))
                continue
            }
            let toMaster = Double(masterSize.width) / Double(w)
            // Another frame fitting as well with a different verdict: in this move, timing and framing can't be told
            // apart (a pan over a flat scene).
            let ambiguous = refined.contains {
                $0.m != best.m && $0.framing.score >= best.framing.score - Self.tie
                    && $0.framing.isReframed(width: w, sourceScale: toMaster) != best.framing.isReframed(width: w, sourceScale: toMaster)
            }
            measures.append((c, best.m, best.framing, ambiguous))
        }
        guard !measures.isEmpty else {
            shot.verdict = .uncertain("Frames couldn't be read")
            return shot
        }
        if shot.hintScale != nil {
            let fitting = measures.filter { !$0.framing.tooPlain && $0.framing.score >= Self.punchInFit }
            let scales = fitting.map(\.framing.scale)
            guard let low = scales.min(), let high = scales.max(), fitting.count == measures.count, high / low <= 1.03 else {
                return CropMatchShot(id: shot.id, start: shot.start, end: shot.end, masterStart: nil, masterEnd: nil,
                                     likeness: 0, verdict: .notInMaster)
            }
        }
        let readable = measures.filter { !$0.framing.tooPlain && !$0.ambiguous }
        guard let worst = readable.max(by: { $0.framing.magnitude(width: w) < $1.framing.magnitude(width: w) }) else {
            let poorFit = measures.contains { !$0.framing.tooPlain && $0.framing.score < Self.minimumFit }
            shot.verdict = .uncertain(poorFit ? "Doesn't match the master closely (another take, or graphics over it?)"
                                      : measures.contains { $0.ambiguous } ? "Camera move: timing and framing can't be told apart"
                                      : Self.tooPlain)
            shot.measuredCutdownFrame = measures[0].cut
            shot.measuredMasterFrame = measures[0].master
            return shot
        }
        let toMaster = Double(masterSize.width) / Double(w)
        shot.measuredCutdownFrame = worst.cut
        shot.measuredMasterFrame = worst.master
        if worst.framing.isReframed(width: w, sourceScale: toMaster) {
            shot.verdict = .reframed
            shot.shift = CGPoint(x: worst.framing.dx * toMaster, y: worst.framing.dy * toMaster)
            shot.scale = worst.framing.scale
        }
        return shot
    }

}

/// Exact frames of one file as grey levels 0…1 at a fixed size, from one image generator.
final class FrameReader: @unchecked Sendable {
    private let generator: AVAssetImageGenerator
    private let fps: Double
    private let width: Int
    private let height: Int

    init(url: URL, fps: Double, width: Int, height: Int) {
        generator = AVAssetImageGenerator(asset: AVURLAsset(url: url))
        generator.appliesPreferredTrackTransform = true
        generator.requestedTimeToleranceBefore = .zero
        generator.requestedTimeToleranceAfter = .zero
        generator.maximumSize = CGSize(width: width * 2, height: height * 2)
        self.fps = fps
        self.width = width
        self.height = height
    }

    /// Frame `frame` (its middle, the app's frame-to-time rule), nil when it can't be decoded.
    func gray(_ frame: Int) async -> [Float]? {
        let time = CMTime(seconds: (Double(frame) + 0.5) / max(1, fps), preferredTimescale: 60000)
        guard let image = try? await generator.image(at: time).image else { return nil }
        var bytes = [UInt8](repeating: 0, count: width * height)
        let (w, h) = (width, height)
        let drawn: Bool = bytes.withUnsafeMutableBytes { buffer in
            guard let context = CGContext(data: buffer.baseAddress, width: w, height: h, bitsPerComponent: 8,
                                          bytesPerRow: w, space: CGColorSpaceCreateDeviceGray(),
                                          bitmapInfo: CGImageAlphaInfo.none.rawValue) else { return false }
            context.interpolationQuality = .high
            context.draw(image, in: CGRect(x: 0, y: 0, width: w, height: h))
            return true
        }
        guard drawn else { return nil }
        var values = [Float](repeating: 0, count: bytes.count)
        vDSP_vfltu8(bytes, 1, &values, 1, vDSP_Length(bytes.count))
        var scale: Float = 1 / 255
        vDSP_vsmul(values, 1, &scale, &values, 1, vDSP_Length(values.count))
        return values
    }
}

/// Measures how a cutdown frame is framed against the master frame it was cut from: a scale about the centre and a
/// shift. Searched coarse to fine (from ~24 px, doubling up to the measured size), scoring each candidate by the correlation of the cutdown's
/// central 60 % with the master sampled where that framing puts it; the shift is refined below a pixel by fitting a
/// parabola to the scores around the best.
public enum CropAligner {
    public struct Framing: Sendable, Equatable {
        /// Where the cutdown's centre sits in the master, in measured-image pixels.
        public var dx: Double
        public var dy: Double
        /// Above 1: the cutdown is tighter.
        public var scale: Double
        /// Correlation at the best framing, and with no change at all.
        public var score: Float
        public var identityScore: Float
        /// Too little detail to measure from (a plain or dark picture).
        public var tooPlain: Bool

        /// How far the framing is off, in measured-image pixels (scale counted at the frame's edge).
        func magnitude(width: Int) -> Double { hypot(dx, dy) + abs(scale - 1) * Double(width) / 2 }

        /// A real reframe: more than about a source pixel of shift or 0.3 % of scale, and fitting clearly better than
        /// no change (measurement noise on a frame that matches as it is doesn't count).
        func isReframed(width: Int, sourceScale: Double) -> Bool {
            let shiftSource = hypot(dx, dy) * sourceScale
            let edgeSource = abs(scale - 1) * Double(width) / 2 * sourceScale
            return (shiftSource >= 1.5 || edgeSource >= 1.5) && score - identityScore >= 0.002
        }
    }

    /// The two images at each search level, coarsest first.
    struct Pyramid {
        var levels: [(cut: [Float], master: [Float], w: Int, h: Int)]
        let width: Int
        let height: Int
        var top: (cut: [Float], master: [Float], w: Int, h: Int) { levels[levels.count - 1] }
    }

    struct Candidate {
        var value: Float
        var scale: Double
        var dx: Double
        var dy: Double
    }

    /// Nil when the images aren't the expected size.
    public static func measure(cutdown: [Float], master: [Float], width: Int, height: Int) -> Framing? {
        guard let pyramid = pyramid(cutdown: cutdown, master: master, width: width, height: height) else { return nil }
        return refine(pyramid, from: coarse(pyramid))
    }

    /// The coarsest level's size for an image of `width` × `height` (as `pyramid` builds it).
    static func coarseSize(width: Int, height: Int) -> (w: Int, h: Int) {
        var size = max(width, height)
        while size / 2 >= 20 { size /= 2 }
        let factor = Double(max(width, height)) / Double(size)
        return (max(8, Int((Double(width) / factor).rounded())), max(8, Int((Double(height) / factor).rounded())))
    }

    /// Area-averaged levels: the image's own size, halved down to about 24 px (the exhaustive search runs there: a
    /// pixel is 4 % of the frame, and each finer level only looks a pixel around).
    static func pyramid(cutdown: [Float], master: [Float], width: Int, height: Int) -> Pyramid? {
        guard cutdown.count == width * height, master.count == width * height, width >= 48, height >= 48 else { return nil }
        var sizes = [max(width, height)]
        while sizes[0] / 2 >= 20 { sizes.insert(sizes[0] / 2, at: 0) }
        var levels: [(cut: [Float], master: [Float], w: Int, h: Int)] = []
        for size in sizes {
            let factor = Double(max(width, height)) / Double(size)
            let w = max(8, Int((Double(width) / factor).rounded()))
            let h = max(8, Int((Double(height) / factor).rounded()))
            levels.append((resize(cutdown, width, height, to: w, h), resize(master, width, height, to: w, h), w, h))
        }
        return Pyramid(levels: levels, width: width, height: height)
    }

    /// Search at the coarsest level: scales 0.75…1.5 and shifts ±25 % of the frame, or only around `near` (±4 px,
    /// ±3 scale steps: a neighbouring frame of the same shot frames almost the same way).
    static func coarse(_ pyramid: Pyramid, near: Candidate? = nil) -> Candidate {
        let level = pyramid.levels[0]
        var best = Candidate(value: -.infinity, scale: 1, dx: 0, dy: 0)
        let span = Int(Double(max(level.w, level.h)) * 0.25)
        let steps = near.map { n -> ClosedRange<Int> in
            let centre = Int((log(n.scale) / log(1.02)).rounded())
            return (centre - 3)...(centre + 3)
        } ?? -14...21   // 1.02^-14 ≈ 0.76, 1.02^21 ≈ 1.52
        // Around a hint, anywhere in the frame (a punch-in's window can sit near an edge); `score` rejects windows
        // that fall outside the master.
        let xs = near.map { (Int($0.dx.rounded()) - 4)...(Int($0.dx.rounded()) + 4) } ?? -span...span
        let ys = near.map { (Int($0.dy.rounded()) - 4)...(Int($0.dy.rounded()) + 4) } ?? -span...span
        for step in steps {
            let s = pow(1.02, Double(step))
            for dy in ys {
                for dx in xs {
                    let v = score(level.cut, level.master, w: level.w, h: level.h, scale: s, dx: Double(dx), dy: Double(dy)).value
                    if v > best.value { best = Candidate(value: v, scale: s, dx: Double(dx), dy: Double(dy)) }
                }
            }
        }
        return best
    }

    /// From a coarse candidate: climbs a pixel and a scale step at a time at each finer level, then below a pixel by a
    /// parabola through the scores either side of the best, per axis.
    static func refine(_ pyramid: Pyramid, from start: Candidate) -> Framing {
        let top = pyramid.top
        let identity = score(top.cut, top.master, w: top.w, h: top.h, scale: 1, dx: 0, dy: 0)
        guard !identity.plain else {
            return Framing(dx: 0, dy: 0, scale: 1, score: identity.value, identityScore: identity.value, tooPlain: true)
        }
        var best = start
        var scaleStep = 0.02
        // Each finer level: a pixel and a scale step around the best, again while that improves (a single step
        // could stop short: a 5 % reframe once read 4 %), then the same with half the scale step.
        func climb(_ level: (cut: [Float], master: [Float], w: Int, h: Int), step: Double) {
            best.value = score(level.cut, level.master, w: level.w, h: level.h, scale: best.scale, dx: best.dx, dy: best.dy).value
            for _ in 0..<12 {
                let center = best
                for ds in -1...1 {
                    let s = center.scale * (1 + Double(ds) * step)
                    for oy in -1...1 {
                        for ox in -1...1 where ds != 0 || oy != 0 || ox != 0 {
                            let v = score(level.cut, level.master, w: level.w, h: level.h, scale: s,
                                          dx: center.dx + Double(ox), dy: center.dy + Double(oy)).value
                            if v > best.value { best = Candidate(value: v, scale: s, dx: center.dx + Double(ox), dy: center.dy + Double(oy)) }
                        }
                    }
                }
                if best.scale == center.scale && best.dx == center.dx && best.dy == center.dy { break }
            }
        }
        for level in pyramid.levels.dropFirst() {
            best.dx *= 2
            best.dy *= 2
            scaleStep /= 2
            climb(level, step: scaleStep)
        }
        climb(top, step: scaleStep / 2)
        scaleStep /= 2
        func vertex(_ minus: Float, _ mid: Float, _ plus: Float) -> Double {
            let denominator = Double(minus - 2 * mid + plus)
            guard denominator < -1e-9 else { return 0 }
            return max(-0.5, min(0.5, 0.5 * Double(minus - plus) / denominator))
        }
        func at(_ scale: Double, _ dx: Double, _ dy: Double) -> Float {
            score(top.cut, top.master, w: top.w, h: top.h, scale: scale, dx: dx, dy: dy).value
        }
        let s = best.scale
        let fx = vertex(at(s, best.dx - 1, best.dy), best.value, at(s, best.dx + 1, best.dy))
        let fy = vertex(at(s, best.dx, best.dy - 1), best.value, at(s, best.dx, best.dy + 1))
        let step = scaleStep / 2
        let fs = vertex(at(s * (1 - step), best.dx, best.dy), best.value, at(s * (1 + step), best.dx, best.dy))
        // Scaled back to the measured image's size (the top level is it, give or take rounding).
        let toImage = Double(max(pyramid.width, pyramid.height)) / Double(max(top.w, top.h))
        return Framing(dx: (best.dx + fx) * toImage, dy: (best.dy + fy) * toImage, scale: s * (1 + fs * step),
                       score: best.value, identityScore: identity.value, tooPlain: false)
    }

    /// Correlation of the cutdown's central 60 % with the master sampled at `centre + (p − centre) / scale + shift`.
    /// Candidates that would sample outside the master score −1.
    static func score(_ cut: [Float], _ master: [Float], w: Int, h: Int, scale: Double, dx: Double, dy: Double) -> (value: Float, plain: Bool) {
        let x0 = Int(Double(w) * 0.2), x1 = Int(Double(w) * 0.8)
        let y0 = Int(Double(h) * 0.2), y1 = Int(Double(h) * 0.8)
        let cx = Double(w - 1) / 2, cy = Double(h - 1) / 2
        let inv = 1 / scale
        // The window's corners must land inside the master.
        let left = cx + (Double(x0) - cx) * inv + dx, right = cx + (Double(x1 - 1) - cx) * inv + dx
        let topEdge = cy + (Double(y0) - cy) * inv + dy, bottom = cy + (Double(y1 - 1) - cy) * inv + dy
        guard left >= 0, right <= Double(w - 1), topEdge >= 0, bottom <= Double(h - 1) else { return (-1, false) }
        var sa: Double = 0, sb: Double = 0, saa: Double = 0, sbb: Double = 0, sab: Double = 0
        var n: Double = 0
        cut.withUnsafeBufferPointer { a in
            master.withUnsafeBufferPointer { b in
                for y in y0..<y1 {
                    let my = cy + (Double(y) - cy) * inv + dy
                    let iy = min(h - 2, Int(my)), fy = Float(my - Double(iy))
                    for x in x0..<x1 {
                        let mx = cx + (Double(x) - cx) * inv + dx
                        let ix = min(w - 2, Int(mx)), fx = Float(mx - Double(ix))
                        let p = iy * w + ix
                        let top = b[p] + (b[p + 1] - b[p]) * fx
                        let bottom = b[p + w] + (b[p + w + 1] - b[p + w]) * fx
                        let mv = Double(top + (bottom - top) * fy)
                        let cv = Double(a[y * w + x])
                        sa += cv; sb += mv; saa += cv * cv; sbb += mv * mv; sab += cv * mv
                        n += 1
                    }
                }
            }
        }
        let va = saa - sa * sa / n, vb = sbb - sb * sb / n
        // Plain: a standard deviation under 1.5 % of full scale in the cutdown's window.
        let plain = va / n < 0.015 * 0.015
        guard va > 1e-12, vb > 1e-12 else { return (0, plain) }
        return (Float((sab - sa * sb / n) / sqrt(va * vb)), plain)
    }

    /// Area-average resize (downscaling only; the same size is a copy).
    static func resize(_ image: [Float], _ w: Int, _ h: Int, to nw: Int, _ nh: Int) -> [Float] {
        guard nw != w || nh != h else { return image }
        var out = [Float](repeating: 0, count: nw * nh)
        var counts = [Float](repeating: 0, count: nw * nh)
        for y in 0..<h {
            let oy = min(nh - 1, y * nh / h)
            for x in 0..<w {
                let ox = min(nw - 1, x * nw / w)
                out[oy * nw + ox] += image[y * w + x]
                counts[oy * nw + ox] += 1
            }
        }
        for k in out.indices { out[k] /= max(1, counts[k]) }
        return out
    }
}
