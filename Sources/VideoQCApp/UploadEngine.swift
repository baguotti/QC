import Foundation
import Network
import UniformTypeIdentifiers

// MARK: - Frame.io calls

/// The Frame.io calls an upload needs: `FrameIO` in the app, a fake in tests.
protocol UploadAPI: Sendable {
    func createLocalUpload(account: String, folder: String, name: String, size: Int64) async throws -> FrameIO.LocalUpload
    func deleteFile(account: String, id: String) async throws
    func uploadStatus(account: String, id: String) async throws -> FrameIO.UploadStatus
    func createFolder(account: String, parent: String, name: String) async throws -> FrameIO.Item
    func children(account: String, folder: String, thumbnails: Bool) async throws -> [FrameIO.Item]
}

extension FrameIO: UploadAPI {}

/// Whether the Mac is online, and a way to wait until it is (the app: `NetworkMonitor`; tests: a stub).
protocol NetworkStatus: Sendable {
    var isOnline: Bool { get }
    func waitUntilOnline() async
}

// MARK: - Work and results

/// One queue row to upload: a file, or every frame of an image sequence.
struct UploadWork: Sendable {
    let jobID: UUID
    let files: [URL]
    let sizes: [Int64]
    /// Subfolders under the destination (keeping the queue's structure), [] otherwise.
    let folders: [String]
}

enum UploadOutcome: Sendable, Equatable {
    case uploaded, skipped, cancelled
    case failed(String)
}

// MARK: - Engine

/// Sends files to Frame.io: Frame.io's pre-signed part URLs are PUT in parallel from one shared pool of streams (several
/// files at once), sized adaptively to the connection within a memory budget. A dropped network doesn't fail anything:
/// parts wait for the network, retry with backoff and resend only themselves. Every finished part is recorded on disk
/// (`UploadResumeStore`), so a pause, quit or crash resumes from the next unsent part. Files are never memory-mapped
/// (a mapped file on a network volume that drops crashes the app): each part is read just before it is sent.
final class UploadEngine: Sendable {
    struct Limits: Sendable {
        var initialStreams = 6
        var maxStreams = 16
        var minStreams = 2
        /// Files in progress at once (image sequences: each frame is a file, and creating one is an API call).
        var maxFiles = 6
        /// Memory for part buffers. Parts are streamed from disk through a `PartBodyStream.bufferSize` buffer each, so
        /// this no longer limits the stream count (whole parts held in memory did: a 13 GB file's large parts allowed
        /// one at a time, read and sent in turn — the bursty speed).
        var memoryBudget: Int64 = 512 << 20
        /// How long a part or Frame.io call keeps retrying while the Mac is online before its file fails (time offline
        /// doesn't count): long enough to ride out a hotel login page or a VPN reconnecting.
        var giveUpAfter: TimeInterval = 15 * 60
        /// Longest wait between retries.
        var maxBackoff: Double = 30
        /// How often the stream count is re-evaluated.
        var tuneInterval: Double = 5
        /// Re-create a file's upload when its links expire within this many seconds.
        var expiryMargin: TimeInterval = 600
    }

    let api: UploadAPI
    let session: URLSession
    let store: UploadResumeStore
    let progress: UploadProgress
    let network: NetworkStatus
    let limits: Limits
    /// A single-file clip finished uploading: its local file, account and Frame.io file id (links it for comments).
    let onUploaded: (@Sendable (URL, String, String) async -> Void)?

    init(api: UploadAPI, session: URLSession, store: UploadResumeStore, progress: UploadProgress, network: NetworkStatus,
         limits: Limits = Limits(), onUploaded: (@Sendable (URL, String, String) async -> Void)? = nil) {
        self.api = api
        self.session = session
        self.store = store
        self.progress = progress
        self.network = network
        self.limits = limits
        self.onUploaded = onUploaded
    }

    /// The session for part uploads: more connections per host than the system's 6 (all parts go to the same storage
    /// host), no cache, and waits for connectivity instead of failing at once.
    static func makeSession(protocolClasses: [AnyClass] = []) -> URLSession {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.httpMaximumConnectionsPerHost = 32
        configuration.timeoutIntervalForRequest = 120
        configuration.timeoutIntervalForResource = 3600
        configuration.waitsForConnectivity = true
        configuration.urlCache = nil
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        if !protocolClasses.isEmpty {
            configuration.protocolClasses = protocolClasses + (configuration.protocolClasses ?? [])
        }
        return URLSession(configuration: configuration)
    }

