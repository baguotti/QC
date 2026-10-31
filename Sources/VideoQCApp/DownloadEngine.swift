import Foundation
import AppKit

// MARK: - Engine

/// The Frame.io calls a download needs: `FrameIO` in the app, a fake in tests.
protocol DownloadAPI: Sendable {
    func originalDownloadURL(account: String, file: String) async throws -> URL?
    func children(account: String, folder: String, thumbnails: Bool) async throws -> [FrameIO.Item]
}

extension FrameIO: DownloadAPI {}

/// One Frame.io file to download (a version stack downloads its current version), and the subfolders it goes into.
struct DownloadItem: Sendable, Equatable {
    let jobID: UUID
    let fileID: String
    let name: String
    let size: Int64
    let folders: [String]
}

enum DownloadOutcome: Sendable, Equatable {
    case downloaded(URL)
    /// Stopped by Pause: the partial file and its finished chunks are kept for Resume.
    case paused
    case cancelled
    case failed(String)
}

/// Downloads Frame.io originals. A single connection to Frame.io's CDN tops out far below a fast line (measured:
/// ~65 MB/s on a 2.5 Gbit/s connection), so each file is fetched as 32 MB byte ranges in parallel from one pool of
/// streams shared by up to 3 files, and written at their offsets into a hidden temporary file beside the destination,
/// renamed only when complete (a failed or cancelled download never leaves a half file under the real name). Network
/// errors retry like uploads (`NetworkRetry`); an expired link is fetched again.
final class DownloadEngine: Sendable {
    struct Limits: Sendable {
        var streams = 8
        var maxFiles = 3
        var chunkSize: Int64 = 32 << 20
        var maxBackoff: Double = 30
        var giveUpAfter: TimeInterval = 15 * 60
    }

    let api: DownloadAPI
    let session: URLSession
    let progress: UploadProgress
    let network: NetworkStatus
    let limits: Limits
    let resume: DownloadResumeState

    init(api: DownloadAPI, session: URLSession, progress: UploadProgress, network: NetworkStatus, limits: Limits = Limits(),
         resume: DownloadResumeState = DownloadResumeState()) {
        self.api = api
        self.session = session
        self.progress = progress
        self.network = network
        self.limits = limits
        self.resume = resume
    }

    private var retry: NetworkRetry { NetworkRetry(network: network, maxBackoff: limits.maxBackoff, giveUpAfter: limits.giveUpAfter) }

    /// Downloads `items` under `destination`, reporting each as it starts and finishes. Cancelling stops at once and
    /// removes the unfinished temporary files, unless `resume` is pausing: then they're kept with their finished chunks.
    func run(_ items: [DownloadItem], account: String, destination: URL,
             onStart: @escaping @Sendable (UUID) async -> Void,
             onFinish: @escaping @Sendable (UUID, DownloadOutcome) async -> Void) async {
        let gate = TransferGate(limit: limits.streams, byteBudget: limits.chunkSize * Int64(limits.streams) * 2)
        await withTaskGroup(of: Void.self) { group in
            var next = items.makeIterator()
            func addNext() -> Bool {
                guard !Task.isCancelled, let item = next.next() else { return false }
                group.addTask {
                    await onStart(item.jobID)
                    await onFinish(item.jobID, await self.download(item, account: account, destination: destination, gate: gate))
                }
                return true
            }
            var started = 0
            while started < max(1, limits.maxFiles) && addNext() { started += 1 }
            for await _ in group { _ = addNext() }
        }
    }

