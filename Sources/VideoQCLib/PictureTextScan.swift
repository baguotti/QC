@preconcurrency import AVFoundation
import CoreMedia
import Foundation
import UniformTypeIdentifiers
import Vision

/// What text a deliverable shows in its picture (Inspect → Check Subs & Graphics): whether it likely has burned-in
/// subtitles, and which other text (titles, supers, wordmarks, end cards) appears and when.
/// Text only: a logo with no letters isn't seen, so "clean" means "no text found".
public struct PictureTextCheck: Equatable, Sendable {
    /// Text seen from `start` to `end` (seconds).
    public struct Sighting: Equatable, Sendable {
        public var text: String
        public var start: Double
        public var end: Double

        public init(text: String, start: Double, end: Double) {
            self.text = text
            self.start = start
            self.end = end
        }
    }

    /// Changing text, centred in the lower part of the picture, several times.
    public var subtitlesLikely: Bool
    /// A few of the lines that made it look like subtitles.
    public var subtitleExamples: [Sighting]
    /// Other text, longest on screen first (at most 5).
    public var graphics: [Sighting]
    /// A video that couldn't be decoded to the end (damaged, cut short, or its drive went away).
    public var isUnreadable: Bool
    /// Nothing to check: audio, a still image or an image sequence.
    public var isUnavailable: Bool

    public var hasGraphics: Bool { !graphics.isEmpty }
    public var isClean: Bool { !isUnreadable && !isUnavailable && !subtitlesLikely && graphics.isEmpty }

    public init(subtitlesLikely: Bool, subtitleExamples: [Sighting] = [], graphics: [Sighting] = [], isUnreadable: Bool = false,
                isUnavailable: Bool = false) {
        self.subtitlesLikely = subtitlesLikely
        self.subtitleExamples = subtitleExamples
        self.graphics = graphics
        self.isUnreadable = isUnreadable
        self.isUnavailable = isUnavailable
    }

    public static let unreadable = PictureTextCheck(subtitlesLikely: false, isUnreadable: true)
    public static let unavailable = PictureTextCheck(subtitlesLikely: false, isUnavailable: true)

    /// Export / table wording.
    public var subsLabel: String { isUnavailable ? "—" : isUnreadable ? "CAN'T READ" : subtitlesLikely ? "LIKELY" : "NONE" }
    public func graphicsLabel(for name: String) -> String {
        if isUnavailable { return "—" }
        if isUnreadable { return "CAN'T READ" }
        let base = graphics.isEmpty ? (subtitlesLikely ? "NO GRAPHICS" : "CLEAN") : "TEXT: " + graphics.map(\.text).joined(separator: " · ")
        let mismatches = nameMismatches(for: name)
        return mismatches.isEmpty ? base : base + " (MISMATCH: " + mismatches.joined(separator: "; ") + ")"
    }

    // MARK: - What the file name promises

    public enum NamePromise: Equatable, Sendable {
        /// CLEAN / TEXTLESS / NOTEXT: no text at all.
        case clean
        /// TITLED / TITLES / LOGO / SUPERS / TXT: text graphics.
        case titled
        /// SUBS / SUBBED / SUBTITLED / OCAPS: burned-in subtitles.
        case subtitled
    }

