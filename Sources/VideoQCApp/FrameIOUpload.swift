import Foundation
import UniformTypeIdentifiers
import VideoQCLib

/// Files dropped on the Upload tab and their upload to a Frame.io folder. Shared so uploads keep running when switching
/// tabs; observed only by the Upload tab. Progress is published at 5 Hz from a lock-protected box, never per network
/// callback. Network and file reads run off the main thread; each part is read from disk just before it is sent (at most
/// 4 parts in memory). Files are not memory-mapped: a mapped file on a network volume that drops crashes the app.
@MainActor
final class UploadQueue: ObservableObject {
    static let shared = UploadQueue()

    enum Status: Equatable {
        case queued, uploading, done, skipped, cancelled
        case failed(String)
    }

    /// One queue row: a file, or an image sequence read as one clip (all its frames are uploaded).
    struct Job: Identifiable, Equatable {
        let id = UUID()
        let url: URL
        let files: [URL]
        let fileSizes: [Int64]
        /// Subfolders of the queue's folder that contain the file, recreated on Frame.io when keeping the structure.
        let folders: [String]
        var status: Status = .queued
        var sent: Int64 = 0

        var size: Int64 { fileSizes.reduce(0, +) }
    }

    struct Destination {
        let account: String
        let folder: String
        /// Shown in the log, e.g. "0000 - MISSONI › HEROS + CUTDOWNS".
        let path: String
    }

    /// Upload history, newest run first. Kept in `Application Support/QCpie/FrameIO/upload-log.json` (last 100 runs).
    @Published private(set) var log: [UploadLogRun] = []
    private var currentRunID: UUID?

    private init() {
        Task {
            let loaded = await Task.detached(priority: .utility) { () -> [UploadLogRun] in
                guard let data = try? Data(contentsOf: UploadLogRun.file) else { return [] }
                let decoder = JSONDecoder()
                decoder.dateDecodingStrategy = .iso8601
                return (try? decoder.decode([UploadLogRun].self, from: data)) ?? []
            }.value
            log = loaded + log
        }
    }

    func clearLog() {
        log = []
        saveLog()
    }

    private func saveLog() {
        let runs = Array(log.prefix(100))
        Task.detached(priority: .utility) {
            let encoder = JSONEncoder()
            encoder.dateEncodingStrategy = .iso8601
            guard let data = try? encoder.encode(runs) else { return }
            try? FileManager.default.createDirectory(at: UploadLogRun.file.deletingLastPathComponent(), withIntermediateDirectories: true)
            try? data.write(to: UploadLogRun.file, options: .atomic)
        }
    }

    private func record(_ entry: UploadLogEntry) {
        guard let index = log.firstIndex(where: { $0.id == currentRunID }) else { return }
        log[index].entries.append(entry)
    }

    @Published private(set) var jobs: [Job] = []
    @Published private(set) var isRunning = false
    @Published private(set) var bytesPerSecond: Double = 0
    /// Smoothed speed every 0.2 s over the last 30 s of the run (the speed graph).
    @Published private(set) var speedHistory: [Double] = []
    @Published private(set) var runStarted: Date?
    @Published private(set) var runFinished: Date?
    /// Bytes sent over the network in this run (excludes files already on Frame.io).
    @Published private(set) var transferredBytes: Int64 = 0
    @Published var keepStructure: Bool = UserDefaults.standard.object(forKey: "uploadKeepStructure") as? Bool ?? false {
        didSet { UserDefaults.standard.set(keepStructure, forKey: "uploadKeepStructure") }
    }

    private let progress = UploadProgress()
    private var runTask: Task<Void, Never>?
    private var ticker: Timer?
    private var lastTick: (date: Date, bytes: Int64)?

    /// Selected queue files (paths), Finder style. Empty uploads the whole queue.
    @Published var selection: Set<String> = []
    func selectAll() {
        guard !isRunning else { return }
        selection = Set(jobs.map(\.url.path))
    }

    /// Jobs of the current or last run: the progress summary counts these only.
    @Published private(set) var runIDs: Set<UUID> = []

