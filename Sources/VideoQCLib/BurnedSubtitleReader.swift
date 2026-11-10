@preconcurrency import AVFoundation
import CoreMedia
import Foundation
import Vision

/// Reads subtitles burned into the picture: samples a few frames a second, reads the lower (or upper) part of each
/// with Vision's text recognition, and turns the readings into timed cues whose in and out land on the exact frame
/// (each change of text between two samples is found by searching the frames in between).
/// The result is a draft to review: OCR can misread stylised text, and low-confidence cues are marked.
/// Measured (M4 Max, 1080p H.264, clean white subtitles, 112 s): every cue word for word, every boundary on the
/// reference frame, ~4× real time per segment. See docs/research/BURNED_IN_SUBTITLES_PLAN.md.
public final class BurnedSubtitleReader: Sendable {
    public enum Region: String, Sendable, CaseIterable {
        case bottom, top

        /// Vision's region of interest (normalised, origin bottom-left).
        var rect: CGRect {
            switch self {
            case .bottom: return CGRect(x: 0, y: 0, width: 1, height: 0.35)
            case .top: return CGRect(x: 0, y: 0.75, width: 1, height: 0.25)
            }
        }
    }

    public struct Options: Sendable, Equatable {
        public var region: Region
        /// Vision language codes in order of preference; empty: Vision detects the language.
        public var languages: [String]
        public var samplesPerSecond: Double

        public init(region: Region = .bottom, languages: [String] = [], samplesPerSecond: Double = 4) {
            self.region = region
            self.languages = languages
            self.samplesPerSecond = samplesPerSecond
        }
    }

    public struct Result: Sendable {
        public var cues: [SubtitleCue]
        /// Indices of cues worth a second look (low recognition confidence).
        public var lowConfidence: Set<Int>
        /// Something the user should know about the whole result (word-by-word captions, nothing found).
        public var note: String?
    }

    /// The text on screen from `frame` on, until the next change.
    public struct Change: Sendable, Equatable {
        public var frame: Int
        public var text: String
        public var confidence: Float

        public init(frame: Int, text: String, confidence: Float) {
            self.frame = frame
            self.text = text
            self.confidence = confidence
        }
    }

    public enum Failure: Error, LocalizedError {
        case missing, noVideo, unreadable, cancelled

        public var errorDescription: String? {
            switch self {
            case .missing: return "The file isn't there any more (moved, renamed, or its drive was ejected)."
            case .noVideo: return "The file has no video track."
            case .unreadable: return "The video couldn't be read."
            case .cancelled: return "Stopped."
            }
        }
    }

    private let cancellation = CancellationState()

    public init() {}

    public func cancel() { cancellation.cancel() }

