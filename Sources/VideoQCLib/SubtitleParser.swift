import Foundation

/// One timed subtitle (times in seconds from the start of the clip).
public struct SubtitleCue: Sendable, Equatable {
    public let start: Double
    public let end: Double
    /// Text as written in the file, including styling tags such as `<i>` (kept so saving loses nothing).
    public var text: String

    public init(start: Double, end: Double, text: String) {
        self.start = start
        self.end = end
        self.text = text
    }

    /// Text as shown on screen: styling tags removed.
    public var displayText: String {
        SubtitleParser.stripTags(text).trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

/// How an .srt file was written, so saving it back keeps the same bytes outside the edited text.
public struct SubtitleFileFormat: Sendable, Equatable {
    public var usesCRLF: Bool
    public var hasBOM: Bool
    public var isUTF8: Bool

    public init(usesCRLF: Bool = false, hasBOM: Bool = false, isUTF8: Bool = true) {
        self.usesCRLF = usesCRLF
        self.hasBOM = hasBOM
        self.isUTF8 = isUTF8
    }
}

public struct SubtitleFile: Sendable, Equatable {
    public var cues: [SubtitleCue]
    public var format: SubtitleFileFormat

    public init(cues: [SubtitleCue], format: SubtitleFileFormat = SubtitleFileFormat()) {
        self.cues = cues
        self.format = format
    }
}

public enum SubtitleParser {
    /// Reads an .srt file, trying UTF-8 first and falling back to Windows-1252 (common in subtitle exports).
    public static func load(from url: URL) throws -> [SubtitleCue] {
        try loadFile(from: url).cues
    }

    public static func loadFile(from url: URL) throws -> SubtitleFile {
        let data = try Data(contentsOf: url)
        let utf8 = String(data: data, encoding: .utf8)
        let text = utf8 ?? String(data: data, encoding: .windowsCP1252) ?? String(decoding: data, as: UTF8.self)
        let format = SubtitleFileFormat(
            usesCRLF: text.contains("\r\n"),
            hasBOM: data.starts(with: [0xEF, 0xBB, 0xBF]),
            isUTF8: utf8 != nil
        )
        return SubtitleFile(cues: parseSRT(text), format: format)
    }

    /// Writes cues as SubRip, numbered from 1, in the file's original encoding / BOM / line endings.
    public static func write(_ file: SubtitleFile, to url: URL) throws {
        let newline = file.format.usesCRLF ? "\r\n" : "\n"
        var text = serializeSRT(file.cues).replacingOccurrences(of: "\n", with: newline)
        if file.format.hasBOM && file.format.isUTF8 { text = "\u{FEFF}" + text }
        let encoding: String.Encoding = file.format.isUTF8 ? .utf8 : .windowsCP1252
        guard let data = text.data(using: encoding, allowLossyConversion: false)
                ?? text.data(using: .utf8) else {
            throw CocoaError(.fileWriteInapplicableStringEncoding)
        }
        try data.write(to: url, options: .atomic)
    }

    public static func serializeSRT(_ cues: [SubtitleCue]) -> String {
        var blocks: [String] = []
        for (index, cue) in cues.enumerated() {
            blocks.append("\(index + 1)\n\(timestamp(cue.start)) --> \(timestamp(cue.end))\n\(cue.text)")
        }
        return blocks.joined(separator: "\n\n") + "\n"
    }

    /// Parses SubRip text. Tolerates a BOM, CRLF/CR line endings, missing index lines, `,` or `.` millisecond
    /// separators, extra blank lines and position suffixes after the timing (`X1:… Y1:…`).
    public static func parseSRT(_ raw: String) -> [SubtitleCue] {
        let normalized = raw
            .replacingOccurrences(of: "\u{FEFF}", with: "")
            .replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: "\r", with: "\n")
        var cues: [SubtitleCue] = []
        var lines = normalized.components(separatedBy: "\n")[...]

        while let line = lines.first {
            lines = lines.dropFirst()
            guard line.contains("-->"), let (start, end) = parseTiming(line) else { continue }
            var textLines: [String] = []
            while let next = lines.first, !next.trimmingCharacters(in: .whitespaces).isEmpty {
                textLines.append(next)
                lines = lines.dropFirst()
            }
            let cue = SubtitleCue(start: start, end: end, text: textLines.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines))
            if !cue.displayText.isEmpty && end > start {
                cues.append(cue)
            }
        }
        return cues.sorted { $0.start < $1.start }
    }

    /// Index of the cue on screen at `time`, or nil (binary search; cues are sorted by start).
    public static func cueIndex(at time: Double, in cues: [SubtitleCue]) -> Int? {
        var low = 0
        var high = cues.count - 1
        var candidate: Int? = nil
        while low <= high {
            let mid = (low + high) / 2
            if cues[mid].start <= time {
                candidate = mid
                low = mid + 1
            } else {
                high = mid - 1
            }
        }
        guard let index = candidate else { return nil }
        // Overlapping cues: prefer the latest-starting one still on screen.
        var i = index
        while i >= 0 && cues[i].start > time - 30 {
            if time < cues[i].end { return i }
            i -= 1
        }
        return nil
    }

    /// Text the user edits: every styling tag (`<font …>`, `<i>`, `{\\an8}` …) removed, line breaks kept.
    public static func editableText(_ raw: String) -> String {
        stripTags(raw)
    }
    
