import AppKit
import UniformTypeIdentifiers
import VideoQCLib

/// Files dropped on the Upload tab and their upload to a Frame.io folder (the sending is `UploadEngine`). Shared so
/// uploads keep running when switching tabs; observed only by the Upload tab. Progress is published at 5 Hz from a
/// lock-protected box, never per network callback. An upload can be paused, and one that was paused, interrupted (quit,
/// crash) or partly failed is offered for resuming from the next unsent part (`resumable`).
@MainActor
final class UploadQueue: ObservableObject {
    static let shared = UploadQueue()

    enum Status: Equatable {
        case queued, uploading, paused, done, skipped, cancelled
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

    /// This run's entry in the transfer log.
    private var currentRunID: UUID?
    /// Where the current run uploads to ("Project › Folder"), for its notification.
    private var runDestination = ""

    private init() {
        Task {
            let saved = await Task.detached(priority: .utility) { UploadResumeStore.load(from: UploadResumeStore.defaultDirectory) }.value
            guard !isRunning else { return }
            if await store.restore(saved) { resumable = saved.run }
            engine.drainDeletes()   // placeholders whose delete didn't get through last time
        }
    }

    @Published private(set) var jobs: [Job] = []
    @Published private(set) var isRunning = false
    /// The pre-upload checks are running (`UploadPreflight`): the Upload button waits.
    @Published private(set) var isChecking = false
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

    /// An upload that can continue: paused, interrupted by a quit or crash, or with files that failed.
    @Published private(set) var resumable: UploadResumeStore.SavedRun?
    var resumableBytes: Int64 { resumable?.jobs.reduce(0) { $0 + $1.sizes.reduce(0, +) } ?? 0 }

    private let progress = UploadProgress()
    private let store = UploadResumeStore(directory: UploadResumeStore.defaultDirectory)
    private lazy var engine = UploadEngine(api: FrameIO.shared, session: UploadEngine.makeSession(), store: store,
                                           progress: progress, network: NetworkMonitor.shared,
                                           onUploaded: { file, account, id in
                                               await FrameIOLinks.shared.link(file, account: account, fileID: id)
                                               await Notifier.shared.noteOwnUpload(id)
                                           })
    private enum Stop { case pause, cancel }
    private var stopping: Stop?
    /// Called once the run has stopped and its progress is saved (quitting waits for this).
    private var whenStopped: [() -> Void] = []
    private var jobStarted: [UUID: Date] = [:]
    /// Keeps the Mac awake while uploading (an asleep Mac drops every connection).
    private var sleepActivity: NSObjectProtocol?
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

    /// Posted with `[URL]`: Finder files dropped on a Frame.io folder, for `ContentView` to add to the queue. It answers
    /// with `finderFilesQueued(version:)` once they're in.
    static let addFromFinder = Notification.Name("QCpieUploadAddFromFinder")

    /// Finder files dropped on a Frame.io folder: added to the queue first, uploaded there once the queue holds them.
    private var finderDrop: (paths: [String], destination: Destination, readyAt: Int?)?

    /// Adds Finder files and folders to the app's queue, then uploads just them to `destination` (Keep subfolders
    /// applies as for any upload).
    func uploadFromFinder(_ urls: [URL], to destination: Destination) {
        guard !isRunning else { return }
        finderDrop = (urls.map { $0.standardizedFileURL.path }, destination, nil)
        NotificationCenter.default.post(name: Self.addFromFinder, object: urls)
    }

    /// The queue now holds the dropped files (as of queue `version`; unchanged when they were already queued).
    func finderFilesQueued(version: Int, changed: Bool) {
        guard finderDrop != nil else { return }
        finderDrop?.readyAt = version
        if !changed { startFinderDrop(syncedVersion: version) }
    }

