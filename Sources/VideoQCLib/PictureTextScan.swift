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
    /// Different subtitle lines read (0 when none).
    public var subtitleLineCount: Int
    /// Every appearance of other text, as read, in order.
    public var allGraphics: [Sighting] { didSet { refresh() } }
    /// Texts marked Not a Graphic (normalised, `BurnedSubtitleReader.normalise`): misreads, signs in the footage.
    public var dismissed: Set<String> { didSet { refresh() } }

    /// The appearances without the dismissed texts (an appearance whose texts are all dismissed is gone). Worked out
    /// when the readings or the dismissals change, not on every read: sorting 1,000 files read it ~20,000 times.
    public private(set) var graphics: [Sighting] = []
    /// Every text in `graphics`, once each, in order of first appearance.
    public private(set) var graphicTexts: [String] = []

    private mutating func refresh() {
        graphics = Self.visible(allGraphics, dismissed: dismissed)
        var texts: [String] = []
        for sighting in graphics {
            for text in sighting.text.components(separatedBy: " · ")
            where !texts.contains(where: { BurnedSubtitleReader.textDistance($0, text) <= 0.25 }) {
                texts.append(text)
            }
        }
        graphicTexts = texts
    }

    private static func visible(_ allGraphics: [Sighting], dismissed: Set<String>) -> [Sighting] {
        guard !dismissed.isEmpty else { return allGraphics }
        return allGraphics.compactMap { sighting in
            // Close matches count: the same misread can come back slightly different on the next check.
            let texts = sighting.text.components(separatedBy: " · ").filter { text in
                let key = BurnedSubtitleReader.normalise(text)
                return !dismissed.contains { $0 == key || BurnedSubtitleReader.textDistance($0, key) <= 0.25 }
            }
            guard !texts.isEmpty else { return nil }
            return Sighting(text: texts.joined(separator: " · "), start: sighting.start, end: sighting.end)
        }
    }

    /// The texts of an appearance, normalised: what Not a Graphic stores.
    public static func dismissKeys(for sighting: Sighting) -> Set<String> {
        Set(sighting.text.components(separatedBy: " · ").map(BurnedSubtitleReader.normalise).filter { !$0.isEmpty })
    }
    /// A video that couldn't be decoded to the end (damaged, cut short, or its drive went away).
    public var isUnreadable: Bool
    /// Nothing to check: audio, a still image or an image sequence.
    public var isUnavailable: Bool

    public var hasGraphics: Bool { !graphics.isEmpty }

    public var isClean: Bool { !isUnreadable && !isUnavailable && !subtitlesLikely && graphics.isEmpty }

    public init(subtitlesLikely: Bool, subtitleExamples: [Sighting] = [], subtitleLineCount: Int = 0, graphics: [Sighting] = [],
                dismissed: Set<String> = [], isUnreadable: Bool = false, isUnavailable: Bool = false) {
        self.subtitlesLikely = subtitlesLikely
        self.subtitleExamples = subtitleExamples
        self.subtitleLineCount = subtitleLineCount
        self.allGraphics = graphics
        self.dismissed = dismissed
        self.isUnreadable = isUnreadable
        self.isUnavailable = isUnavailable
        refresh()
    }

    public static let unreadable = PictureTextCheck(subtitlesLikely: false, isUnreadable: true)
    public static let unavailable = PictureTextCheck(subtitlesLikely: false, isUnavailable: true)

    /// Export / table wording.
    public var subsLabel: String {
        isUnavailable ? "—" : isUnreadable ? "CAN'T READ"
            : subtitlesLikely ? (subtitleLineCount > 1 ? "LIKELY (\(subtitleLineCount) lines)" : "LIKELY") : "NONE"
    }
    public func graphicsLabel(for name: String) -> String {
        if isUnavailable { return "—" }
        if isUnreadable { return "CAN'T READ" }
        let base = graphics.isEmpty ? (subtitlesLikely ? "NO GRAPHICS" : "CLEAN") : "TEXT: " + graphicTexts.joined(separator: " · ")
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

    /// Language codes a delivery name carries (`_EN_`, `_FR_`, `_ENG_`…).
    static let languageTokens: Set<String> = ["EN", "ENG", "FR", "FRA", "DE", "GER", "ES", "SPA", "IT", "ITA", "PT", "NL", "JA",
                                               "JP", "ZH", "CN", "KO", "KR", "AR", "RU", "PL", "SV", "DA", "FI", "TR"]   // not NO: it negates (NO_LOGO)

    static func namesLanguage(_ name: String) -> Bool {
        !languageTokens.isDisjoint(with: (name as NSString).deletingPathExtension.uppercased()
            .split { !$0.isLetter && !$0.isNumber }.map(String.init))
    }

    /// Where the picture disagrees with what the name says (empty: no disagreement, or nothing to compare).
    public func nameMismatches(for name: String) -> [String] {
        guard !isUnreadable, !isUnavailable else { return [] }
        let promised = Self.promises(inName: name)
        var out: [String] = []
        // "…_EN_CLEAN_…": a language beside CLEAN asks for subtitles, so CLEAN only rules out logos and titles.
        let subsAllowed = Self.namesLanguage(name)
        if promised.contains(.clean), hasGraphics || (subtitlesLikely && !subsAllowed) {
            out.append("Named CLEAN but shows \(hasGraphics ? "text graphics" : "subtitles")")
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
    public static var sampleInterval: Double { 1 / samplesPerSecond }

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
        // The decoder's own 4:2:0 format, which Vision reads directly: converting every frame to BGRA (most are never
        // read) cost more than half the decode (measured, 1080p H.264: 0.93 s → 0.39 s per 30 s, same text read).
        var settings: [String: Any] = [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange]
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
            // Stray marks read at the edges of a line ("/ JIMMY CHOO") aren't part of it.
            let text = best.string.trimmingCharacters(in: CharacterSet.whitespacesAndNewlines.union(CharacterSet(charactersIn: "/\\|_·•-–—")))
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
        // Or one sentence-like line (4+ words) that comes, goes and comes back: a repeated subtitle. A short tagline
        // at the start and end of a spot stays a graphic, and so does text that stays on screen throughout.
        let repeatedSentence = distinct.count == 1 && distinct[0].split(separator: " ").count >= 4
            && zip(lower, lower.dropFirst()).contains { $1.0 - $0.0 > interval * 1.5 }
        let subtitlesLikely = lower.count >= 3 && (distinct.count >= 2 || repeatedSentence)
        let examples = subtitlesLikely
            ? Array(group(lower.map { ($0.0, $0.1) }, interval: interval).prefix(3)) : []

        // Graphics: everything else (all text when it isn't subtitles) at least 2% of the frame tall, as appearances:
        // a stretch of samples with text on screen is one graphic (all the words of a title card together), and a
        // logo shown at the start and again at the end is two. Each appearance gets its own Player marker.
        var perSample: [(time: Double, texts: [Observation])] = samples.map { sample in
            (sample.time, sample.observations.filter {
                !(subtitlesLikely && isSubtitleArea($0.box, aspect: aspect)) && $0.box.height >= 0.02
            })
        }
        // Text on screen most of the time (a corner logo, a channel bug) is its own graphic, and is taken out before
        // the rest is grouped: it would otherwise join every title of the clip into one appearance.
        var persistent: [PictureTextCheck.Sighting] = []
        // Only in clips of 20 s or more, for text in 60% of the samples with no break longer than 2 s: in a short
        // spot, a name on two cards in a row isn't a bug, and a logo at the start and the end is two appearances.
        if perSample.count >= Int(20 * samplesPerSecond) {
            var counts: [String: (text: String, count: Int, first: Double, last: Double, longestGap: Double)] = [:]
            for sample in perSample {
                for key in Set(sample.texts.map { BurnedSubtitleReader.normalise($0.text) }) where !key.isEmpty {
                    let text = sample.texts.first { BurnedSubtitleReader.normalise($0.text) == key }?.text ?? key
                    let entry = counts[key] ?? (text, 0, sample.time, sample.time, 0)
                    counts[key] = (entry.text, entry.count + 1, entry.first, sample.time, max(entry.longestGap, sample.time - entry.last))
                }
            }
            let steady = counts.filter { Double($0.value.count) >= Double(perSample.count) * 0.6 && $0.value.longestGap <= 2 }
            persistent = steady.values.map { PictureTextCheck.Sighting(text: $0.text, start: $0.first, end: $0.last + interval) }
            for i in perSample.indices {
                perSample[i].texts.removeAll { steady[BurnedSubtitleReader.normalise($0.text)] != nil }
            }
        }
        var runs: [[(time: Double, texts: [Observation])]] = []
        for sample in perSample where !sample.texts.isEmpty {
            // Same appearance while most of the previous sample's text is still there (text building up on a card)
            // or most of this sample's text was already there (text going away): one shared word (a brand name on two
            // cards in a row) doesn't join two cards.
            if let previous = runs.last?.last, sample.time - previous.time <= interval * 1.5,
               Double(previous.texts.filter { old in sample.texts.contains { related($0.text, old.text) } }.count) > Double(previous.texts.count) * 0.5
                || Double(sample.texts.filter { new in previous.texts.contains { related($0.text, new.text) } }.count) > Double(sample.texts.count) * 0.5 {
                runs[runs.count - 1].append(sample)
            } else {
                runs.append([sample])   // a gap, or a whole new set of text (a cut to another card)
            }
        }
        // A lone sample right next to another appearance is a transition frame (a card wiping into the next one, or
        // animated text): it joins its neighbour, where its one-off readings drop out. A lone sample on its own (a
        // short end logo) stays an appearance.
        var kept: [[(time: Double, texts: [Observation])]] = []
        for (index, run) in runs.enumerated() {
            if run.count == 1, let time = run.first?.time {
                if let previous = kept.last?.last?.time, time - previous <= interval * 1.5 {
                    kept[kept.count - 1].append(contentsOf: run)
                    continue
                }
                if index + 1 < runs.count, let next = runs[index + 1].first?.time, next - time <= interval * 1.5 {
                    runs[index + 1].insert(contentsOf: run, at: 0)
                    continue
                }
            }
            kept.append(run)
        }
        let graphics = (kept.compactMap { run in appearance(run, interval: interval, aspect: aspect) } + persistent)
            .sorted { $0.start < $1.start }
        return PictureTextCheck(subtitlesLikely: subtitlesLikely, subtitleExamples: examples,
                                subtitleLineCount: subtitlesLikely ? distinct.count : 0, graphics: Array(graphics.prefix(30)))
    }

    /// The same text read twice: a close match, or one reading inside the other (a title typing itself out).
    static func related(_ a: String, _ b: String) -> Bool {
        if BurnedSubtitleReader.textDistance(a, b) <= 0.25 { return true }
        let x = BurnedSubtitleReader.normalise(a), y = BurnedSubtitleReader.normalise(b)
        let (short, long) = x.count <= y.count ? (x, y) : (y, x)
        return short.count >= 3 && long.contains(short)
    }

    /// One appearance of text graphics: its readings that recur (or are big), fragments of fuller readings dropped,
    /// most seen first. Nil for a lone small reading (a misread or a flash).
    static func appearance(_ run: [(time: Double, texts: [Observation])], interval: Double,
                           aspect: Double = 16.0 / 9.0) -> PictureTextCheck.Sighting? {
        guard let first = run.first, let last = run.last else { return nil }
        var readings: [(text: String, count: Int, big: Bool)] = []
        for sample in run {
            for observation in sample.texts {
                // Seen once, text running sideways (taller than wide in pixels) is a misread edge, not a graphic.
                if run.count == 1, observation.box.width * aspect < observation.box.height { continue }
                let big = observation.box.height >= 0.05
                if let i = readings.firstIndex(where: { related($0.text, observation.text) }) {
                    readings[i].count += 1
                    readings[i].big = readings[i].big || big
                    // Keep the longer reading of the same text ("JMMY CHOO" → "JIMMY CHOO").
                    if observation.text.count > readings[i].text.count { readings[i].text = observation.text }
                } else {
                    readings.append((observation.text, 1, big))
                }
            }
        }
        guard run.count >= 2 || readings.contains(where: \.big) else { return nil }
        var kept = readings.filter { $0.count >= 2 || $0.big || run.count == 1 }
        // Text that changed every sample (typed out, animated) leaves no recurring reading: keep its fullest one.
        if kept.isEmpty, run.count >= 2, let fullest = readings.max(by: { $0.text.count < $1.text.count }) { kept = [fullest] }
        // A reading inside a fuller one seen at the same time is a fragment ("VIBES" of "ADIDAS VIBES").
        let names = kept.filter { reading in
            let mine = BurnedSubtitleReader.normalise(reading.text)
            return !kept.contains { other in
                let theirs = BurnedSubtitleReader.normalise(other.text)
                return theirs.count > mine.count && (theirs.contains(mine)
                    || BurnedSubtitleReader.textDistance(String(theirs.suffix(mine.count)), mine) <= 0.34
                    || BurnedSubtitleReader.textDistance(String(theirs.prefix(mine.count)), mine) <= 0.34)
            }
        }
        .sorted { $0.count > $1.count }
        guard !names.isEmpty else { return nil }
        return PictureTextCheck.Sighting(text: names.prefix(6).map(\.text).joined(separator: " · "),
                                         start: first.time, end: last.time + interval)
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