    /// Uploads `work` into `folder` (or its subfolders). `onStart`/`onFinish` report each queue row; cancelling the
    /// calling task stops at once and leaves every unfinished file resumable in the store.
    func run(_ work: [UploadWork], account: String, folder root: String,
             onStart: @escaping @Sendable (UUID) async -> Void,
             onFinish: @escaping @Sendable (UUID, UploadOutcome) async -> Void) async {
        let gate = TransferGate(limit: limits.initialStreams, byteBudget: limits.memoryBudget)
        let resolver = FolderResolver(api: RetryingAPI(engine: self), account: account, root: root)
        let tracker = JobTracker(work)
        drainDeletes()
        let tuner = Task.detached { [limits, progress] in await Self.tune(gate, progress: progress, limits: limits) }
        defer { tuner.cancel() }

        let units = work.flatMap { item in item.files.indices.map { (item, $0) } }
        await withTaskGroup(of: Void.self) { group in
            var next = units.makeIterator()
            func addNext() -> Bool {
                guard !Task.isCancelled, let (item, index) = next.next() else { return false }
                group.addTask {
                    if await tracker.start(item.jobID) { await onStart(item.jobID) }
                    let outcome = await self.uploadFile(item, index: index, account: account, resolver: resolver, gate: gate)
                    if let finished = await tracker.finish(item.jobID, outcome) { await onFinish(item.jobID, finished) }
                }
                return true
            }
            var started = 0
            while started < max(1, limits.maxFiles) && addNext() { started += 1 }
            for await _ in group { _ = addNext() }
        }
        for jobID in await tracker.unfinished() { await onFinish(jobID, .cancelled) }
        await store.flush()
    }

    // MARK: Files

    private func uploadFile(_ work: UploadWork, index: Int, account: String, resolver: FolderResolver, gate: TransferGate) async -> UploadOutcome {
        let file = work.files[index]
        let size = work.sizes[index]
        let fileKey = "f\(index)"
        guard size > 0 else { return .skipped }
        guard !Task.isCancelled else { return .cancelled }
        do {
            let folder = try await resolver.folder(for: work.folders)
            var saved = await store.file(file.path)
            if saved == nil, try await resolver.contains(name: file.lastPathComponent, size: size, in: folder) {
                progress.complete(work.jobID, key: fileKey, bytes: size)
                return .skipped
            }
            let modified = try Self.checkedModificationDate(of: file, size: size)
            var recreated = false
            while true {
                let record: UploadResumeStore.SavedFile
                if let saved, saved.matches(size: size, modified: modified, folder: folder),
                   !saved.expires(within: limits.expiryMargin) {
                    record = saved
                } else {
                    if let saved { await discard(saved) }
                    record = try await createUpload(file, size: size, modified: modified, account: account, folder: folder)
                }
                do {
                    try await sendParts(of: record, file: file, jobID: work.jobID, fileKey: fileKey, gate: gate)
                    guard (try? Self.checkedModificationDate(of: file, size: size)) == modified else { throw UploadError.changed }
                    try await verify(record)
                    await store.removeFile(file.path)
                    progress.complete(work.jobID, key: fileKey, bytes: size)
                    if work.files.count == 1 { await onUploaded?(file, record.account, record.placeholderID) }
                    return .uploaded
                } catch UploadError.linksExpired where !recreated {
                    // Frame.io's links can't be refreshed: start this file over with a new upload, once.
                    recreated = true
                    saved = record.expired()
                }
            }
        } catch {
            if Self.isCancellation(error) || Task.isCancelled { return .cancelled }
            if let error = error as? UploadError, error.discardsUpload, let saved = await store.file(file.path) {
                await discard(saved)
            }
            return .failed(Self.describe(error))
        }
    }

    private func createUpload(_ file: URL, size: Int64, modified: Date, account: String, folder: String) async throws -> UploadResumeStore.SavedFile {
        let name = file.lastPathComponent
        let attempts = AttemptCounter()
        let upload = try await withRetries(classify: Self.classifyAPI) {
            attempts.increment()
            return try await self.api.createLocalUpload(account: account, folder: folder, name: name, size: size)
        }
        if attempts.value > 1 {
            await removeDuplicates(of: upload.id, name: name, size: size, account: account, folder: folder)
        }
        let record = UploadResumeStore.SavedFile(
            path: file.path, size: size, modified: modified, account: account, folderID: folder, placeholderID: upload.id,
            mediaType: upload.mediaType, parts: upload.uploadURLs.map { .init(size: $0.size, url: $0.url) }, done: [])
        await store.putFile(record)
        return record
    }

