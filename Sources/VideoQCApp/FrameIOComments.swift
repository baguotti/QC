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
        /// Frame.io file id → [QC note id: the comment it was sent as] (Send to Frame.io). Nil in older files.
        var sent: [String: [String: String]]?
        /// Version stack id → the file ids that have been its current version (latest last, ≤ 20), from the favourites
        /// crawl: a head seen before (a version removed from the top) isn't a new version.
        var heads: [String: [String]]?
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
        state.sent?[fileID] = nil
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

    /// Records the stacks' current versions and returns those with a new one since the last look: a version never
    /// seen as their head before, and not a file linked here (uploaded or downloaded by QCpie, so not news). A stack seen
    /// for the first time is only recorded.
    func updateHeads(_ items: [FrameIO.Item]) -> [(stack: FrameIO.Item, head: FrameIO.Item.Head)] {
        var heads = state.heads ?? [:]
        var changed: [(stack: FrameIO.Item, head: FrameIO.Item.Head)] = []
        let linked = Set(state.links.values.map(\.fileID))
        for item in items where item.isVersionStack {
            guard let head = item.headVersion, heads[item.id]?.last != head.id else { continue }
            if let known = heads[item.id], !known.contains(head.id), !linked.contains(head.id) { changed.append((item, head)) }
            heads[item.id] = Array(((heads[item.id] ?? []).filter { $0 != head.id } + [head.id]).suffix(20))
        }
        if heads != (state.heads ?? [:]) {
            state.heads = heads.count > 50_000 ? [:] : heads
            save()
        }
        return changed
    }

    /// Comment id → the QC note it was sent from, for the notes of this file sent to Frame.io.
    func sent(_ fileID: String) -> [String: UUID] {
        Dictionary((state.sent?[fileID] ?? [:]).compactMap { note, comment in UUID(uuidString: note).map { (comment, $0) } },
                   uniquingKeysWith: { a, _ in a })
    }

    /// Written at once (not a second later like the rest): losing it to a quit would send the note again.
    func markSent(note: UUID, comment: String, fileID: String) {
        var sent = state.sent ?? [:]
        sent[fileID, default: [:]][note.uuidString] = comment
        state.sent = sent
        writeNow()
    }

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
    static let colorTag = QCNoteTheme.frameIOTag

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
    /// completed, replies as the note's replies; a drawing or range is mentioned in the text. A comment sent from a QC
    /// note (`sent`: comment id → note id) comes back as an echo of that note instead: its id, no text and the oldest
    /// date (so `merge` never takes its text or tag), resolved when completed, and Frame.io's replies.
    static func notes(from comments: [FrameIO.Comment], fps: Double, sent: [String: UUID] = [:]) -> [QCFileNote] {
        let start = startFrames(comments, fps: fps)
        return comments.compactMap { comment in
            if let note = sent[comment.id] {
                return QCFileNote(id: note, frameIndex: 0, timecode: "", author: "", text: "", colorTag: "",
                                  createdAt: .distantPast, isResolved: comment.completedAt != nil, replies: replies(of: comment))
            }
            guard let frame = frame(of: comment, fps: fps, start: start) else { return nil }
            var text = comment.text.trimmingCharacters(in: .whitespacesAndNewlines)
            if let duration = comment.duration, duration > 0 {
                let end = frame + duration
                text += "\n(Range to \(TimecodeFormatter.format(frameIndex: end, fps: fps)), \(duration + 1) frames)"
            }
            if comment.annotation != nil { text += "\n✎ Has a drawing on Frame.io" }
            return QCFileNote(id: noteID(comment.id), frameIndex: frame, timecode: TimecodeFormatter.format(frameIndex: frame, fps: fps),
                              author: author(comment.owner), text: text, colorTag: colorTag,
                              createdAt: date(comment.createdAt) ?? .distantPast, isResolved: comment.completedAt != nil,
                              editedAt: date(comment.textEditedAt), replies: replies(of: comment))
        }
    }

    private static func replies(of comment: FrameIO.Comment) -> [QCNoteReply] {
        (comment.replies ?? []).map { reply in
            QCNoteReply(id: noteID(reply.id), author: author(reply.owner), text: reply.text, createdAt: date(reply.createdAt) ?? .distantPast)
        }
    }

    /// Adds new comments and updates imported notes (`QCNotesManager.merge`: newer text wins, resolved stays resolved,
    /// new replies added); an imported note's frame follows Frame.io. Comments imported before whose note is gone here
    /// were deleted here: they stay deleted. Echoes of sent notes (`sent`) only update the note they came from (its
    /// replies and resolved): one deleted here isn't brought back, and its frame stays the note's.
    static func merge(local: [QCFileNote], incoming: [QCFileNote], previouslyImported: Set<UUID>, sent: Set<UUID> = [])
        -> (notes: [QCFileNote], added: Int, updated: Int) {
        let present = Set(local.map(\.id))
        let wanted = incoming.filter { present.contains($0.id) || (!previouslyImported.contains($0.id) && !sent.contains($0.id)) }
        var result = QCNotesManager.merge(existing: local, incoming: wanted)
        let positions = Dictionary(wanted.filter { !sent.contains($0.id) }.map { ($0.id, ($0.frameIndex, $0.timecode)) },
                                   uniquingKeysWith: { a, _ in a })
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
    /// Without either: frame 0 (comments on a still image, or a video comment not tied to a time), except PDF page
    /// comments, which have no place in a clip.
    static func frame(of comment: FrameIO.Comment, fps: Double, start: Int) -> Int? {
        if let timecode = comment.timecode, let frames = frames(timecode, fps: fps) { return max(0, frames - start) }
        if let timestamp = comment.timestamp { return max(0, timestamp - frameBase) }
        return comment.page == nil ? 0 : nil
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
        /// Comments sent from QC notes: comment id → note id (they update that note).
        let sent: [String: UUID]
        let userInitiated: Bool
        /// A minute check after the first one: new comments in it are news (notifications).
        var routine = false
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
    /// The shown clip's notes that came from Frame.io and that were sent to it: the rest can be sent.
    @Published private(set) var activeImported: Set<UUID> = []
    @Published private(set) var activeSent: Set<UUID> = []
    @Published private(set) var isSending = false
    private var activeLink: FrameIOLinks.Link?
    /// The shown clip has been checked once (its existing comments imported).
    private var checkedActive = false

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
        activeLink = nil
        checkedActive = false
        activeImported = []
        activeSent = []
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
        if !isSignedIn { activeLinked = false; activeLink = nil; lastChecked = nil; lastError = nil }
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
        // What was imported from and sent to this file: known before asking Frame.io, so Send works even when the
        // check fails (offline, rate limited).
        let previous = Set(await FrameIOLinks.shared.imported(link.fileID).map(FrameIOCommentImport.noteID))
        let sent = await FrameIOLinks.shared.sent(link.fileID)
        guard isActive(url) else { return }
        activeLinked = true
        activeLink = link
        activeImported = previous
        activeSent = Set(sent.values)
        isChecking = true
        defer { isChecking = false }
        do {
            let comments = try await FrameIO.shared.comments(account: link.account, file: link.fileID)
            guard isActive(url) else { return }
            lastChecked = Date()
            lastError = nil
            // While notes are being sent, comments they just created may not be recorded as sent yet: they'd be
            // imported as new notes (duplicates of the sent ones). The next check applies them.
            guard !isSending else { return }
            // Read again after the fetch: a send that finished meanwhile recorded its comments.
            let sentNow = await FrameIOLinks.shared.sent(link.fileID)
            guard isActive(url), !isSending else { return }
            activeSent = Set(sentNow.values)
            // The first check after the clip opens imports what's already there: only later ones are news.
            let routine = checkedActive
            checkedActive = true
            NotificationCenter.default.post(name: Self.didFetch, object: Change(
                url: url, fileID: link.fileID, comments: comments, previouslyImported: previous, sent: sentNow,
                userInitiated: userInitiated, routine: routine && !userInitiated))
        } catch FrameIO.Failure.http(404, _) {
            // The Frame.io file was deleted: stop asking for it (and showing an error) every minute.
            await FrameIOLinks.shared.forget(fileID: link.fileID)
            guard isActive(url) else { return }
            activeLinked = false
            activeLink = nil
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

    // MARK: Sending notes

    /// The Notes drawer's Send to Frame.io: the shown clip's notes written in QCpie and not sent yet, as comments on its
    /// Frame.io file. Returns what to tell the user.
    func sendActive(_ notes: [QCFileNote]) async -> String {
        guard !isSending else { return "Already sending notes" }
        guard let url = activeURL, let link = activeLink else { return "Link this clip to its Frame.io file first." }
        let sentSoFar = Set(await FrameIOLinks.shared.sent(link.fileID).values).union(activeSent)
        guard !isSending, isActive(url) else { return "Already sending notes" }
        let pending = FrameIOCommentPush.pending(notes, imported: activeImported, sent: sentSoFar)
        guard !pending.isEmpty else { return "Every note is already on Frame.io" }
        isSending = true
        defer { isSending = false }
        let outcome = await send(pending, account: link.account, fileID: link.fileID, clip: url)
        if isActive(url) { activeSent.formUnion(outcome.sent.map(\.note)) }
        return FrameIOCommentPush.summary(sent: outcome.sent.count, clips: 1, failures: outcome.failures)
    }

    /// What right-click → Send QC Notes to Frame.io would send: the items' files (folders: every file; stacks: the
    /// current version) matched to queue clips by name and size, with each clip's unsent notes.
    struct SendPlan: Sendable {
        let account: String
        let clips: [(url: URL, fileID: String, notes: [QCFileNote])]
        let unmatched: Int
        var noteCount: Int { clips.reduce(0) { $0 + $1.notes.count } }
    }

    func planSend(_ items: [FrameIO.Item], account: String) async throws -> SendPlan {
        let files = try await DownloadEngine.expand(items, account: account, api: FrameIO.shared,
                                                    retry: NetworkRetry(network: NetworkMonitor.shared))
        let clips = queueClipsByNameAndSize()
        var planned: [(url: URL, fileID: String, notes: [QCFileNote])] = []
        var unmatched = 0
        for file in files {
            guard let urls = clips["\(file.name)|\(file.size)"], !urls.isEmpty else { unmatched += 1; continue }
            let imported = Set(await FrameIOLinks.shared.imported(file.fileID).map(FrameIOCommentImport.noteID))
            let sent = Set(await FrameIOLinks.shared.sent(file.fileID).values)
            for url in urls {
                let notes = FrameIOCommentPush.pending(await QCNotesManager.shared.loadNotes(for: url), imported: imported, sent: sent)
                if !notes.isEmpty { planned.append((url, file.fileID, notes)) }
            }
        }
        return SendPlan(account: account, clips: planned, unmatched: unmatched)
    }

    func send(_ plan: SendPlan) async -> String {
        guard !isSending else { return "Already sending notes" }
        isSending = true
        defer { isSending = false }
        var sent = 0
        var failures: [String] = []
        for clip in plan.clips {
            // Checked again now: notes may have been sent since the plan was made (the Notes bar, another plan).
            let already = Set(await FrameIOLinks.shared.sent(clip.fileID).values)
            let notes = clip.notes.filter { !already.contains($0.id) }
            guard !notes.isEmpty else { continue }
            await FrameIOLinks.shared.link(clip.url, account: plan.account, fileID: clip.fileID)
            let outcome = await send(notes, account: plan.account, fileID: clip.fileID, clip: clip.url)
            sent += outcome.sent.count
            failures += outcome.failures
            if isActive(clip.url), activeLink?.fileID == clip.fileID { activeSent.formUnion(outcome.sent.map(\.note)) }
            if failures.contains(FrameIOCommentPush.signedOutMessage) { break }
        }
        return FrameIOCommentPush.summary(sent: sent, clips: plan.clips.count, failures: failures)
    }

    /// Sends notes as comments and records each one as it lands, so a note is never sent twice (even if the rest fail).
    /// A still image's comments carry no frame (Frame.io refuses a timestamp on images).
    private func send(_ notes: [QCFileNote], account: String, fileID: String, clip: URL) async -> FrameIOCommentPush.Outcome {
        await FrameIOCommentPush.run(notes, account: account, file: fileID, signedInName: FrameIOBrowser.shared.userName,
                                     timed: QCUtilities.mediaKind(of: clip) != .image, api: FrameIO.shared) { note, comment in
            await FrameIOLinks.shared.markSent(note: note, comment: comment, fileID: fileID)
        }
    }

    /// Single-file queue clips (an image sequence is many Frame.io files) by "name|size".
    private func queueClipsByNameAndSize() -> [String: [URL]] {
        var clips: [String: [URL]] = [:]
        for job in UploadQueue.shared.jobs where job.files.count == 1 {
            clips["\(job.url.lastPathComponent)|\(job.fileSizes.first ?? 0)", default: []].append(job.url)
        }
        return clips
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
        var newVersions: [(stack: String, file: String)] = []
        while !queue.isEmpty, visited.count < 400, !Task.isCancelled {
            let (account, folder) = queue.removeFirst()
            guard visited.insert(folder).inserted else { continue }
            guard let items = try? await FrameIO.shared.children(account: account, folder: folder, thumbnails: false) else { continue }
            await FrameIOLinks.shared.remember(items, account: account)
            for (stack, head) in await FrameIOLinks.shared.updateHeads(items) where !Notifier.shared.ownUploads.contains(head.id) {
                newVersions.append((stack.title, head.name ?? stack.title))
            }
            queue += items.filter(\.isFolder).map { (account, $0.id) }
            try? await Task.sleep(for: .milliseconds(500))
        }
        if let message = NotificationText.versions(newVersions) { Notifier.shared.post(.versions, message) }
        if let active = activeURL, !activeLinked { await check(active, userInitiated: false) }
    }

    // MARK: From the browser

    /// Right-click → Import Comments into QCpie: links each Frame.io file (folders: their files; stacks: the current
    /// version) to the queue clip with the same name and size, then imports its comments. Returns a summary.
    func importComments(_ items: [FrameIO.Item], account: String) async -> String {
        // Comments being created by a send aren't recorded as sent yet: importing now would duplicate them.
        guard !isSending else { return "Wait for the notes being sent to Frame.io, then import again" }
        let files: [(fileID: String, name: String, size: Int64, folders: [String])]
        do {
            files = try await DownloadEngine.expand(items, account: account, api: FrameIO.shared,
                                                    retry: NetworkRetry(network: NetworkMonitor.shared))
        } catch {
            return "Couldn't list the files: \(UploadEngine.describe(error))"
        }
        let clips = queueClipsByNameAndSize()
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
        let sent = await FrameIOLinks.shared.sent(fileID)
        if isActive(url) {
            NotificationCenter.default.post(name: Self.didFetch, object: Change(
                url: url, fileID: fileID, comments: comments, previouslyImported: previous, sent: sent, userInitiated: true))
            return comments.filter { sent[$0.id] == nil && !previous.contains(FrameIOCommentImport.noteID($0.id)) && $0.page == nil }.count
        }
        let fps = await Self.frameRate(of: url)
        let local = await QCNotesManager.shared.loadNotes(for: url)
        let incoming = FrameIOCommentImport.notes(from: comments, fps: fps, sent: sent)
        let result = FrameIOCommentImport.merge(local: local, incoming: incoming, previouslyImported: previous, sent: Set(sent.values))
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
