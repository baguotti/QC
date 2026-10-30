import Foundation
import AppKit
import AVFoundation
import CryptoKit
import VideoQCLib

// MARK: - Links

/// Which Frame.io file each local clip is, and which of its comments were already imported (so a note deleted here
/// isn't brought back by the next import). Links come from QCpie's own uploads and downloads, and from Import Comments
/// in the Frame.io browser (queue clips matched by name and size). Kept in `Application Support/QCpie/FrameIO/frameio-links.json`.
actor FrameIOLinks {
    static let shared = FrameIOLinks(directory: FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        .appendingPathComponent("QCpie/FrameIO", isDirectory: true))

    struct Link: Codable, Sendable, Equatable {
        let account: String
        let fileID: String
        /// The local file's size when linked: a file replaced since (different size) is no longer this Frame.io file.
        let size: Int64
    }

    /// A Frame.io file seen in a listing, found again by name and size (`index`).
    struct Seen: Codable, Sendable, Equatable {
        let account: String
        let fileID: String
    }

    private struct State: Codable {
        var links: [String: Link] = [:]
        /// Frame.io file id → ids of its comments imported so far.
        var imported: [String: Set<String>] = [:]
        /// "name|size" → the Frame.io file: every file seen in the browser or the favourites crawl. Nil in older files.
        var seen: [String: Seen]?
    }

    private var loadedState: State?
    private let file: URL?
    private var saveScheduled = false

    /// `directory: nil` keeps everything in memory (tests). Nothing is read here: `shared` is first touched on the main
    /// thread (a clip opening in the Player), and the name/size index can hold tens of thousands of entries.
    init(directory: URL?) {
        file = directory?.appendingPathComponent("frameio-links.json")
    }

    /// The saved links, read from disk on first use (on this actor, off the main thread).
    private var state: State {
        get {
            if let loadedState { return loadedState }
            let loaded = file.flatMap { try? Data(contentsOf: $0) }.flatMap { try? JSONDecoder().decode(State.self, from: $0) } ?? State()
            loadedState = loaded
            return loaded
        }
        set { loadedState = newValue }
    }

    func link(_ url: URL, account: String, fileID: String) {
        let size = Self.size(of: url)
        guard size > 0 else { return }
        state.links[Self.key(url)] = Link(account: account, fileID: fileID, size: size)
        save()
    }

    /// The clip's Frame.io file, if it's linked and still the same size.
    func link(for url: URL) -> Link? {
        guard let link = state.links[Self.key(url)] else { return nil }
        return Self.size(of: url) == link.size ? link : nil
    }

    /// A Frame.io file that's gone (deleted here or on the web): clips linked to it are unlinked and it leaves the
    /// name/size index, so it isn't linked again.
    func forget(fileID: String) {
        let links = state.links.filter { $0.value.fileID != fileID }
        let seen = state.seen?.filter { $0.value.fileID != fileID }
        guard links.count != state.links.count || seen?.count != state.seen?.count else { return }
        state.links = links
        state.seen = seen
        state.imported[fileID] = nil
        save()
    }

    /// Records the files of a listing (stacks: their current version) for matching clips by name and size later.
    func remember(_ items: [FrameIO.Item], account: String) {
        var seen = state.seen ?? [:]
        var changed = false
        for item in items where !item.isFolder {
            let fileID = item.isVersionStack ? item.headVersion?.id : item.id
            let name = item.isVersionStack ? (item.headVersion?.name ?? item.title) : item.title
            guard let fileID, let size = item.displaySize, size > 0 else { continue }
            let entry = Seen(account: account, fileID: fileID)
            if seen[Self.indexKey(name, size)] != entry { seen[Self.indexKey(name, size)] = entry; changed = true }
        }
        guard changed else { return }
        if seen.count > 50_000 { seen = [:] }   // a runaway index starts over rather than growing without bound
        state.seen = seen
        save()
    }

    /// The Frame.io file with this clip's exact name and size, if one was seen.
    func indexed(_ url: URL) -> Seen? {
        let size = Self.size(of: url)
        guard size > 0 else { return nil }
        return state.seen?[Self.indexKey(url.lastPathComponent, size)]
    }

    private static func indexKey(_ name: String, _ size: Int64) -> String { "\(name)|\(size)" }

    func imported(_ fileID: String) -> Set<String> { state.imported[fileID] ?? [] }

    func markImported(_ commentIDs: [String], fileID: String) {
        let before = state.imported[fileID] ?? []
        let after = before.union(commentIDs)
        guard after != before else { return }
        state.imported[fileID] = after
        save()
    }

    /// Writes the links a second after the last change: listings and the favourites crawl (one folder every 0.5 s)
    /// change the index in bursts, and it's rewritten whole.
    private func save() {
        guard file != nil, !saveScheduled else { return }
        saveScheduled = true
        Task {
            try? await Task.sleep(for: .seconds(1))
            self.writeNow()
        }
    }

    private func writeNow() {
        saveScheduled = false
        guard let file, let data = try? JSONEncoder().encode(state) else { return }
        try? FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? data.write(to: file, options: .atomic)
    }

    private static func key(_ url: URL) -> String { url.standardizedFileURL.path }

    private static func size(of url: URL) -> Int64 {
        ((try? FileManager.default.attributesOfItem(atPath: url.path)[.size]) as? NSNumber)?.int64Value ?? 0
    }
}

