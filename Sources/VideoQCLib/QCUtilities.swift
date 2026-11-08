import Foundation
import CoreMedia

/// Video plays through the full pipeline; images are a single still; audio plays without a picture.
public enum MediaKind: Sendable {
    case video, image, audio
}

public enum QCUtilities: Sendable {
    /// The file's size read from disk now. `URL.resourceValues` caches per URL object, and the app keeps its URLs (queue,
    /// Inspect): a file re-exported under the same name kept reporting its old size.
    public static func fileSize(of url: URL) -> Int64? {
        ((try? FileManager.default.attributesOfItem(atPath: url.path))?[.size] as? NSNumber)?.int64Value
    }

    
    public static let supportedVideoExtensions: Set<String> = [
        "mp4", "mov", "m4v", "mkv", "avi", "prores", "mxf"
    ]
    public static let supportedImageExtensions: Set<String> = [
        "png", "jpg", "jpeg", "tif", "tiff", "heic", "heif", "gif", "bmp", "webp", "psd", "exr"
    ]
    public static let supportedAudioExtensions: Set<String> = [
        "wav", "aif", "aiff", "mp3", "m4a", "aac", "flac", "caf"
    ]
    
    /// nil for files the Player can't open.
    public static func mediaKind(of url: URL) -> MediaKind? {
        let ext = url.pathExtension.lowercased()
        if supportedVideoExtensions.contains(ext) { return .video }
        if supportedImageExtensions.contains(ext) { return .image }
        if supportedAudioExtensions.contains(ext) { return .audio }
        return nil
    }
    
    /// A frame rate as people write it: "25", "23.976", "29.97", "59.94" (`%.3g` rounded 29.97 to "30").
    public static func formatFPS(_ fps: Double) -> String {
        guard fps.isFinite else { return "--" }
        var text = String(format: "%.3f", fps)
        while text.hasSuffix("0") { text.removeLast() }
        if text.hasSuffix(".") { text.removeLast() }
        return text
    }

    public static func isSupportedMedia(url: URL) -> Bool {
        // "._clip.mov": AppleDouble metadata that exFAT / SMB volumes keep beside every file, never media.
        !url.lastPathComponent.hasPrefix("._") && mediaKind(of: url) != nil
    }
    
    /// `path` is `folder` or inside it. A plain `hasPrefix` took "/Jobs/Job10/a.mov" as inside "/Jobs/Job1".
    public static func isPath(_ path: String, inside folder: String) -> Bool {
        if folder == "/" { return path.hasPrefix("/") }
        let base = folder.hasSuffix("/") ? String(folder.dropLast()) : folder
        return path == base || path.hasPrefix(base + "/")
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
        // Printable ASCII only: a zero or garbage code ("\0\0\0\0") read as an invisible, non-empty name, so callers'
        // "unknown codec" fallbacks never showed.
        guard bytes.allSatisfy({ (0x20...0x7E).contains($0) }) else { return "" }
        return String(decoding: bytes, as: UTF8.self).trimmingCharacters(in: .whitespaces)
    }
    
    /// Escapes a string for CSV formatting according to RFC 4180
    public static func escapeCSV(_ str: String) -> String {
        // Scalars, not Characters: "\r\n" is one Character in Swift, so contains("\n") missed Windows line breaks and the
        // field was left unquoted, splitting the row.
        if str.unicodeScalars.contains(where: { $0 == "," || $0 == "\"" || $0 == "\n" || $0 == "\r" }) {
            let escaped = str.replacingOccurrences(of: "\"", with: "\"\"")
            return "\"\(escaped)\""
        }
        return str
    }
    
    /// Escapes a string for TSV formatting (tabs and newlines replaced/escaped)
    /// Text from file names and paths placed in an HTML report (element content and quoted attributes).
    public static func escapeHTML(_ str: String) -> String {
        str.replacingOccurrences(of: "&", with: "&amp;").replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;").replacingOccurrences(of: "\"", with: "&quot;")
            .replacingOccurrences(of: "'", with: "&#39;")
    }

    /// Text placed inside a JavaScript template literal in an HTML <script>: backslashes, backticks, `${` and `</`.
    public static func escapeJSTemplate(_ str: String) -> String {
        str.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "`", with: "\\`")
            .replacingOccurrences(of: "${", with: "\\${").replacingOccurrences(of: "</", with: "<\\/")
    }

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
