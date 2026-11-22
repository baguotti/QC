import Foundation

/// A limit set on an Inspect column (right-click its header): files whose value misses it are flagged.
public struct ColumnTarget: Sendable, Equatable {
    public enum Comparison: String, CaseIterable, Sendable {
        case atMost = "≤", atLeast = "≥", equal = "="
    }

    public enum Unit: String, CaseIterable, Sendable {
        case megabytes = "MB", gigabytes = "GB", megabitsPerSecond = "Mbps", fps = "fps", duration = ""

        /// Decimal, as Inspect shows sizes and bit rates.
        var scale: Double {
            switch self {
            case .megabytes: return 1e6
            case .gigabytes: return 1e9
            case .megabitsPerSecond: return 1e6
            case .fps, .duration: return 1
            }
        }
    }

    /// The columns a target can be set on.
    public static let columns: [SpecsSortColumn] = [.timecode, .fps, .size, .bitrate]

    public let column: SpecsSortColumn
    public let comparison: Comparison
    /// In base units: bytes, bits per second, frames per second or seconds.
    public let value: Double
    /// Duration only: frames after `value`'s seconds (HH:MM:SS:FF), counted at each file's own rate.
    public let frames: Int
    // Durations compare frame counts as the Timecode column shows them (frames at the rounded rate, non-drop): a
    // 900-frame 29.97 spot reads 00:00:30:00 there, though it runs 30.03 s, and must meet "exactly 30 s".
    /// What was typed, with its unit, for the header and tooltips ("5 MB", "00:00:30:00").
    public let valueText: String

    public static func comparisons(for column: SpecsSortColumn) -> [Comparison] {
        column == .fps || column == .timecode ? Comparison.allCases : [.atMost, .atLeast]
    }

    public static func units(for column: SpecsSortColumn) -> [Unit] {
        switch column {
        case .size: return [.megabytes, .gigabytes]
        case .bitrate: return [.megabitsPerSecond]
        case .fps: return [.fps]
        default: return [.duration]
        }
    }

    /// Nil when `text` isn't a positive number (or, for a duration, seconds / MM:SS / HH:MM:SS / HH:MM:SS:FF).
    public init?(column: SpecsSortColumn, comparison: Comparison, text: String, unit: Unit) {
        let trimmed = text.trimmingCharacters(in: .whitespaces).replacingOccurrences(of: ",", with: ".")
        guard Self.columns.contains(column), Self.comparisons(for: column).contains(comparison) else { return nil }
        self.column = column
        self.comparison = comparison
        if column == .timecode {
            let parts = trimmed.split(separator: ":", omittingEmptySubsequences: false).map { Double($0) }
            guard (1...4).contains(parts.count), parts.allSatisfy({ ($0 ?? -1) >= 0 }) else { return nil }
            let numbers = parts.map { $0! }
            let clock = numbers.count == 4 ? Array(numbers.prefix(3)) : numbers
            // A clock is whole numbers, minutes and seconds under 60 ("1.5:00" and "1:75" are typos).
            guard numbers.count == 1 || (numbers.allSatisfy { $0 == $0.rounded() && $0 < 1e6 }
                                         && clock.dropFirst().allSatisfy { $0 < 60 }) else { return nil }
            value = clock.reduce(0) { $0 * 60 + $1 }
            frames = numbers.count == 4 ? Int(numbers[3]) : 0
            guard value > 0 || frames > 0 else { return nil }
            valueText = numbers.count == 1 ? "\(Self.trim(value)) s" : trimmed
        } else {
            guard let number = Double(trimmed), number > 0, (number * unit.scale).isFinite else { return nil }
            value = number * unit.scale
            frames = 0
            valueText = "\(Self.trim(number)) \(unit.rawValue)"
        }
    }

    /// "≤ 5 MB"
    public var label: String { "\(comparison.rawValue) \(valueText)" }

    /// The file's value in base units; nil when it has none (stills have no duration, frame rate or bit rate).
    public func measured(_ asset: DeliverableAsset) -> Double? {
        switch column {
        case .size: return asset.fileSizeBytes > 0 ? Double(asset.fileSizeBytes) : nil
        case .bitrate: return asset.overallBitsPerSecond
        case .fps: return asset.fps > 0 && asset.fps.isFinite ? asset.fps : nil
        default: return asset.durationSeconds > 0 && asset.durationSeconds.isFinite && asset.totalFrames > 0 ? Double(asset.totalFrames) : nil
        }
    }

    /// The whole frames per second a duration's timecode counts at (as `TimecodeFormatter`, 25 without a rate).
    static func timecodeRate(_ fps: Double) -> Double {
        (fps > 0 && fps.isFinite ? min(max(1, fps), 1000) : 25).rounded()
    }

    /// True when the file misses the target. Files without the value aren't flagged.
    public func flags(_ asset: DeliverableAsset) -> Bool {
        guard let measured = measured(asset) else { return false }
        var target = value
        var tolerance = 0.0
        if column == .timecode {
            target = (value * Self.timecodeRate(asset.fps)).rounded() + Double(frames)   // in frames, exact
        } else if column == .fps {
            tolerance = 0.0051   // as shown: 23.976 is 23.98
        }
        switch comparison {
        case .atMost: return measured > target + tolerance
        case .atLeast: return measured < target - tolerance
        case .equal: return abs(measured - target) > tolerance
        }
    }

    private static func trim(_ number: Double) -> String {
        number == number.rounded() && abs(number) < 1e15 ? String(Int(number)) : String(format: "%.10g", number)
    }
}