// MARK: - Comments → notes

/// Turns Frame.io comments into QC notes. Pure, so it's tested directly.
enum FrameIOCommentImport {
    /// Without a timecode, Frame.io's `timestamp` (counted from 1, rounded) is used: notes count from 0.
    static let frameBase = 1
    static let colorTag = "purple"

    /// A note's id from its comment's: the same on every Mac, so importing again (or a collaborator importing too)
    /// updates the note instead of duplicating it.
    static func noteID(_ commentID: String) -> UUID {
        let digest = Array(SHA256.hash(data: Data("frameio-comment:\(commentID)".utf8)))
        var bytes = Array(digest.prefix(16))
        bytes[6] = (bytes[6] & 0x0F) | 0x50   // name-based UUID layout
        bytes[8] = (bytes[8] & 0x3F) | 0x80
        return UUID(uuid: (bytes[0], bytes[1], bytes[2], bytes[3], bytes[4], bytes[5], bytes[6], bytes[7],
                           bytes[8], bytes[9], bytes[10], bytes[11], bytes[12], bytes[13], bytes[14], bytes[15]))
    }

    /// Comments with a frame (not document page comments), as notes: author marked "(Frame.io)", purple, resolved when
    /// completed, replies as the note's replies; a drawing or range is mentioned in the text.
    static func notes(from comments: [FrameIO.Comment], fps: Double) -> [QCFileNote] {
        let start = startFrames(comments, fps: fps)
        return comments.compactMap { comment in
            guard let frame = frame(of: comment, fps: fps, start: start) else { return nil }
            var text = comment.text.trimmingCharacters(in: .whitespacesAndNewlines)
            if let duration = comment.duration, duration > 0 {
                let end = frame + duration
                text += "\n(Range to \(TimecodeFormatter.format(frameIndex: end, fps: fps)), \(duration + 1) frames)"
            }
            if comment.annotation != nil { text += "\n✎ Has a drawing on Frame.io" }
            let replies = (comment.replies ?? []).map { reply in
                QCNoteReply(id: noteID(reply.id), author: author(reply.owner), text: reply.text,
                            createdAt: date(reply.createdAt) ?? .distantPast)
            }
            return QCFileNote(id: noteID(comment.id), frameIndex: frame, timecode: TimecodeFormatter.format(frameIndex: frame, fps: fps),
                              author: author(comment.owner), text: text, colorTag: colorTag,
                              createdAt: date(comment.createdAt) ?? .distantPast, isResolved: comment.completedAt != nil,
                              editedAt: date(comment.textEditedAt), replies: replies)
        }
    }