    private var runJobs: [Job] { jobs.filter { runIDs.contains($0.id) } }
    var runCount: Int { runIDs.count }
    var runFinishedCount: Int { runJobs.filter { $0.status == .done || $0.status == .skipped }.count }
    var totalBytes: Int64 { runJobs.reduce(0) { $0 + $1.size } }
    var sentBytes: Int64 { runJobs.reduce(0) { $0 + ($1.status == .done || $1.status == .skipped ? $1.size : $1.sent) } }

    // MARK: Drag and drop

    /// Pasteboard text identifying queue files dragged onto a Frame.io folder.
    nonisolated static let dragPrefix = "qcpie-upload\n"

    /// What dragging these rows carries: the whole selection when the row is part of it (Finder), else just the row.
    func dragPaths(for paths: [String]) -> [String] {
        guard !paths.isEmpty else { return [] }
        if paths.allSatisfy(selection.contains) { return jobs.map(\.url.path).filter(selection.contains) }
        return paths
    }

    // MARK: Queue

    private var syncToken = 0

    /// Mirrors the app's queue (shared by Play, Inspect and Scan): new rows are added, removed rows dropped, and rows
    /// already uploaded keep their status. File sizes are read off the main thread.
    func sync(with rows: [(url: URL, folders: [String])]) {
        syncToken += 1
        let token = syncToken
        Task {
            let resolved = await Task.detached(priority: .utility) { Self.resolve(rows) }.value
            guard token == syncToken else { return }
            let existing = Dictionary(jobs.map { ($0.url.standardizedFileURL, $0) }, uniquingKeysWith: { a, _ in a })
            var next: [Job] = resolved.map { job in
                guard let old = existing[job.url.standardizedFileURL] else { return job }
                // Jobs of the running upload keep their identity: the upload reports progress by job id.
                if old.files == job.files && old.folders == job.folders || (isRunning && runIDs.contains(old.id)) { return old }
                return job
            }
            let kept = Set(next.map(\.id))
            next += jobs.filter { $0.status == .uploading && !kept.contains($0.id) }
            jobs = next
            selection.formIntersection(next.map(\.url.path))
        }
    }

    nonisolated private static func resolve(_ rows: [(url: URL, folders: [String])]) -> [Job] {
        rows.compactMap { row in
            let files = ImageSequenceStore.shared.sequence(for: row.url)?.frameURLs ?? [row.url]
            let sizes = files.map { Int64((try? $0.resourceValues(forKeys: [.fileSizeKey]))?.fileSize ?? 0) }
            guard sizes.contains(where: { $0 > 0 }) else { return nil }
            return Job(url: row.url, files: files, fileSizes: sizes, folders: row.folders)
        }
    }

    // MARK: Running

    /// Uploads `paths` (files dragged onto a Frame.io folder), else the selected files, else the whole queue, two at a
    /// time. Files already on Frame.io (same name and size) are skipped, so uploading again only sends what's missing.
    func start(to destination: Destination, paths: Set<String>? = nil) {
        guard !isRunning else { return }
        let targets = paths ?? (selection.isEmpty ? Set(jobs.map(\.url.path)) : selection)
        for index in jobs.indices where targets.contains(jobs[index].url.path) {
            jobs[index].status = .queued
            jobs[index].sent = 0
        }
        let work = jobs.filter { $0.status == .queued && targets.contains($0.url.path) }
        guard !work.isEmpty else { return }
        runIDs = Set(work.map(\.id))
        let run = UploadLogRun(id: UUID(), started: Date(), finished: nil, destination: destination.path,
                               keepStructure: keepStructure, entries: [])
        currentRunID = run.id
        log.insert(run, at: 0)
        let destinationPath = destination.path
        isRunning = true
        progress.reset()
        lastTick = nil
        bytesPerSecond = 0
        speedHistory = []
        transferredBytes = 0
        runStarted = Date()
        runFinished = nil
        startTicker()
        let keep = keepStructure
        let folders = FolderResolver(account: destination.account, root: destination.folder)
        let progress = progress
        runTask = Task {
            await withTaskGroup(of: Void.self) { group in
                var next = work.makeIterator()
                func addNext() -> Bool {
                    guard let job = next.next() else { return false }
                    group.addTask { await self.upload(job, keepStructure: keep, folders: folders, destination: destinationPath, progress: progress) }
                    return true
                }
                _ = addNext() && addNext()
                for await _ in group where !Task.isCancelled { _ = addNext() }
            }
            finish()
        }
    }