    /// A create call that was retried may have reached Frame.io the first time too, leaving an empty twin: delete
    /// same-named placeholders still waiting for data (`status: created`) made in the last few minutes.
    private func removeDuplicates(of id: String, name: String, size: Int64, account: String, folder: String) async {
        guard let items = try? await withRetries(classify: Self.classifyAPI, {
            try await self.api.children(account: account, folder: folder, thumbnails: false)
        }) else { return }
        let twins = items.filter {
            $0.id != id && !$0.isFolder && $0.title == name && $0.fileSize == size && $0.status == "created"
                && ($0.createdDate.map { -$0.timeIntervalSinceNow < 900 } ?? false)
        }
        guard !twins.isEmpty else { return }
        await store.addDeletes(twins.map { .init(account: account, id: $0.id) })
        drainDeletes()
    }

    /// Forgets a placeholder that can't be resumed (its file changed, or its links expired) and deletes it on Frame.io.
    private func discard(_ saved: UploadResumeStore.SavedFile) async {
        await store.removeFile(saved.path)
        await store.addDeletes([.init(account: saved.account, id: saved.placeholderID)])
        drainDeletes()
    }

    /// Deletes the placeholders waiting to be deleted (kept on disk until Frame.io confirms, so a delete that failed
    /// offline or was cut short by a quit is retried by the next upload or launch). Detached: callers may be cancelled.
    func drainDeletes() {
        Task.detached(priority: .utility) {
            for pending in await self.store.claimDeletes() {
                do {
                    try await self.withRetries(classify: Self.classifyAPI) {
                        try await self.api.deleteFile(account: pending.account, id: pending.id)
                    }
                    await self.store.finishDelete(pending, done: true)
                } catch FrameIO.Failure.http(404, _) {
                    await self.store.finishDelete(pending, done: true)
                } catch {
                    await self.store.finishDelete(pending, done: false)
                }
            }
        }
    }

    /// Asks Frame.io once whether the upload failed. Assembling the file can take longer than this, so only a reported
    /// failure counts; an unanswered check doesn't hold the upload up.
    private func verify(_ record: UploadResumeStore.SavedFile) async throws {
        guard let status = try? await api.uploadStatus(account: record.account, id: record.placeholderID) else { return }
        if status.uploadFailed == true { throw UploadError.rejected }
    }

    // MARK: Parts

    private func sendParts(of record: UploadResumeStore.SavedFile, file: URL, jobID: UUID, fileKey: String, gate: TransferGate) async throws {
        var ranges: [(index: Int, url: URL, range: Range<Int64>)] = []
        var offset: Int64 = 0
        for (index, part) in record.parts.enumerated() {
            guard let url = URL(string: part.url) else { throw FrameIO.Failure.unreadable }
            let end = min(offset + part.size, record.size)
            ranges.append((index, url, offset..<end))
            offset = end
        }
        guard offset == record.size else { throw UploadError.partsMismatch }
        let contentType = record.mediaType ?? UTType(filenameExtension: file.pathExtension)?.preferredMIMEType ?? "application/octet-stream"
        progress.complete(jobID, key: fileKey, bytes: ranges.filter { record.done.contains($0.index) }.reduce(0) { $0 + Int64($1.range.count) })

        let failure = FirstError()
        try await withThrowingTaskGroup(of: Void.self) { group in
            for part in ranges where !record.done.contains(part.index) {
                if let error = failure.value { throw error }
                try Task.checkCancellation()
                let cost = PartBodyStream.bufferSize
                guard await gate.acquire(cost: cost) else { throw CancellationError() }
                group.addTask {
                    let partKey = "\(fileKey)-\(part.index)"
                    do {
                        try await self.sendPart(part.range, of: file, to: part.url, contentType: contentType, gate: gate) { sent in
                            self.progress.set(jobID, key: partKey, bytes: sent)
                        }
                        await gate.release(cost: cost)
                        await self.store.markDone(record.path, part: part.index)
                    } catch {
                        await gate.release(cost: cost)
                        failure.set(error)
                        throw error
                    }
                }
            }
            try await group.waitForAll()
        }
        progress.clearParts(jobID, prefix: "\(fileKey)-")
    }

    /// PUTs one part, reading it from disk for each attempt. Network failures wait for the network and back off; a
    /// part's partial progress is reset before it's resent.
    private func sendPart(_ range: Range<Int64>, of file: URL, to url: URL, contentType: String, gate: TransferGate,
                          report: @escaping @Sendable (Int64) -> Void) async throws {
        do {
            try await withRetries(classify: Self.classify, onTransient: { await gate.noteTransientError() }) {
                report(0)
                try await self.put(range, of: file, to: url, contentType: contentType, report: report)
                report(Int64(range.count))
            }
        } catch RetryExpired.expired {
            throw UploadError.linksExpired
        }
    }

