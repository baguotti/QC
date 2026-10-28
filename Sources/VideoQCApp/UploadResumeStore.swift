import Foundation

/// What a paused, interrupted or partly failed upload needs to continue: each file's Frame.io placeholder, its part
/// links and which parts are already sent, plus the run (destination and remaining queue rows) to resume. Saved to
/// `Application Support/QCpie/FrameIO/` (`upload-run.json`, `upload-resume.json`) a second after a change and on pause /
/// finish, off the main thread. Part links are pre-signed and expire; a file whose links are about to expire starts over.
actor UploadResumeStore {
    struct Part: Codable, Sendable, Equatable {
        let size: Int64
        let url: String
    }

    struct SavedFile: Codable, Sendable, Equatable {
        let path: String
        let size: Int64
        let modified: Date
        let account: String
        let folderID: String
        let placeholderID: String
        let mediaType: String?
        let parts: [Part]
        var done: Set<Int>
        /// The earliest expiry of the part links (`X-Amz-Date` + `X-Amz-Expires`), nil when they don't say.
        var expires: Date?

        init(path: String, size: Int64, modified: Date, account: String, folderID: String, placeholderID: String,
             mediaType: String?, parts: [Part], done: Set<Int>) {
            self.path = path
            self.size = size
            self.modified = modified
            self.account = account
            self.folderID = folderID
            self.placeholderID = placeholderID
            self.mediaType = mediaType
            self.parts = parts
            self.done = done
            self.expires = parts.compactMap { Self.expiry(of: $0.url) }.min()
        }

        func matches(size: Int64, modified: Date, folder: String) -> Bool {
            self.size == size && abs(self.modified.timeIntervalSince(modified)) < 1 && folderID == folder
        }

        func expires(within margin: TimeInterval) -> Bool {
            guard let expires else { return false }
            return expires.timeIntervalSinceNow < margin
        }

        /// The same placeholder, marked as needing a new upload.
        func expired() -> SavedFile {
            var copy = self
            copy.expires = .distantPast
            return copy
        }

        var sentBytes: Int64 { done.reduce(0) { $0 + (parts.indices.contains($1) ? parts[$1].size : 0) } }

        /// S3 pre-signed URLs carry their signing time and lifetime in the query.
        static func expiry(of url: String) -> Date? {
            guard let items = URLComponents(string: url)?.queryItems,
                  let signed = items.first(where: { $0.name == "X-Amz-Date" })?.value,
                  let seconds = items.first(where: { $0.name == "X-Amz-Expires" })?.value.flatMap(Double.init) else { return nil }
            return try? Date(signed, strategy: amzDate).addingTimeInterval(seconds)
        }

        /// `X-Amz-Date`: "20261028T101500Z" (a reusable, Sendable parse strategy rather than a formatter per part).
        private static let amzDate = Date.ParseStrategy(
            format: "\(year: .padded(4))\(month: .twoDigits)\(day: .twoDigits)T\(hour: .twoDigits(clock: .twentyFourHour, hourCycle: .zeroBased))\(minute: .twoDigits)\(second: .twoDigits)Z",
            locale: Locale(identifier: "en_US_POSIX"), timeZone: TimeZone(identifier: "UTC")!)
    }

    /// A queue row still to upload.
    struct SavedJob: Codable, Sendable, Equatable {
        let path: String
        let files: [String]
        let sizes: [Int64]
        let folders: [String]
    }

    /// An upload that didn't finish: where it was going and the rows left.
    struct SavedRun: Codable, Sendable, Equatable {
        let account: String
        let folder: String
        let destinationPath: String
        let keepStructure: Bool
        var jobs: [SavedJob]
    }

    /// A placeholder to delete on Frame.io, kept until the delete succeeds.
    struct PendingDelete: Codable, Sendable, Hashable {
        let account: String
        let id: String
    }

    struct State: Codable, Sendable {
        var run: SavedRun?
        var files: [String: SavedFile] = [:]
        var deletes: [PendingDelete] = []
    }

    /// The run (destination and rows left, long for image sequences) changes rarely; the files' sent parts change all
    /// the time. They're saved to separate files so each part doesn't rewrite the row list.
    private struct Parts: Codable {
        var files: [String: SavedFile] = [:]
        var deletes: [PendingDelete] = []

        init(files: [String: SavedFile] = [:], deletes: [PendingDelete] = []) {
            self.files = files
            self.deletes = deletes
        }

        init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            files = try container.decodeIfPresent([String: SavedFile].self, forKey: .files) ?? [:]
            deletes = try container.decodeIfPresent([PendingDelete].self, forKey: .deletes) ?? []
        }
    }

    nonisolated static var defaultDirectory: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent("QCpie/FrameIO")
    }

    private var state: State
    private let directory: URL?
    private var runDirty = false
    private var partsDirty = false
    private var saveScheduled = false
    private var deleting: Set<PendingDelete> = []

    /// `directory` nil keeps everything in memory (tests).
    init(directory: URL?, state: State = State()) {
        self.directory = directory
        self.state = state
    }

    private nonisolated static func runFile(in directory: URL) -> URL { directory.appendingPathComponent("upload-run.json") }
    private nonisolated static func partsFile(in directory: URL) -> URL { directory.appendingPathComponent("upload-resume.json") }

    /// Reads a saved state (call off the main thread).
    nonisolated static func load(from directory: URL) -> State {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let run = (try? Data(contentsOf: runFile(in: directory))).flatMap { try? decoder.decode(SavedRun.self, from: $0) }
        let parts = (try? Data(contentsOf: partsFile(in: directory))).flatMap { try? decoder.decode(Parts.self, from: $0) } ?? Parts()
        return State(run: run, files: parts.files, deletes: parts.deletes)
    }

    var snapshot: State { state }

    /// Takes the state saved by an earlier session, unless something was recorded since (an upload already started).
    func restore(_ saved: State) -> Bool {
        guard state.run == nil, state.files.isEmpty, state.deletes.isEmpty,
              saved.run != nil || !saved.files.isEmpty || !saved.deletes.isEmpty else { return false }
        state = saved
        return saved.run != nil
    }

    func file(_ path: String) -> SavedFile? { state.files[path] }

    func putFile(_ saved: SavedFile) {
        state.files[saved.path] = saved
        changed(run: false)
    }

    func markDone(_ path: String, part: Int) {
        state.files[path]?.done.insert(part)
        changed(run: false)
    }

    func removeFile(_ path: String) {
        guard state.files.removeValue(forKey: path) != nil else { return }
        changed(run: false)
    }

    func setRun(_ run: SavedRun?) {
        state.run = run
        changed(run: true)
    }

    func removeJob(_ path: String) {
        state.run?.jobs.removeAll { $0.path == path }
        if state.run?.jobs.isEmpty == true { state.run = nil }
        changed(run: true)
    }

    func addDeletes(_ deletes: [PendingDelete]) {
        state.deletes += deletes.filter { !state.deletes.contains($0) }
        changed(run: false)
    }

    /// Pending deletes not already being sent (so two drains don't delete the same placeholder twice).
    func claimDeletes() -> [PendingDelete] {
        let claimed = state.deletes.filter { !deleting.contains($0) }
        deleting.formUnion(claimed)
        return claimed
    }

    func finishDelete(_ pending: PendingDelete, done: Bool) {
        deleting.remove(pending)
        guard done else { return }
        state.deletes.removeAll { $0 == pending }
        changed(run: false)
    }

    /// Forgets the run and its files; their placeholders become pending deletes, except `keeping` (files about to be
    /// uploaded again, whose placeholders are reused).
    func discard(keeping: Set<String>) {
        let dropped = state.files.values.filter { !keeping.contains($0.path) }
        state.files = state.files.filter { keeping.contains($0.key) }
        state.run = nil
        state.deletes += dropped.map { PendingDelete(account: $0.account, id: $0.placeholderID) }
        changed(run: true)
    }

    func flush() {
        saveScheduled = false
        guard let directory else { return }
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        if runDirty {
            runDirty = false
            if let run = state.run, let data = try? encoder.encode(run) {
                try? data.write(to: Self.runFile(in: directory), options: .atomic)
            } else {
                try? FileManager.default.removeItem(at: Self.runFile(in: directory))
            }
        }
        if partsDirty {
            partsDirty = false
            if let data = try? encoder.encode(Parts(files: state.files, deletes: state.deletes)) {
                try? data.write(to: Self.partsFile(in: directory), options: .atomic)
            }
        }
    }

    private func changed(run: Bool) {
        if run { runDirty = true } else { partsDirty = true }
        guard directory != nil, !saveScheduled else { return }
        saveScheduled = true
        Task {
            try? await Task.sleep(for: .seconds(1))
            self.flushIfScheduled()
        }
    }

    private func flushIfScheduled() {
        if saveScheduled { flush() }
    }
}
