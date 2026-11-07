import Foundation
import SwiftUI
import VideoQCLib

/// The plan's Frame.io folder scan, listed folders, extras and mismatches (and dismissing them).
extension DeliveryPlanStore {
    /// The Frame.io project or folder that holds the plan's files. Only its tree is read for the plan: links found while
    /// listing, "on Frame.io" and "on Frame.io, not in the plan" come from it alone, so they don't depend on what was
    /// browsed or favourited. Set once per plan (••• → Frame.io Folder…).
    struct FrameIORoot: Codable, Equatable, Sendable {
        let account: String
        /// The folder listed (a project: its root folder).
        let folder: String
        /// "Project › Folder", for display.
        let title: String
    }

    /// The tree's folders as of the last full scan (`frameio-tree.json`).
    struct RootTree: Codable, Sendable {
        let root: String
        let folders: [String]
        let scanned: Date
    }

    enum RootScan: Equatable { case idle, scanning(Int), done(Date), failed(String) }

    static let rootScanInterval: TimeInterval = 15 * 60
    static let rootScanFolderLimit = 1000

    /// Binds the plan to a Frame.io folder (nil: none). What was listed elsewhere is dropped and the tree is read.
    func setFrameIORoot(_ root: FrameIORoot?) {
        guard var config, config.frameioRoot != root else { return }
        config.frameioRoot = root
        self.config = config
        saveConfig()
        rootScanTask?.cancel(); rootScanTask = nil
        rootFolders = root.map { [$0.folder] } ?? []
        linkSuggestions = [:]   // found in the old folder
        lastRootScan = nil
        rootScan = .idle
        frameioFolders = [:]
        saveFrameIOFolders()
        saveRootTree(nil)
        scheduleRecompute()
        if root != nil { scanFrameIORoot() }
    }

    /// Whether a listing of `folder` is the plan's: anything without a bound folder, else only its tree.
    func inPlanTree(_ folder: String?) -> Bool {
        guard let root = config?.frameioRoot else { return true }
        guard let folder else { return false }
        return folder == root.folder || rootFolders.contains(folder)
    }

    /// Every 15 minutes while a plan panel is on screen (and on opening one).
    func scanFrameIORootIfDue() {
        guard config?.frameioRoot != nil, rootScanTask == nil else { return }
        if let last = lastRootScan, Date().timeIntervalSince(last) < Self.rootScanInterval { return }
        scanFrameIORoot()
    }

    func scanFrameIORoot() {
        guard let root = config?.frameioRoot, let link = config?.link, rootScanTask == nil else { return }
        let token = UUID()
        rootScanToken = token
        rootScanTask = Task { [weak self] in
            await self?.runRootScan(root, link: link)
            // A scan cancelled for a new folder mustn't clear the new scan's handle.
            if self?.rootScanToken == token { self?.rootScanTask = nil }
        }
    }