    /// Puts edited plain text back into the line's formatting: each line keeps the opening / closing tags that
    /// wrapped the matching original line (extra lines reuse the last line's). Unchanged text returns `raw` untouched,
    /// so tags inside a line are only dropped from lines that were actually edited.
    public static func applyingEditedText(_ edited: String, to raw: String) -> String {
        guard edited != editableText(raw) else { return raw }
        let wrappers = raw.components(separatedBy: "\n").map(lineWrapper)
        let lines = edited.components(separatedBy: "\n")
        return lines.enumerated().map { index, line in
            guard !line.isEmpty, let wrapper = wrappers.isEmpty ? nil : wrappers[min(index, wrappers.count - 1)] else { return line }
            return wrapper.prefix + line + wrapper.suffix
        }.joined(separator: "\n")
    }
    
    private static func lineWrapper(_ line: String) -> (prefix: String, suffix: String) {
        let ns = line as NSString
        let full = NSRange(location: 0, length: ns.length)
        let prefixRange = (try? NSRegularExpression(pattern: #"^(?:<[^/>][^>]*>|\{\\[^}]*\})*"#))?.firstMatch(in: line, range: full)?.range
        let suffixRange = (try? NSRegularExpression(pattern: #"(?:</[^>]+>)*$"#))?.firstMatch(in: line, range: full)?.range
        let prefix = prefixRange.map { ns.substring(with: $0) } ?? ""
        let suffix = suffixRange.map { ns.substring(with: $0) } ?? ""
        return (prefix, prefix.count + suffix.count >= line.count ? "" : suffix)
    }
    
    public static func stripTags(_ text: String) -> String {
        text.replacingOccurrences(of: "<[^>]+>", with: "", options: .regularExpression)
            .replacingOccurrences(of: "\\{\\\\[^}]*\\}", with: "", options: .regularExpression)
    }

    static func timestamp(_ seconds: Double) -> String {
        let totalMs = max(0, Int((seconds * 1000).rounded()))
        let h = totalMs / 3_600_000
        let m = (totalMs / 60_000) % 60
        let s = (totalMs / 1000) % 60
        let ms = totalMs % 1000
        return String(format: "%02d:%02d:%02d,%03d", h, m, s, ms)
    }

    private static func parseTiming(_ line: String) -> (Double, Double)? {
        let parts = line.components(separatedBy: "-->")
        guard parts.count == 2,
              let start = parseTimestamp(parts[0]),
              let endToken = parts[1].trimmingCharacters(in: .whitespaces).split(separator: " ").first,
              let end = parseTimestamp(String(endToken)) else { return nil }
        return (start, end)
    }

    private static func parseTimestamp(_ token: String) -> Double? {
        let cleaned = token.trimmingCharacters(in: .whitespaces).replacingOccurrences(of: ",", with: ".")
        let fields = cleaned.split(separator: ":")
        guard fields.count == 3 || fields.count == 2 else { return nil }
        var seconds = 0.0
        for field in fields {
            guard let value = Double(field) else { return nil }
            seconds = seconds * 60 + value
        }
        return seconds
    }
}

/// Find / replace over the editable (tag-free) subtitle text, optionally case-sensitive. Match ranges are in
/// `SubtitleParser.editableText` coordinates; replacements keep each line's formatting.
public enum SubtitleSearch {
    public struct Match: Sendable, Equatable {
        public let cueIndex: Int
        public let range: NSRange
    }

    public static func matches(in cues: [SubtitleCue], query: String, matchCase: Bool) -> [Match] {
        guard !query.isEmpty else { return [] }
        let options: NSString.CompareOptions = matchCase ? [] : [.caseInsensitive]
        var result: [Match] = []
        for (index, cue) in cues.enumerated() {
            for range in ranges(of: query, in: SubtitleParser.editableText(cue.text), options: options) {
                result.append(Match(cueIndex: index, range: range))
            }
        }
        return result
    }

    public static func ranges(of query: String, in text: String, options: NSString.CompareOptions) -> [NSRange] {
        let ns = text as NSString
        var found: [NSRange] = []
        var searchRange = NSRange(location: 0, length: ns.length)
        while searchRange.length > 0 {
            let r = ns.range(of: query, options: options, range: searchRange)
            guard r.location != NSNotFound, r.length > 0 else { break }
            found.append(r)
            let next = r.location + r.length
            searchRange = NSRange(location: next, length: ns.length - next)
        }
        return found
    }

    /// Replaces every occurrence; returns the new cues and how many replacements were made.
    public static func replaceAll(in cues: [SubtitleCue], query: String, with replacement: String, matchCase: Bool) -> ([SubtitleCue], Int) {
        guard !query.isEmpty else { return (cues, 0) }
        let options: NSString.CompareOptions = matchCase ? [] : [.caseInsensitive]
        var count = 0
        let updated = cues.map { cue -> SubtitleCue in
            let plain = SubtitleParser.editableText(cue.text) as NSString
            let hits = ranges(of: query, in: plain as String, options: options).count
            guard hits > 0 else { return cue }
            count += hits
            var copy = cue
            let replaced = plain.replacingOccurrences(of: query, with: replacement, options: options, range: NSRange(location: 0, length: plain.length))
            copy.text = SubtitleParser.applyingEditedText(replaced, to: cue.text)
            return copy
        }
        return (updated, count)
    }
}
