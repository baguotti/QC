import Foundation

/// Numbered stills in one folder (`shot_0001.png` … `shot_0240.png`) read as one clip.
/// Timeline frame 0 is the first number; gaps are kept as missing frames, not closed up.
public struct ImageSequence: Sendable, Hashable {
    public let directory: URL
    public let prefix: String
    public let ext: String
    public let padding: Int
    /// Existing frames, sorted by number.
    public let frameURLs: [URL]
    public let frameNumbers: [Int]
    private let urlByNumber: [Int: URL]

    init(directory: URL, prefix: String, ext: String, padding: Int, frames: [(number: Int, url: URL)]) {
        let sorted = frames.sorted { $0.number < $1.number }
        self.directory = directory
        self.prefix = prefix
        self.ext = ext
        self.padding = padding
        self.frameURLs = sorted.map(\.url)
        self.frameNumbers = sorted.map(\.number)
        self.urlByNumber = Dictionary(sorted.map { ($0.number, $0.url) }, uniquingKeysWith: { a, _ in a })
    }

    /// Identifies the sequence across launches (for the remembered sequence / single-images choice and frame rate).
    public var key: String { directory.path + "/" + prefix + "#." + ext.lowercased() }
    public var firstURL: URL { frameURLs[0] }
    public var firstNumber: Int { frameNumbers[0] }
    public var lastNumber: Int { frameNumbers[frameNumbers.count - 1] }
    /// Timeline length in frames, gaps included.
    public var length: Int { lastNumber - firstNumber + 1 }
    public var missingCount: Int { length - frameURLs.count }

    /// e.g. `shot_[0001-0240].png`
    public var displayName: String {
        func pad(_ n: Int) -> String {
            let s = String(n)
            return s.count >= padding ? s : String(repeating: "0", count: padding - s.count) + s
        }
        return "\(prefix)[\(pad(firstNumber))-\(pad(lastNumber))].\(ext)"
    }

    /// File for a timeline frame (0-based), nil where the sequence has a gap.
    public func url(forFrame index: Int) -> URL? {
        urlByNumber[firstNumber + index]
    }

    public static func == (lhs: ImageSequence, rhs: ImageSequence) -> Bool {
        lhs.key == rhs.key && lhs.frameNumbers == rhs.frameNumbers
    }

    public func hash(into hasher: inout Hasher) {
        hasher.combine(key)
        hasher.combine(frameNumbers.count)
    }
}

public enum ImageSequenceDetector {
    /// Fewer numbered stills than this are treated as separate images.
    public static let minimumFrames = 6

    /// Groups numbered stills by folder, prefix and extension. File names only: no disk access.
    public static func detect(_ urls: [URL]) -> [ImageSequence] {
        struct GroupKey: Hashable { let dir: String; let prefix: String; let ext: String }
        var groups: [GroupKey: (dir: URL, ext: String, padding: Int, frames: [(number: Int, url: URL)])] = [:]
        for url in urls where QCUtilities.supportedImageExtensions.contains(url.pathExtension.lowercased()) {
            let base = url.deletingPathExtension().lastPathComponent
            let digits = base.reversed().prefix { $0.isASCII && $0.isNumber }
            guard !digits.isEmpty, digits.count <= 9, let number = Int(String(digits.reversed())) else { continue }
            let prefix = String(base.dropLast(digits.count))
            let dir = url.deletingLastPathComponent()
            let key = GroupKey(dir: dir.path, prefix: prefix, ext: url.pathExtension.lowercased())
            var entry = groups[key] ?? (dir, url.pathExtension, digits.count, [])
            entry.padding = min(entry.padding, digits.count)
            entry.frames.append((number, url))
            groups[key] = entry
        }
        return groups.compactMap { key, entry in
            guard entry.frames.count >= minimumFrames else { return nil }
            let numbers = entry.frames.map(\.number)
            // Sparse numbering (e.g. camera photos IMG_4012, IMG_4815…) is not a sequence.
            guard let lo = numbers.min(), let hi = numbers.max(), hi - lo + 1 <= entry.frames.count * 2 else { return nil }
            return ImageSequence(directory: entry.dir, prefix: key.prefix, ext: entry.ext, padding: entry.padding, frames: entry.frames)
        }
    }
}

/// Detected sequences plus the user's per-sequence choices (sequence vs single images, frame rate). Thread-safe.
public final class ImageSequenceStore: @unchecked Sendable {
    public static let shared = ImageSequenceStore()
    public static let defaultFPSKey = "prefSequenceFPS"
    private static let individualKey = "imageSequenceIndividual"
    private static let fpsKey = "imageSequenceFPS"
    
    private let lock = NSLock()
    private var byFirstPath: [String: ImageSequence] = [:]
    private var keyByMemberPath: [String: String] = [:]
    private var byKey: [String: ImageSequence] = [:]
    /// Keys read as single images (cached in memory: row views query the store on every render).
    private var individual = Set(UserDefaults.standard.stringArray(forKey: ImageSequenceStore.individualKey) ?? [])
    
    /// Registers the sequences in `urls` and drops the frames of those read as a sequence (keeping each first frame).
    public func collapse(_ urls: [URL]) -> [URL] {
        let sequences = ImageSequenceDetector.detect(urls)
        guard !sequences.isEmpty else { return urls }
        var hidden = Set<String>()
        lock.lock()
        for seq in sequences {
            byKey[seq.key] = seq
            byFirstPath[seq.firstURL.path] = seq
            for url in seq.frameURLs { keyByMemberPath[url.path] = seq.key }
            if !individual.contains(seq.key) {
                hidden.formUnion(seq.frameURLs.dropFirst().map(\.path))
            }
        }
        lock.unlock()
        return urls.filter { !hidden.contains($0.path) }
    }
    
    /// The sequence `url` starts, when it is read as a sequence.
    public func sequence(for url: URL) -> ImageSequence? {
        lock.lock()
        defer { lock.unlock() }
        guard let seq = byFirstPath[url.path], !individual.contains(seq.key) else { return nil }
        return seq
    }
    
    /// The sequence a frame belongs to, whichever way it is read.
    public func sequence(containing url: URL) -> ImageSequence? {
        lock.lock()
        defer { lock.unlock() }
        return keyByMemberPath[url.path].flatMap { byKey[$0] }
    }
    
    public func setReadAsSequence(_ asSequence: Bool, for seq: ImageSequence) {
        lock.lock()
        if asSequence { individual.remove(seq.key) } else { individual.insert(seq.key) }
        let keys = Array(individual)
        lock.unlock()
        UserDefaults.standard.set(keys, forKey: Self.individualKey)
    }
    
    public func fps(for seq: ImageSequence) -> Double {
        if let stored = (UserDefaults.standard.dictionary(forKey: Self.fpsKey) as? [String: Double])?[seq.key], stored > 0 { return stored }
        let fallback = UserDefaults.standard.double(forKey: Self.defaultFPSKey)
        return fallback > 0 ? fallback : 25
    }
    
    public func setFPS(_ fps: Double, for seq: ImageSequence) {
        var map = (UserDefaults.standard.dictionary(forKey: Self.fpsKey) as? [String: Double]) ?? [:]
        map[seq.key] = fps
        UserDefaults.standard.set(map, forKey: Self.fpsKey)
    }
}