    private func download(_ item: DownloadItem, account: String, destination: URL, gate: TransferGate) async -> DownloadOutcome {
        var temp: URL?
        do {
            let folder = item.folders.reduce(destination) { $0.appendingPathComponent(Self.safeName($1), isDirectory: true) }
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            // A paused download carries on in its partial file, skipping the chunks already in it.
            var saved = resume.saved(item.jobID)
            if let file = saved?.partial,
               (try? FileManager.default.attributesOfItem(atPath: file.path)[.size] as? NSNumber)?.int64Value != item.size {
                try? FileManager.default.removeItem(at: file)
                saved = nil
            }
            if saved == nil,
               let free = try? folder.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey]).volumeAvailableCapacityForImportantUsage,
               free < item.size {
                throw DownloadError.noSpace
            }
            let link = LinkBox()
            guard try await refreshLink(link, item: item, account: account) else {
                return .failed("Frame.io doesn't offer this file for download (no download rights, or it isn't processed yet).")
            }
            // Named by the job, not the file: a long name plus a prefix and suffix could pass the 255-byte limit.
            let partial = saved?.partial ?? folder.appendingPathComponent(".\(item.jobID.uuidString).qcpie-download")
            temp = partial
            if saved == nil {
                FileManager.default.createFile(atPath: partial.path, contents: nil)
                let handle = try FileHandle(forWritingTo: partial)
                try handle.truncate(atOffset: UInt64(item.size))
                try handle.close()
            }
            let done = saved?.done ?? []
            resume.begin(item.jobID, partial: partial, done: done)
            // A retried or resumed file: chunks of the earlier attempt count again only once they're fetched or done.
            progress.clearParts(item.jobID, prefix: "c")

