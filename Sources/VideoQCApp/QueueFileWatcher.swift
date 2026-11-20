import Foundation
import CoreServices
import VideoQCLib

/// Notices queued files deleted, moved or renamed in Finder (or anywhere else) and reports them, so the queue drops them
/// without a Refresh. One FSEvents stream over the queued files' own folders, delivered on a background queue and
/// coalesced for 0.5 s; only the files of a changed folder are checked on disk, never on the main thread.
/// - A file found missing is checked again after `grace` before it's reported: an export over the same path can delete
///   the old file a moment before writing the new one.
/// - A watched folder that is itself renamed or trashed sends no event (FSEvents' WatchRoot flag would, but it opens
///   every parent folder up front, which hung on a privacy prompt): `verifyFolders()` covers it when QCpie comes back
///   to the front.
/// - Files on a volume that went away (an ejected drive) are kept: they come back when it is mounted again.
final class QueueFileWatcher: @unchecked Sendable {
    private let queue = DispatchQueue(label: "com.studio.qcpie.queue-watcher", qos: .utility)
    private let grace: TimeInterval
    /// Read and written on `queue` only.
    private var stream: FSEventStreamRef?
    private var roots: [String] = []
    private var filesByFolder: [String: [String]] = [:]
    private var onMissing: (@MainActor ([URL]) -> Void)?

    init(grace: TimeInterval = 1.5) {
        self.grace = grace
    }

    deinit {
        queue.sync { if let stream { Self.close(stream) } }
    }

    /// Watches `urls` from now on (replacing the previous list); `onMissing` gets the ones that disappear.
    func watch(_ urls: [URL], onMissing: @escaping @MainActor ([URL]) -> Void) {
        let paths = urls.map { $0.standardizedFileURL.path }
        queue.async { [self] in
            self.onMissing = onMissing
            filesByFolder = Dictionary(grouping: paths) { ($0 as NSString).deletingLastPathComponent }
            let newRoots = Self.topFolders(of: Array(filesByFolder.keys))
            guard newRoots != roots else { return }
            roots = newRoots
            if let stream { Self.close(stream); self.stream = nil }
            guard !newRoots.isEmpty else { return }
            stream = open(newRoots)
        }
    }

    /// Checks the files of any queued folder that no longer exists (renamed, moved or trashed as a whole).
    func verifyFolders() {
        queue.async { [self] in
            let gone = filesByFolder.keys.filter { !FileManager.default.fileExists(atPath: $0) }
            if !gone.isEmpty { check(folders: gone) }
        }
    }

    // MARK: - Stream

    private func open(_ paths: [String]) -> FSEventStreamRef? {
        var context = FSEventStreamContext(version: 0, info: Unmanaged.passUnretained(self).toOpaque(),
                                           retain: nil, release: nil, copyDescription: nil)
        let callback: FSEventStreamCallback = { _, info, _, eventPaths, _, _ in
            guard let info else { return }
            let paths = Unmanaged<CFArray>.fromOpaque(eventPaths).takeUnretainedValue() as? [String] ?? []
            // FSEvents reports real paths: /var and /tmp come back as /private/var and /private/tmp.
            let folders = paths.map { $0.hasPrefix("/private/") ? [$0, String($0.dropFirst(8))] : [$0] }.joined()
            Unmanaged<QueueFileWatcher>.fromOpaque(info).takeUnretainedValue().check(folders: Array(folders))
        }
        let flags = FSEventStreamCreateFlags(kFSEventStreamCreateFlagUseCFTypes)
        guard let stream = FSEventStreamCreate(nil, callback, &context, paths as CFArray,
                                               FSEventStreamEventId(kFSEventStreamEventIdSinceNow), 0.5, flags) else {
            Log.app.error("Queue watcher: couldn't watch \(paths.count) folder(s)")
            return nil
        }
        FSEventStreamSetDispatchQueue(stream, queue)
        guard FSEventStreamStart(stream) else {
            Log.app.error("Queue watcher: couldn't start watching \(paths.count) folder(s)")
            FSEventStreamInvalidate(stream)
            FSEventStreamRelease(stream)
            return nil
        }
        return stream
    }

    private static func close(_ stream: FSEventStreamRef) {
        FSEventStreamStop(stream)
        FSEventStreamInvalidate(stream)
        FSEventStreamRelease(stream)
    }

    /// Runs on `queue`. Files of the queued folders at or under `changed` that are missing, checked again after `grace`.
    private func check(folders changed: [String]) {
        let candidates = missingFiles(under: changed)
        guard !candidates.isEmpty else { return }
        queue.asyncAfter(deadline: .now() + grace) { [self] in
            let queued = Set(filesByFolder.values.joined())
            let missing = candidates.filter { queued.contains($0) && !FileManager.default.fileExists(atPath: $0) }
            guard !missing.isEmpty, let onMissing else { return }
            let gone = Set(missing)
            for folder in Set(missing.map { ($0 as NSString).deletingLastPathComponent }) {
                filesByFolder[folder]?.removeAll { gone.contains($0) }
            }
            Log.app.notice("Queue: \(missing.count) file(s) deleted or moved on disk, removed from the queue")
            let urls = missing.map { URL(fileURLWithPath: $0) }
            Task { @MainActor in onMissing(urls) }
        }
    }

    private func missingFiles(under changed: [String]) -> [String] {
        var missing: [String] = []
        for (folder, files) in filesByFolder where changed.contains(where: { QCUtilities.isPath(folder, inside: $0) }) {
            guard Self.volumeIsMounted(folder) else { continue }
            missing += files.filter { !FileManager.default.fileExists(atPath: $0) }
        }
        return missing
    }

    // MARK: - Paths

    /// `folders` without any that sit inside another (the stream watches folders recursively).
    static func topFolders(of folders: [String]) -> [String] {
        var top: [String] = []
        for folder in Set(folders).sorted() where !top.contains(where: { QCUtilities.isPath(folder, inside: $0) }) {
            top.append(folder)
        }
        return top
    }

    /// False for a path on a volume under /Volumes that is no longer mounted.
    static func volumeIsMounted(_ path: String) -> Bool {
        let parts = path.split(separator: "/", omittingEmptySubsequences: true)
        guard parts.count >= 2, parts[0] == "Volumes" else { return true }
        return FileManager.default.fileExists(atPath: "/Volumes/\(parts[1])")
    }
}