    /// Runs `body` until it succeeds, with the upload's network rules (`NetworkRetry`).
    func withRetries<T>(classify: (Error) -> Retry, onTransient: @Sendable () async -> Void = {},
                        _ body: @Sendable () async throws -> T) async throws -> T {
        try await NetworkRetry(network: network, maxBackoff: limits.maxBackoff, giveUpAfter: limits.giveUpAfter)
            .run(classify: classify, onTransient: onTransient, body)
    }

    /// PUTs one part, streamed from disk while it's sent (`PartBodyStream`): reading and sending overlap, and memory is
    /// one small buffer per part whatever Frame.io's part size. `Content-Length` is set so the body isn't sent chunked
    /// (pre-signed S3 PUTs need the length).
    private func put(_ range: Range<Int64>, of file: URL, to url: URL, contentType: String,
                     report: @escaping @Sendable (Int64) -> Void) async throws {
        var request = URLRequest(url: url)
        request.httpMethod = "PUT"
        request.setValue("private", forHTTPHeaderField: "x-amz-acl")
        request.setValue(contentType, forHTTPHeaderField: "Content-Type")
        request.setValue(String(range.count), forHTTPHeaderField: "Content-Length")
        let body = try PartBodyStream(file: file, range: range, report: report)
        request.httpBodyStream = body.input
        defer { body.stop() }
        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await session.data(for: request, delegate: body)
        } catch {
            throw body.readError ?? error   // a file that vanished or changed beats the network error it caused
        }
        if let readError = body.readError { throw readError }
        let http = response as? HTTPURLResponse
        let status = http?.statusCode ?? 0
        guard (200..<300).contains(status) else {
            throw PartFailure(status: status, body: String(data: data.prefix(600), encoding: .utf8) ?? "",
                              retryAfter: http?.value(forHTTPHeaderField: "Retry-After").flatMap(Double.init))
        }
    }

    nonisolated static func read(_ range: Range<Int64>, of file: URL) throws -> Data {
        guard FileManager.default.fileExists(atPath: file.path) else { throw UploadError.missing }
        let handle = try FileHandle(forReadingFrom: file)
        defer { try? handle.close() }
        try handle.seek(toOffset: UInt64(range.lowerBound))
        let data = try handle.read(upToCount: Int(range.count)) ?? Data()
        guard data.count == range.count else { throw UploadError.changed }
        return data
    }

    /// The file's modification date, after checking it's still there at the expected size. Read from disk each time
    /// (`URL.resourceValues` caches per URL, which hid changes made mid-upload).
    nonisolated static func checkedModificationDate(of file: URL, size: Int64) throws -> Date {
        guard let attributes = try? FileManager.default.attributesOfItem(atPath: file.path) else { throw UploadError.missing }
        guard (attributes[.size] as? NSNumber)?.int64Value == size else { throw UploadError.changed }
        return attributes[.modificationDate] as? Date ?? .distantPast
    }

    // MARK: Errors and retries

    enum Retry: Equatable {
        case transient(retryAfter: Double?)
        case expired
        case fatal
    }

    /// Network trouble and storage hiccups retry; refused links (expired, or the upload was dropped) need a new upload.
    nonisolated static func classify(_ error: Error) -> Retry {
        if let failure = error as? PartFailure {
            switch failure.status {
            case 408, 429, 500...599: return .transient(retryAfter: failure.retryAfter.map { min($0, 60) })
            case 400 where failure.body.contains("RequestTimeout"): return .transient(retryAfter: nil)
            case 403, 404: return .expired
            default: return .fatal
            }
        }
        if let error = error as? URLError {
            switch error.code {
            case .networkConnectionLost, .notConnectedToInternet, .timedOut, .cannotConnectToHost, .cannotFindHost,
                 .dnsLookupFailed, .secureConnectionFailed, .internationalRoamingOff, .dataNotAllowed, .callIsActive,
                 .resourceUnavailable, .badServerResponse, .cannotLoadFromNetwork, .backgroundSessionWasDisconnected:
                return .transient(retryAfter: nil)
            default:
                return .fatal
            }
        }
        return .fatal
    }

    /// Frame.io API calls: the same network errors retry, and 408 / 429 / 5xx (signed out and other refusals don't).
    nonisolated static func classifyAPI(_ error: Error) -> Retry {
        if case FrameIO.Failure.http(let code, _) = error {
            return code == 408 || code == 429 || (500...599).contains(code) ? .transient(retryAfter: nil) : .fatal
        }
        return error is URLError ? classify(error) : .fatal
    }

    /// A failure in words for the queue row and the log (URL errors otherwise read "NSURLErrorDomain error -1005").
    nonisolated static func describe(_ error: Error) -> String {
        guard let error = error as? URLError else { return error.localizedDescription }
        switch error.code {
        case .networkConnectionLost: return "The network connection was lost."
        case .notConnectedToInternet: return "The Mac is offline."
        case .timedOut: return "Frame.io didn't respond in time."
        case .cannotFindHost, .dnsLookupFailed, .cannotConnectToHost: return "Couldn't reach Frame.io."
        case .secureConnectionFailed: return "A secure connection to Frame.io couldn't be made."
        case .dataNotAllowed, .internationalRoamingOff: return "This network doesn't allow data."
        default: return error.localizedDescription
        }
    }

    /// 1, 2, 4 … s up to `cap`, ± 25 % so parallel parts don't retry in lockstep.
    nonisolated static func backoff(_ failures: Int, cap: Double) -> Double {
        let base = min(cap, pow(2, Double(max(0, failures - 1))))
        return base * Double.random(in: 0.75...1.25)
    }

    nonisolated static func isCancellation(_ error: Error) -> Bool {
        error is CancellationError || (error as? URLError)?.code == .cancelled
    }

    // MARK: Adaptive streams

    /// Adds streams while they add speed (when every stream is busy), and backs off when the network struggles.
    private static func tune(_ gate: TransferGate, progress: UploadProgress, limits: Limits) async {
        var limit = limits.initialStreams
        var best = 0.0
        var lastBytes = progress.transferredBytes
        while !Task.isCancelled {
            try? await Task.sleep(for: .seconds(limits.tuneInterval))
            guard !Task.isCancelled else { return }
            let bytes = progress.transferredBytes
            let rate = Double(bytes - lastBytes) / limits.tuneInterval
            lastBytes = bytes
            let (errors, saturated) = await gate.sample()
            if errors > 0 {
                limit = max(limits.minStreams, limit - 2)
                best = rate
            } else if saturated && rate > best * 1.08 && limit < limits.maxStreams {
                best = rate
                limit = min(limits.maxStreams, limit + 2)
            } else {
                best = max(best, rate)
            }
            await gate.setLimit(limit)
        }
    }
}

