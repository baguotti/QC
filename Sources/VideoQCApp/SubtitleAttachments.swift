import Foundation

/// Which .srt belongs to a video: one attached by hand (remembered across launches) or else a same-name
/// sidecar next to it (`clip.srt` for `clip.mov`). Shared by the Specs tab and the player.
enum SubtitleAttachments {
    private static let defaultsKey = "subtitleAttachments"

    /// Manually attached .srt for a video, if any.
    static func manual(for video: URL) -> URL? {
        guard let map = UserDefaults.standard.dictionary(forKey: defaultsKey) as? [String: String],
              let path = map[video.standardizedFileURL.path] else { return nil }
        return URL(fileURLWithPath: path)
    }

    /// Attaches (or with nil, detaches) an .srt to a video.
    static func setManual(_ srt: URL?, for video: URL) {
        var map = (UserDefaults.standard.dictionary(forKey: defaultsKey) as? [String: String]) ?? [:]
        map[video.standardizedFileURL.path] = srt?.standardizedFileURL.path
        UserDefaults.standard.set(map, forKey: defaultsKey)
    }

    /// The .srt next to the video with the same name, ignoring case: `clip.srt`, then `clip.mov.srt`, then a language
    /// suffix such as `clip.en.srt` (disk access: call off the main thread).
    static func sidecar(for video: URL) -> URL? {
        let folder = video.deletingLastPathComponent()
        guard let names = try? FileManager.default.contentsOfDirectory(atPath: folder.path) else { return nil }
        let base = video.deletingPathExtension().lastPathComponent.lowercased()
        let full = video.lastPathComponent.lowercased()
        let srts = names.filter { $0.lowercased().hasSuffix(".srt") }.sorted()
        let match = srts.first { $0.lowercased() == base + ".srt" }
            ?? srts.first { $0.lowercased() == full + ".srt" }
            ?? srts.first { name in
                let stem = (name as NSString).deletingPathExtension.lowercased()
                return stem.hasPrefix(base + ".") && !stem.dropFirst(base.count + 1).contains(".")
            }
        return match.map { folder.appendingPathComponent($0) }
    }

    /// The .srt to use for a video: an existing manual attachment, else the sidecar (disk access: off the main thread).
    static func resolve(for video: URL) -> URL? {
        if let attached = manual(for: video), FileManager.default.fileExists(atPath: attached.path) {
            return attached
        }
        return sidecar(for: video)
    }
}