    /// Lists the tree breadth-first, one folder at a time (0.4 s apart: Frame.io's rate limits, and the browser shares
    /// them). Each listing goes through `FrameIOLinks.remember` like a browsed one (link index, plan links, extras).
    /// A complete scan replaces the tree, so folders moved out or deleted leave the plan.
    private func runRootScan(_ root: FrameIORoot, link: PlanSheetLink) async {
        guard await FrameIO.shared.isSignedIn else {
            let failure = RootScan.failed("Sign in to Frame.io (Upload tab) to read the plan's folder.")
            if rootScan != failure { rootScan = failure }
            lastRootScan = Date().addingTimeInterval(60 - Self.rootScanInterval)   // look again in a minute
            return
        }
        rootScan = .scanning(0)
        var queue = [root.folder]
        var tree: Set<String> = [root.folder]
        var listed = 0
        while !queue.isEmpty, listed < Self.rootScanFolderLimit {
            if Task.isCancelled { return }
            let folder = queue.removeFirst()
            let items: [FrameIO.Item]
            do {
                items = try await FrameIO.shared.children(account: root.account, folder: folder, thumbnails: false)
            } catch {
                guard config?.frameioRoot == root else { return }
                if folder == root.folder {
                    rootScan = .failed("Couldn't read the plan's Frame.io folder: \(UploadEngine.describe(error))")
                    lastRootScan = Date().addingTimeInterval(120 - Self.rootScanInterval)   // again in two minutes
                    return
                }
                continue   // one unreadable subfolder doesn't stop the scan (its old listing stays)
            }
            guard config?.frameioRoot == root, config?.link == link else { return }
            for item in items where item.isFolder && tree.insert(item.id).inserted {
                queue.append(item.id)
                rootFolders.insert(item.id)
            }
            await FrameIOLinks.shared.remember(items, account: root.account, folder: folder)
            listed += 1
            if listed % 10 == 0 { rootScan = .scanning(listed) }
            try? await Task.sleep(for: .milliseconds(400))
        }
        guard !Task.isCancelled, config?.frameioRoot == root else { return }
        let complete = queue.isEmpty
        if complete {
            rootFolders = tree
            frameioFolders = frameioFolders.filter { tree.contains($0.key) }
            saveFrameIOFolders()
        }
        let now = Date()
        lastRootScan = now
        saveRootTree(RootTree(root: root.folder, folders: Array(rootFolders), scanned: now))
        rootScan = complete ? .done(now) : .failed("The plan's Frame.io folder has more than \(Self.rootScanFolderLimit) folders: only those were read. Pick a smaller folder.")
        scheduleRecompute()
    }

    private func saveRootTree(_ tree: RootTree?) {
        guard let config else { return }
        let file = Self.directory(config.link.sheetID).appendingPathComponent("frameio-tree.json")
        Task.detached(priority: .utility) {
            if let tree { JSONFile.save(tree, to: file, log: .plan) } else { JSONFile.remove(file, log: .plan) }
        }
    }

    /// "Project › Folder" for a browser path.
    nonisolated static func rootTitle(_ path: [FrameIOBrowser.Crumb]) -> String {
        path.filter { $0.level == .project || $0.level == .folder }.map(\.title).joined(separator: " › ")
    }

    /// The folder a pasted Frame.io project or folder link points to (a file link: the folder holding it).
    func frameIORoot(fromLink text: String) async throws -> FrameIORoot {
        let link = try FrameIOLink.parse(await FrameIOLink.expand(text))
        let (path, _) = try await FrameIOLink.resolve(link, preferredAccount: FrameIOBrowser.shared.accountID)
        guard let account = path.first?.id, let folder = path.last(where: { $0.listedFolder != nil })?.listedFolder else {
            throw FrameIOLink.Failure.notFound
        }
        let folders = path.prefix { $0.listedFolder != nil || $0.level == .account || $0.level == .workspace }
        return FrameIORoot(account: account, folder: folder, title: Self.rootTitle(Array(folders)))
    }



    nonisolated static func mismatchKey(_ rowID: String, _ kind: PlanMismatch, link: String, newest: Date?) -> String {
        let id = frameIOID(link) ?? ""
        // "Another version" comes back when the local file changes again.
        let stamp = kind == .differs ? newest.map { String(Int($0.timeIntervalSince1970)) } ?? "" : ""
        return "\(rowID)|\(kind.rawValue)|\(id)|\(stamp)"
    }

    /// Dismisses the rows' current mismatches (`kind` nil: all of them).
    func dismissMismatches(_ kind: PlanMismatch? = nil, rowIDs: [String]) {
        let ids = Set(rowIDs)
        let dates = Dictionary(files.compactMap { f in f.modified.map { (f.url, $0) } }, uniquingKeysWith: { a, _ in a })
        var keys: [String] = []
        for row in rows where ids.contains(row.id) {
            let newest = match.result(row).files.compactMap { dates[$0] }.max()
            for found in state(row).mismatches where kind == nil || found == kind {
                keys.append(Self.mismatchKey(row.id, found, link: frameioLink(row), newest: newest))
            }
        }
        dismiss(keys)
    }

    func dismissFrameIOExtras(_ urls: [String]) { dismiss(urls.map { "fx|" + (Self.frameIOID($0) ?? $0) }) }
    func dismissLocalExtras(_ urls: [URL]) { dismiss(urls.map { "lx|" + $0.path }) }