    /// Promises made by the file name's tokens ("…_16x9_CLEAN_v2.mov" → [.clean]). A word after NO / WITHOUT
    /// ("NO_LOGO", "NO SUBS") promises its absence instead: NO_TEXT is clean, NO_LOGO and NO_SUBS promise nothing
    /// about the rest.
    public static func promises(inName name: String) -> Set<NamePromise> {
        let words = (name as NSString).deletingPathExtension.uppercased()
            .split { !$0.isLetter && !$0.isNumber }.map(String.init)
        var tokens = Set<String>()
        var negated = Set<String>()
        for (i, word) in words.enumerated() {
            if i > 0, ["NO", "WITHOUT", "WO"].contains(words[i - 1]) { negated.insert(word) } else { tokens.insert(word) }
        }
        var out = Set<NamePromise>()
        if !tokens.isDisjoint(with: ["CLEAN", "TEXTLESS", "NOTEXT", "NOTXT"]) || !negated.isDisjoint(with: ["TEXT", "TXT"]) {
            out.insert(.clean)
        }
        if !tokens.isDisjoint(with: ["TITLED", "TITLES", "LOGO", "SUPERS", "TXT"]) { out.insert(.titled) }
        if !tokens.isDisjoint(with: ["SUB", "SUBS", "SUBBED", "SUBTITLED", "SUBTITLES", "OCAP", "OCAPS"]) { out.insert(.subtitled) }
        // A name can't promise both clean and text: say nothing rather than flag one of them wrongly.
        if out.contains(.clean), out.count > 1 { return [] }
        return out
    }

    /// Where the picture disagrees with what the name says (empty: no disagreement, or nothing to compare).
    public func nameMismatches(for name: String) -> [String] {
        guard !isUnreadable, !isUnavailable else { return [] }
        let promised = Self.promises(inName: name)
        var out: [String] = []
        if promised.contains(.clean), !isClean {
            out.append("Named CLEAN but shows \(subtitlesLikely ? "subtitles" : "text graphics")")
        }
        if promised.contains(.titled), !hasGraphics {
            out.append("Named as titled but no text graphics were found")
        }
        if promised.contains(.subtitled), !subtitlesLikely {
            out.append("Named as subtitled but no subtitles were found")
        }
        return out
    }
}

/// Samples one frame a second of each file and reads its text with Vision. Two files at a time, each on a dispatch
/// thread (never Swift's shared task threads: a read blocks for seconds).
public enum PictureTextScanner {
    /// One text box seen in one sample (`box` normalised, origin bottom-left).
    public struct Observation: Equatable, Sendable {
        public var text: String
        public var box: CGRect

        public init(text: String, box: CGRect) {
            self.text = text
            self.box = box
        }
    }

    public struct Sample: Equatable, Sendable {
        public var time: Double
        public var observations: [Observation]

        public init(time: Double, observations: [Observation]) {
            self.time = time
            self.observations = observations
        }
    }

    public static let samplesPerSecond = 2.0

    /// Checks `urls` two at a time; `progress` gets each result as it lands (url, result, files done).
    /// `reading` gets each file's share read so far (0…1), at most a few times a second per file.
    public static func checkBatch(urls: [URL], isCancelled: @escaping @Sendable () -> Bool,
                                  reading: @escaping @Sendable (URL, Double) -> Void = { _, _ in },
                                  progress: @escaping @Sendable (URL, PictureTextCheck, Int) -> Void) async {
        let counter = Counter()
        await withTaskGroup(of: Void.self) { group in
            var next = 0
            func submit() {
                guard next < urls.count, !isCancelled() else { return }
                let url = urls[next]
                next += 1
                group.addTask {
                    let result = await check(url, isCancelled: isCancelled) { reading(url, $0) }
                    guard !isCancelled() else { return }
                    progress(url, result, counter.increment())
                }
            }
            for _ in 0..<2 { submit() }
            for await _ in group { submit() }
        }
    }

