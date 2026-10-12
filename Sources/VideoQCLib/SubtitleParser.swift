import Foundation

/// One timed subtitle (times in seconds from the start of the clip).
public struct SubtitleCue: Sendable, Equatable {
    public let start: Double
    public let end: Double
    public let text: String

    public init(start: Double, end: Double, text: String) {
        self.start = start
        self.end = end
        self.text = text
    }
}

public enum SubtitleParser {
    /// Reads an .srt file, trying UTF-8 first and falling back to Windows-1252 / Latin-1 (common in subtitle exports).
    public static func load(from url: URL) throws -> [SubtitleCue] {
        let data = try Data(contentsOf: url)
        let text = String(data: data, encoding: .utf8)
            ?? String(data: data, encoding: .windowsCP1252)
            ?? String(decoding: data, as: UTF8.self)
        return parseSRT(text)
    }

    /// Parses SubRip text. Tolerates a BOM, CRLF/CR line endings, missing index lines, `,` or `.` millisecond
    /// separators, extra blank lines and position suffixes after the timing (`X1:… Y1:…`). Basic tags are stripped.
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
            let text = stripTags(textLines.joined(separator: "\n")).trimmingCharacters(in: .whitespacesAndNewlines)
            if !text.isEmpty && end > start {
                cues.append(SubtitleCue(start: start, end: end, text: text))
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

    private static func stripTags(_ text: String) -> String {
        text.replacingOccurrences(of: "<[^>]+>", with: "", options: .regularExpression)
            .replacingOccurrences(of: "\\{\\\\[^}]*\\}", with: "", options: .regularExpression)
    }
}