    func cancel() {
        runTask?.cancel()
    }

    private func finish() {
        for index in jobs.indices where runIDs.contains(jobs[index].id) && (jobs[index].status == .queued || jobs[index].status == .uploading) {
            jobs[index].status = .cancelled
        }
        tick()
        ticker?.invalidate()
        ticker = nil
        isRunning = false
        runTask = nil
        bytesPerSecond = 0
        runFinished = Date()
        if let index = log.firstIndex(where: { $0.id == currentRunID }) {
            log[index].finished = Date()
            if log[index].entries.isEmpty { log.remove(at: index) }
        }
        currentRunID = nil
        saveLog()
        FrameIOBrowser.shared.reload()
    }

    private func set(_ id: UUID, _ status: Status) {
        guard let index = jobs.firstIndex(where: { $0.id == id }) else { return }
        jobs[index].status = status
    }

    nonisolated private func upload(_ job: Job, keepStructure: Bool, folders: FolderResolver, destination: String,
                                    progress: UploadProgress) async {
        guard !Task.isCancelled else { return }
        await set(job.id, .uploading)
        let started = Date()
        let target = ([destination] + (keepStructure ? job.folders : [])).joined(separator: " › ")
        func log(_ outcome: UploadLogEntry.Outcome, message: String? = nil) async {
            let entry = UploadLogEntry(id: UUID(), name: job.files.count > 1 ? "\(job.url.lastPathComponent) (\(job.files.count) frames)" : job.url.lastPathComponent,
                                       destination: target, bytes: job.size, started: started, finished: Date(),
                                       outcome: outcome, message: message)
            await record(entry)
        }
        var placeholder: String?
        do {
            let folder = try await folders.folder(for: keepStructure ? job.folders : [])
            var uploadedAny = false
            var offset: Int64 = 0
            for (index, file) in job.files.enumerated() {
                let size = job.fileSizes[index]
                defer { offset += size }
                guard size > 0 else { continue }
                let name = file.lastPathComponent
                if try await folders.contains(name: name, size: size, in: folder) {
                    progress.set(job.id, part: -1, bytes: offset + size)
                    continue
                }
                let upload = try await FrameIO.shared.createLocalUpload(account: folders.account, folder: folder, name: name, size: size)
                placeholder = upload.id
                try await Self.sendParts(of: file, size: size, upload: upload) { part, sent in
                    progress.set(job.id, part: part, bytes: sent)
                }
                placeholder = nil
                uploadedAny = true
                progress.clearParts(job.id)
                progress.set(job.id, part: -1, bytes: offset + size)
            }
            await set(job.id, uploadedAny ? .done : .skipped)
            await log(uploadedAny ? .uploaded : .skipped)
        } catch {
            if let placeholder {
                // Detached: this task may be cancelled, which would cancel the request too.
                let account = folders.account
                Task.detached { try? await FrameIO.shared.deleteFile(account: account, id: placeholder) }
            }
            let cancelled = Task.isCancelled || (error as? URLError)?.code == .cancelled || error is CancellationError
            await set(job.id, cancelled ? .cancelled : .failed(error.localizedDescription))
            await log(cancelled ? .cancelled : .failed, message: cancelled ? nil : error.localizedDescription)
        }
    }