            // Size unknown (0): one request for the whole file. Otherwise 32 MB ranges.
            var ranges: [Range<Int64>?] = item.size == 0 ? [nil] : []
            var offset: Int64 = 0
            while offset < item.size {
                let end = min(offset + limits.chunkSize, item.size)
                ranges.append(offset..<end)
                offset = end
            }
            let failure = FirstError()
            try await withThrowingTaskGroup(of: Void.self) { group in
                for (index, range) in ranges.enumerated() {
                    if done.contains(index) {
                        progress.complete(item.jobID, key: "c\(index)", bytes: Int64(range?.count ?? 0))
                        continue
                    }
                    if let error = failure.value { throw error }
                    try Task.checkCancellation()
                    let cost = Int64(range?.count ?? 0)
                    guard await gate.acquire(cost: cost) else { throw CancellationError() }
                    group.addTask {
                        do {
                            try await self.fetch(range, item: item, account: account, link: link, into: partial, gate: gate) { received in
                                self.progress.set(item.jobID, key: "c\(index)", bytes: received)
                            }
                            self.resume.markDone(item.jobID, chunk: index)
                            await gate.release(cost: cost)
                        } catch {
                            await gate.release(cost: cost)
                            failure.set(error)
                            throw error
                        }
                    }
                }
                try await group.waitForAll()
            }
            let written = (try? FileManager.default.attributesOfItem(atPath: partial.path)[.size] as? NSNumber)?.int64Value
            guard item.size == 0 || written == item.size else { throw DownloadError.incomplete }
            let final = try Self.moveIntoPlace(partial, name: Self.safeName(item.name), in: folder)
            resume.forget(item.jobID)
            temp = nil
            return .downloaded(final)
        } catch {
            let cancelled = UploadEngine.isCancellation(error) || Task.isCancelled
            if cancelled && resume.isPausing { return .paused }
            if let temp { try? FileManager.default.removeItem(at: temp) }
            resume.forget(item.jobID)
            return cancelled ? .cancelled : .failed(UploadEngine.describe(error))
        }
    }

    /// Fetches the original's download link (again after one expired). False when Frame.io gives none.
    private func refreshLink(_ link: LinkBox, item: DownloadItem, account: String) async throws -> Bool {
        let api = api
        let url = try await retry.run(classify: UploadEngine.classifyAPI) {
            try await api.originalDownloadURL(account: account, file: item.fileID)
        }
        guard let url else { return false }
        link.set(url)
        return true
    }

    /// GETs one byte range (the whole file when `range` is nil) and writes it at its offset; retries network errors and
    /// fetches a new link when the current one has expired (403 / 404) — once for all the file's chunks.
    private func fetch(_ range: Range<Int64>?, item: DownloadItem, account: String, link: LinkBox, into file: URL, gate: TransferGate,
                       report: @escaping @Sendable (Int64) -> Void) async throws {
        var refreshed = 0
        while true {
            let used = link.value
            do {
                try await retry.run(classify: UploadEngine.classify, onTransient: { await gate.noteTransientError() }) {
                    report(0)
                    guard let url = used else { throw DownloadError.noLink }
                    var request = URLRequest(url: url)
                    if let range { request.setValue("bytes=\(range.lowerBound)-\(range.upperBound - 1)", forHTTPHeaderField: "Range") }
                    let (data, response) = try await Self.get(request, session: self.session, expected: range?.count, report: report)
                    let http = response as? HTTPURLResponse
                    let status = http?.statusCode ?? 0
                    let whole = range == nil || (range!.lowerBound == 0 && Int64(data.count) == Int64(range!.count))
                    guard status == 206 || (status == 200 && whole) else {
                        throw PartFailure(status: status, body: String(data: data.prefix(600), encoding: .utf8) ?? "",
                                          retryAfter: http?.value(forHTTPHeaderField: "Retry-After").flatMap(Double.init))
                    }
                    if let range { guard Int64(data.count) == Int64(range.count) else { throw URLError(.networkConnectionLost) } }
                    try await Self.write(data, at: range?.lowerBound ?? 0, to: file)
                    report(Int64(data.count))
                }
                return
            } catch RetryExpired.expired where refreshed < 2 {
                refreshed += 1
                // Another chunk may have fetched a new link already.
                if link.value == used {
                    guard try await refreshLink(link, item: item, account: account) else { throw DownloadError.noLink }
                }
            } catch RetryExpired.expired {
                throw DownloadError.linkExpired
            }
        }
    }

    /// A GET whose bytes are reported as they arrive (`URLSession.data(for:delegate:)` never calls the delegate's
    /// `didReceive data`, so progress would only move once per finished chunk).
    nonisolated static func get(_ request: URLRequest, session: URLSession, expected: Int?,
                                report: @escaping @Sendable (Int64) -> Void) async throws -> (Data, URLResponse) {
        let receiver = ChunkReceiver(expected: expected, report: report)
        let task = session.dataTask(with: request)
        task.delegate = receiver
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                receiver.start(continuation)
                task.resume()
            }
        } onCancel: {
            task.cancel()
        }
    }

    /// Writes block (a slow or network drive): they run on their own queue, not the shared task threads.
    private static let writeQueue = DispatchQueue(label: "QCpie.DownloadWrites", qos: .utility, attributes: .concurrent)

    nonisolated static func write(_ data: Data, at offset: Int64, to file: URL) async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            writeQueue.async {
                continuation.resume(with: Result {
                    let handle = try FileHandle(forWritingTo: file)
                    defer { try? handle.close() }
                    try handle.seek(toOffset: UInt64(offset))
                    try handle.write(contentsOf: data)
                })
            }
        }
    }

    /// Moves the finished file to `name`, or Finder-style "name 2.ext" … when taken. The rename is exclusive
    /// (`RENAME_EXCL`): `FileManager.moveItem` checks then renames, and a rename replaces, so two downloads with the same
    /// name (Frame.io allows that in one folder) finishing together lost one file. A taken name tries the next number.
    nonisolated static func moveIntoPlace(_ file: URL, name: String, in folder: URL) throws -> URL {
        for _ in 0..<1000 {
            let target = uniqueURL(for: name, in: folder)
            if renamex_np(file.path, target.path, UInt32(RENAME_EXCL)) == 0 { return target }
            guard errno == EEXIST else { throw CocoaError(.fileWriteUnknown, userInfo: [NSFilePathErrorKey: target.path]) }
        }
        throw CocoaError(.fileWriteFileExists)
    }

    /// Removes partial downloads left behind by a crash or force quit (a normal quit removes its own): hidden
    /// `.qcpie-download` files under `folder`, a few levels deep, untouched for 6 hours and not in use. They can be
    /// gigabytes each and are invisible in Finder.
    nonisolated static func sweepStalePartials(in folder: URL, keeping inUse: Set<String>) {
        guard let walker = FileManager.default.enumerator(at: folder, includingPropertiesForKeys: [.contentModificationDateKey],
                                                          options: [.skipsPackageDescendants]) else { return }
        let cutoff = Date().addingTimeInterval(-6 * 3600)
        for case let file as URL in walker {
            if walker.level > 4 { walker.skipDescendants(); continue }
            guard file.pathExtension == "qcpie-download", file.lastPathComponent.hasPrefix("."),
                  !inUse.contains(file.standardizedFileURL.path),
                  let modified = try? file.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate,
                  modified < cutoff else { continue }
            try? FileManager.default.removeItem(at: file)
        }
    }

    /// Frame.io names can hold "/" and ":", which would make subfolders (or fail) on disk.
    nonisolated static func safeName(_ name: String) -> String {
        let cleaned = name.replacingOccurrences(of: "/", with: "-").replacingOccurrences(of: ":", with: "-")
        return cleaned.isEmpty || cleaned == "." || cleaned == ".." ? "Untitled" : cleaned
    }

    /// `name`, or Finder-style "name 2.ext", "name 3.ext" … when it's taken.
    nonisolated static func uniqueURL(for name: String, in folder: URL) -> URL {
        let candidate = folder.appendingPathComponent(name)
        guard FileManager.default.fileExists(atPath: candidate.path) else { return candidate }
        let base = (name as NSString).deletingPathExtension
        let ext = (name as NSString).pathExtension
        for number in 2... {
            let next = folder.appendingPathComponent(ext.isEmpty ? "\(base) \(number)" : "\(base) \(number).\(ext)")
            if !FileManager.default.fileExists(atPath: next.path) { return next }
        }
        return candidate
    }

    /// Folders and version stacks as the files to download (stacks: their current version), keeping folder structure.
    static func expand(_ items: [FrameIO.Item], account: String, api: DownloadAPI, retry: NetworkRetry,
                       folders: [String] = []) async throws -> [(fileID: String, name: String, size: Int64, folders: [String])] {
        var files: [(fileID: String, name: String, size: Int64, folders: [String])] = []
        for item in items {
            try Task.checkCancellation()
            if item.isFolder {
                let children = try await retry.run(classify: UploadEngine.classifyAPI) {
                    try await api.children(account: account, folder: item.id, thumbnails: false)
                }
                files += try await expand(children, account: account, api: api, retry: retry, folders: folders + [item.title])
            } else if item.isVersionStack, let head = item.headVersion {
                files.append((head.id, head.name ?? item.title, head.fileSize ?? 0, folders))
            } else {
                files.append((item.id, item.title, item.fileSize ?? 0, folders))
            }
        }
        return files
    }
}