    /// Starts the dropped files' upload once a sync has seen the queue version that holds them.
    private func startFinderDrop(syncedVersion: Int) {
        guard let drop = finderDrop, let ready = drop.readyAt, syncedVersion >= ready else { return }
        finderDrop = nil
        let matches = jobs.filter { job in
            job.files.contains { file in
                let path = file.standardizedFileURL.path
                return drop.paths.contains { path == $0 || path.hasPrefix($0 + "/") }
            }
        }
        guard !matches.isEmpty else {
            FrameIOBrowser.shared.notify("Nothing to upload: the queue only takes video, audio and image files.", isError: true)
            return
        }
        guard !isRunning else { return }
        start(to: drop.destination, paths: Set(matches.map(\.url.path)))
    }

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
    func sync(with rows: [(url: URL, folders: [String])], version: Int = 0) {
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
            // Rows of the running or paused upload stay even when they leave the app's queue.
            next += jobs.filter { !kept.contains($0.id) && ($0.status == .paused || (isRunning && runIDs.contains($0.id))) }
            jobs = next
            selection.formIntersection(next.map(\.url.path))
            startFinderDrop(syncedVersion: version)
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

    /// Uploads `paths` (files dragged onto a Frame.io folder), else the selected files, else the whole queue. Files
    /// already on Frame.io (same name and size) are skipped, so uploading again only sends what's missing. A paused or
    /// interrupted upload is discarded first, keeping the files this upload reuses.
    /// First checks the files (`UploadPreflight`: names already in the folder, files still being written, odd files)
    /// and asks about any it flags.
    func start(to destination: Destination, paths: Set<String>? = nil) {
        guard !isRunning else { return }
        guard !isChecking else {
            FrameIOBrowser.shared.notify("Still checking the last files: drop these again in a moment", isError: true)
            return
        }
        let targets = paths ?? (selection.isEmpty ? Set(jobs.map(\.url.path)) : selection)
        // Read once: the checks and the upload must agree on where files go.
        let keep = keepStructure
        let rows = jobs.filter { targets.contains($0.url.path) }.map {
            UploadPreflight.Row(path: $0.url.path, name: $0.url.lastPathComponent, files: $0.files, sizes: $0.fileSizes,
                                topLevel: !keep || $0.folders.isEmpty)
        }
        isChecking = true
        Task {
            async let writing = UploadPreflight.stillWriting(rows)
            var report = UploadPreflight.Report()
            if let items = try? await FrameIO.shared.children(account: destination.account, folder: destination.folder, thumbnails: false) {
                report.duplicates = UploadPreflight.duplicates(rows, existing: UploadPreflight.existing(items))
            }
            report.odd = UploadPreflight.odd(rows)
            report.writing = await writing
            isChecking = false
            guard !isRunning else { return }
            guard !report.isEmpty else { return begin(to: destination, targets: targets, keepStructure: keep) }
            let names = Dictionary(rows.map { ($0.path, $0.name) }, uniquingKeysWith: { a, _ in a })
            confirm(report, names: names, folder: destination.path.split(separator: "›").last.map { "“\($0.trimmingCharacters(in: .whitespaces))”" } ?? "the folder") { choice in
                switch choice {
                case .skip:
                    let rest = targets.subtracting(report.flagged)
                    if rest.isEmpty { FrameIOBrowser.shared.notify("Nothing left to upload") } else { self.begin(to: destination, targets: rest, keepStructure: keep) }
                case .all:
                    self.begin(to: destination, targets: targets, keepStructure: keep)
                case .cancel:
                    break
                }
            }
        }
    }

    private enum PreflightChoice { case skip, all, cancel }

    /// A sheet on the window: Skip These (Return: the safe choice) uploads the rest, Upload All sends everything.
    private func confirm(_ report: UploadPreflight.Report, names: [String: String], folder: String,
                         then decide: @escaping (PreflightChoice) -> Void) {
        let text = UploadPreflight.summary(report, names: names, folder: folder)
        let alert = NSAlert()
        alert.messageText = text.title
        alert.informativeText = text.detail
        alert.addButton(withTitle: "Skip These")
        alert.addButton(withTitle: "Upload All")
        alert.addButton(withTitle: "Cancel")
        let finish: (NSApplication.ModalResponse) -> Void = { response in
            switch response {
            case .alertFirstButtonReturn: decide(.skip)
            case .alertSecondButtonReturn: decide(.all)
            default: decide(.cancel)
            }
        }
        if let window = NSApp.keyWindow ?? NSApp.mainWindow {
            alert.beginSheetModal(for: window, completionHandler: finish)
        } else {
            finish(alert.runModal())
        }
    }

    private func begin(to destination: Destination, targets: Set<String>, keepStructure keep: Bool) {
        guard !isRunning else { return }
        let reused = resumable == nil ? nil : Set(jobs.filter { targets.contains($0.url.path) }.flatMap { $0.files.map(\.path) })
        run(to: destination, targets: targets, keepStructure: keep, discardingFirst: reused)
    }

    /// Continues the paused, interrupted or partly failed upload from the next unsent part of each file.
    func resume() {
        guard !isRunning, let saved = resumable else { return }
        let known = Set(jobs.map { $0.url.standardizedFileURL })
        for job in saved.jobs where !known.contains(URL(fileURLWithPath: job.path).standardizedFileURL) {
            jobs.append(Job(url: URL(fileURLWithPath: job.path), files: job.files.map { URL(fileURLWithPath: $0) },
                            fileSizes: job.sizes, folders: job.folders))
        }
        run(to: Destination(account: saved.account, folder: saved.folder, path: saved.destinationPath),
            targets: Set(saved.jobs.map(\.path)), keepStructure: saved.keepStructure)
    }

    /// Stops sending; nothing is deleted on Frame.io, and Resume continues from the next unsent part.
    func pause() {
        guard isRunning, stopping == nil else { return }
        stopping = .pause
        runTask?.cancel()
    }

    /// Quitting while uploading: pauses and saves where the upload got to, then calls `done` (resume after relaunch).
    func pauseForQuit(_ done: @escaping () -> Void) {
        guard isRunning else { done(); return }
        whenStopped.append(done)
        pause()
    }

    /// Stops the upload (or drops the paused one) and deletes its unfinished files on Frame.io.
    func cancel() {
        if isRunning {
            guard stopping == nil else { return }
            stopping = .cancel
            runTask?.cancel()
        } else {
            resumable = nil
            for index in jobs.indices where jobs[index].status == .paused { jobs[index].status = .cancelled }
            Task { await discardSaved(keeping: []) }
        }
    }

    /// `discardingFirst`: drop the paused/interrupted upload before starting, keeping these files' placeholders.
    private func run(to destination: Destination, targets: Set<String>, keepStructure keep: Bool, discardingFirst reused: Set<String>? = nil) {
        for index in jobs.indices where targets.contains(jobs[index].url.path) {
            jobs[index].status = .queued
            jobs[index].sent = 0
        }
        let work = jobs.filter { $0.status == .queued && targets.contains($0.url.path) }
        guard !work.isEmpty else { return }
        runIDs = Set(work.map(\.id))
        runDestination = destination.path
        currentRunID = TransferLog.shared.begin(.upload, destination: destination.path, keepStructure: keep)
        isRunning = true
        stopping = nil
        resumable = nil
        jobStarted = [:]
        progress.reset()
        lastTick = nil
        bytesPerSecond = 0
        speedHistory = []
        transferredBytes = 0
        runStarted = Date()
        runFinished = nil
        startTicker()
        sleepActivity = ProcessInfo.processInfo.beginActivity(options: [.userInitiated, .idleSystemSleepDisabled],
                                                              reason: "Uploading to Frame.io")
        let saved = UploadResumeStore.SavedRun(
            account: destination.account, folder: destination.folder, destinationPath: destination.path, keepStructure: keep,
            jobs: work.map { .init(path: $0.url.path, files: $0.files.map(\.path), sizes: $0.fileSizes, folders: $0.folders) })
        let items = work.map { UploadWork(jobID: $0.id, files: $0.files, sizes: $0.fileSizes, folders: keep ? $0.folders : []) }
        let paths = Dictionary(uniqueKeysWithValues: work.map { ($0.id, $0.url.path) })
        let engine = engine
        let store = store
        runTask = Task {
            if let reused { await self.discardSaved(keeping: reused) }
            await store.setRun(saved)
            await engine.run(items, account: destination.account, folder: destination.folder,
                             onStart: { id in await self.jobStarted(id) },
                             onFinish: { id, outcome in await self.jobFinished(id, outcome, path: paths[id], destination: destination.path, keep: keep) })
            await finish()
        }
    }

    private func jobStarted(_ id: UUID) {
        jobStarted[id] = Date()
        set(id, .uploading)
    }

    private func jobFinished(_ id: UUID, _ outcome: UploadOutcome, path: String?, destination: String, keep: Bool) async {
        guard let job = jobs.first(where: { $0.id == id }) else { return }
        switch outcome {
        case .uploaded, .skipped:
            set(id, outcome == .uploaded ? .done : .skipped)
            if let path { await store.removeJob(path) }
        case .failed(let message):
            set(id, .failed(message))
        case .cancelled:
            break   // settled in `finish` (paused or cancelled)
        }
        guard !(outcome == .cancelled && stopping == .pause), let started = jobStarted[id] else { return }
        let entryOutcome: UploadLogEntry.Outcome = switch outcome {
        case .uploaded: .uploaded
        case .skipped: .skipped
        case .failed: .failed
        case .cancelled: .cancelled
        }
        var message: String?
        if case .failed(let text) = outcome { message = text }
        guard let currentRunID else { return }
        TransferLog.shared.record(UploadLogEntry(id: UUID(), name: job.files.count > 1 ? "\(job.url.lastPathComponent) (\(job.files.count) frames)" : job.url.lastPathComponent,
                              destination: ([destination] + (keep ? job.folders : [])).joined(separator: " › "), bytes: job.size,
                              started: started, finished: Date(), outcome: entryOutcome, message: message),
                                  in: currentRunID)
    }

    private func finish() async {
        let stop = stopping
        let unfinished: Status = stop == .pause ? .paused : .cancelled
        for index in jobs.indices where runIDs.contains(jobs[index].id) && (jobs[index].status == .queued || jobs[index].status == .uploading) {
            jobs[index].status = unfinished
        }
        tick()
        ticker?.invalidate()
        ticker = nil
        if let sleepActivity { ProcessInfo.processInfo.endActivity(sleepActivity) }
        sleepActivity = nil
        isRunning = false
        runTask = nil
        stopping = nil
        bytesPerSecond = 0
        runFinished = Date()
        if let currentRunID { TransferLog.shared.end(currentRunID) }
        currentRunID = nil
        if stop == nil {
            // Not paused or cancelled by the user: every file that didn't go (failed, or stopped by the network or a
            // sign-out) counts as failed.
            let finished = runJobs
            let uploaded = finished.filter { $0.status == .done }.count, skipped = finished.filter { $0.status == .skipped }.count
            Notifier.shared.post(.uploads, NotificationText.upload(uploaded: uploaded, skipped: skipped,
                                                                   failed: finished.count - uploaded - skipped, destination: runDestination))
        }
        if stop == .cancel {
            await discardSaved(keeping: [])
        } else {
            await store.flush()
            resumable = await store.snapshot.run
        }
        let stopped = whenStopped
        whenStopped = []
        stopped.forEach { $0() }
        FrameIOBrowser.shared.reload()
    }

    /// Forgets the saved upload and deletes its unfinished files on Frame.io, except `keeping` (files about to be
    /// uploaded again, whose placeholders are reused). Runs before the next upload touches the store.
    private func discardSaved(keeping: Set<String>) async {
        await store.discard(keeping: keeping)
        await store.flush()
        engine.drainDeletes()
    }

    private func set(_ id: UUID, _ status: Status) {
        guard let index = jobs.firstIndex(where: { $0.id == id }) else { return }
        jobs[index].status = status
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

/// Uploads and downloads, newest run first: the Upload tab's Log. Kept in
/// `Application Support/QCpie/FrameIO/upload-log.json` (last 100 runs), saved off the main thread when a run ends.
/// Observed only by the Log drawer (not the queues, so it doesn't redraw at their 5 Hz progress).
@MainActor
final class TransferLog: ObservableObject {
    static let shared = TransferLog()

    @Published private(set) var runs: [UploadLogRun] = []
    /// Saving waits for the saved history to load: saving earlier would overwrite it with this session's runs only.
    private var didLoad = false
    private var saveAfterLoad = false

    private init() {
        Task {
            let loaded = await Task.detached(priority: .utility) { () -> [UploadLogRun] in
                guard let data = try? Data(contentsOf: UploadLogRun.file) else { return [] }
                let decoder = JSONDecoder()
                decoder.dateDecodingStrategy = .iso8601
                return (try? decoder.decode([UploadLogRun].self, from: data)) ?? []
            }.value
            let known = Set(runs.map(\.id))
            runs += loaded.filter { !known.contains($0.id) }
            didLoad = true
            if saveAfterLoad { save() }
        }
    }

    var isRecording: Bool { runs.contains { $0.finished == nil } }

    func begin(_ kind: UploadLogRun.Kind, destination: String, keepStructure: Bool = false) -> UUID {
        let run = UploadLogRun(id: UUID(), kind: kind, started: Date(), finished: nil, destination: destination,
                               keepStructure: keepStructure, entries: [])
        runs.insert(run, at: 0)
        return run.id
    }

    func record(_ entry: UploadLogEntry, in run: UUID) {
        guard let index = runs.firstIndex(where: { $0.id == run }) else { return }
        runs[index].entries.append(entry)
    }

    /// Ends a run (dropped when nothing was recorded in it) and saves the log.
    func end(_ run: UUID) {
        if let index = runs.firstIndex(where: { $0.id == run }) {
            runs[index].finished = Date()
            if runs[index].entries.isEmpty { runs.remove(at: index) }
        }
        save()
    }

    func clear() {
        runs.removeAll { $0.finished != nil }
        save()
    }

    private func save() {
        guard didLoad else { saveAfterLoad = true; return }
        let saved = Array(runs.filter { $0.finished != nil }.prefix(100))
        Task.detached(priority: .utility) {
            let encoder = JSONEncoder()
            encoder.dateEncodingStrategy = .iso8601
            guard let data = try? encoder.encode(saved) else { return }
            try? FileManager.default.createDirectory(at: UploadLogRun.file.deletingLastPathComponent(), withIntermediateDirectories: true)
            try? data.write(to: UploadLogRun.file, options: .atomic)
        }
    }
}

struct UploadLogRun: Codable, Identifiable, Equatable, Sendable {
    enum Kind: String, Codable, Sendable { case upload, download }

    let id: UUID
    let kind: Kind
    let started: Date
    var finished: Date?
    /// Uploads: the Frame.io folder path; downloads: the local folder.
    let destination: String
    let keepStructure: Bool
    var entries: [UploadLogEntry]

    init(id: UUID, kind: Kind, started: Date, finished: Date?, destination: String, keepStructure: Bool, entries: [UploadLogEntry]) {
        self.id = id
        self.kind = kind
        self.started = started
        self.finished = finished
        self.destination = destination
        self.keepStructure = keepStructure
        self.entries = entries
    }

    /// Runs saved before downloads were logged have no kind: they're uploads.
    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(UUID.self, forKey: .id)
        kind = try container.decodeIfPresent(Kind.self, forKey: .kind) ?? .upload
        started = try container.decode(Date.self, forKey: .started)
        finished = try container.decodeIfPresent(Date.self, forKey: .finished)
        destination = try container.decode(String.self, forKey: .destination)
        keepStructure = try container.decode(Bool.self, forKey: .keepStructure)
        entries = try container.decode([UploadLogEntry].self, forKey: .entries)
    }

    nonisolated static var file: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("QCpie/FrameIO/upload-log.json")
    }

    /// Bytes uploaded or downloaded (files already on Frame.io excluded).
    var transferredBytes: Int64 { entries.filter { $0.outcome == .uploaded }.reduce(0) { $0 + $1.bytes } }
}

struct UploadLogEntry: Codable, Identifiable, Equatable, Sendable {
    /// `uploaded` also stands for downloaded in a download run.
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
    /// Downloads: where the file landed (its name may have gained a number).
    var localPath: String? = nil

    var duration: TimeInterval { finished.timeIntervalSince(started) }
    var bytesPerSecond: Double { duration > 0 ? Double(bytes) / duration : 0 }
}