// MARK: - Supporting types

enum RetryExpired: Error { case expired }

/// Runs a network operation until it succeeds (uploads and downloads share these rules): transient failures wait for
/// the network (time offline doesn't count) and back off 1–30 s ± 25 %; the last error is thrown after `giveUpAfter`
/// seconds of failing while online, fatal ones at once, and `.expired` as `RetryExpired.expired`.
struct NetworkRetry: Sendable {
    let network: NetworkStatus
    var maxBackoff: Double = 30
    var giveUpAfter: TimeInterval = 15 * 60

    func run<T>(classify: (Error) -> UploadEngine.Retry, onTransient: @Sendable () async -> Void = {},
                _ body: @Sendable () async throws -> T) async throws -> T {
        var failures = 0
        var failingSince: Date?
        var offline: TimeInterval = 0
        while true {
            try Task.checkCancellation()
            do {
                return try await body()
            } catch {
                if UploadEngine.isCancellation(error) { throw error }
                switch classify(error) {
                case .fatal:
                    throw error
                case .expired:
                    throw RetryExpired.expired
                case .transient(let retryAfter):
                    await onTransient()
                    failures += 1
                    let since = failingSince ?? Date()
                    failingSince = since
                    if -since.timeIntervalSinceNow - offline > giveUpAfter { throw error }
                    if !network.isOnline {
                        let waited = Date()
                        await network.waitUntilOnline()
                        offline += -waited.timeIntervalSinceNow
                    }
                    try Task.checkCancellation()
                    try await Task.sleep(for: .seconds(retryAfter ?? UploadEngine.backoff(failures, cap: maxBackoff)))
                }
            }
        }
    }
}

final class AttemptCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var count = 0
    var value: Int { lock.withLock { count } }
    func increment() { lock.withLock { count += 1 } }
}

/// Folder lookups and creation for `FolderResolver`, retried like the parts.
struct RetryingAPI: UploadAPI {
    let engine: UploadEngine