enum DownloadError: LocalizedError {
    case noLink, linkExpired, incomplete, noSpace

    var errorDescription: String? {
        switch self {
        case .noLink: return "Frame.io didn't give a download link."
        case .linkExpired: return "Frame.io's download link kept expiring."
        case .incomplete: return "The download didn't complete."
        case .noSpace: return "Not enough space on the destination drive."
        }
    }
}

/// Partial files of paused downloads and the chunks already in them, so Resume fetches only the rest. Kept for this
/// session only: quitting removes the partial files.
final class DownloadResumeState: @unchecked Sendable {
    private let lock = NSLock()
    private var files: [UUID: (partial: URL, done: Set<Int>)] = [:]
    private var pausing = false

    /// Set before cancelling the run for Pause: stopped files keep their partial file instead of removing it.
    var isPausing: Bool {
        get { lock.withLock { pausing } }
        set { lock.withLock { pausing = newValue } }
    }

    func saved(_ job: UUID) -> (partial: URL, done: Set<Int>)? { lock.withLock { files[job] } }
    func begin(_ job: UUID, partial: URL, done: Set<Int>) { lock.withLock { files[job] = (partial, done) } }
    func markDone(_ job: UUID, chunk: Int) { lock.withLock { _ = files[job]?.done.insert(chunk) } }
    func forget(_ job: UUID) { lock.withLock { _ = files.removeValue(forKey: job) } }
    var partialPaths: Set<String> { lock.withLock { Set(files.values.map(\.partial.standardizedFileURL.path)) } }

    /// Forgets these jobs and removes their partial files (paused downloads cancelled, or the app quitting).
    func discard(_ jobs: [UUID]) {
        let partials = lock.withLock { jobs.compactMap { files.removeValue(forKey: $0)?.partial } }
        for file in partials { try? FileManager.default.removeItem(at: file) }
    }
}

/// The file's current download link, shared by its chunks (replaced when it expires).
final class LinkBox: @unchecked Sendable {
    private let lock = NSLock()
    private var url: URL?
    var value: URL? { lock.withLock { url } }
    func set(_ new: URL) { lock.withLock { url = new } }
}

/// Collects one GET's body and reports the bytes received so far; resumes its caller when the request ends.
private final class ChunkReceiver: NSObject, URLSessionDataDelegate, @unchecked Sendable {
    private let report: @Sendable (Int64) -> Void
    private let lock = NSLock()
    private var body = Data()
    private var continuation: CheckedContinuation<(Data, URLResponse), Error>?

