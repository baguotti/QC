import Foundation
import CoreMedia

public enum QCUtilities: Sendable {
    
    /// Supported video file extensions recognized across QCpie
    public static let supportedVideoExtensions: Set<String> = [
        "mp4", "mov", "m4v", "mkv", "avi", "prores"
    ]
    
    /// Checks if a given file URL has a supported video extension
    public static func isSupportedVideo(url: URL) -> Bool {
        supportedVideoExtensions.contains(url.pathExtension.lowercased())
    }
    
    /// Robust URL equality comparison that handles path standardization and symlinks
    @inline(__always)
    public static func isSameURL(_ lhs: URL?, _ rhs: URL?) -> Bool {
        guard let lhs = lhs, let rhs = rhs else { return lhs == nil && rhs == nil }
        if lhs == rhs { return true }
        return lhs.standardizedFileURL.path == rhs.standardizedFileURL.path
    }
    
    /// Greatest common divisor for rational aspect ratio calculations
    public static func gcd(_ a: Int, _ b: Int) -> Int {
        var x = abs(a)
        var y = abs(b)
        while y != 0 {
            let temp = y
            y = x % y
            x = temp
        }
        return x == 0 ? 1 : x
    }
    
    /// Converts a 32-bit FourCC integer into a human-readable 4-character string
    public static func fourCCToString(_ fourCC: FourCharCode) -> String {
        let bytes: [UInt8] = [
            UInt8((fourCC >> 24) & 0xff),
            UInt8((fourCC >> 16) & 0xff),
            UInt8((fourCC >> 8) & 0xff),
            UInt8(fourCC & 0xff)
        ]
        return String(bytes: bytes, encoding: .ascii)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
    }
    
    /// Escapes a string for CSV formatting according to RFC 4180
    public static func escapeCSV(_ str: String) -> String {
        if str.contains(",") || str.contains("\"") || str.contains("\n") || str.contains("\r") {
            let escaped = str.replacingOccurrences(of: "\"", with: "\"\"")
            return "\"\(escaped)\""
        }
        return str
    }
    
    /// Escapes a string for TSV formatting (tabs and newlines replaced/escaped)
    public static func escapeTSV(_ str: String) -> String {
        var s = str.replacingOccurrences(of: "\t", with: " ")
        s = s.replacingOccurrences(of: "\r\n", with: " ")
        s = s.replacingOccurrences(of: "\n", with: " ")
        s = s.replacingOccurrences(of: "\r", with: " ")
        return s
    }
}

@inline(__always)
public func isSameURL(_ lhs: URL?, _ rhs: URL?) -> Bool {
    QCUtilities.isSameURL(lhs, rhs)
}