    /// Adds new comments and updates imported notes (`QCNotesManager.merge`: newer text wins, resolved stays resolved,
    /// new replies added); an imported note's frame follows Frame.io. Comments imported before whose note is gone here
    /// were deleted here: they stay deleted.
    static func merge(local: [QCFileNote], incoming: [QCFileNote], previouslyImported: Set<UUID>)
        -> (notes: [QCFileNote], added: Int, updated: Int) {
        let present = Set(local.map(\.id))
        let wanted = incoming.filter { present.contains($0.id) || !previouslyImported.contains($0.id) }
        var result = QCNotesManager.merge(existing: local, incoming: wanted)
        let positions = Dictionary(wanted.map { ($0.id, ($0.frameIndex, $0.timecode)) }, uniquingKeysWith: { a, _ in a })
        var moved = 0
        for index in result.notes.indices {
            guard present.contains(result.notes[index].id), let (frame, timecode) = positions[result.notes[index].id],
                  result.notes[index].frameIndex != frame else { continue }
            result.notes[index].frameIndex = frame
            result.notes[index].timecode = timecode
            moved += 1
        }
        if moved > 0 { result.notes.sort { $0.frameIndex < $1.frameIndex } }
        return (result.notes, result.added, result.updated + moved)
    }

    /// Where Frame.io's player shows the comment: its timecode as frames from the clip's start, else `timestamp − 1`.
    static func frame(of comment: FrameIO.Comment, fps: Double, start: Int) -> Int? {
        if let timecode = comment.timecode, let frames = frames(timecode, fps: fps) { return max(0, frames - start) }
        return comment.timestamp.map { max(0, $0 - frameBase) }
    }

    /// The file's embedded start timecode in frames (Frame.io's timecodes include it; QC notes count from 0). Each
    /// comment's timecode is start + the rounded-down frame and its `timestamp` the rounded one, so timecode − timestamp
    /// is start or start − 1: the largest difference is the start (0 when they're all 0 or −1).
    static func startFrames(_ comments: [FrameIO.Comment], fps: Double) -> Int {
        let differences = comments.compactMap { comment -> Int? in
            guard let timestamp = comment.timestamp, let timecode = comment.timecode, let frames = frames(timecode, fps: fps) else { return nil }
            return frames - timestamp
        }
        return max(0, differences.max() ?? 0)
    }

    /// "HH:MM:SS:FF" (or drop-frame "HH:MM:SS;FF") as a frame count at the clip's nominal rate.
    static func frames(_ timecode: String, fps: Double) -> Int? {
        let parts = timecode.split(whereSeparator: { $0 == ":" || $0 == ";" || $0 == "." }).compactMap { Int($0) }
        guard parts.count == 4 else { return nil }
        let (hours, minutes, seconds, frames) = (parts[0], parts[1], parts[2], parts[3])
        let base = max(1, Int(fps.rounded()))
        var total = ((hours * 60 + minutes) * 60 + seconds) * base + frames
        if timecode.contains(";") {
            // Drop-frame: 2 frame numbers (4 at 59.94) are skipped each minute except every tenth.
            let drop = base >= 50 ? 4 : 2
            let totalMinutes = hours * 60 + minutes
            total -= drop * (totalMinutes - totalMinutes / 10)
        }
        return total
    }

    private static func author(_ owner: FrameIO.Comment.Owner?) -> String {
        let name = owner?.name?.trimmingCharacters(in: .whitespaces)
        return "\((name?.isEmpty == false ? name : owner?.email) ?? "Frame.io") (Frame.io)"
    }

    private static func date(_ text: String?) -> Date? {
        guard let text else { return nil }
        return (try? Date(text, strategy: Date.ISO8601FormatStyle(includingFractionalSeconds: true)))
            ?? (try? Date(text, strategy: Date.ISO8601FormatStyle()))
    }
}

// MARK: - Importing

/// Imports Frame.io comments into QC notes. The clip shown in the Player is checked when it opens and every 60 s
/// while it stays open (when it's linked); its comments go to `ContentView` (`didFetch`), which merges them into the
/// notes on screen and saves (and syncs) them like any edit. Clips matched from the browser's Import Comments are
/// merged on disk here. Observed only by the Notes drawer's Frame.io bar.
@MainActor
final class FrameIOCommentSync: ObservableObject {
    static let shared = FrameIOCommentSync()

    /// Posted with a `Change` for the clip shown in the Player.
    static let didFetch = Notification.Name("QCpieFrameIOCommentsFetched")

    struct Change {
        let url: URL
        let fileID: String
        let comments: [FrameIO.Comment]
        /// Notes of comments imported before (a missing one was deleted here).
        let previouslyImported: Set<UUID>
        let userInitiated: Bool
    }

