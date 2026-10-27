import Foundation

/// Compares subtitle files that should carry the same captions (e.g. the 16x9 / 9x16 / 1x1 crops of one video).
public enum SubtitleCrossCheck {
    public struct Options: Sendable, Equatable {
        /// Line breaks and repeated spaces don't count (crops re-wrap lines legitimately).
        public var ignoreLineBreaks: Bool
        /// `<font>`, `<i>`, positioning codes etc. don't count.
        public var ignoreFormatting: Bool
        public var ignoreCase: Bool
        /// In / out times may differ by up to this much (seconds) before it is reported. Default: exact (half a
        /// millisecond absorbs float rounding; SRT times are whole milliseconds).
        public var timingTolerance: Double

        public init(ignoreLineBreaks: Bool = true, ignoreFormatting: Bool = true, ignoreCase: Bool = false, timingTolerance: Double = 0.0005) {
            self.ignoreLineBreaks = ignoreLineBreaks
            self.ignoreFormatting = ignoreFormatting
            self.ignoreCase = ignoreCase
            self.timingTolerance = timingTolerance
        }
    }

    public enum Kind: String, Sendable {
        case text = "Wording"
        case timing = "Timing"
        case missing = "Missing line"
        case extra = "Extra line"
    }

    public struct Difference: Sendable, Equatable, Identifiable {
        public let id: Int
        public let kind: Kind
        /// Line numbers (1-based) in the reference / compared file, when the line exists there.
        public let referenceLine: Int?
        public let otherLine: Int?
        public let referenceCue: SubtitleCue?
        public let otherCue: SubtitleCue?
        /// Where to jump to in the compared file (start of its line, or of the reference line if it is missing).
        public var time: Double { otherCue?.start ?? referenceCue?.start ?? 0 }
    }

    /// Normalized text used for comparison under `options`.
    public static func comparableText(_ raw: String, options: Options) -> String {
        var text = options.ignoreFormatting ? SubtitleParser.stripTags(raw) : raw
        if options.ignoreLineBreaks {
            text = text.components(separatedBy: .whitespacesAndNewlines).filter { !$0.isEmpty }.joined(separator: " ")
        }
        text = text.trimmingCharacters(in: .whitespacesAndNewlines)
        return options.ignoreCase ? text.lowercased() : text
    }

    /// Pairs lines by timing (overlap, or starts within a second) so one extra / missing line doesn't shift every
    /// later comparison, then reports wording, timing, missing and extra lines.
    public static func compare(reference: [SubtitleCue], other: [SubtitleCue], options: Options = Options()) -> [Difference] {
        var result: [Difference] = []
        var i = 0
        var j = 0
        func add(_ kind: Kind, _ ri: Int?, _ oj: Int?) {
            result.append(Difference(
                id: result.count, kind: kind,
                referenceLine: ri.map { $0 + 1 }, otherLine: oj.map { $0 + 1 },
                referenceCue: ri.map { reference[$0] }, otherCue: oj.map { other[$0] }
            ))
        }
        while i < reference.count || j < other.count {
            guard i < reference.count else { add(.extra, nil, j); j += 1; continue }
            guard j < other.count else { add(.missing, i, nil); i += 1; continue }
            let r = reference[i]
            let o = other[j]
            func overlaps(_ a: SubtitleCue, _ b: SubtitleCue) -> Bool { min(a.end, b.end) - max(a.start, b.start) > 0 }
            // Near-miss pairing (no overlap, starts within 1 s) only when neither line has a better partner next.
            let nearMiss = abs(r.start - o.start) <= 1.0
                && !(j + 1 < other.count && overlaps(r, other[j + 1]))
                && !(i + 1 < reference.count && overlaps(reference[i + 1], o))
            if overlaps(r, o) || nearMiss {
                if comparableText(r.text, options: options) != comparableText(o.text, options: options) {
                    add(.text, i, j)
                } else if abs(r.start - o.start) > options.timingTolerance || abs(r.end - o.end) > options.timingTolerance {
                    add(.timing, i, j)
                }
                i += 1
                j += 1
            } else if r.start < o.start {
                add(.missing, i, nil)
                i += 1
            } else {
                add(.extra, nil, j)
                j += 1
            }
        }
        return result
    }
}
