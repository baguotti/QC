import Foundation
import os

/// App-wide logging: unified logging (`log stream --predicate 'subsystem == "com.studio.qcpie"'`) plus, for notices
/// and errors, a small rotating file in Application Support/QCpie/Logs that can be collected from any Mac.
///
/// Never log from per-frame paths (display link, scrub, time observer): only events such as loads, scans, network
/// calls, retries and failed saves.
public struct Log: Sendable {
    public static let app = Log("app")
    public static let player = Log("player")
    public static let scan = Log("scan")
    public static let inspect = Log("inspect")
    public static let upload = Log("upload")
    public static let download = Log("download")
    public static let frameio = Log("frameio")
    public static let plan = Log("plan")
    public static let google = Log("google")
    public static let sync = Log("sync")
    public static let notes = Log("notes")
    public static let update = Log("update")

    public static let subsystem = Bundle.main.bundleIdentifier ?? "com.studio.qcpie"

    /// Folder holding `QCpie.log` (current) and `QCpie.1.log`, `QCpie.2.log` (older).
    public static var folder: URL { LogFile.shared.folder }
    public static var currentFile: URL { LogFile.shared.current }

    private let logger: Logger
    private let category: String

    private init(_ category: String) {
        self.category = category
        logger = Logger(subsystem: Log.subsystem, category: category)
    }

    /// Unified logging only; the message isn't built unless someone is streaming debug logs.
    public func debug(_ message: @autoclosure () -> String) {
        guard logger.isEnabled(type: .debug) else { return }
        let text = message()
        logger.debug("\(text, privacy: .public)")
    }

    /// Unified logging only.
    public func info(_ message: String) {
        logger.info("\(message, privacy: .public)")
    }

    /// Worth keeping: unified logging and the log file.
    public func notice(_ message: String) {
        logger.notice("\(message, privacy: .public)")
        LogFile.shared.write("NOTE", category, message)
    }

    public func error(_ message: String) {
        logger.error("\(message, privacy: .public)")
        LogFile.shared.write("ERROR", category, message)
    }

    public func error(_ message: String, _ error: any Error) {
        self.error("\(message): \(Log.describe(error))")
    }

    /// `try?` that leaves a trace: runs `body`, logs a failure as an error and returns nil.
    @discardableResult
    public func attempt<T>(_ what: @autoclosure () -> String, _ body: () throws -> T) -> T? {
        do { return try body() } catch {
            if !Log.isCancellation(error) { self.error(what(), error) }
            return nil
        }
    }

    @discardableResult
    public func attempt<T>(_ what: @autoclosure () -> String, isolation: isolated (any Actor)? = #isolation,
                           _ body: () async throws -> T) async -> T? {
        do { return try await body() } catch {
            if !Log.isCancellation(error) { self.error(what(), error) }
            return nil
        }
    }

    /// A task or request cancelled on purpose isn't a failure worth logging.
    public static func isCancellation(_ error: any Error) -> Bool {
        if error is CancellationError { return true }
        if let url = error as? URLError, url.code == .cancelled { return true }
        let ns = error as NSError
        return ns.domain == NSURLErrorDomain && ns.code == NSURLErrorCancelled
    }

    public static func describe(_ error: any Error) -> String {
        let ns = error as NSError
        return "\(ns.localizedDescription) [\(ns.domain) \(ns.code)]"
    }
}

/// Appends lines on its own queue; rotates at 1 MB, keeping three files. Opened on first write, never at launch.
final class LogFile: @unchecked Sendable {
    static let shared = LogFile()

    let folder: URL
    let current: URL
    private let queue = DispatchQueue(label: "QCpie.LogFile", qos: .utility)
    private let maxBytes: UInt64 = 1_000_000
    private let keep = 3
    private var handle: FileHandle?
    private var size: UInt64 = 0
    private let formatter: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyy-MM-dd HH:mm:ss.SSS"
        return f
    }()

    private init() {
        folder = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("QCpie/Logs", isDirectory: true)
        current = folder.appendingPathComponent("QCpie.log")
    }

    /// Only the app bundle writes the file: test runs and the bare debug binary would fill it with fixture paths.
    private let enabled = Bundle.main.bundleIdentifier == "com.studio.qcpie"

    func write(_ level: String, _ category: String, _ message: String) {
        guard enabled else { return }
        let date = Date()
        queue.async { [self] in
            let line = "\(formatter.string(from: date)) \(level) [\(category)] \(message)\n"
            guard let data = line.data(using: .utf8) else { return }
            if handle == nil { open() }
            guard let handle else { return }
            handle.write(data)
            size += UInt64(data.count)
            if size >= maxBytes { rotate() }
        }
    }

    private func open() {
        let fm = FileManager.default
        try? fm.createDirectory(at: folder, withIntermediateDirectories: true)
        if !fm.fileExists(atPath: current.path) { fm.createFile(atPath: current.path, contents: nil) }
        handle = try? FileHandle(forWritingTo: current)
        size = (try? handle?.seekToEnd()) ?? 0
    }

    private func rotate() {
        try? handle?.close()
        handle = nil
        let fm = FileManager.default
        for index in stride(from: keep - 1, through: 1, by: -1) {
            let from = index == 1 ? current : folder.appendingPathComponent("QCpie.\(index - 1).log")
            let to = folder.appendingPathComponent("QCpie.\(index).log")
            try? fm.removeItem(at: to)
            try? fm.moveItem(at: from, to: to)
        }
        open()
    }
}

/// Saved state on disk (JSON caches, resume files, tokens) without silent failures: a failed write, or a file that
/// exists but can't be read or decoded, is logged. A missing file is normal and isn't.
public enum JSONFile {
    /// Encodes and writes atomically, creating the folder first. Returns false (logged) on failure.
    @discardableResult
    public static func save<T: Encodable>(_ value: T, to url: URL, encoder: JSONEncoder = JSONEncoder(), log: Log) -> Bool {
        do {
            return write(try encoder.encode(value), to: url, log: log)
        } catch {
            log.error("Encoding \(url.lastPathComponent) failed", error)
            return false
        }
    }

    /// Writes atomically, creating the folder first. Returns false (logged) on failure.
    @discardableResult
    public static func write(_ data: Data, to url: URL, log: Log) -> Bool {
        do {
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try data.write(to: url, options: .atomic)
            return true
        } catch {
            log.error("Saving \(url.path) failed", error)
            return false
        }
    }

    /// nil when the file doesn't exist (silent) or can't be read or decoded (logged).
    public static func load<T: Decodable>(_ type: T.Type, from url: URL, decoder: JSONDecoder = JSONDecoder(), log: Log) -> T? {
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }
        do {
            return try decoder.decode(T.self, from: try Data(contentsOf: url))
        } catch {
            log.error("Reading \(url.path) failed", error)
            return nil
        }
    }

    /// Removes the file if it's there; a failure other than "not found" is logged.
    public static func remove(_ url: URL, log: Log) {
        do { try FileManager.default.removeItem(at: url) } catch CocoaError.fileNoSuchFile {
        } catch {
            log.error("Removing \(url.path) failed", error)
        }
    }
}