    /// The shown clip's link and last check, for the Notes drawer.
    @Published private(set) var activeLinked = false
    @Published private(set) var isChecking = false
    @Published private(set) var lastChecked: Date?
    @Published private(set) var lastError: String?
    /// Signed in to Frame.io (the Notes tab offers linking only then).
    @Published private(set) var signedIn = false
    /// Changes with the clip shown (clears the Notes bar's last message).
    @Published private(set) var activeVersion = 0

    private var activeURL: URL?
    private var poll: Task<Void, Never>?

    private init() {}

    /// The clip whose notes the Player shows (nil: none). Checks it now, then every 60 s.
    func setActive(_ url: URL?) {
        startIndexing()
        guard url?.standardizedFileURL != activeURL?.standardizedFileURL else { return }
        activeURL = url
        activeVersion &+= 1
        Task { signedIn = await FrameIO.shared.isSignedIn }
        activeLinked = false
        lastChecked = nil
        lastError = nil
        poll?.cancel()
        poll = nil
        guard let url else { return }
        poll = Task { [weak self] in
            while !Task.isCancelled {
                await self?.check(url, userInitiated: false)
                try? await Task.sleep(for: .seconds(60))
            }
        }
    }

    /// Signed in or out in the Upload tab: the Notes bar shows or hides its Link button at once (and a newly signed-in
    /// session checks the open clip).
    func signInChanged(_ isSignedIn: Bool) {
        signedIn = isSignedIn
        if isSignedIn, let url = activeURL { Task { await check(url, userInitiated: false) } }
        if !isSignedIn { activeLinked = false; lastChecked = nil; lastError = nil }
    }

    /// Link from Clipboard (Notes tab) and ⌘V in the Player: links the open clip to the Frame.io link on the clipboard.
    /// False when the clipboard holds no Frame.io link (the key isn't swallowed).
    @discardableResult
    func linkActiveFromClipboard(_ report: @escaping @MainActor (String) -> Void) -> Bool {
        guard activeURL != nil, let text = NSPasteboard.general.string(forType: .string), FrameIOLink.looksLikeLink(text) else { return false }
        Task { report(await linkActive(toLink: text)) }
        return true
    }

    /// The Notes drawer's Check Now.
    func checkActive() {
        guard let url = activeURL else { return }
        Task { await check(url, userInitiated: true) }
    }

    /// Records the comments `ContentView` merged, so a note deleted later isn't imported again.
    func didApply(_ change: Change) {
        Task { await FrameIOLinks.shared.markImported(change.comments.map(\.id), fileID: change.fileID) }
    }

    private func check(_ url: URL, userInitiated: Bool) async {
        // Signed out: nothing to ask (the 60 s poll keeps running for when the user signs in again).
        guard await FrameIO.shared.isSignedIn else {
            if isActive(url) { activeLinked = false }
            return
        }
        if await FrameIOLinks.shared.link(for: url) == nil, let seen = await FrameIOLinks.shared.indexed(url) {
            // Same name and size as a Frame.io file seen in the browser or the favourites crawl: link it.
            await FrameIOLinks.shared.link(url, account: seen.account, fileID: seen.fileID)
        }
        guard let link = await FrameIOLinks.shared.link(for: url) else {
            if isActive(url) { activeLinked = false }
            return
        }
        guard isActive(url) else { return }
        activeLinked = true
        isChecking = true
        defer { isChecking = false }
        do {
            let comments = try await FrameIO.shared.comments(account: link.account, file: link.fileID)
            guard isActive(url) else { return }
            lastChecked = Date()
            lastError = nil
            let previous = await FrameIOLinks.shared.imported(link.fileID)
            NotificationCenter.default.post(name: Self.didFetch, object: Change(
                url: url, fileID: link.fileID, comments: comments,
                previouslyImported: Set(previous.map(FrameIOCommentImport.noteID)), userInitiated: userInitiated))
        } catch FrameIO.Failure.http(404, _) {
            // The Frame.io file was deleted: stop asking for it (and showing an error) every minute.
            await FrameIOLinks.shared.forget(fileID: link.fileID)
            guard isActive(url) else { return }
            activeLinked = false
            lastError = nil
        } catch {
            guard isActive(url) else { return }
            lastError = UploadEngine.describe(error)
        }
    }

    private func isActive(_ url: URL) -> Bool { activeURL?.standardizedFileURL == url.standardizedFileURL }

    // MARK: Linking