    func createLocalUpload(account: String, folder: String, name: String, size: Int64) async throws -> FrameIO.LocalUpload {
        try await engine.withRetries(classify: UploadEngine.classifyAPI) {
            try await engine.api.createLocalUpload(account: account, folder: folder, name: name, size: size)
        }
    }
    func deleteFile(account: String, id: String) async throws {
        try await engine.withRetries(classify: UploadEngine.classifyAPI) { try await engine.api.deleteFile(account: account, id: id) }
    }
    func uploadStatus(account: String, id: String) async throws -> FrameIO.UploadStatus {
        try await engine.api.uploadStatus(account: account, id: id)
    }
    func createFolder(account: String, parent: String, name: String) async throws -> FrameIO.Item {
        try await engine.withRetries(classify: UploadEngine.classifyAPI) {
            try await engine.api.createFolder(account: account, parent: parent, name: name)
        }
    }
    func children(account: String, folder: String, thumbnails: Bool) async throws -> [FrameIO.Item] {
        try await engine.withRetries(classify: UploadEngine.classifyAPI) {
            try await engine.api.children(account: account, folder: folder, thumbnails: thumbnails)
        }
    }
}

struct PartFailure: LocalizedError {
    let status: Int
    let body: String
    let retryAfter: Double?

    var errorDescription: String? {
        let detail = body.range(of: "<Message>(.*?)</Message>", options: .regularExpression).map {
            String(body[$0]).replacingOccurrences(of: "<Message>", with: "").replacingOccurrences(of: "</Message>", with: "")
        } ?? ""
        return "Upload failed (\(status))\(detail.isEmpty ? "" : ": \(detail)")"
    }
}

enum UploadError: LocalizedError {
    case changed, missing, partsMismatch, linksExpired, rejected

    var errorDescription: String? {
        switch self {
        case .changed: return "The file changed while uploading."
        case .missing: return "The file is no longer there (moved, renamed or the drive was disconnected)."
        case .partsMismatch: return "Frame.io's upload parts don't match the file size."
        case .linksExpired: return "Frame.io's upload links expired."
        case .rejected: return "Frame.io reported the upload as failed."
        }
    }

    /// The placeholder on Frame.io can't be completed: delete it rather than keep it for resuming.
    var discardsUpload: Bool { self != .missing }
}

/// Parts in flight, limited by count (the adaptive stream count) and by the bytes they hold in memory.
actor TransferGate {
    private var limit: Int
    private let byteBudget: Int64
    private var active = 0
    private var bytes: Int64 = 0
    private var waiters: [(id: UUID, cost: Int64, continuation: CheckedContinuation<Bool, Never>)] = []
    private var transientErrors = 0
    private var wasSaturated = false

    init(limit: Int, byteBudget: Int64) {
        self.limit = max(1, limit)
        self.byteBudget = byteBudget
    }

    /// Waits for a slot; false when the task was cancelled while waiting (then there's nothing to release).
    func acquire(cost: Int64) async -> Bool {
        if waiters.isEmpty && fits(cost) {
            take(cost)
            return true
        }
        wasSaturated = true
        let id = UUID()
        return await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                if Task.isCancelled { continuation.resume(returning: false) } else { waiters.append((id, cost, continuation)) }
            }
        } onCancel: {
            Task { await self.cancelWaiter(id) }
        }
    }

    func release(cost: Int64) {
        active -= 1
        bytes -= cost
        resumeWaiters()
    }

    func setLimit(_ newLimit: Int) {
        limit = max(1, newLimit)
        resumeWaiters()
    }

    func noteTransientError() { transientErrors += 1 }

    /// Errors since the last sample, and whether every slot was in use.
    func sample() -> (errors: Int, saturated: Bool) {
        defer { transientErrors = 0; wasSaturated = !waiters.isEmpty || active >= limit }
        return (transientErrors, wasSaturated || !waiters.isEmpty || active >= limit)
    }

    private func fits(_ cost: Int64) -> Bool { active < limit && (active == 0 || bytes + cost <= byteBudget) }

    private func take(_ cost: Int64) {
        active += 1
        bytes += cost
        if active >= limit { wasSaturated = true }
    }

    private func resumeWaiters() {
        while let first = waiters.first, fits(first.cost) {
            waiters.removeFirst()
            take(first.cost)
            first.continuation.resume(returning: true)
        }
    }

    private func cancelWaiter(_ id: UUID) {
        guard let index = waiters.firstIndex(where: { $0.id == id }) else { return }
        waiters.remove(at: index).continuation.resume(returning: false)
    }
}