    /// Two segments read at once (one decode + OCR stream leaves the machine half idle).
    public func read(_ url: URL, options: Options = Options(), progress: @escaping @Sendable (Double) -> Void) async throws -> Result {
        guard FileManager.default.fileExists(atPath: url.path) else { throw Failure.missing }
        let asset = AVURLAsset(url: url)
        guard let track = try? await asset.loadTracks(withMediaType: .video).first else { throw Failure.noVideo }
        var rate = Double((try? await track.load(.nominalFrameRate)) ?? 0)
        if !(rate > 0), let minimum = try? await track.load(.minFrameDuration), minimum.seconds > 0 {
            rate = 1 / minimum.seconds   // some variable-rate files report no nominal rate
        }
        let fps = rate
        let duration = (try? await asset.load(.duration))?.seconds ?? 0
        guard fps > 0, fps.isFinite, duration.isFinite, duration > 0 else { throw Failure.unreadable }
        let size = (try? await track.load(.naturalSize)) ?? .zero
        let transform = (try? await track.load(.preferredTransform)) ?? .identity
        let orientationRaw = Self.orientation(of: transform).rawValue   // the enum isn't Sendable
        let outputSize = Self.decodeSize(size)
        let totalFrames = max(1, Int((duration * fps).rounded()))
        let step = max(1, Int((fps / max(0.5, options.samplesPerSecond)).rounded()))
        // Split on a sample frame, read by both: the second segment's first reading repeats the first's last.
        let split = totalFrames > step * 8 ? (totalFrames / 2) / step * step : totalFrames - 1
        let ranges = split < totalFrames - 1 ? [0...split, split...(totalFrames - 1)] : [0...(totalFrames - 1)]
        let cancellation = self.cancellation
        let shares = ProgressShares(count: ranges.count, report: progress)

        let segments = try await withThrowingTaskGroup(of: (Int, [Change]).self) { group in
            for (index, range) in ranges.enumerated() {
                group.addTask {
                    // Seconds of blocking decode and OCR: on a dispatch thread, never one of Swift's few shared task
                    // threads (blocking those starved everything else; seen with several reads at once).
                    let changes = try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<[Change], Error>) in
                        DispatchQueue.global(qos: .utility).async(execute: DispatchWorkItem {
                            do {
                                continuation.resume(returning: try Self.readSegment(
                                    asset: asset, track: track, fps: fps, frames: range, step: step, size: outputSize,
                                    orientation: CGImagePropertyOrientation(rawValue: orientationRaw) ?? .up,
                                    options: options, cancellation: cancellation) { shares.set(index, $0) })
                            } catch {
                                continuation.resume(throwing: error)
                            }
                        })
                    }
                    return (index, changes)
                }
            }
            var out: [[Change]] = Array(repeating: [], count: ranges.count)
            for try await (index, changes) in group { out[index] = changes }
            return out
        }
        if cancellation.isCancelled { throw Failure.cancelled }
        // The halves share their split frame: the second's first reading repeats the first's last, unless the first
        // half didn't get that far (a frame the decoder skipped), in which case it's a real change and stays.
        var changes = segments.first ?? []
        for segment in segments.dropFirst() {
            guard let head = segment.first else { continue }
            let repeated = changes.last.map { Self.sameText($0.text, head.text) } ?? false
            changes += repeated ? Array(segment.dropFirst()) : segment
        }
        return Self.result(from: changes, totalFrames: totalFrames, fps: fps)
    }

    // MARK: - Reading

    struct Reading { var text: String; var confidence: Float }

    /// Decoded at most 1920 px on the long side: subtitles read the same, and a 4K or 60 fps clip keeps the frames
    /// held between two samples (for the boundary search) to ~8 MB each instead of 33.
    static func decodeSize(_ natural: CGSize) -> CGSize? {
        let long = max(abs(natural.width), abs(natural.height))
        guard long > 1920 else { return nil }
        let scale = 1920 / long
        func even(_ v: CGFloat) -> CGFloat { max(2, (abs(v) * scale / 2).rounded() * 2) }
        return CGSize(width: even(natural.width), height: even(natural.height))
    }

    /// How the stored pixels must be turned to look upright (phone recordings store landscape pixels plus a rotation).
    static func orientation(of t: CGAffineTransform) -> CGImagePropertyOrientation {
        switch (t.a, t.b, t.c, t.d) {
        case (0, 1, -1, 0): return .right
        case (0, -1, 1, 0): return .left
        case (-1, 0, 0, -1): return .down
        default: return .up
        }
    }

    static func recognise(_ buffer: CVPixelBuffer, orientation: CGImagePropertyOrientation = .up, options: Options) -> Reading {
        let request = VNRecognizeTextRequest()
        request.recognitionLevel = .accurate
        request.usesLanguageCorrection = true
        if options.languages.isEmpty {
            request.automaticallyDetectsLanguage = true
        } else {
            request.recognitionLanguages = options.languages
        }
        request.regionOfInterest = options.region.rect
        try? VNImageRequestHandler(cvPixelBuffer: buffer, orientation: orientation, options: [:]).perform([request])
        // Top to bottom; specks narrower than 1.5% of the picture are noise ("No." on a 1080p frame is ~4%).
        let lines = (request.results ?? [])
            .filter { $0.boundingBox.width > 0.015 }
            .sorted { $0.boundingBox.midY > $1.boundingBox.midY }
            .compactMap { $0.topCandidates(1).first }
        guard !lines.isEmpty else { return Reading(text: "", confidence: 0) }
        return Reading(text: lines.map(\.string).joined(separator: "\n"),
                       confidence: lines.map(\.confidence).reduce(0, +) / Float(lines.count))
    }

    static func sameText(_ a: String, _ b: String) -> Bool {
        if a.isEmpty || b.isEmpty { return a.isEmpty && b.isEmpty }
        return textDistance(a, b) <= 0.15
    }

    /// Reads frames `frames` (sampling every `step`-th frame of the clip) and returns each change of text, found to
    /// the exact frame by a binary search over the frames between the two samples around it.
    static func readSegment(asset: AVAsset, track: AVAssetTrack, fps: Double, frames: ClosedRange<Int>, step: Int,
                            size: CGSize? = nil, orientation: CGImagePropertyOrientation = .up,
                            options: Options, cancellation: CancellationState,
                            progress: (Double) -> Void) throws -> [Change] {
        guard let reader = try? AVAssetReader(asset: asset) else { throw Failure.unreadable }
        var settings: [String: Any] = [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA]
        if let size {
            settings[kCVPixelBufferWidthKey as String] = Int(size.width)
            settings[kCVPixelBufferHeightKey as String] = Int(size.height)
        }
        let output = AVAssetReaderTrackOutput(track: track, outputSettings: settings)
        output.alwaysCopiesSampleData = false
        reader.add(output)
        // Half a frame early: the first frame's time can sit a hair before its nominal position.
        let start = CMTime(seconds: max(0, (Double(frames.lowerBound) - 0.5) / fps), preferredTimescale: 600_000)
        let end = CMTime(seconds: (Double(frames.upperBound) + 0.5) / fps, preferredTimescale: 600_000)
        reader.timeRange = CMTimeRange(start: start, end: end)
        guard reader.startReading() else { throw Failure.unreadable }
        defer { reader.cancelReading() }

        var window: [(frame: Int, buffer: CVPixelBuffer)] = []
        var previous: Reading? = nil
        var changes: [Change] = []
        let span = Double(max(1, frames.count))
        var lastReported = -1.0
        while let sample = output.copyNextSampleBuffer() {
            if cancellation.isCancelled { throw Failure.cancelled }
            guard let buffer = CMSampleBufferGetImageBuffer(sample) else { continue }
            let frame = Int((CMSampleBufferGetPresentationTimeStamp(sample).seconds * fps).rounded())
            guard frames.contains(frame) else { continue }
            guard frame % step == 0 else { window.append((frame, buffer)); continue }
            let reading = autoreleasepool { recognise(buffer, orientation: orientation, options: options) }
            if let previous {
                if !sameText(previous.text, reading.text) {
                    var lo = 0, hi = window.count
                    while lo < hi {
                        let mid = (lo + hi) / 2
                        let text = autoreleasepool { recognise(window[mid].buffer, orientation: orientation, options: options).text }
                        if sameText(text, reading.text) { hi = mid } else { lo = mid + 1 }
                    }
                    changes.append(Change(frame: hi < window.count ? window[hi].frame : frame, text: reading.text, confidence: reading.confidence))
                } else if reading.confidence > (changes.last?.confidence ?? 0), !reading.text.isEmpty {
                    // The same subtitle read more clearly: keep the best reading.
                    changes[changes.count - 1].text = reading.text
                    changes[changes.count - 1].confidence = reading.confidence
                }
            } else {
                changes.append(Change(frame: frame, text: reading.text, confidence: reading.confidence))
            }
            previous = reading
            window.removeAll(keepingCapacity: true)
            let done = Double(frame - frames.lowerBound) / span
            if done - lastReported >= 0.01 { lastReported = done; progress(done) }
        }
        if cancellation.isCancelled { throw Failure.cancelled }
        if reader.status == .failed { throw Failure.unreadable }
        progress(1)
        return changes
    }

    // MARK: - Changes → cues (pure)

    /// Cues from the changes of text: wobbles merged, stray dialogue dashes and non-subtitles (too short, too long,
    /// on screen most of the clip) dropped, low-confidence cues marked.
    public static func result(from changes: [Change], totalFrames: Int, fps: Double) -> Result {
        guard fps > 0 else { return Result(cues: [], lowConfidence: [], note: nil) }
        struct Span { var start: Int; var end: Int; var text: String; var confidence: Float }
        var spans: [Span] = []
        for (i, change) in changes.enumerated() where !change.text.isEmpty {
            let end = i + 1 < changes.count ? changes[i + 1].frame : totalFrames
            guard end > change.frame else { continue }
            // Neighbours that are the same subtitle read slightly differently become one.
            if var last = spans.last, last.end == change.frame, textDistance(last.text, change.text) <= 0.25 {
                if change.confidence > last.confidence { last.text = change.text; last.confidence = change.confidence }
                last.end = end
                spans[spans.count - 1] = last
            } else {
                spans.append(Span(start: change.frame, end: end, text: change.text, confidence: change.confidence))
            }
        }
        // Text on screen for most of a longer clip is a logo or a bug, not a subtitle. Short clips (socials) can hold
        // one caption throughout, so they keep it.
        var onScreen: [String: Int] = [:]
        for span in spans { onScreen[normalise(span.text), default: 0] += span.end - span.start }
        let clipSeconds = Double(totalFrames) / fps
        let kept = spans.filter { span in
            Double(span.end - span.start) / fps >= 0.4   // shorter: a misread during a fade
                && !(clipSeconds > 30 && Double(onScreen[normalise(span.text)] ?? 0) > Double(totalFrames) * 0.6)
        }
        var cues: [SubtitleCue] = []
        var low = Set<Int>()
        for span in kept {
            // Unusually long text (a title card, a super) is kept but marked for a look.
            if span.confidence < 0.6 || Double(span.end - span.start) / fps > 10 { low.insert(cues.count) }
            cues.append(SubtitleCue(start: Double(span.start) / fps, end: Double(span.end) / fps, text: cleaned(span.text)))
        }
        var note: String? = nil
        if cues.isEmpty {
            note = "No subtitles found in that part of the picture."
        } else if Double(cues.filter { $0.end - $0.start < 0.8 }.count) > Double(cues.count) * 0.4 {
            note = "The captions change very quickly (word by word?): check the result closely."
        }
        return Result(cues: cues, lowConfidence: low, note: note)
    }

    /// A dash on one line of several is a misread mark (dialogue dashes start every line).
    static func cleaned(_ text: String) -> String {
        var lines = text.components(separatedBy: "\n")
        let dashed = lines.indices.filter { lines[$0].hasPrefix("- ") || lines[$0].hasPrefix("-") && lines[$0].count > 1 && lines[$0].dropFirst().first?.isLetter == true }
        if lines.count > 1, dashed.count == 1 {
            let i = dashed[0]
            lines[i] = String(lines[i].drop { $0 == "-" || $0 == " " })
        } else if lines.count == 1, let line = lines.first, line.hasPrefix("- ") {
            lines[0] = String(line.dropFirst(2))
        }
        return lines.joined(separator: "\n")
    }

    // MARK: - Text comparison

    /// Lowercased, curly quotes straightened, punctuation and line breaks folded to single spaces.
    public static func normalise(_ s: String) -> String {
        let straight = s.replacingOccurrences(of: "’", with: "'").replacingOccurrences(of: "‘", with: "'")
            .replacingOccurrences(of: "“", with: "\"").replacingOccurrences(of: "”", with: "\"").lowercased()
        let kept = straight.unicodeScalars.map { CharacterSet.alphanumerics.contains($0) || $0 == "'" ? Character($0) : " " }
        return String(kept).split(separator: " ").joined(separator: " ")
    }

    /// Edit distance of the normalised texts over the longer one's length (0 = same, 1 = nothing in common).
    public static func textDistance(_ a: String, _ b: String) -> Double {
        let x = Array(normalise(a)), y = Array(normalise(b))
        guard max(x.count, y.count) > 0 else { return 0 }
        guard !x.isEmpty, !y.isEmpty else { return 1 }
        var prev = Array(0...y.count), cur = [Int](repeating: 0, count: y.count + 1)
        for i in 1...x.count {
            cur[0] = i
            for j in 1...y.count {
                cur[j] = min(prev[j] + 1, cur[j - 1] + 1, prev[j - 1] + (x[i - 1] == y[j - 1] ? 0 : 1))
            }
            swap(&prev, &cur)
        }
        return Double(prev[y.count]) / Double(max(x.count, y.count))
    }
}

/// Combines each segment's progress into one figure.
private final class ProgressShares: @unchecked Sendable {
    private let lock = NSLock()
    private var parts: [Double]
    private let report: @Sendable (Double) -> Void

    init(count: Int, report: @escaping @Sendable (Double) -> Void) {
        parts = Array(repeating: 0, count: max(1, count))
        self.report = report
    }

    func set(_ index: Int, _ value: Double) {
        let total: Double = lock.withLock {
            parts[index] = value
            return parts.reduce(0, +) / Double(parts.count)
        }
        report(total)
    }
}
