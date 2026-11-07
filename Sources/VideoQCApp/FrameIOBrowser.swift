import SwiftUI
import AppKit
import AuthenticationServices
import UniformTypeIdentifiers
import ImageIO

/// Frame.io browser: account → workspace → project → folders, with Finder-style selection, rename, move (drag or
/// Move to…), links and undo. Shared so the tab keeps its place when switching tabs; observed only by the Upload tab,
/// never by `ContentView`.
@MainActor
final class FrameIOBrowser: ObservableObject {
    static let shared = FrameIOBrowser()

    enum Level: String, Hashable, Codable {
        case account, workspace, project, folder
        /// A version stack opened to show its versions.
        case stack
    }

    struct Crumb: Hashable, Codable {
        let level: Level
        let id: String
        let title: String
        /// Projects: the root folder listed when the project is opened.
        let folderID: String?

        /// The folder this crumb lists (projects: their root folder).
        var listedFolder: String? { level == .folder ? id : (level == .project ? folderID : nil) }
    }

    /// A saved place (project, folder or stack) to jump back to. Kept in UserDefaults, per Mac.
    struct Favourite: Codable, Identifiable, Hashable {
        var id: String { path.map(\.id).joined(separator: "/") }
        let path: [Crumb]
        /// The favourites page (tab) it's on, 0…4. Favourites saved before pages existed are on the first.
        var page = 0

        init(path: [Crumb], page: Int = 0) {
            self.path = path
            self.page = page
        }

        init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            path = try c.decode([Crumb].self, forKey: .path)
            page = try c.decodeIfPresent(Int.self, forKey: .page) ?? 0
        }