/// Each queue row's files: reports a row as started once and finished when its last file is.
actor JobTracker {
    private var remaining: [UUID: Int] = [:]
    private var outcomes: [UUID: [UploadOutcome]] = [:]
    private var started: Set<UUID> = []

    init(_ work: [UploadWork]) {
        for item in work { remaining[item.jobID] = item.files.count }
    }

    func start(_ job: UUID) -> Bool { started.insert(job).inserted }

    func finish(_ job: UUID, _ outcome: UploadOutcome) -> UploadOutcome? {
        outcomes[job, default: []].append(outcome)
        remaining[job, default: 1] -= 1
        guard remaining[job] == 0 else { return nil }
        remaining[job] = nil
        return Self.combine(outcomes[job] ?? [])
    }

    /// Rows that never finished (the run was cancelled before all their files ran).
    func unfinished() -> [UUID] {
        defer { remaining = [:] }
        return Array(remaining.keys)
    }

    static func combine(_ outcomes: [UploadOutcome]) -> UploadOutcome {
        if let failure = outcomes.first(where: { if case .failed = $0 { return true }; return false }) { return failure }
        if outcomes.contains(.cancelled) { return .cancelled }
        if outcomes.contains(.uploaded) { return .uploaded }
        return .skipped
    }
}

/// The first error of a file's parts, so no more parts start after one fails.
final class FirstError: @unchecked Sendable {
    private let lock = NSLock()
    private var error: Error?
    var value: Error? { lock.withLock { error } }
    func set(_ newError: Error) { lock.withLock { if error == nil { error = newError } } }
}

/// Bytes sent per queue row and file/part key, written from URLSession callbacks and read by the 5 Hz ticker.
final class UploadProgress: @unchecked Sendable {
    private let lock = NSLock()
    private var parts: [UUID: [String: Int64]] = [:]
    /// Bytes actually sent over the network (resends included, skipped and resumed parts not): the speed comes from this.
    private var transferred: Int64 = 0

    /// A part in flight (its key holds a "-").
    func set(_ job: UUID, key: String, bytes: Int64) {
        lock.withLock {
            transferred += max(0, bytes - (parts[job]?[key] ?? 0))
            parts[job, default: [:]][key] = bytes
        }
    }

    /// A whole file (or its parts finished before a resume): counts towards the row, not the speed.
    func complete(_ job: UUID, key: String, bytes: Int64) {
        lock.withLock { parts[job, default: [:]][key] = bytes }
    }

    var transferredBytes: Int64 { lock.withLock { transferred } }

    func snapshot() -> [UUID: Int64] {
        lock.withLock { parts.mapValues { $0.values.reduce(0, +) } }
    }

    func clearParts(_ job: UUID, prefix: String) {
        lock.withLock { parts[job] = parts[job]?.filter { !$0.key.hasPrefix(prefix) } }
    }

    func reset() {
        lock.withLock { parts = [:]; transferred = 0 }
    }
}

/// One part's body, streamed from the file while it's sent: a pump on its own thread reads 1 MB at a time into a bound
/// stream pair whose input end is the request body. Reading and sending overlap, and memory stays at the stream buffer.
/// Read failures (the file moved, shrank, or its drive went away) end the body early and are reported as `readError`.
/// Also the task delegate: a body URLSession asks for again (a redirect) isn't replayed; the part fails and is retried.
final class PartBodyStream: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
    static let bufferSize: Int64 = 4 << 20
    private static let chunk = 1 << 20
    private static let pumpQueue = DispatchQueue(label: "QCpie.UploadReads", qos: .utility, attributes: .concurrent)

    let input: InputStream
    private let output: OutputStream
    private let lock = NSLock()
    private var stopped = false
    private var error: Error?

    var readError: Error? { lock.withLock { error } }

    init(file: URL, range: Range<Int64>, report: @escaping @Sendable (Int64) -> Void) throws {
        guard FileManager.default.fileExists(atPath: file.path) else { throw UploadError.missing }
        let handle = try FileHandle(forReadingFrom: file)
        var input: InputStream?
        var output: OutputStream?
        Stream.getBoundStreams(withBufferSize: Int(Self.bufferSize), inputStream: &input, outputStream: &output)
        guard let input, let output else { throw UploadError.missing }
        self.input = input
        self.output = output
        super.init()
        Self.pumpQueue.async { self.pump(handle, range: range, report: report) }
    }

    func stop() { lock.withLock { stopped = true } }

    private var isStopped: Bool { lock.withLock { stopped } }

    private func pump(_ handle: FileHandle, range: Range<Int64>, report: @Sendable (Int64) -> Void) {
        output.open()
        defer {
            output.close()
            try? handle.close()
        }
        do {
            try handle.seek(toOffset: UInt64(range.lowerBound))
            var sent: Int64 = 0
            while sent < Int64(range.count) && !isStopped {
                let count = Int(min(Int64(Self.chunk), Int64(range.count) - sent))
                guard let data = try handle.read(upToCount: count), data.count == count else { throw UploadError.changed }
                var offset = 0
                var wait: UInt32 = 200
                while offset < data.count {
                    if isStopped || output.streamStatus == .error || output.streamStatus == .closed { return }
                    guard output.hasSpaceAvailable else {
                        // Full buffer: the network is the bottleneck. Back off to 5 ms (up to 16 pumps polling every
                        // 0.3 ms cost ~50,000 wake-ups a second on a slow line).
                        usleep(wait)
                        wait = min(wait * 2, 5_000)
                        continue
                    }
                    wait = 200
                    let written = data.withUnsafeBytes { buffer in
                        output.write(buffer.bindMemory(to: UInt8.self).baseAddress! + offset, maxLength: data.count - offset)
                    }
                    if written <= 0 { return }
                    offset += written
                    sent += Int64(written)
                    report(sent)
                }
            }
        } catch {
            lock.withLock { self.error = error }
        }
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, needNewBodyStream completionHandler: @escaping (InputStream?) -> Void) {
        completionHandler(nil)
    }
}