    /// A folder was listed in the browser: queue clips with the same name and size as a file there (a stack: its current
    /// version) are linked to it. The listing already has names and sizes, so this costs no API calls. The clip open in
    /// the Player is checked at once when it gets linked.
    func linkQueueClips(to items: [FrameIO.Item], account: String) {
        Task { await FrameIOLinks.shared.remember(items, account: account) }
        var clips: [String: [URL]] = [:]
        for job in UploadQueue.shared.jobs where job.files.count == 1 {
            clips["\(job.url.lastPathComponent)|\(job.fileSizes.first ?? 0)", default: []].append(job.url)
        }
        guard !clips.isEmpty else { return }
        var matches: [(URL, String)] = []
        for item in items where !item.isFolder {
            let fileID = item.isVersionStack ? item.headVersion?.id : item.id
            let name = item.isVersionStack ? (item.headVersion?.name ?? item.title) : item.title
            guard let fileID, let size = item.displaySize, size > 0 else { continue }
            for url in clips["\(name)|\(size)"] ?? [] { matches.append((url, fileID)) }
        }
        guard !matches.isEmpty else { return }
        let active = activeURL
        Task {
            var linkedActive = false
            for (url, fileID) in matches where await FrameIOLinks.shared.link(for: url)?.fileID != fileID {
                await FrameIOLinks.shared.link(url, account: account, fileID: fileID)
                if url.standardizedFileURL == active?.standardizedFileURL { linkedActive = true }
            }
            if linkedActive, let active { await check(active, userInitiated: true) }
        }
    }

    /// Links the clip open in the Player to the Frame.io file in a pasted link (⌘V in the Player, or Link from
    /// Clipboard in the Notes tab) and imports its comments. Returns what to tell the user.
    func linkActive(toLink text: String) async -> String {
        guard let url = activeURL else { return "Open a clip first, then paste its Frame.io link." }
        let link: FrameIOLink
        do {
            link = try FrameIOLink.parse(await FrameIOLink.expand(text))
        } catch {
            return (error as? FrameIOLink.Failure)?.errorDescription ?? error.localizedDescription
        }
        guard let asset = link.asset else { return "That's a folder or project link: paste the link of the file itself." }
        guard let accounts = try? await FrameIO.shared.accounts() else { return "Sign in to Frame.io (Upload tab) to link clips." }
        for account in accounts {
            var file = try? await FrameIO.shared.item(account: account.id, kind: "files", id: asset)
            if file == nil, let stack = try? await FrameIO.shared.item(account: account.id, kind: "version_stacks", id: asset),
               let head = stack.headVersion?.id {
                file = try? await FrameIO.shared.item(account: account.id, kind: "files", id: head)
            }
            guard let file else { continue }
            await FrameIOLinks.shared.link(url, account: account.id, fileID: file.id)
            await check(url, userInitiated: true)
            let localSize = ((try? FileManager.default.attributesOfItem(atPath: url.path)[.size]) as? NSNumber)?.int64Value ?? 0
            let sizeNote = file.fileSize.map { $0 != localSize ? " (its size differs from this file: check it's the same export)" : "" } ?? ""
            return "Linked to “\(file.title)” on Frame.io\(sizeNote)"
        }
        return FrameIOLink.Failure.notFound.errorDescription ?? ""
    }

    // MARK: Favourites crawl

    private var indexer: Task<Void, Never>?

    /// Lists the browser's favourite projects and folders (and their subfolders) into the name/size index, so clips
    /// match files nobody opened in the browser: 20 s after launch, then every 30 min. Gentle: one listing at a time,
    /// 0.5 s apart, at most 400 folders per pass, nothing while signed out. Re-checks the open clip when done.
    private func startIndexing() {
        guard indexer == nil else { return }
        indexer = Task { [weak self] in
            try? await Task.sleep(for: .seconds(20))
            while !Task.isCancelled {
                await self?.crawlFavourites()
                try? await Task.sleep(for: .seconds(30 * 60))
            }
        }
    }