    init(expected: Int?, report: @escaping @Sendable (Int64) -> Void) {
        self.report = report
        if let expected { body.reserveCapacity(expected) }
    }

    func start(_ continuation: CheckedContinuation<(Data, URLResponse), Error>) {
        lock.withLock { self.continuation = continuation }
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
        report(lock.withLock { body.append(data); return Int64(body.count) })
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        let (continuation, data) = lock.withLock { () -> (CheckedContinuation<(Data, URLResponse), Error>?, Data) in
            defer { self.continuation = nil }
            return (self.continuation, body)
        }
        if let error {
            continuation?.resume(throwing: error)
        } else if let response = task.response {
            continuation?.resume(returning: (data, response))
        } else {
            continuation?.resume(throwing: URLError(.badServerResponse))
        }
    }
}

// MARK: - Queue (UI state)

/// Frame.io files and folders downloaded to this Mac (right-click → Download…), shown in the Upload tab's Downloads
/// drawer. Observed only by Upload-tab views; progress is published at 5 Hz from a lock-protected box. Files can be
/// added to the app's queue as each one lands (`addedToQueue` notification, picked up by `ContentView`).
@MainActor
final class DownloadQueue: ObservableObject {
    static let shared = DownloadQueue()

    /// Posted with `[URL]` (batched) when downloaded files should join the app's queue.
    static let addToQueue = Notification.Name("QCpieDownloadAddToQueue")

    enum Status: Equatable {
        case queued, downloading, paused, done, cancelled
        case failed(String)
    }

    struct Job: Identifiable, Equatable {
        let id = UUID()
        let fileID: String
        let account: String
        let name: String
        let size: Int64
        let folders: [String]
        let destination: URL
        let addToQueue: Bool
        var status: Status = .queued
        var received: Int64 = 0
        var localURL: URL?
    }

    @Published private(set) var jobs: [Job] = []
    @Published private(set) var isRunning = false
    /// Listing a downloaded folder's contents before the files start.
    @Published private(set) var isPreparing = false
    @Published private(set) var bytesPerSecond: Double = 0
    @Published private(set) var speedHistory: [Double] = []
    @Published private(set) var runStarted: Date?
    @Published private(set) var runFinished: Date?
    @Published private(set) var transferredBytes: Int64 = 0
    /// Something new started: the header opens the drawer on Downloads.
    @Published private(set) var startCount = 0
    /// Why the last Download… couldn't start (a folder that couldn't be listed).
    @Published private(set) var lastError: String?

    private let progress = UploadProgress()
    private let resumeState = DownloadResumeState()
    private lazy var engine = DownloadEngine(api: FrameIO.shared, session: UploadEngine.makeSession(), progress: progress,
                                             network: NetworkMonitor.shared, resume: resumeState)
    /// The batch's entry in the transfer log, and when each of its files started.
    private var logRunID: UUID?
    /// Files finished since the queue was last idle (runs chain per destination), for one notification at the end.
    private var batchTally = (downloaded: 0, failed: 0)
    private var firstDestination: URL?
    private var jobStarted: [UUID: Date] = [:]
    private var runTask: Task<Void, Never>?
    private var ticker: Timer?
    private var lastTick: (date: Date, bytes: Int64)?
    private var sleepActivity: NSObjectProtocol?
    private var pendingForQueue: [URL] = []
    private var queueFlush: Task<Void, Never>?
    /// Called once a cancelled run has stopped and removed its partial files (quitting waits for this).
    private var whenStopped: [() -> Void] = []

    var totalBytes: Int64 { jobs.reduce(0) { $0 + $1.size } }
    var receivedBytes: Int64 { jobs.reduce(0) { $0 + ($1.status == .done ? $1.size : $1.received) } }
    var finishedCount: Int { jobs.filter { $0.status == .done }.count }
    var percent: Int { Int((Double(receivedBytes) / Double(max(totalBytes, 1)) * 100).rounded(.down)) }
    var failedCount: Int { jobs.filter { if case .failed = $0.status { return true }; return false }.count }
    var hasFinished: Bool { jobs.contains { $0.status != .queued && $0.status != .downloading && $0.status != .paused } }
    /// Paused, waiting for Resume (or Cancel).
    var isPaused: Bool { !isRunning && jobs.contains { $0.status == .paused } }