    /// Reads one file (nil when cancelled).
    public static func check(_ url: URL, isCancelled: @escaping @Sendable () -> Bool = { false },
                             reading: @escaping @Sendable (Double) -> Void = { _ in }) async -> PictureTextCheck {
        var isFolder: ObjCBool = false
        guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isFolder) else { return .unreadable }
        guard !isFolder.boolValue else { return .unavailable }   // an image sequence
        let asset = AVURLAsset(url: url)
        guard let track = try? await asset.loadTracks(withMediaType: .video).first else {
            // No video: audio or a still is nothing to check; a movie file without a readable track is damaged.
            let type = UTType(filenameExtension: url.pathExtension.lowercased())
            return type.map { $0.conforms(to: .movie) || $0.conforms(to: .video) } == true ? .unreadable : .unavailable
        }
        let duration = (try? await asset.load(.duration))?.seconds ?? 0
        let natural = (try? await track.load(.naturalSize)) ?? .zero
        let upright = natural.applying((try? await track.load(.preferredTransform)) ?? .identity)
        let aspect = upright.height == 0 ? 16.0 / 9.0 : abs(upright.width / upright.height)
        let size = (try? await track.load(.naturalSize)) ?? .zero
        let orientationRaw = BurnedSubtitleReader.orientation(of: (try? await track.load(.preferredTransform)) ?? .identity).rawValue
        let outputSize = BurnedSubtitleReader.decodeSize(size)
        let samples: [Sample]? = await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .utility).async(execute: DispatchWorkItem {
                var reported = Date.distantPast
                continuation.resume(returning: readSamples(asset: asset, track: track, size: outputSize,
                                                           orientation: CGImagePropertyOrientation(rawValue: orientationRaw) ?? .up,
                                                           isCancelled: isCancelled) { time in
                    guard duration > 0, Date().timeIntervalSince(reported) >= 0.5 else { return }
                    reported = Date()
                    reading(min(1, time / duration))
                })
            })
        }
        // Cut short (a copy or render that stopped, a drive that went away): the reader just ends early, so what was
        // read isn't the whole picture.
        guard let samples, let lastTime = samples.last?.time,
              !duration.isFinite || duration <= 0 || lastTime >= duration - max(1.5, duration * 0.02) else { return .unreadable }
        return classify(samples, aspect: aspect)
    }

    static func readSamples(asset: AVAsset, track: AVAssetTrack, size: CGSize?, orientation: CGImagePropertyOrientation,
                            isCancelled: () -> Bool, sampled: (Double) -> Void = { _ in }) -> [Sample]? {
        guard let reader = try? AVAssetReader(asset: asset) else { return nil }
        var settings: [String: Any] = [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA]
        if let size {
            settings[kCVPixelBufferWidthKey as String] = Int(size.width)
            settings[kCVPixelBufferHeightKey as String] = Int(size.height)
        }
        let output = AVAssetReaderTrackOutput(track: track, outputSettings: settings)
        output.alwaysCopiesSampleData = false
        reader.add(output)
        guard reader.startReading() else { return nil }
        defer { reader.cancelReading() }
        var samples: [Sample] = []
        var nextTime = 0.0
        // The last frame is always read too: an end logo can sit in the final half second, between two samples.
        var last: (time: Double, buffer: CVPixelBuffer)? = nil
        while let sample = output.copyNextSampleBuffer() {
            if isCancelled() { return samples }
            let time = CMSampleBufferGetPresentationTimeStamp(sample).seconds
            guard time.isFinite, let buffer = CMSampleBufferGetImageBuffer(sample) else { continue }
            guard time >= nextTime else { last = (time, buffer); continue }
            last = nil
            nextTime = (time / (1 / samplesPerSecond)).rounded(.down) * (1 / samplesPerSecond) + 1 / samplesPerSecond
            let observations = autoreleasepool { recognise(buffer, orientation: orientation) }
            samples.append(Sample(time: time, observations: observations))
            sampled(time)
        }
        if let last, !isCancelled() {
            samples.append(Sample(time: last.time, observations: autoreleasepool { recognise(last.buffer, orientation: orientation) }))
        }
        if reader.status == .failed { return nil }
        return samples
    }

    static func recognise(_ buffer: CVPixelBuffer, orientation: CGImagePropertyOrientation) -> [Observation] {
        let request = VNRecognizeTextRequest()
        request.recognitionLevel = .accurate
        request.usesLanguageCorrection = false
        request.automaticallyDetectsLanguage = true
        try? VNImageRequestHandler(cvPixelBuffer: buffer, orientation: orientation, options: [:]).perform([request])
        return (request.results ?? []).compactMap { result in
            guard let best = result.topCandidates(1).first, best.confidence >= 0.4 else { return nil }
            let text = best.string.trimmingCharacters(in: .whitespacesAndNewlines)
            // At least two letters or digits: lone marks and noise aren't text.
            guard text.unicodeScalars.filter({ CharacterSet.alphanumerics.contains($0) }).count >= 2 else { return nil }
            return Observation(text: text, box: result.boundingBox)
        }
    }

    // MARK: - Classification (pure)

    /// Subtitle-like: a line wider than it is tall in pixels (text printed on a product or a rotated logo isn't),
    /// centred horizontally, in the lower 35% of the picture (45% for portrait: social captions sit higher, clear of
    /// the app's buttons). `aspect` is the upright picture's width / height.
    static func isSubtitleArea(_ box: CGRect, aspect: Double = 16.0 / 9.0) -> Bool {
        box.midY < (aspect < 1 ? 0.45 : 0.35) && abs(box.midX - 0.5) < 0.2
            && box.width * aspect >= box.height * 1.5
    }

    public static func classify(_ samples: [Sample], aspect: Double = 16.0 / 9.0) -> PictureTextCheck {
        let interval = 1 / samplesPerSecond
        // Subtitles: lower-centre text in 3+ samples, with 2+ different lines. A sample with more than three lines
        // there is a credits roll or a text card, not a subtitle.
        let lower = samples.compactMap { sample -> (Double, String)? in
            let lines = sample.observations.filter { isSubtitleArea($0.box, aspect: aspect) }
                .sorted { $0.box.midY > $1.box.midY }.map(\.text)
            return lines.isEmpty || lines.count > 3 ? nil : (sample.time, lines.joined(separator: " "))
        }
        var distinct: [String] = []
        for (_, text) in lower where !distinct.contains(where: { BurnedSubtitleReader.textDistance($0, text) <= 0.25 }) {
            distinct.append(text)
        }
        let subtitlesLikely = lower.count >= 3 && distinct.count >= 2
        let examples = subtitlesLikely
            ? Array(group(lower.map { ($0.0, $0.1) }, interval: interval).prefix(3)) : []

        // Graphics: everything else (all text when it isn't subtitles), big enough, and on screen for 2+ samples
        // in a row unless large (a one-second end logo).
        let others: [(Double, Observation)] = samples.flatMap { sample in
            sample.observations
                .filter { !(subtitlesLikely && isSubtitleArea($0.box, aspect: aspect)) && $0.box.height >= 0.02 }
                .map { (sample.time, $0) }
        }
        let grouped = group(others.map { ($0.0, $0.1.text) }, interval: interval)
        let bigTexts = Set(others.filter { $0.1.box.height >= 0.05 }.map { BurnedSubtitleReader.normalise($0.1.text) })
        let graphics = grouped
            .filter { $0.end - $0.start >= interval * 1.5 || bigTexts.contains(BurnedSubtitleReader.normalise($0.text)) }
            .sorted { ($0.end - $0.start) > ($1.end - $1.start) }
        return PictureTextCheck(subtitlesLikely: subtitlesLikely, subtitleExamples: examples, graphics: Array(graphics.prefix(5)))
    }

    /// Joins sightings of the same text (OCR wobble allowed) into one with its first and last time; a text seen in
    /// separate stretches stays one sighting spanning them (the tooltip says when it first and last appears).
    static func group(_ items: [(time: Double, text: String)], interval: Double) -> [PictureTextCheck.Sighting] {
        var out: [PictureTextCheck.Sighting] = []
        for (time, text) in items {
            if let i = out.firstIndex(where: { BurnedSubtitleReader.textDistance($0.text, text) <= 0.25 }) {
                out[i].start = min(out[i].start, time)
                out[i].end = max(out[i].end, time + interval)
            } else {
                out.append(PictureTextCheck.Sighting(text: text, start: time, end: time + interval))
            }
        }
        return out.sorted { $0.start < $1.start }
    }

    private final class Counter: @unchecked Sendable {
        private let lock = NSLock()
        private var value = 0
        func increment() -> Int { lock.withLock { value += 1; return value } }
    }
}