    func restoreDismissedMismatches() {
        guard !dismissedMismatches.isEmpty else { return }
        dismissedMismatches = []
        saveDismissed()
        scheduleRecompute()
    }

    func dismiss(_ keys: [String]) {
        let before = dismissedMismatches.count
        dismissedMismatches.formUnion(keys)
        guard dismissedMismatches.count != before else { return }
        saveDismissed()
        recomputeStates()
        publishGrids()
    }

    /// One write at a time, the latest set (separate detached writes could land out of order).
    private func saveDismissed() {
        guard let config else { return }
        let dir = Self.directory(config.link.sheetID)
        let previous = dismissedSaveTask
        let keys = dismissedMismatches.sorted()
        dismissedSaveTask = Task {
            await previous?.value
            await Task.detached(priority: .utility) {
                _ = JSONFile.save(keys, to: dir.appendingPathComponent("dismissed-mismatches.json"), log: .plan)
            }.value
        }
    }

    /// A file seen in a Frame.io folder listing (stacks: the stack's link with its current version's name and size).
    struct ListedFile: Codable, Equatable, Sendable {
        let name: String
        let url: String
        let size: Int64
        /// Stacks: the current version's id (a row may link the version rather than the stack).
        var head: String? = nil
        var ids: [String] { [DeliveryPlanStore.frameIOID(url), head].compactMap { $0 } }
        func isLinked(in linked: Set<String>) -> Bool { ids.contains(where: linked.contains) }
    }

    /// The Frame.io id a link ends with ("…/view/<id>?…"), nil for an empty link.
    nonisolated static func frameIOID(_ link: String) -> String? {
        let path = link.split(separator: "?").first.map(String.init) ?? link
        let id = path.split(separator: "/").last.map(String.init) ?? ""
        return id.isEmpty ? nil : id.lowercased()
    }

    func recordListing(_ items: [FrameIO.Item], folder: String?) {
        guard let folder = folder ?? items.first(where: { !$0.isFolder })?.parentID else { return }
        let files = items.filter { !$0.isFolder }.compactMap { item -> ListedFile? in
            guard let url = item.viewURL else { return nil }
            return ListedFile(name: Self.listedName(item), url: PlanGrid.normalized(url), size: item.displaySize ?? 0,
                              head: item.isVersionStack ? item.headVersion?.id.lowercased() : nil)
        }
        let next: [ListedFile]?
        if config?.frameioRoot != nil {
            next = files   // every folder of the plan's tree, plan files or not
        } else {
            let links = Set(rows.compactMap { Self.frameIOID(frameioLink($0)) })
            let holdsPlanFiles = files.contains { $0.isLinked(in: links) || !codes(inFileNamed: $0.name).isEmpty }
            next = holdsPlanFiles ? files : nil
        }
        guard frameioFolders[folder] != next else { return }
        frameioFolders[folder] = next
        saveFrameIOFolders()
        scheduleRecompute()
    }

    private func saveFrameIOFolders() {
        guard let config else { return }
        let dir = Self.directory(config.link.sheetID)
        foldersSaveTask?.cancel()
        foldersSaveTask = Task {
            try? await Task.sleep(for: .seconds(2))
            guard !Task.isCancelled else { return }
            let folders = frameioFolders
            await Task.detached(priority: .utility) {
                _ = JSONFile.save(folders, to: dir.appendingPathComponent("frameio-folders.json"), log: .plan)
            }.value
        }
    }

    /// Why a Frame.io file in a plan folder has no row: none has its code, its row links another file, or it's unlinked.
    /// `linkedCodes`: lower-case code → whether every row with it has a link.
    func extraNote(_ name: String, linkedCodes: [String: Bool]) -> String {
        guard let code = codes(inFileNamed: name).sorted().first else { return "No row has this file's code." }
        return linkedCodes[code] == true
            ? "Another file for \(code.uppercased()): its row links a different one."
            : "Looks like \(code.uppercased())'s file: link it from the row."
    }

    /// When a listed item last reached Frame.io: a file's creation; a stack's last change (its newest version).
    nonisolated static func listedDate(_ item: FrameIO.Item) -> Date? {
        item.isVersionStack ? (item.updatedDate ?? item.createdDate) : item.createdDate
    }