    private init() {}

    // MARK: Starting

    /// Asks where to save (and whether to add the files to the queue), then downloads `items` there.
    func download(_ items: [FrameIO.Item], account: String) {
        guard !items.isEmpty else { return }
        Self.chooseDestination(for: items) { choice in self.start(items, account: account, choice: choice) }
    }

    private func start(_ items: [FrameIO.Item], account: String, choice: (folder: URL, addToQueue: Bool)) {
        startCount += 1
        isPreparing = true
        lastError = nil
        Task {
            do {
                let files = try await DownloadEngine.expand(items, account: account, api: FrameIO.shared,
                                                            retry: NetworkRetry(network: NetworkMonitor.shared))
                jobs += files.map { Job(fileID: $0.fileID, account: account, name: $0.name, size: $0.size, folders: $0.folders,
                                        destination: choice.folder, addToQueue: choice.addToQueue) }
                if files.isEmpty { lastError = "Nothing to download: the folder is empty." }
            } catch {
                lastError = "Couldn't list what to download: \(UploadEngine.describe(error))"
            }
            isPreparing = false
            pump()
        }
    }

    /// Frame.io rows dragged from the browser and dropped on the Downloads drawer or its tab: the same as Download….
    /// Other text (queue files dragged for upload) is ignored.
    nonisolated static func acceptDrop(_ providers: [NSItemProvider]) -> Bool {
        guard let provider = providers.first(where: { $0.canLoadObject(ofClass: NSString.self) }) else { return false }
        _ = provider.loadObject(ofClass: NSString.self) { object, _ in
            guard let text = object as? String, text.hasPrefix(FrameIOBrowser.dragPrefix) else { return }
            let ids = Set(text.dropFirst(FrameIOBrowser.dragPrefix.count).split(separator: "\n").map(String.init))
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    let browser = FrameIOBrowser.shared
                    let items = browser.items.filter { ids.contains($0.id) }
                    guard let account = browser.accountID, !items.isEmpty else { return }
                    DownloadQueue.shared.download(items, account: account)
                }
            }
        }
        return true
    }

    /// Downloads the failed files again.
    func retryFailed() {
        for index in jobs.indices {
            if case .failed = jobs[index].status {
                jobs[index].status = .queued
                jobs[index].received = 0
            }
        }
        pump()
    }

    /// Stops the running files, keeping what they downloaded so far: Resume fetches only the missing chunks.
    func pause() {
        guard isRunning, !resumeState.isPausing else { return }
        resumeState.isPausing = true
        runTask?.cancel()
    }

    func resume() {
        guard !isRunning else { return }
        for index in jobs.indices where jobs[index].status == .paused { jobs[index].status = .queued }
        pump()
    }

    /// Stops everything and removes the partial files, paused ones included.
    func cancel() {
        discardPaused()
        runTask?.cancel()
    }

    private func discardPaused() {
        let paused = jobs.filter { $0.status == .paused }.map(\.id)
        resumeState.discard(paused)
        for index in jobs.indices where jobs[index].status == .paused { jobs[index].status = .cancelled }
    }

    /// Quitting while downloading or paused: stops, removes the partial files (downloads don't resume across launches),
    /// then calls `done`.
    func stopForQuit(_ done: @escaping () -> Void) {
        discardPaused()
        guard isRunning else { done(); return }
        resumeState.isPausing = false
        whenStopped.append(done)
        runTask?.cancel()
    }

    /// Removes finished, failed and cancelled rows.
    func clearFinished() {
        jobs.removeAll { $0.status != .queued && $0.status != .downloading && $0.status != .paused }
        if jobs.isEmpty { runStarted = nil; runFinished = nil; speedHistory = [] }
    }

    /// The folder a file not downloaded yet goes to (created if needed, so Finder can show it).
    func revealDestination(_ job: Job) {
        let folder = job.folders.reduce(job.destination) { $0.appendingPathComponent(DownloadEngine.safeName($1), isDirectory: true) }
        let shown = FileManager.default.fileExists(atPath: folder.path) ? folder : job.destination
        NSWorkspace.shared.activateFileViewerSelecting([shown])
    }

    func revealInFinder(_ job: Job) {
        guard let url = job.localURL else { return }
        NSWorkspace.shared.activateFileViewerSelecting([url])
    }

    /// Runs every queued file, batch by batch (files of one account and destination together).
    private func pump() {
        guard !isRunning, let first = jobs.first(where: { $0.status == .queued }) else { return }
        let batch = jobs.filter { $0.status == .queued && $0.account == first.account && $0.destination == first.destination }
        isRunning = true
        if runStarted == nil || runFinished != nil {
            runStarted = Date()
            speedHistory = []
            progress.reset()
            lastTick = nil
            transferredBytes = 0
        }
        runFinished = nil
        startTicker()
        logRunID = TransferLog.shared.begin(.download, destination: (first.destination.path as NSString).abbreviatingWithTildeInPath)
        if sleepActivity == nil {
            sleepActivity = ProcessInfo.processInfo.beginActivity(options: [.userInitiated, .idleSystemSleepDisabled],
                                                                  reason: "Downloading from Frame.io")
        }
        let destination = first.destination, inUse = resumeState.partialPaths
        Task.detached(priority: .background) { DownloadEngine.sweepStalePartials(in: destination, keeping: inUse) }
        let items = batch.map { DownloadItem(jobID: $0.id, fileID: $0.fileID, name: $0.name, size: $0.size, folders: $0.folders) }
        let addToQueue = Dictionary(uniqueKeysWithValues: batch.map { ($0.id, $0.addToQueue) })
        let engine = engine
        runTask = Task {
            await engine.run(items, account: first.account, destination: first.destination,
                             onStart: { id in await self.started(id) },
                             onFinish: { id, outcome in await self.finished(id, outcome, addToQueue: addToQueue[id] ?? false) })
            let cancelled = Task.isCancelled
            finishRun(cancelled: cancelled)
        }
    }

    private func started(_ id: UUID) {
        jobStarted[id] = Date()
        set(id, .downloading)
    }

    private func finished(_ id: UUID, _ outcome: DownloadOutcome, addToQueue: Bool) {
        guard let index = jobs.firstIndex(where: { $0.id == id }) else { return }
        let entryOutcome: UploadLogEntry.Outcome?
        var message: String?
        switch outcome {
        case .downloaded(let url):
            jobs[index].status = .done
            batchTally.downloaded += 1
            if firstDestination == nil { firstDestination = jobs[index].destination }
            jobs[index].localURL = url
            if addToQueue { queueForPlayer(url) }
            let account = jobs[index].account, fileID = jobs[index].fileID
            Task { await FrameIOLinks.shared.link(url, account: account, fileID: fileID) }   // for its comments
            entryOutcome = .uploaded
        case .paused:
            jobs[index].status = .paused
            entryOutcome = nil
        case .cancelled:
            jobs[index].status = .cancelled
            entryOutcome = .cancelled
        case .failed(let text):
            jobs[index].status = .failed(text)
            batchTally.failed += 1
            entryOutcome = .failed
            message = text
        }
        let job = jobs[index]
        guard let entryOutcome, let logRunID, let started = jobStarted.removeValue(forKey: id) else { return }
        let place = ([(job.destination.path as NSString).abbreviatingWithTildeInPath] + job.folders).joined(separator: " › ")
        TransferLog.shared.record(UploadLogEntry(id: UUID(), name: job.name, destination: place, bytes: job.size, started: started,
                                                 finished: Date(), outcome: entryOutcome, message: message,
                                                 localPath: job.localURL?.path), in: logRunID)
    }

    private func finishRun(cancelled: Bool) {
        let pausing = resumeState.isPausing
        resumeState.isPausing = false
        let stoppedStatus: Status = pausing ? .paused : .cancelled
        for index in jobs.indices where jobs[index].status == .downloading || (cancelled && jobs[index].status == .queued) {
            jobs[index].status = stoppedStatus
        }
        tick()
        isRunning = false
        runTask = nil
        if let logRunID { TransferLog.shared.end(logRunID) }
        logRunID = nil
        jobStarted = [:]
        if !cancelled && jobs.contains(where: { $0.status == .queued }) {
            pump()   // the next batch (another destination or account)
            return
        }
        ticker?.invalidate()
        ticker = nil
        bytesPerSecond = 0
        runFinished = Date()
        if let sleepActivity { ProcessInfo.processInfo.endActivity(sleepActivity) }
        sleepActivity = nil
        if !cancelled && !pausing && batchTally.downloaded + batchTally.failed > 0 {
            let place = firstDestination.map { ($0.path as NSString).abbreviatingWithTildeInPath } ?? ""
            Notifier.shared.post(.downloads, NotificationText.download(downloaded: batchTally.downloaded,
                                                                       failed: batchTally.failed, destination: place))
        }
        batchTally = (0, 0)
        firstDestination = nil
        let stopped = whenStopped
        whenStopped = []
        stopped.forEach { $0() }
    }

    private func set(_ id: UUID, _ status: Status) {
        guard let index = jobs.firstIndex(where: { $0.id == id }) else { return }
        jobs[index].status = status
    }

    /// Batches files landing close together into one add to the queue (each add rebuilds the queue's tree).
    private func queueForPlayer(_ url: URL) {
        pendingForQueue.append(url)
        queueFlush?.cancel()
        queueFlush = Task {
            try? await Task.sleep(for: .milliseconds(600))
            guard !Task.isCancelled else { return }
            let urls = pendingForQueue
            pendingForQueue = []
            NotificationCenter.default.post(name: Self.addToQueue, object: urls)
        }
    }

    // MARK: Choosing where

    static let folderKey = "frameioDownloadFolder"
    static let addToQueueKey = "frameioDownloadAddToQueue"
    /// Off (User Settings → Frame.io): downloads go straight to the saved folder, without the Open panel.
    static let askKey = "prefDownloadAsk"

    /// The folder to save into and whether to add the files to the queue: one Open panel with a checkbox, both remembered.
    /// Shown as a sheet, not `runModal`: a modal loop started from a drop blocked the drag from finishing, and its image
    /// stayed on screen until the panel closed.
    private static func chooseDestination(for items: [FrameIO.Item], then chosen: @escaping ((folder: URL, addToQueue: Bool)) -> Void) {
        let defaults = UserDefaults.standard
        if defaults.object(forKey: askKey) as? Bool == false, let saved = defaults.url(forKey: folderKey),
           FileManager.default.fileExists(atPath: saved.path) {
            return chosen((saved, defaults.bool(forKey: addToQueueKey)))
        }
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.canCreateDirectories = true
        panel.allowsMultipleSelection = false
        panel.prompt = "Download Here"
        panel.message = items.count == 1 ? "Choose where to download “\(items[0].title)”." : "Choose where to download \(items.count) items."
        if let saved = UserDefaults.standard.url(forKey: folderKey) {
            panel.directoryURL = saved
        } else {
            panel.directoryURL = FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask).first
        }
        let checkbox = NSButton(checkboxWithTitle: "Add to the QCpie queue when downloaded", target: nil, action: nil)
        checkbox.state = UserDefaults.standard.bool(forKey: addToQueueKey) ? .on : .off
        let accessory = NSView(frame: NSRect(x: 0, y: 0, width: 320, height: 36))
        checkbox.frame.origin = NSPoint(x: 16, y: 9)
        checkbox.sizeToFit()
        accessory.addSubview(checkbox)
        panel.accessoryView = accessory
        panel.isAccessoryViewDisclosed = true
        let finish: (NSApplication.ModalResponse) -> Void = { response in
            guard response == .OK, let folder = panel.url else { return }
            let addToQueue = checkbox.state == .on
            UserDefaults.standard.set(folder, forKey: folderKey)
            UserDefaults.standard.set(addToQueue, forKey: addToQueueKey)
            chosen((folder, addToQueue))
        }
        if let window = NSApp.mainWindow ?? NSApp.keyWindow {
            panel.beginSheetModal(for: window, completionHandler: finish)
        } else {
            panel.begin(completionHandler: finish)
        }
    }

    // MARK: Progress

    private func startTicker() {
        guard ticker == nil else { return }
        let timer = Timer(timeInterval: 0.2, repeats: true) { _ in
            MainActor.assumeIsolated { DownloadQueue.shared.tick() }
        }
        RunLoop.main.add(timer, forMode: .common)
        ticker = timer
    }

    private func tick() {
        let received = progress.snapshot()
        var updated = jobs
        for index in updated.indices where updated[index].status == .downloading {
            updated[index].received = received[updated[index].id] ?? 0
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