    /// PUTs each part (two at a time), read from the file as it goes, retrying a failed part up to 3 times.
    nonisolated private static func sendParts(of file: URL, size: Int64, upload: FrameIO.LocalUpload,
                                              report: @escaping @Sendable (_ part: Int, _ sent: Int64) -> Void) async throws {
        guard FileManager.default.fileExists(atPath: file.path) else { throw UploadError.missing }
        let current = (try? file.resourceValues(forKeys: [.fileSizeKey]))?.fileSize.map(Int64.init)
        guard current == size else { throw UploadError.changed }
        let contentType = upload.mediaType
            ?? UTType(filenameExtension: file.pathExtension)?.preferredMIMEType
            ?? "application/octet-stream"
        var ranges: [(index: Int, url: URL, range: Range<Int64>)] = []
        var offset: Int64 = 0
        for (index, part) in upload.uploadURLs.enumerated() {
            guard let url = URL(string: part.url) else { throw FrameIO.Failure.unreadable }
            let end = min(offset + part.size, size)
            ranges.append((index, url, offset..<end))
            offset = end
        }
        guard offset == size else { throw UploadError.partsMismatch }

        try await withThrowingTaskGroup(of: Void.self) { group in
            var next = ranges.makeIterator()
            func addNext() {
                guard let part = next.next() else { return }
                group.addTask {
                    let body = try readPart(of: file, range: part.range)
                    try await sendPart(body, to: part.url, contentType: contentType) { sent in
                        report(part.index, sent)
                    }
                }
            }
            addNext(); addNext()
            while try await group.next() != nil { addNext() }
        }
    }

    nonisolated private static func readPart(of file: URL, range: Range<Int64>) throws -> Data {
        let handle = try FileHandle(forReadingFrom: file)
        defer { try? handle.close() }
        try handle.seek(toOffset: UInt64(range.lowerBound))
        let data = try handle.read(upToCount: Int(range.count)) ?? Data()
        guard data.count == range.count else { throw UploadError.changed }
        return data
    }

    nonisolated private static func sendPart(_ body: Data, to url: URL, contentType: String,
                                             report: @escaping @Sendable (Int64) -> Void) async throws {
        var request = URLRequest(url: url)
        request.httpMethod = "PUT"
        request.setValue("private", forHTTPHeaderField: "x-amz-acl")
        request.setValue(contentType, forHTTPHeaderField: "Content-Type")
        var attempt = 0
        while true {
            try Task.checkCancellation()
            report(0)
            do {
                let (data, response) = try await URLSession.shared.upload(for: request, from: body, delegate: PartProgress(report))
                let status = (response as? HTTPURLResponse)?.statusCode ?? 0
                guard (200..<300).contains(status) else {
                    throw UploadError.part(status, String(data: data.prefix(300), encoding: .utf8) ?? "")
                }
                report(Int64(body.count))
                return
            } catch {
                attempt += 1
                if attempt > 3 || Task.isCancelled || (error as? URLError)?.code == .cancelled { throw error }
                try await Task.sleep(for: .seconds(Double(attempt * 2)))
            }
        }
    }

    // MARK: Progress

    private func startTicker() {
        let timer = Timer(timeInterval: 0.2, repeats: true) { _ in
            MainActor.assumeIsolated { UploadQueue.shared.tick() }
        }
        RunLoop.main.add(timer, forMode: .common)
        ticker = timer
    }

    private func tick() {
        let sent = progress.snapshot()
        var updated = jobs
        for index in updated.indices where updated[index].status == .uploading {
            updated[index].sent = sent[updated[index].id] ?? 0
        }
        if updated != jobs { jobs = updated }
        let total = progress.transferredBytes
        let now = Date()
        if let last = lastTick, now.timeIntervalSince(last.date) > 0 {
            let rate = max(0, Double(total - last.bytes) / now.timeIntervalSince(last.date))
            bytesPerSecond = bytesPerSecond == 0 ? rate : bytesPerSecond * 0.8 + rate * 0.2
            if isRunning {
                speedHistory.append(bytesPerSecond)
                if speedHistory.count > 150 { speedHistory.removeFirst(speedHistory.count - 150) }
            }
        }
        lastTick = (now, total)
        if transferredBytes != total { transferredBytes = total }
    }
}

struct UploadLogRun: Codable, Identifiable, Equatable, Sendable {
    let id: UUID
    let started: Date
    var finished: Date?
    let destination: String
    let keepStructure: Bool
    var entries: [UploadLogEntry]

    nonisolated static var file: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("QCpie/FrameIO/upload-log.json")
    }

    var uploadedBytes: Int64 { entries.filter { $0.outcome == .uploaded }.reduce(0) { $0 + $1.bytes } }
}

struct UploadLogEntry: Codable, Identifiable, Equatable, Sendable {
    enum Outcome: String, Codable, Sendable {
        case uploaded, skipped, failed, cancelled
    }