    /// States and grids once, 0.3 s after the last of a burst of automatic writes.
    func scheduleRecompute() {
        recomputeTask?.cancel()
        recomputeTask = Task {
            try? await Task.sleep(for: .milliseconds(300))
            guard !Task.isCancelled else { return }
            recomputeStates()
            publishGrids()
        }
    }

    /// A listed file's name (stacks: their current version's).
    nonisolated static func listedName(_ item: FrameIO.Item) -> String {
        item.isVersionStack ? (item.headVersion?.name ?? item.title) : item.title
    }

    /// A name compared without extension, case or separators ("A_20s.mp4" = "a 20s").
    nonisolated static func nameKey(_ name: String) -> String {
        PlanMatcher.tokens((name as NSString).deletingPathExtension).joined(separator: " ")
    }

    /// The row's name without its code at the end ("…_20s_KL0140" → "…_20s").
    nonisolated static func strippingCode(_ row: PlanRow) -> String {
        guard let code = row.code, !code.isEmpty else { return row.name }
        let tokens = PlanMatcher.tokens(row.name), codeTokens = PlanMatcher.tokens(code)
        guard tokens.count > codeTokens.count, Array(tokens.suffix(codeTokens.count)) == codeTokens else { return row.name }
        return tokens.dropLast(codeTokens.count).joined(separator: " ")
    }

    func exactNameIndex() -> (local: [String: Set<String>], bare: [String: Set<String>]) {
        if let nameIndex, nameIndex.rows == rowsVersion, nameIndex.match == matchRevision { return (nameIndex.local, nameIndex.bare) }
        var local: [String: Set<String>] = [:], bare: [String: Set<String>] = [:]
        for row in rows {
            guard let code = row.code?.lowercased(), !code.isEmpty else { continue }
            bare[Self.nameKey(Self.strippingCode(row)), default: []].insert(code)
            for url in match.result(row).files { local[Self.nameKey(url.lastPathComponent), default: []].insert(code) }
        }
        nameIndex = (rowsVersion, matchRevision, local, bare)
        return (local, bare)
    }

    /// Scans the Frame.io favourites and the projects the plan's links already point to now, instead of waiting for the
    /// 30-minute background scan; rows without a link get one as listings come in (the same rules as browsing).
    func findFrameIOLinks() async {
        guard !searchingLinks else { return }
        guard hasQCTab else {
            showLinkSearch("Set up the QCpie tab first (Delivery Plan ••• menu).")
            return
        }
        if config?.frameioRoot != nil {
            let before = linkedCodes()
            linkSearch = "Reading the plan's Frame.io folder…"
            scanFrameIORoot()
            await rootScanTask?.value
            try? await Task.sleep(for: .milliseconds(500))   // the last listings reach the plan on the main actor
            if case .failed(let message) = rootScan { showLinkSearch(message); return }
            let found = linkedCodes().subtracting(before).count
            showLinkSearch(found == 0 ? "No new Frame.io links found." : "Found \(found) Frame.io link\(found == 1 ? "" : "s").")
            return
        }
        searchingLinks = true
        defer { searchingLinks = false }
        let before = linkedCodes()
        let link = config?.link
        linkSearch = "Looking on Frame.io…"
        let projects = Set(rows.compactMap { row -> String? in
            let link = frameioLink(row)
            return link.isEmpty ? nil : (try? FrameIOLink.parse(link))?.project
        })
        let ran = await FrameIOCommentSync.shared.scanNow(projects: projects)
        try? await Task.sleep(for: .milliseconds(500))   // the last listings reach the plan on the main actor
        guard config?.link == link else { linkSearch = nil; return }   // another sheet was linked meanwhile
        let found = linkedCodes().subtracting(before).count
        showLinkSearch(!ran ? "Sign in to Frame.io (Upload tab), or wait for the scan already running."
                       : found == 0 ? "No new Frame.io links found." : "Found \(found) Frame.io link\(found == 1 ? "" : "s").")
    }

    private func linkedCodes() -> Set<String> {
        Set(rows.compactMap { row in frameioLink(row).isEmpty ? nil : row.code?.lowercased() })
    }