        var title: String { path.last?.title ?? "Frame.io" }
        /// Where it lives: "Project › Parent" (empty for a project).
        var location: String {
            path.filter { $0.level == .project || $0.level == .folder || $0.level == .stack }.dropLast().map(\.title)
                .joined(separator: " › ")
        }
    }

    /// A short message under the list, with Undo for the last rename or move.
    struct Toast: Identifiable {
        let id = UUID()
        let message: String
        var isError = false
        var undo: (@MainActor () -> Void)?
    }

    @Published private(set) var signedIn: Bool?
    @Published private(set) var userName = ""
    @Published private(set) var path: [Crumb] = [] {
        didSet {
            // Remembered for "Open at: Last place" (navigation only, not per frame).
            if path != oldValue, path.count > 1, let data = try? JSONEncoder().encode(path) {
                UserDefaults.standard.set(data, forKey: Self.lastPathKey)
            }
        }
    }
    /// Where the browser opens after signing in (User Settings → Frame.io): "home", "last" or a favourite's id.
    static let startPlaceKey = "prefFrameioStartPlace"

    /// After signing in: the remembered place or a favourite (User Settings → Frame.io → Open at), else the top.
    private func openStartPlace() {
        let start = UserDefaults.standard.string(forKey: Self.startPlaceKey) ?? "last"
        var target: [Crumb] = []
        if start == "last", let data = UserDefaults.standard.data(forKey: Self.lastPathKey),
           let saved = try? JSONDecoder().decode([Crumb].self, from: data) {
            target = saved
        } else if let favourite = favourites.first(where: { $0.id == start }) {
            target = favourite.path
        }
        // A remembered place from another account (signed in as someone else) fails and falls back to the top.
        isRestoringStart = !target.isEmpty
        path = target
        reload()
    }

    /// User Settings → Clear Caches.
    nonisolated static func clearThumbnailCache() { Task { await FrameIOThumbnailCache.shared.clear() } }
    static let lastPathKey = "frameioLastPath"
    @Published private(set) var items: [FrameIO.Item] = []
    @Published private(set) var isLoading = false
    @Published private(set) var isSigningIn = false
    @Published var error: String?
    @Published var selection: Set<String> = []
    @Published var renamingID: String?
    @Published private(set) var toast: Toast?
    /// The last rename/move/stack change, undoable from the toast, the toolbar, right-click or ⌘Z until the next one.
    @Published private(set) var lastUndo: Toast?
    /// Filters the open listing by name (cleared when navigating).
    @Published var filter = ""
    @Published private(set) var favourites: [Favourite] = FrameIOBrowser.loadFavourites() {
        // The last favourite project gone: an empty Favourites list would hide every project.
        didSet { if favouriteProjectsOnly && !Self.hasProjectFavourites(favourites) { favouriteProjectsOnly = false } }
    }
    /// Favourites pages (tabs), 1…5, named by the user ("MISSONI", "AD Germany"…).
    @Published private(set) var favouritePages: [String] = UserDefaults.standard.stringArray(forKey: FrameIOBrowser.favouritePagesKey) ?? ["Page 1"]
    /// The page shown (and the one new stars go to).
    @Published var favouritePage = UserDefaults.standard.integer(forKey: FrameIOBrowser.favouritePageKey) {
        didSet { UserDefaults.standard.set(favouritePage, forKey: Self.favouritePageKey) }
    }
    static let maxFavouritePages = 5
    enum ProjectStatusFilter: String, CaseIterable, Identifiable {
        case active, inactive, all
        var id: String { rawValue }
        var title: String {
            switch self {
            case .active: return "Active"
            case .inactive: return "Inactive"
            case .all: return "All Statuses"
            }
        }
    }

    /// The project list's status filter, like Frame.io's (default Active).
    @Published var projectStatus = ProjectStatusFilter(rawValue: UserDefaults.standard.string(forKey: FrameIOBrowser.projectStatusKey) ?? "") ?? .active {
        didSet { UserDefaults.standard.set(projectStatus.rawValue, forKey: Self.projectStatusKey) }
    }
    /// The project list shows favourite projects only. Opens on Favourites when there are favourite projects, else on
    /// All Projects.
    @Published var favouriteProjectsOnly = FrameIOBrowser.hasProjectFavourites(FrameIOBrowser.loadFavourites())
    /// The open project's share links (newest first), for "Add to Share Link".
    @Published private(set) var projectShares: [FrameIO.Share] = []
    private var sharesProject: String?
    /// Number of versions per stack in the open folder (fetched after listing; drives the "V3" badges).
    @Published private(set) var versionCounts: [String: Int] = [:]

    private var loadToken = 0
    private var anchor: String?
    /// A pasted link's file or stack: selected once its folder has loaded.
    private var pendingSelection: String?
    /// The row the list scrolls to (a pasted link's file).
    @Published private(set) var revealID: String?

    func didReveal() { revealID = nil }

    /// Selects one row and scrolls to it (the preview's ← →).
    func reveal(_ id: String) {
        selection = [id]
        anchor = id
        revealID = id
    }

    /// Pasteboard text identifying Frame.io items dragged inside the browser (moves).
    nonisolated static let dragPrefix = "qcpie-frameio\n"

    var accountID: String? { path.first?.id }

    /// The folder uploads go to: the open folder or the open project's root.
    var destination: Crumb? {
        guard let last = path.last, last.level == .folder || last.level == .project else { return nil }
        return last
    }

    var currentFolderID: String? { destination?.listedFolder }

    var inStack: Bool { path.last?.level == .stack }

    /// A workspace is open: the listing is its projects.
    var atProjectList: Bool { path.last?.level == .workspace }

    var showsFavouriteProjectsOnly: Bool { atProjectList && favouriteProjectsOnly }

    /// Projects passing the status filter (all items elsewhere).
    var statusFilteredItems: [FrameIO.Item] {
        guard atProjectList else { return items }
        switch projectStatus {
        case .active: return items.filter { !$0.isInactive }
        case .inactive: return items.filter(\.isInactive)
        case .all: return items
        }
    }

    /// The listing after the status filter and favourites switch (project list), before the name filter.
    var listedItems: [FrameIO.Item] {
        showsFavouriteProjectsOnly ? statusFilteredItems.filter(isFavourite) : statusFilteredItems
    }

    /// The listing after the name filter too.
    var visibleItems: [FrameIO.Item] {
        let query = filter.trimmingCharacters(in: .whitespaces)
        return query.isEmpty ? listedItems : listedItems.filter { $0.title.localizedCaseInsensitiveContains(query) }
    }

    /// The open project's id (shares are created per project).
    var projectID: String? { path.first { $0.level == .project }?.id }

    /// Inside a stack: the folder that holds it.
    private var stackParentFolder: String? { inStack && path.count >= 2 ? path[path.count - 2].listedFolder : nil }

    /// "Project › Folder › Subfolder" of the open folder.
    var destinationTitles: [String] { path.filter { $0.level == .project || $0.level == .folder }.map(\.title) }

    // MARK: Session

    func start() {
        guard signedIn == nil else { return }
        Task {
            signedIn = await FrameIO.shared.isSignedIn
            guard signedIn == true else { return }
            await loadUser()
            openStartPlace()
        }
    }

    func signIn() {
        isSigningIn = true
        error = nil
        Task {
            defer { isSigningIn = false }
            do {
                try await FrameIOSignIn.run()
                signedIn = true
                FrameIOCommentSync.shared.signInChanged(true)
                await loadUser()
                openStartPlace()
            } catch let failure as ASWebAuthenticationSessionError where failure.code == .canceledLogin {
                return
            } catch {
                self.error = error.localizedDescription
            }
        }
    }

    func signOut() {
        Task { await FrameIO.shared.signOut() }
        loadToken += 1   // a listing still loading mustn't fill the signed-out browser
        signedIn = false
        FrameIOCommentSync.shared.signInChanged(false)
        userName = ""
        path = []
        items = []
        selection = []
        error = nil
        filter = ""
        renamingID = nil
        toast = nil
        lastUndo = nil
        projectShares = []
        sharesProject = nil
        versionCounts = [:]
        loadedPath = []
    }

    // MARK: Navigation

    func open(_ item: FrameIO.Item) {
        guard let next = childLevel else { return }
        if next == .folder && item.isVersionStack {
            path.append(Crumb(level: .stack, id: item.id, title: item.title, folderID: nil))
        } else {
            if next == .folder && !item.isFolder { return }
            path.append(Crumb(level: next, id: item.id, title: item.title, folderID: item.rootFolderID))
        }
        reload()
    }

    // MARK: Pasted links

    /// Goes to a Frame.io link (project, folder, file or stack; `f.io` short links too) and selects its file.
    func openLink(_ text: String) {
        guard signedIn == true else {
            show(Toast(message: "Sign in to Frame.io to open links.", isError: true))
            return
        }
        show(Toast(message: "Opening the Frame.io link…"))
        let preferred = accountID
        Task {
            do {
                let link = try FrameIOLink.parse(await FrameIOLink.expand(text))
                let (crumbs, select) = try await FrameIOLink.resolve(link, preferredAccount: preferred)
                pendingSelection = select
                path = crumbs
                reload()
                toast = nil
            } catch {
                show(Toast(message: (error as? FrameIOLink.Failure)?.errorDescription ?? "Couldn't open the link: \(error.localizedDescription)",
                           isError: true))
            }
        }
    }

    /// ⌘V in the Upload tab (no text field focused) and Open Link: a Frame.io link on the clipboard opens. False when
    /// the clipboard holds something else, so the key isn't swallowed.
    @discardableResult
    func openLinkOnClipboard() -> Bool {
        guard let text = NSPasteboard.general.string(forType: .string), FrameIOLink.looksLikeLink(text) else { return false }
        openLink(text)
        return true
    }

    func goTo(depth: Int) {
        guard depth < path.count else { return }
        path.removeSubrange(depth...)
        reload()
    }

    // MARK: Favourites

    private static let favouritesKey = "frameioFavourites"
    private static let favouritePagesKey = "frameioFavouritePages"
    private static let favouritePageKey = "frameioFavouritePage"
    private static let projectStatusKey = "frameioProjectStatus"

    private static func hasProjectFavourites(_ favourites: [Favourite]) -> Bool {
        favourites.contains { $0.path.last?.level == .project }
    }

    private static func loadFavourites() -> [Favourite] {
        guard let data = UserDefaults.standard.data(forKey: favouritesKey) else { return [] }
        // One per place: renaming a starred folder used to let it be starred again under its new name.
        var seen = Set<String>()
        return ((try? JSONDecoder().decode([Favourite].self, from: data)) ?? []).filter { seen.insert($0.id).inserted }
    }

    /// Drag to reorder: puts `id` where `target` is (the bar and the list show favourites in this order).
    func moveFavourite(_ id: String, onto target: String) {
        guard id != target, let from = favourites.firstIndex(where: { $0.id == id }),
              let to = favourites.firstIndex(where: { $0.id == target }) else { return }
        favourites.move(fromOffsets: IndexSet(integer: from), toOffset: to > from ? to + 1 : to)
        saveFavourites()
    }

    /// Settings → Import: takes the imported favourites and pages.
    func reloadFavourites() {
        favourites = Self.loadFavourites()
        favouritePages = UserDefaults.standard.stringArray(forKey: Self.favouritePagesKey) ?? ["Page 1"]
    }

    private func saveFavourites() {
        UserDefaults.standard.set(try? JSONEncoder().encode(favourites), forKey: Self.favouritesKey)
    }

    // MARK: Favourites pages

    /// The page shown, clamped to the pages that exist.
    var currentFavouritePage: Int { min(max(favouritePage, 0), favouritePages.count - 1) }

    /// The favourites on the shown page, in their order.
    var pageFavourites: [Favourite] { favourites.filter { $0.page == currentFavouritePage } }

    func favouriteCount(onPage page: Int) -> Int { favourites.filter { $0.page == page }.count }

    func addFavouritePage() {
        guard favouritePages.count < Self.maxFavouritePages else { return }
        favouritePages.append("Page \(favouritePages.count + 1)")
        saveFavouritePages()
        favouritePage = favouritePages.count - 1
    }

    func renameFavouritePage(_ page: Int, to name: String) {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard favouritePages.indices.contains(page), !trimmed.isEmpty else { return }
        favouritePages[page] = trimmed
        saveFavouritePages()
    }

    /// Deletes a page; its favourites move to the page before it (the first page's to the next), so none are lost.
    func deleteFavouritePage(_ page: Int) {
        guard favouritePages.count > 1, favouritePages.indices.contains(page) else { return }
        let destination = page == 0 ? 0 : page - 1
        for index in favourites.indices {
            if favourites[index].page == page { favourites[index].page = destination } else if favourites[index].page > page { favourites[index].page -= 1 }
        }
        favouritePages.remove(at: page)
        saveFavouritePages()
        saveFavourites()
        if favouritePage >= favouritePages.count || favouritePage > page { favouritePage = max(0, favouritePage - 1) }
    }

    /// Right-click → Move to Page, or a chip dropped on a tab.
    func moveFavourite(_ id: String, toPage page: Int) {
        guard favouritePages.indices.contains(page), let index = favourites.firstIndex(where: { $0.id == id }),
              favourites[index].page != page else { return }
        var moved = favourites.remove(at: index)
        moved.page = page
        favourites.append(moved)
        saveFavourites()
    }

    private func saveFavouritePages() {
        UserDefaults.standard.set(favouritePages, forKey: Self.favouritePagesKey)
    }

    /// Compared by ids: titles in a saved path go stale when a folder is renamed.
    private var currentPlaceID: String { path.map(\.id).joined(separator: "/") }
    var isCurrentFavourite: Bool { favourites.contains { $0.id == currentPlaceID } }

    /// Stars or unstars the open project, folder or stack (stars go to the page shown).
    func toggleCurrentFavourite() {
        guard path.last.map({ [.project, .folder, .stack].contains($0.level) }) == true else { return }
        if isCurrentFavourite {
            favourites.removeAll { $0.id == currentPlaceID }
        } else {
            favourites.append(Favourite(path: path, page: currentFavouritePage))
        }
        saveFavourites()
    }

    /// Adds a project (from the project list), or a folder or stack of the open folder (right-click → Add to Favourites).
    func addFavourite(_ item: FrameIO.Item) {
        let crumb: Crumb
        if atProjectList {
            crumb = Crumb(level: .project, id: item.id, title: item.title, folderID: item.rootFolderID)
        } else if item.isVersionStack {
            crumb = Crumb(level: .stack, id: item.id, title: item.title, folderID: nil)
        } else {
            crumb = Crumb(level: .folder, id: item.id, title: item.title, folderID: item.rootFolderID)
        }
        let favourite = Favourite(path: path + [crumb], page: currentFavouritePage)
        guard !favourites.contains(where: { $0.id == favourite.id }) else { return }
        favourites.append(favourite)
        saveFavourites()
        show(Toast(message: favouritePages.count > 1 ? "Added “\(item.title)” to “\(favouritePages[currentFavouritePage])”"
                                                     : "Added “\(item.title)” to Favourites"))
    }

    func isFavourite(_ item: FrameIO.Item) -> Bool { favourites.contains { $0.path.last?.id == item.id } }

    /// The star on a project row or a folder/stack's right-click menu.
    func toggleFavourite(_ item: FrameIO.Item) {
        if let favourite = favourites.first(where: { $0.path.last?.id == item.id }) {
            removeFavourite(favourite)
        } else {
            addFavourite(item)
        }
    }

    func removeFavourite(_ favourite: Favourite) {
        favourites.removeAll { $0 == favourite }
        saveFavourites()
    }

    func open(_ favourite: Favourite) {
        path = favourite.path
        reload()
    }

    /// The Refresh button: also re-counts stack versions (they can change on the website).
    func refresh() {
        versionCounts = [:]
        reload()
    }

    func reload() {
        loadToken += 1
        let token = loadToken
        let crumbs = path
        isLoading = items.isEmpty || crumbs != loadedPath
        error = nil
        Task {
            do {
                let loaded = try await Self.fetch(crumbs)
                guard token == loadToken else { return }
                // One account: open it straight away.
                if crumbs.isEmpty, loaded.count == 1, let only = loaded.first {
                    path = [Crumb(level: .account, id: only.id, title: only.title, folderID: nil)]
                    reload()
                    return
                }
                if crumbs != loadedPath { selection = []; anchor = nil; filter = "" }
                loadedPath = crumbs
                // A stack lists its versions newest first: keep that order (it is the version order). Items deleted a
                // moment ago stay hidden in case Frame.io still lists them while it finishes deleting.
                let listed = recentlyDeleted.isEmpty ? loaded : loaded.filter { !recentlyDeleted.contains($0.id) }
                items = crumbs.last?.level == .stack ? listed : Self.sorted(listed)
                selection.formIntersection(items.map(\.id))
                if let pending = pendingSelection, items.contains(where: { $0.id == pending }) {
                    selection = [pending]
                    anchor = pending
                    revealID = pending
                }
                pendingSelection = nil
                isLoading = false
                isRestoringStart = false
                if let account = crumbs.first?.id, crumbs.last?.level == .folder || crumbs.last?.level == .project {
                    FrameIOCommentSync.shared.linkQueueClips(to: items, account: account, folder: crumbs.last?.listedFolder)
                }
                if crumbs.last?.level == .stack, let stack = crumbs.last { versionCounts[stack.id] = loaded.count }
                loadVersionCounts(items.filter(\.isVersionStack))
                if projectID != sharesProject { loadShares() }
            } catch {
                guard token == loadToken else { return }
                // The remembered place is gone (deleted, access removed): start from the top instead.
                if isRestoringStart, !crumbs.isEmpty {
                    isRestoringStart = false
                    path = []
                    reload()
                    return
                }
                items = []
                loadedPath = crumbs
                isLoading = false
                handle(error)
            }
        }
    }

    /// The first listing after sign-in is a remembered place (falls back to the top if it fails).
    private var isRestoringStart = false

    /// The path `items` were listed for (selection is kept across refreshes of the same folder).
    private var loadedPath: [Crumb] = []

    private static func sorted(_ items: [FrameIO.Item]) -> [FrameIO.Item] {
        items.sorted { a, b in
            a.isFolder != b.isFolder ? a.isFolder : a.title.localizedStandardCompare(b.title) == .orderedAscending
        }
    }

    private var childLevel: Level? {
        switch path.last?.level {
        case nil: return .account
        case .account: return .workspace
        case .workspace: return .project
        case .project, .folder: return .folder
        case .stack: return nil
        }
    }

    /// Stacks whose version count is being fetched (a reload while it's in flight doesn't ask again).
    private var countingStacks: Set<String> = []

    /// Fetches the version count of each stack in the open folder (one call each, the first 25).
    private func loadVersionCounts(_ stacks: [FrameIO.Item]) {
        guard let account = accountID else { return }
        for stack in stacks.prefix(25) where versionCounts[stack.id] == nil && !countingStacks.contains(stack.id) {
            countingStacks.insert(stack.id)
            Task {
                defer { countingStacks.remove(stack.id) }
                if let versions = try? await FrameIO.shared.stackVersions(account: account, stack: stack.id, thumbnails: false) {
                    versionCounts[stack.id] = versions.count
                }
            }
        }
    }

    private static func fetch(_ crumbs: [Crumb]) async throws -> [FrameIO.Item] {
        guard let account = crumbs.first?.id, let last = crumbs.last else { return try await FrameIO.shared.accounts() }
        switch last.level {
        case .account: return try await FrameIO.shared.workspaces(account: account)
        case .workspace: return try await FrameIO.shared.projects(account: account, workspace: last.id)
        case .project, .folder:
            guard let folder = last.listedFolder else { throw FrameIO.Failure.unreadable }
            return try await FrameIO.shared.children(account: account, folder: folder)
        case .stack:
            return try await FrameIO.shared.stackVersions(account: account, stack: last.id)
        }
    }

    // MARK: Selection (Finder style)

    /// Click selects, ⌘-click toggles, ⇧-click selects the range from the last click; clicking the only selected item
    /// again deselects it.
    func click(_ id: String) {
        let flags = NSEvent.modifierFlags
        let visible = visibleItems
        if flags.contains(.shift), let anchor, let a = visible.firstIndex(where: { $0.id == anchor }),
           let b = visible.firstIndex(where: { $0.id == id }) {
            let range = visible[min(a, b)...max(a, b)].map(\.id)
            selection = flags.contains(.command) ? selection.union(range) : Set(range)
            return
        }
        if flags.contains(.command) {
            if selection.contains(id) { selection.remove(id) } else { selection.insert(id) }
        } else {
            selection = selection == [id] ? [] : [id]
        }
        anchor = id
    }

    /// What a right-click or drag on `item` acts on: the selection when the item is part of it, else the item alone.
    func targets(for item: FrameIO.Item) -> [FrameIO.Item] {
        selection.contains(item.id) ? items.filter { selection.contains($0.id) } : [item]
    }

    // MARK: Changes

    /// Finder's New Folder: creates "untitled folder" here and starts renaming it.
    func newFolder() {
        guard let account = accountID, let parent = currentFolderID else { return }
        filter = ""   // the new folder must be visible to rename it
        let existing = Set(items.map(\.title))
        var name = "untitled folder"
        var counter = 2
        while existing.contains(name) { name = "untitled folder \(counter)"; counter += 1 }
        Task {
            do {
                let folder = try await FrameIO.shared.createFolder(account: account, parent: parent, name: name)
                guard currentFolderID == parent else { return }   // navigated away meanwhile: it lists there
                items = Self.sorted(items + [folder])
                selection = [folder.id]
                anchor = folder.id
                renamingID = folder.id
            } catch {
                show(Toast(message: "Couldn't create the folder: \(error.localizedDescription)", isError: true))
            }
        }
    }

    /// Creates a project in the open workspace and opens it. In the Favourites view it's starred, so it shows there.
    func newProject(named newName: String) {
        let name = newName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard atProjectList, !name.isEmpty, let account = accountID, let workspace = path.last?.id else { return }
        Task {
            do {
                var project = try await FrameIO.shared.createProject(account: account, workspace: workspace, name: name)
                // Opening it needs its root folder; ask again if the create response left it out.
                if project.rootFolderID == nil {
                    project = (try? await FrameIO.shared.item(account: account, kind: "projects", id: project.id)) ?? project
                }
                guard atProjectList, path.last?.id == workspace else { return }
                items = Self.sorted(items + [project])
                if favouriteProjectsOnly { addFavourite(project) }
                open(project)
                show(Toast(message: "Created project “\(project.title)”"))
            } catch {
                show(Toast(message: "Couldn't create the project: \(error.localizedDescription)", isError: true))
            }
        }
    }

    func rename(_ item: FrameIO.Item, to newName: String, undoable: Bool = true) {
        let name = newName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty, name != item.title, let account = accountID else { return }
        replace(item.renamed(name))
        Task {
            do {
                try await FrameIO.shared.rename(account: account, item: item, to: name)
                retitle(item.id, to: name)
                guard undoable else { return }
                show(Toast(message: "Renamed “\(item.title)” to “\(name)”") {
                    self.rename(item.renamed(name), to: item.title, undoable: false)
                })
            } catch {
                replace(item)
                show(Toast(message: "Couldn't rename “\(item.title)”: \(error.localizedDescription)", isError: true))
            }
        }
    }

    /// Moves items from the open folder into `folder` (Undo moves them back).
    func move(_ moving: [FrameIO.Item], to folder: String, titled title: String, undoable: Bool = true) {
        let moving = moving.filter { $0.id != folder }
        guard !moving.isEmpty, let account = accountID, let from = currentFolderID, folder != from else { return }
        let fromTitle = destinationTitles.last ?? "the previous folder"
        let ids = Set(moving.map(\.id))
        items.removeAll { ids.contains($0.id) }
        selection.subtract(ids)
        Task {
            do {
                try await FrameIO.shared.move(account: account, items: moving, to: folder)
                let what = moving.count == 1 ? "“\(moving[0].title)”" : "\(moving.count) items"
                if undoable {
                    show(Toast(message: "Moved \(what) to “\(title)”") {
                        Task {
                            do {
                                try await FrameIO.shared.move(account: account, items: moving, to: from)
                                self.show(Toast(message: "Moved \(what) back to “\(fromTitle)”"))
                            } catch {
                                self.show(Toast(message: "Couldn't undo the move: \(error.localizedDescription)", isError: true))
                            }
                            self.reload()
                        }
                    })
                }
            } catch {
                show(Toast(message: "Couldn't move: \(error.localizedDescription)", isError: true))
            }
            reload()
        }
    }

    /// Copy to: copies into `folder` (no Undo: undoing would mean deleting).
    func copy(_ targets: [FrameIO.Item], to folder: String, titled title: String) {
        guard let account = accountID, !targets.isEmpty else { return }
        let what = targets.count == 1 ? "“\(targets[0].title)”" : "\(targets.count) items"
        Task {
            do {
                try await FrameIO.shared.copy(account: account, items: targets, to: folder)
                show(Toast(message: "Copied \(what) to “\(title)”"))
            } catch {
                show(Toast(message: "Couldn't copy: \(error.localizedDescription)", isError: true))
            }
            if folder == currentFolderID { reload() }
        }
    }

    /// Duplicate: a copy next to the original.
    func duplicate(_ targets: [FrameIO.Item]) {
        guard let account = accountID, !targets.isEmpty else { return }
        let what = targets.count == 1 ? "“\(targets[0].title)”" : "\(targets.count) items"
        Task {
            do {
                try await FrameIO.shared.copy(account: account, items: targets, to: currentFolderID)
                show(Toast(message: "Duplicated \(what)"))
                // Folder copies can finish a moment later: list again after a short wait too.
                reload()
                try? await Task.sleep(for: .seconds(2))
                reload()
            } catch {
                show(Toast(message: "Couldn't duplicate: \(error.localizedDescription)", isError: true))
            }
        }
    }

    // MARK: Delete

    /// What Delete acts on for a right-click on `item` (nil: nothing here can be deleted): files, folders and stacks in
    /// a folder, or versions in an open stack. Never projects, workspaces or accounts.
    func deletable(for item: FrameIO.Item) -> [FrameIO.Item]? {
        guard destination != nil || inStack else { return nil }
        let targets = targets(for: item).filter(FrameIODelete.canDelete)
        return targets.isEmpty ? nil : targets
    }

    /// ⌘⌫: the selection, after asking.
    func deleteSelection() {
        guard destination != nil || inStack else { return }
        let targets = items.filter { selection.contains($0.id) && FrameIODelete.canDelete($0) }
        if !targets.isEmpty { confirmDelete(targets) }
    }

    /// Asks (a sheet on the window, Cancel is the default button), then deletes. While an upload runs, folders stay:
    /// one may be where it's uploading.
    func confirmDelete(_ targets: [FrameIO.Item]) {
        guard !targets.isEmpty else { return }
        if UploadQueue.shared.isRunning && targets.contains(where: \.isFolder) {
            show(Toast(message: "Folders can't be deleted while an upload is running.", isError: true))
            return
        }
        let text = FrameIODelete.summary(targets)
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = text.title
        alert.informativeText = text.detail
        let delete = alert.addButton(withTitle: "Delete")
        delete.hasDestructiveAction = true
        let cancel = alert.addButton(withTitle: "Cancel")
        // Return cancels, so a stray key press never deletes.
        delete.keyEquivalent = ""
        cancel.keyEquivalent = "\r"
        let finish: (NSApplication.ModalResponse) -> Void = { response in
            if response == .alertFirstButtonReturn { self.delete(targets) }
        }
        if let window = NSApp.keyWindow ?? NSApp.mainWindow {
            alert.beginSheetModal(for: window, completionHandler: finish)
        } else {
            finish(alert.runModal())
        }
    }

    /// Ids deleted in the last 30 s, left out of listings (`reload`).
    private var recentlyDeleted: Set<String> = []

    private func hideDeleted(_ ids: Set<String>) {
        guard !ids.isEmpty else { return }
        recentlyDeleted.formUnion(ids)
        Task {
            try? await Task.sleep(for: .seconds(30))
            recentlyDeleted.subtract(ids)
        }
    }

    /// Deletes from Frame.io: the rows go at once, and come back with the next listing if they couldn't be deleted.
    private func delete(_ targets: [FrameIO.Item]) {
        guard let account = accountID else { return }
        let ids = Set(targets.map(\.id))
        let stack = inStack ? path.last : nil
        items.removeAll { ids.contains($0.id) }
        selection.subtract(ids)
        let what = targets.count == 1 ? "“\(targets[0].title)”" : "\(targets.count) items"
        if targets.count > 3 { show(Toast(message: "Deleting \(what)…")) }
        Task {
            let outcome = await FrameIODelete.run(targets, account: account, api: FrameIO.shared)
            // Favourites of deleted folders and stacks (or anything inside them) can't open any more.
            if favourites.contains(where: { $0.path.contains { outcome.deleted.contains($0.id) } }) {
                favourites.removeAll { $0.path.contains { outcome.deleted.contains($0.id) } }
                saveFavourites()
            }
            for id in outcome.deleted { versionCounts[id] = nil }
            DeliveryPlanStore.shared.frameIOGone(outcome.deleted)
            hideDeleted(outcome.deleted)
            if let stack { versionCounts[stack.id] = nil }
            if let first = outcome.failures.first {
                let failed = outcome.failures.count == 1 ? "“\(first.title)”" : "\(outcome.failures.count) items"
                let message = outcome.deleted.isEmpty ? "Couldn't delete \(failed)"
                    : "Deleted \(outcome.deleted.count), but couldn't delete \(failed)"
                show(Toast(message: "\(message): \(first.message)", isError: true))
            } else {
                show(Toast(message: "Deleted \(what)"))
            }
            // A stack whose last versions went is gone: back to the folder that held it.
            if let stack, path.last?.id == stack.id, items.isEmpty, !outcome.deleted.isEmpty { path.removeLast() }
            reload()
        }
    }

    // MARK: Share links

    /// Lists the open project's share links (on entering a project and after creating one).
    func loadShares() {
        guard let account = accountID, let project = projectID else {
            projectShares = []
            sharesProject = nil
            return
        }
        sharesProject = project
        Task {
            let shares = (try? await FrameIO.shared.shares(account: account, project: project)) ?? []
            guard projectID == project else { return }
            projectShares = shares
        }
    }

    /// Adds items to an existing share link.
    func addToShare(_ targets: [FrameIO.Item], share: FrameIO.Share) {
        guard let account = accountID, !targets.isEmpty else { return }
        let label = share.name ?? share.shortURL ?? "the share link"
        let what = targets.count == 1 ? "“\(targets[0].title)”" : "\(targets.count) items"
        if targets.count > 10 {
            let minutes = Int((Double(targets.count) * 6.2 / 60).rounded(.up))
            show(Toast(message: "Adding \(what) to “\(label)”: Frame.io takes 10 a minute, so about \(minutes) min…"))
        } else if targets.count > 3 {
            show(Toast(message: "Adding \(what) to “\(label)”…"))
        }
        Task {
            do {
                try await FrameIO.shared.addToShare(account: account, share: share.id, assetIDs: targets.map(\.id))
                show(Toast(message: "Added \(what) to “\(label)”"))
            } catch {
                show(Toast(message: "Couldn't add to “\(label)”: \(error.localizedDescription)", isError: true))
            }
        }
    }

    // MARK: Version stacks

    /// Stacks files of the open folder in the given order: the first is V1, the last becomes the current version.
    func stack(_ ordered: [FrameIO.Item], in folderOverride: String? = nil) {
        guard let account = accountID, let folder = folderOverride ?? currentFolderID else { return }
        guard (2...10).contains(ordered.count) else {
            // Also Undo of an Unstack: Frame.io stacks at most 10 files at once.
            if ordered.count > 10 { show(Toast(message: "Frame.io can stack at most 10 files at once.", isError: true)) }
            return
        }
        Task {
            do {
                let stack = try await FrameIO.shared.createStack(account: account, folder: folder, fileIDs: ordered.map(\.id))
                versionCounts[stack.id] = ordered.count
                show(Toast(message: "Stacked \(ordered.count) versions as “\(stack.title)”") {
                    self.unstack(stack, into: folder, undoable: false)
                })
            } catch {
                show(Toast(message: "Couldn't stack: \(error.localizedDescription)", isError: true))
            }
            reload()
        }
    }

    /// Files dropped onto another file: stack them, the target first (V1) and the dropped files as newer versions.
    func stackOnto(_ target: FrameIO.Item, _ dropped: [FrameIO.Item]) {
        let dropped = dropped.filter { !$0.isFolder && !$0.isVersionStack && $0.id != target.id }
        guard !dropped.isEmpty else { return }
        guard dropped.count < 10 else {
            show(Toast(message: "A new stack can hold at most 10 files.", isError: true))
            return
        }
        stack([target] + dropped)
    }

    /// Takes every version out of a stack, back into the folder that holds it.
    func unstack(_ stack: FrameIO.Item, into folderOverride: String? = nil, undoable: Bool = true) {
        guard let account = accountID,
              let folder = folderOverride ?? (inStack ? stackParentFolder : currentFolderID) else { return }
        Task {
            do {
                let versions = try await FrameIO.shared.stackVersions(account: account, stack: stack.id, thumbnails: false)
                try await FrameIO.shared.move(account: account, items: versions, to: folder)
                versionCounts[stack.id] = nil
                if inStack, path.last?.id == stack.id { path.removeLast() }
                let oldestFirst = Array(versions.reversed())
                let message = "Unstacked “\(stack.title)” into \(versions.count) files"
                if undoable {
                    show(Toast(message: message) { self.stack(oldestFirst, in: folder) })
                } else {
                    show(Toast(message: message))
                }
            } catch {
                show(Toast(message: "Couldn't unstack: \(error.localizedDescription)", isError: true))
            }
            reload()
        }
    }

    /// Inside a stack: moves these versions out of it, into the folder that holds the stack.
    func removeFromStack(_ versions: [FrameIO.Item]) {
        guard inStack, let account = accountID, let folder = stackParentFolder, let stack = path.last else { return }
        let ids = Set(versions.map(\.id))
        let remaining = items.count - versions.count
        items.removeAll { ids.contains($0.id) }
        Task {
            do {
                try await FrameIO.shared.move(account: account, items: versions, to: folder)
                versionCounts[stack.id] = nil
                show(Toast(message: versions.count == 1 ? "Removed “\(versions[0].title)” from the stack"
                                                        : "Removed \(versions.count) versions from the stack") {
                    Task {
                        try? await FrameIO.shared.addToStack(account: account, files: versions, stack: stack.id)
                        self.reload()
                    }
                })
                if remaining <= 0, path.last?.id == stack.id { path.removeLast() }
            } catch {
                show(Toast(message: "Couldn't remove from the stack: \(error.localizedDescription)", isError: true))
            }
            reload()
        }
    }

    /// Adds files (dragged onto a stack) as its newest versions.
    func addToStack(_ files: [FrameIO.Item], stack: FrameIO.Item) {
        let files = files.filter { !$0.isFolder && !$0.isVersionStack && $0.id != stack.id }
        guard !files.isEmpty, let account = accountID, let folder = currentFolderID else { return }
        let ids = Set(files.map(\.id))
        items.removeAll { ids.contains($0.id) }
        selection.subtract(ids)
        Task {
            do {
                try await FrameIO.shared.addToStack(account: account, files: files, stack: stack.id)
                versionCounts[stack.id] = nil
                show(Toast(message: files.count == 1 ? "Added “\(files[0].title)” to “\(stack.title)” as the newest version"
                                                     : "Added \(files.count) versions to “\(stack.title)”") {
                    Task {
                        try? await FrameIO.shared.move(account: account, items: files, to: folder)
                        self.versionCounts[stack.id] = nil
                        self.reload()
                    }
                })
            } catch {
                show(Toast(message: "Couldn't add to the stack: \(error.localizedDescription)", isError: true))
            }
            reload()
        }
    }

    /// Feedback for drops that can't start an upload right now.
    func notify(_ message: String, isError: Bool = false) {
        show(Toast(message: message, isError: isError))
    }

    func dismissToast() {
        toast = nil
    }


    func performUndo() {
        guard let undo = lastUndo?.undo else { return }
        lastUndo = nil
        toast = nil
        undo()
    }

    private func show(_ next: Toast) {
        toast = next
        if next.undo != nil { lastUndo = next }
        let id = next.id
        Task {
            try? await Task.sleep(for: .seconds(next.isError ? 8 : 6))
            if toast?.id == id { toast = nil }
        }
    }

    /// A renamed folder, project or stack: its crumb in favourites (and the open path) takes the new name.
    private func retitle(_ id: String, to title: String) {
        func renamed(_ crumbs: [Crumb]) -> [Crumb] {
            crumbs.map { $0.id == id ? Crumb(level: $0.level, id: $0.id, title: title, folderID: $0.folderID) : $0 }
        }
        if favourites.contains(where: { $0.path.contains { $0.id == id } }) {
            favourites = favourites.map { Favourite(path: renamed($0.path), page: $0.page) }
            saveFavourites()
        }
        if path.contains(where: { $0.id == id }) {
            let updated = renamed(path)
            loadedPath = loadedPath == path ? updated : loadedPath
            path = updated
        }
    }

    private func replace(_ item: FrameIO.Item) {
        guard let index = items.firstIndex(where: { $0.id == item.id }) else { return }
        items[index] = item
        if !inStack { items = Self.sorted(items) }   // a stack's order is its version order
    }

    private func loadUser() async {
        do {
            userName = try await FrameIO.shared.me().title
        } catch {
            handle(error)
        }
    }

    private func handle(_ error: Error) {
        if case FrameIO.Failure.signedOut = error {
            signedIn = false
            path = []
        }
        self.error = error.localizedDescription
    }
}