/// Finds or creates the destination subfolders, once each even when several files need the same new folder, and
/// remembers each folder's contents for the already-uploaded check.
actor FolderResolver {
    let account: String
    private let api: UploadAPI
    private let root: String
    private var folders: [[String]: Task<String, Error>] = [:]
    private var contents: [String: Task<[FrameIO.Item], Error>] = [:]

    init(api: UploadAPI, account: String, root: String) {
        self.api = api
        self.account = account
        self.root = root
    }

    func folder(for path: [String]) async throws -> String {
        guard let name = path.last else { return root }
        if let existing = folders[path] { return try await existing.value }
        let parentPath = Array(path.dropLast())
        let api = api, account = account
        let task = Task {
            let parent = try await self.folder(for: parentPath)
            if let match = try await self.items(in: parent).first(where: { $0.isFolder && $0.title == name }) {
                return match.id
            }
            return try await api.createFolder(account: account, parent: parent, name: name).id
        }
        folders[path] = task
        do {
            return try await task.value
        } catch {
            folders[path] = nil   // a transient failure shouldn't fail every later file in this folder
            throw error
        }
    }

    /// A finished file with this name and size is already in the folder (a re-run after a partial upload). Placeholders
    /// still waiting for their data (`status: created`) don't count.
    func contains(name: String, size: Int64, in folder: String) async throws -> Bool {
        try await items(in: folder).contains { item in
            if item.isVersionStack { return item.headVersion?.name == name && item.headVersion?.fileSize == size }
            return !item.isFolder && item.title == name && item.fileSize == size && item.status != "created"
        }
    }

    private func items(in folder: String) async throws -> [FrameIO.Item] {
        if let existing = contents[folder] { return try await existing.value }
        let api = api, account = account
        let task = Task { try await api.children(account: account, folder: folder, thumbnails: false) }
        contents[folder] = task
        do {
            return try await task.value
        } catch {
            contents[folder] = nil
            throw error
        }
    }
}

/// Online/offline from `NWPathMonitor`; waiting resumes when a usable path appears (or the task is cancelled).
final class NetworkMonitor: NetworkStatus, @unchecked Sendable {
    static let shared = NetworkMonitor()

    private let monitor = NWPathMonitor()
    private let lock = NSLock()
    private var online = true
    private var waiters: [UUID: CheckedContinuation<Void, Never>] = [:]

    private init() {
        monitor.pathUpdateHandler = { [weak self] path in self?.update(path.status == .satisfied) }
        monitor.start(queue: DispatchQueue(label: "QCpie.NetworkMonitor", qos: .utility))
    }

    var isOnline: Bool { lock.withLock { online } }

    func waitUntilOnline() async {
        let id = UUID()
        await withTaskCancellationHandler {
            await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
                let resumeNow = lock.withLock { () -> Bool in
                    if online || Task.isCancelled { return true }
                    waiters[id] = continuation
                    return false
                }
                if resumeNow { continuation.resume() }
            }
        } onCancel: {
            lock.withLock { waiters.removeValue(forKey: id) }?.resume()
        }
    }

    private func update(_ isOnline: Bool) {
        let ready = lock.withLock { () -> [CheckedContinuation<Void, Never>] in
            online = isOnline
            guard isOnline else { return [] }
            defer { waiters = [:] }
            return Array(waiters.values)
        }
        ready.forEach { $0.resume() }
    }
}