    private func showLinkSearch(_ text: String) {
        linkSearch = text
        linkSearchClear?.cancel()
        linkSearchClear = Task {
            try? await Task.sleep(for: .seconds(8))
            guard !Task.isCancelled else { return }
            linkSearch = nil
        }
    }

    /// A linked file answered 404 to a comment check: if Frame.io confirms it's gone (a second 404 for the file itself),
    /// rows linked to it lose the link. A file still processing, or a hiccup, keeps it.
    func frameIOFileMissing(account: String, fileID: String) async {
        guard rows.contains(where: { frameioLink($0).hasSuffix("/" + fileID) }) else { return }
        do {
            _ = try await FrameIO.shared.item(account: account, kind: "files", id: fileID)
        } catch FrameIO.Failure.http(404, _) {
            frameIOGone([fileID])
        } catch {}
    }

    /// Frame.io files or stacks deleted (in the browser, or found gone): rows linked to them lose the link.
    func frameIOGone(_ ids: Set<String>) {
        guard !ids.isEmpty else { return }
        // Out of the listed folders too, or the file would show as "on Frame.io, not in the plan" until relisted.
        let goneIDs = Set(ids.map { $0.lowercased() })
        var dropped = false
        // By the item's own id: a stack's current version going doesn't take the stack with it.
        func gone(_ file: ListedFile) -> Bool { Self.frameIOID(file.url).map(goneIDs.contains) ?? false }
        for (folder, files) in frameioFolders where files.contains(where: gone) {
            frameioFolders[folder] = files.filter { !gone($0) }
            dropped = true
        }
        if dropped { saveFrameIOFolders(); scheduleRecompute() }
        let staleSuggestions = linkSuggestions.filter { goneIDs.contains($0.value.fileID) }.map(\.key)
        for key in staleSuggestions { linkSuggestions[key] = nil }
        let targets = rows.filter { row in
            let link = frameioLink(row)
            return !link.isEmpty && ids.contains { link.hasSuffix("/" + $0) || link.contains("/" + $0 + "?") }
        }
        guard !targets.isEmpty else { return }
        queueQC(targets, quiet: true) { item in item[.frameio] = ""; item[.uploaded] = "" }
    }

    /// Link Frame.io File…: a pasted Frame.io file or stack link goes into the rows' Frame.io column (a link set by hand
    /// is never replaced by one found while browsing). Failures show in the status line.
    func linkFrameIO(_ text: String, rowIDs: [String]) async {
        if let failure = await linkFrameIOFailure(text, rowIDs: rowIDs) { editState = .failed(failure) }
    }

    /// Nil when linked, else why not.
    private func linkFrameIOFailure(_ text: String, rowIDs: [String]) async -> String? {
        let link: FrameIOLink
        do {
            link = try FrameIOLink.parse(await FrameIOLink.expand(text))
        } catch {
            return (error as? FrameIOLink.Failure)?.errorDescription ?? error.localizedDescription
        }
        guard let asset = link.asset else { return "That's a folder or project link: paste the link of the file itself." }
        guard let accounts = try? await FrameIO.shared.accounts() else { return "Sign in to Frame.io (Upload tab) to check the link." }
        for account in accounts {
            var found = try? await FrameIO.shared.item(account: account.id, kind: "files", id: asset)
            if found == nil { found = try? await FrameIO.shared.item(account: account.id, kind: "version_stacks", id: asset) }
            guard let item = found, let url = item.viewURL else { continue }
            let ids = Set(rowIDs)
            let date = Self.listedDate(item)
            queueQC(rows.filter { ids.contains($0.id) }) { entry in
                entry[.frameio] = url
                if let date { entry[.uploaded] = Self.uploadStamp(date) }
            }
            return nil
        }
        return FrameIOLink.Failure.notFound.errorDescription ?? "That file wasn't found in your Frame.io accounts."
    }

    func clearFrameIO(rowIDs: [String]) {
        let ids = Set(rowIDs)
        queueQC(rows.filter { ids.contains($0.id) }) { item in item[.frameio] = ""; item[.uploaded] = "" }
    }
}