    private func crawlFavourites() async {
        guard await FrameIO.shared.isSignedIn else { return }
        var queue: [(account: String, folder: String)] = FrameIOBrowser.shared.favourites.compactMap { favourite in
            guard let account = favourite.path.first?.id, let folder = favourite.path.last?.listedFolder else { return nil }
            return (account, folder)
        }
        var visited = Set<String>()
        while !queue.isEmpty, visited.count < 400, !Task.isCancelled {
            let (account, folder) = queue.removeFirst()
            guard visited.insert(folder).inserted else { continue }
            guard let items = try? await FrameIO.shared.children(account: account, folder: folder, thumbnails: false) else { continue }
            await FrameIOLinks.shared.remember(items, account: account)
            queue += items.filter(\.isFolder).map { (account, $0.id) }
            try? await Task.sleep(for: .milliseconds(500))
        }
        if let active = activeURL, !activeLinked { await check(active, userInitiated: false) }
    }

    // MARK: From the browser

    /// Right-click → Import Comments into QCpie: links each Frame.io file (folders: their files; stacks: the current
    /// version) to the queue clip with the same name and size, then imports its comments. Returns a summary.
    func importComments(_ items: [FrameIO.Item], account: String) async -> String {
        let files: [(fileID: String, name: String, size: Int64, folders: [String])]
        do {
            files = try await DownloadEngine.expand(items, account: account, api: FrameIO.shared,
                                                    retry: NetworkRetry(network: NetworkMonitor.shared))
        } catch {
            return "Couldn't list the files: \(UploadEngine.describe(error))"
        }
        // Single-file queue clips (an image sequence is many Frame.io files), by name and size.
        var clips: [String: [URL]] = [:]
        for job in UploadQueue.shared.jobs where job.files.count == 1 {
            clips["\(job.url.lastPathComponent)|\(job.fileSizes.first ?? 0)", default: []].append(job.url)
        }
        var matched = 0, unmatched = 0, imported = 0, failed = 0
        for file in files {
            guard let urls = clips["\(file.name)|\(file.size)"], !urls.isEmpty else { unmatched += 1; continue }
            do {
                let comments = try await FrameIO.shared.comments(account: account, file: file.fileID)
                for url in urls {
                    matched += 1
                    await FrameIOLinks.shared.link(url, account: account, fileID: file.fileID)
                    imported += await importOnDisk(comments, fileID: file.fileID, into: url)
                }
            } catch {
                failed += 1
            }
        }
        var parts = ["\(imported) new comment\(imported == 1 ? "" : "s") in \(matched) clip\(matched == 1 ? "" : "s")"]
        if unmatched > 0 { parts.append("\(unmatched) file\(unmatched == 1 ? "" : "s") not in the queue") }
        if failed > 0 { parts.append("\(failed) couldn't be read") }
        return "Imported " + parts.joined(separator: " · ")
    }

    /// Merges comments into a clip's notes file; the clip shown in the Player goes through `ContentView` instead.
    /// Returns how many notes were added.
    private func importOnDisk(_ comments: [FrameIO.Comment], fileID: String, into url: URL) async -> Int {
        let previous = Set(await FrameIOLinks.shared.imported(fileID).map(FrameIOCommentImport.noteID))
        if isActive(url) {
            NotificationCenter.default.post(name: Self.didFetch, object: Change(
                url: url, fileID: fileID, comments: comments, previouslyImported: previous, userInitiated: true))
            return comments.filter { !previous.contains(FrameIOCommentImport.noteID($0.id)) && $0.timestamp != nil }.count
        }
        let fps = await Self.frameRate(of: url)
        let local = await QCNotesManager.shared.loadNotes(for: url)
        let incoming = FrameIOCommentImport.notes(from: comments, fps: fps)
        let result = FrameIOCommentImport.merge(local: local, incoming: incoming, previouslyImported: previous)
        if result.added + result.updated > 0 {
            await QCNotesManager.shared.saveNotes(result.notes, for: url, fps: fps)
            await NotesSync.shared.push(url)
        }
        await FrameIOLinks.shared.markImported(comments.map(\.id), fileID: fileID)
        return result.added
    }

    /// The frame rate notes are timed in: the one their file already records, else the video track's.
    nonisolated private static func frameRate(of url: URL) async -> Double {
        if let stored = await QCNotesManager.shared.storedFps(for: url), stored > 0 { return stored }
        let asset = AVURLAsset(url: url)
        if let track = try? await asset.loadTracks(withMediaType: .video).first,
           let rate = try? await track.load(.nominalFrameRate), rate > 0 {
            return Double(rate)
        }
        return 25
    }
}