    let id: UUID
    let name: String
    let destination: String
    let bytes: Int64
    let started: Date
    let finished: Date
    let outcome: Outcome
    let message: String?

    var duration: TimeInterval { finished.timeIntervalSince(started) }
    var bytesPerSecond: Double { duration > 0 ? Double(bytes) / duration : 0 }
}

enum UploadError: LocalizedError {
    case changed, missing, partsMismatch
    case part(Int, String)

    var errorDescription: String? {
        switch self {
        case .changed: return "The file changed while uploading."
        case .missing: return "The file is no longer there (moved, renamed or the drive was disconnected)."
        case .partsMismatch: return "Frame.io's upload parts don't match the file size."
        case .part(let code, let message): return "Upload failed (\(code))\(message.isEmpty ? "" : ": \(message)")"
        }
    }
}

/// Bytes sent per job and part, written from URLSession callbacks and read by the 5 Hz ticker.
final class UploadProgress: @unchecked Sendable {
    private let lock = NSLock()
    private var parts: [UUID: [Int: Int64]] = [:]
    /// Bytes actually sent over the network (retries included, skipped files not): the speed is measured from this.
    private var transferred: Int64 = 0

    func set(_ job: UUID, part: Int, bytes: Int64) {
        lock.withLock {
            if part >= 0 { transferred += max(0, bytes - (parts[job]?[part] ?? 0)) }
            parts[job, default: [:]][part] = bytes
        }
    }

    var transferredBytes: Int64 { lock.withLock { transferred } }

    func snapshot() -> [UUID: Int64] {
        lock.withLock { parts.mapValues { $0.values.reduce(0, +) } }
    }

    /// Keeps only the job's completed-files total (part -1) once a file has finished.
    func clearParts(_ job: UUID) {
        lock.withLock { parts[job] = parts[job].map { $0.filter { $0.key == -1 } } }
    }

    func reset() {
        lock.withLock { parts = [:]; transferred = 0 }
    }
}

private final class PartProgress: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
    private let report: @Sendable (Int64) -> Void

    init(_ report: @escaping @Sendable (Int64) -> Void) {
        self.report = report
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didSendBodyData bytesSent: Int64,
                    totalBytesSent: Int64, totalBytesExpectedToSend: Int64) {
        report(totalBytesSent)
    }
}

/// Finds or creates the destination subfolders, once each even when several files need the same new folder, and
/// remembers each folder's contents for the already-uploaded check.
actor FolderResolver {
    let account: String
    private let root: String
    private var folders: [[String]: Task<String, Error>] = [:]
    private var contents: [String: Task<[FrameIO.Item], Error>] = [:]

    init(account: String, root: String) {
        self.account = account
        self.root = root
    }

    func folder(for path: [String]) async throws -> String {
        guard let name = path.last else { return root }
        if let existing = folders[path] { return try await existing.value }
        let parentPath = Array(path.dropLast())
        let task = Task {
            let parent = try await self.folder(for: parentPath)
            if let match = try await self.items(in: parent).first(where: { $0.isFolder && $0.title == name }) {
                return match.id
            }
            return try await FrameIO.shared.createFolder(account: self.account, parent: parent, name: name).id
        }
        folders[path] = task
        do {
            return try await task.value
        } catch {
            folders[path] = nil   // a transient failure shouldn't fail every later file in this folder
            throw error
        }
    }

    /// A file with this name and size is already in the folder (a re-run after a partial upload).
    func contains(name: String, size: Int64, in folder: String) async throws -> Bool {
        try await items(in: folder).contains { item in
            if item.isVersionStack { return item.headVersion?.name == name && item.headVersion?.fileSize == size }
            return !item.isFolder && item.title == name && item.fileSize == size
        }
    }

    private func items(in folder: String) async throws -> [FrameIO.Item] {
        if let existing = contents[folder] { return try await existing.value }
        let account = account
        let task = Task { try await FrameIO.shared.children(account: account, folder: folder, thumbnails: false) }
        contents[folder] = task
        do {
            return try await task.value
        } catch {
            contents[folder] = nil
            throw error
        }
    }
}
