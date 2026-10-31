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
    @Published private(set) var favourites: [Favourite] = FrameIOBrowser.loadFavourites()
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
    /// The project list shows favourite projects only (default: a company workspace can hold dozens of projects).
    @Published var favouriteProjectsOnly = UserDefaults.standard.object(forKey: FrameIOBrowser.favouriteProjectsOnlyKey) as? Bool ?? true {
        didSet { UserDefaults.standard.set(favouriteProjectsOnly, forKey: Self.favouriteProjectsOnlyKey) }
    }
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
    private static let favouriteProjectsOnlyKey = "frameioFavouriteProjectsOnly"
    private static let projectStatusKey = "frameioProjectStatus"

    private static func loadFavourites() -> [Favourite] {
        guard let data = UserDefaults.standard.data(forKey: favouritesKey) else { return [] }
        return (try? JSONDecoder().decode([Favourite].self, from: data)) ?? []
    }

    /// Drag to reorder: puts `id` where `target` is (the bar and the list show favourites in this order).
    func moveFavourite(_ id: String, onto target: String) {
        guard id != target, let from = favourites.firstIndex(where: { $0.id == id }),
              let to = favourites.firstIndex(where: { $0.id == target }) else { return }
        favourites.move(fromOffsets: IndexSet(integer: from), toOffset: to > from ? to + 1 : to)
        saveFavourites()
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

    var isCurrentFavourite: Bool { favourites.contains { $0.path == path } }

    /// Stars or unstars the open project, folder or stack (stars go to the page shown).
    func toggleCurrentFavourite() {
        guard path.last.map({ [.project, .folder, .stack].contains($0.level) }) == true else { return }
        if isCurrentFavourite {
            favourites.removeAll { $0.path == path }
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
        guard !favourites.contains(where: { $0.path == favourite.path }) else { return }
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
                    FrameIOCommentSync.shared.linkQueueClips(to: items, account: account)
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
        if targets.count > 3 { show(Toast(message: "Adding \(what) to “\(label)”…")) }
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
        guard (2...10).contains(ordered.count), let account = accountID,
              let folder = folderOverride ?? currentFolderID else { return }
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

    /// A passing note at the bottom of the browser (no undo).
    func notice(_ message: String) { show(Toast(message: message)) }

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

/// Right side of the Upload tab: Adobe sign-in, then the Frame.io browser.
struct FrameIOBrowserView: View {
    @ObservedObject private var themeManager = ThemeManager.shared   // accent changes redraw
    var isLightMode: Bool
    @ObservedObject private var browser = FrameIOBrowser.shared
    /// Row or breadcrumb under a drag.
    @State private var dropTarget: String?
    @State private var isListTargeted = false
    @State private var renameText = ""
    @FocusState private var renameFocused: Bool
    @State private var metadataRequest: FrameIOMetadataSheet.Request?
    @State private var moveItems: MoveRequest?
    @State private var stackItems: MoveRequest?
    @State private var copyItems: MoveRequest?
    @State private var shareRequest: ShareRequest?
    @State private var showNewProject = false
    /// The breadcrumbs' "…" (folded start of a long path) is open.
    @State private var hiddenCrumbsOpen = false
    /// How favourites show: "bar" (chips under the breadcrumbs) or "list" (a vertical list from the Favourites button).
    /// Clicking Favourites switches; right-click picks one. (An old "hidden" setting reads as the bar.)
    @AppStorage("frameioFavouritesLayout") private var favouritesLayout = "bar"
    @State private var showFavouritesList = false
    /// The favourite being dragged to reorder (drops elsewhere ignore it).
    @State private var draggingFavourite: String?
    @AppStorage("frameioThumbnails") private var showThumbnails = false
    @AppStorage("frameioThumbnailWidth") private var thumbnailWidth: Double = 64

    struct ShareRequest: Identifiable {
        let id = UUID()
        let project: String
        let name: String
        let assetIDs: [String]
        /// For the preview (empty when sharing the open folder).
        var items: [FrameIO.Item] = []
    }

    private var palette: StudioPalette { StudioPalette(isLightMode) }
    private var inFolder: Bool { browser.destination != nil }

    struct MoveRequest: Identifiable {
        let id = UUID()
        let items: [FrameIO.Item]
    }

    var body: some View {
        VStack(spacing: 0) {
            switch browser.signedIn {
            case nil:
                Spacer()
            case false?:
                signInPrompt
            case true?:
                if !benchHides("header") { header }
                if !isListLayout && !benchHides("favbar") {
                    favouritesBar
                    Rectangle().fill(palette.borderLine).frame(height: 1)
                }
                if !benchHides("toolbar") { toolbar }
                Rectangle().fill(palette.borderLine).frame(height: 1)
                if benchHides("list") { Spacer() } else { folderList }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(palette.bgMain)
        .overlay { FrameIOPreviewOverlay(isLightMode: isLightMode) }
        .overlay(alignment: .bottom) { toastView }
        .onAppear { browser.start() }
        .sheet(item: $shareRequest, onDismiss: { browser.loadShares() }) { request in
            FrameIOShareSheet(request: request, isLightMode: isLightMode)
        }
        .sheet(isPresented: $showNewProject) {
            FrameIONewProjectSheet(isLightMode: isLightMode) { name in browser.newProject(named: name) }
        }
        .sheet(item: $metadataRequest) { request in
            FrameIOMetadataSheet(request: request, isLightMode: isLightMode)
        }
        .sheet(item: $stackItems) { request in
            FrameIOStackSheet(files: request.items, isLightMode: isLightMode) { ordered in
                browser.stack(ordered)
            }
        }
        .sheet(item: $moveItems) { request in
            FrameIOMoveSheet(items: request.items, isCopy: false, isLightMode: isLightMode) { folder, title in
                browser.move(request.items, to: folder, titled: title)
            }
        }
        .sheet(item: $copyItems) { request in
            FrameIOMoveSheet(items: request.items, isCopy: true, isLightMode: isLightMode) { folder, title in
                browser.copy(request.items, to: folder, titled: title)
            }
        }
    }

    // MARK: Signed out

    private var signInPrompt: some View {
        VStack(spacing: 14) {
            Spacer()
            Image(systemName: "icloud.and.arrow.up")
                .font(.system(size: StudioTheme.scaleFont(34), weight: .light))
                .foregroundColor(palette.textMuted)
            Text("Upload to Frame.io")
                .font(.ui(size: 15, weight: .semibold))
            Text("Sign in with the Adobe account you use for Frame.io.")
                .font(.ui(size: 12))
                .foregroundColor(palette.textMuted)
            Button(action: browser.signIn) {
                Text(browser.isSigningIn ? "Signing In…" : "Sign In with Adobe")
                    .font(.ui(size: 12, weight: .semibold))
                    .foregroundColor(palette.primaryBtnFg)
                    .padding(.horizontal, 16)
                    .padding(.vertical, 7)
                    .background(RoundedRectangle(cornerRadius: Radius.segment).fill(palette.primaryBtnBg))
            }
            .buttonStyle(.plain)
            .disabled(browser.isSigningIn)
            if let error = browser.error {
                Text(error)
                    .font(.ui(size: 11))
                    .foregroundColor(palette.negative)
                    .multilineTextAlignment(.center)
            }
            Spacer()
        }
        .frame(maxWidth: 420)
    }

    // MARK: Header

    /// The Assets & Queue chevron, where you are, and the actions that don't depend on it: refresh, Frame.io's
    /// status, the account, and the right drawer's chevron at the far right. Sized like the Play and Inspect headers.
    private var header: some View {
        HStack(spacing: 4) {
            QueueSleeveToggle(isLightMode: isLightMode)
                .padding(.trailing, 8)
            if !benchHides("crumbs") { breadcrumbs }
            Spacer(minLength: 12)
            if inFolder {
                toolButton("New Folder", systemImage: "folder.badge.plus", help: "Create a folder here", action: browser.newFolder)
            }
            if browser.atProjectList {
                toolButton("New Project", systemImage: "plus.rectangle.on.folder", help: "Create a project in this workspace") {
                    showNewProject = true
                }
            }
            toolButton(nil, systemImage: "arrow.clockwise", help: "Refresh", action: browser.refresh)
            toolDivider
            if !benchHides("badge") { FrameIOStatusBadge(isLightMode: isLightMode) }
            if !benchHides("account") {
            Menu {
                Button("Sign Out", action: browser.signOut)
            } label: {
                toolLabel(browser.userName.isEmpty ? "Frame.io" : browser.userName, systemImage: "person.crop.circle", menu: true)
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .fixedSize()
            .modifier(ToolHover(fill: palette.bgSubtle))
            .tip("The Frame.io account you're signed in with (click to sign out)")
            }
            toolDivider
            if !benchHides("drawertabs") { DrawerTabs(isLightMode: isLightMode) }
        }
        .headerBand(palette)
    }

    /// Filter, then what applies to the open place: Favourites / All (project list), view, undo, share, its star,
    /// and the Favourites menu.
    private var toolbar: some View {
        let canFavourite = browser.path.last.map { [.project, .folder, .stack].contains($0.level) } == true
        let canShare = browser.projectID != nil && (browser.currentFolderID != nil || browser.inStack)
        return HStack(spacing: 4) {
            filterField
            if !browser.filter.isEmpty {
                Text("\(browser.visibleItems.count) of \(browser.listedItems.count)")
                    .font(.ui(size: 11))
                    .foregroundColor(palette.textMuted)
                    .padding(.leading, 6)
            }
            Spacer(minLength: 12)
            if browser.atProjectList {
                Menu {
                    Picker("", selection: $browser.projectStatus) {
                        ForEach(FrameIOBrowser.ProjectStatusFilter.allCases) { Text($0.title).tag($0) }
                    }
                    .pickerStyle(.inline)
                    .labelsHidden()
                } label: {
                    toolLabel(browser.projectStatus.title, systemImage: "line.3.horizontal.decrease.circle", menu: true)
                }
                .menuStyle(.borderlessButton)
                .menuIndicator(.hidden)
                .fixedSize()
                .modifier(ToolHover(fill: palette.bgSubtle))
                .tip("Show active, inactive or all projects")
                Picker("", selection: $browser.favouriteProjectsOnly) {
                    Text("Favourites").tag(true)
                    Text("All Projects").tag(false)
                }
                .labelsHidden()
                .pickerStyle(.segmented)
                .controlSize(.small)
                .fixedSize()
                .tip("Show your favourite projects or every project in this workspace")
            }
            if inFolder || browser.inStack {
                toolButton(nil, systemImage: showThumbnails ? "square.grid.2x2" : "list.bullet",
                           help: showThumbnails ? "Show as list" : "Show thumbnails", isOn: showThumbnails) { showThumbnails.toggle() }
                if showThumbnails {
                    Slider(value: $thumbnailWidth, in: 48...256)
                        .controlSize(.mini)
                        .frame(width: 70)
                        .tip("Thumbnail size")
                }
            }
            if let undo = browser.lastUndo {
                toolButton("Undo", systemImage: "arrow.uturn.backward", help: "Undo: \(undo.message) (⌘Z)", action: browser.performUndo)
            }
            if canShare {
                toolButton("Share", systemImage: "square.and.arrow.up",
                           help: browser.selection.isEmpty ? "Create a share link for this folder" : "Create a share link for the selected items",
                           action: shareSelectionOrFolder)
            }
            if canFavourite || browser.atProjectList || inFolder || browser.inStack || canShare {
                toolDivider
            }
            if canFavourite {
                toolButton(nil, systemImage: browser.isCurrentFavourite ? "star.fill" : "star",
                           help: browser.isCurrentFavourite ? "Remove from Favourites" : "Add this place to Favourites",
                           tint: browser.isCurrentFavourite ? palette.accentBlue : nil, action: browser.toggleCurrentFavourite)
            }
            favouritesButton
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 6)
        .background(palette.bgPanel)
    }

    private var filterField: some View {
        HStack(spacing: 6) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: StudioTheme.scaleFont(10)))
                .foregroundColor(palette.textMuted)
            TextField(browser.atProjectList ? "Filter or paste a Frame.io link" : "Filter by name or paste a link", text: $browser.filter)
                .textFieldStyle(.plain)
                .font(.ui(size: 11))
                .onChange(of: browser.filter) { _, text in
                    // A Frame.io link pasted here goes to its place instead of filtering.
                    guard FrameIOLink.looksLikeLink(text) else { return }
                    browser.filter = ""
                    browser.openLink(text)
                }
            if !browser.filter.isEmpty {
                Button(action: { browser.filter = "" }) {
                    Image(systemName: "xmark.circle.fill")
                        .font(.system(size: StudioTheme.scaleFont(10)))
                        .foregroundColor(palette.textMuted)
                }
                .buttonStyle(.plain)
                .tip("Clear the filter")
            }
        }
        .padding(.horizontal, 8)
        .frame(height: StudioTheme.scale(24))
        .frame(maxWidth: 260)
        .studioBox(background: palette.bgSubtle, border: palette.borderLine)
    }

    /// Saved places: open one, or remove it.
    /// Favourite projects, folders and stacks as chips under the breadcrumbs: click to go there (the one you're in is
    /// highlighted), × or right-click to remove. Scrolls sideways when there are many.
    private var favouritesBar: some View {
        HStack(spacing: 10) {
            favouritePageTabs
            Rectangle().fill(palette.borderLine).frame(width: 1, height: StudioTheme.scale(20))
            if browser.pageFavourites.isEmpty {
                Text(browser.favourites.isEmpty ? "Star a project, folder or stack (☆ in the toolbar or right-click) to pin it here."
                     : "Nothing on this page yet: star a place while it's open, or drag a favourite onto this tab.")
                    .font(.ui(size: 11))
                    .foregroundColor(palette.textMuted)
                    .lineLimit(1)
                    .truncationMode(.tail)
                    .frame(height: StudioTheme.scale(30))
                Spacer(minLength: 0)
            } else {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 6) {
                        ForEach(browser.pageFavourites) { favourite in
                            favouriteChip(favourite)
                        }
                    }
                    .padding(.vertical, 6)
                }
            }
        }
        .padding(.horizontal, 14)
        // Fixed: a chip row's height, empty or not, so switching pages doesn't move the list below.
        .frame(height: StudioTheme.scale(34) + 12)
        .background(palette.bgPanel)
    }

    /// A chip that opens its place, and drags to reorder (in the bar or the list).
    private func favouriteChip(_ favourite: FrameIOBrowser.Favourite, fullWidth: Bool = false) -> some View {
        FavouriteChip(favourite: favourite, isCurrent: favourite.path == browser.path, isLightMode: isLightMode, fullWidth: fullWidth,
                      isDragging: draggingFavourite == favourite.id, pages: browser.favouritePages,
                      onMoveToPage: { browser.moveFavourite(favourite.id, toPage: $0) },
                      onOpen: {
                          showFavouritesList = false
                          browser.open(favourite)
                      },
                      onRemove: { browser.removeFavourite(favourite) })
            .onDrag {
                draggingFavourite = favourite.id
                return NSItemProvider(object: ("qcpie-favourite\n" + favourite.id) as NSString)
            }
            .onDrop(of: [.utf8PlainText], delegate: FavouriteDropDelegate(target: favourite.id, dragging: $draggingFavourite,
                                                                          move: { browser.moveFavourite($0, onto: $1) }))
            // A drag dropped outside the chips (cancelled) never reaches a delegate: clear it once the mouse is up.
            .onHover { _ in if draggingFavourite != nil && NSEvent.pressedMouseButtons == 0 { draggingFavourite = nil } }
    }

    private static let favouritesLayouts: [(id: String, title: String, icon: String)] = [
        ("bar", "Bar", "rectangle.split.3x1"), ("list", "List", "list.bullet.rectangle")
    ]

    private var isListLayout: Bool { favouritesLayout == "list" }

    /// Switches the layout: Bar → List (opens it); in List, a click while closed opens it and while open goes back to Bar.
    private var favouritesButton: some View {
        let help = isListLayout
            ? (showFavouritesList ? "Click to show favourites as a bar instead (right-click for layouts)"
                                  : "Show favourites (click again while open for the bar; right-click for layouts)")
            : "Click to show favourites as a list instead (right-click for layouts)"
        return Button {
            if !isListLayout {
                favouritesLayout = "list"
                showFavouritesList = true
            } else if !showFavouritesList {
                showFavouritesList = true
            } else {
                showFavouritesList = false
                favouritesLayout = "bar"
            }
        } label: {
            HStack(spacing: 5) {
                Image(systemName: "star.square.on.square")
                    .font(.system(size: StudioTheme.scaleFont(11), weight: .medium))
                    .foregroundColor(palette.accentBlue)
                Text("Favourites")
                    .font(.ui(size: 12))
                    .foregroundColor(palette.textMain)
                if !browser.favourites.isEmpty {
                    Text("\(browser.favouritePages.count > 1 ? browser.pageFavourites.count : browser.favourites.count)")
                        .font(.ui(size: 11, weight: .semibold))
                        .monospacedDigit()
                        .foregroundColor(palette.textMuted)
                        .padding(.horizontal, 5)
                        .background(Capsule().fill(palette.bgSubtle))
                }
            }
            .padding(.horizontal, 7)
            .frame(height: StudioTheme.scale(24))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .modifier(ToolHover(fill: palette.bgSubtle, isOn: isListLayout && showFavouritesList))
        .help(help)
        .contextMenu {
            ForEach(Self.favouritesLayouts, id: \.id) { layout in
                Button {
                    favouritesLayout = layout.id
                    showFavouritesList = layout.id == "list"
                } label: {
                    Label(layout.title, systemImage: (isListLayout ? "list" : "bar") == layout.id ? "checkmark" : layout.icon)
                }
            }
        }
        .popover(isPresented: $showFavouritesList, arrowEdge: .bottom) { favouritesList }
    }

    /// The List layout: the same chips, stacked, in a popover from the Favourites button.
    private var favouritesList: some View {
        VStack(alignment: .leading, spacing: 8) {
            ScrollView(.horizontal, showsIndicators: false) { favouritePageTabs }
            if browser.pageFavourites.count > 1 {
                Text("Drag to reorder, or onto a tab to move")
                    .font(.ui(size: 11))
                    .foregroundColor(palette.textMuted)
            }
            if browser.pageFavourites.isEmpty {
                Text(browser.favourites.isEmpty ? "Star a project, folder or stack (☆ in the toolbar or right-click) to add it here."
                     : "Nothing on this page yet: star a place while it's open, or drag a favourite onto this tab.")
                    .font(.ui(size: 11))
                    .foregroundColor(palette.textMuted)
                    .fixedSize(horizontal: false, vertical: true)
            } else {
                ScrollView {
                    VStack(spacing: 5) {
                        ForEach(browser.pageFavourites) { favourite in
                            favouriteChip(favourite, fullWidth: true)
                        }
                    }
                }
                .frame(maxHeight: 420)
                .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(12)
        .frame(width: 320)
        .background(palette.bgPanel)
    }

    /// The favourites pages as tabs (up to 5): click to show one, double-click or right-click to rename, right-click
    /// to delete, + to add; a chip dropped on a tab moves there.
    private var favouritePageTabs: some View {
        HStack(spacing: 3) {
            Image(systemName: "star.fill")
                .font(.system(size: StudioTheme.scaleFont(10), weight: .semibold))
                .foregroundColor(palette.accentBlue)
                .padding(.trailing, 3)
            ForEach(Array(browser.favouritePages.enumerated()), id: \.offset) { index, name in
                FavouritePageTab(name: name, count: browser.favouriteCount(onPage: index),
                                 isSelected: index == browser.currentFavouritePage, canDelete: browser.favouritePages.count > 1,
                                 isLightMode: isLightMode, dragging: $draggingFavourite,
                                 onSelect: { browser.favouritePage = index },
                                 onRename: { browser.renameFavouritePage(index, to: $0) },
                                 onDelete: { browser.deleteFavouritePage(index) },
                                 onDropFavourite: { browser.moveFavourite($0, toPage: index) })
            }
            if browser.favouritePages.count < FrameIOBrowser.maxFavouritePages {
                Button(action: browser.addFavouritePage) {
                    Image(systemName: "plus")
                        .font(.system(size: StudioTheme.scaleFont(9), weight: .bold))
                        .foregroundColor(palette.textMuted)
                        .frame(width: StudioTheme.scale(22), height: StudioTheme.scale(22))
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .modifier(ToolHover(fill: palette.bgSubtle))
                .help("Add a favourites page (up to \(FrameIOBrowser.maxFavouritePages)), e.g. one per project")
            }
        }
        .fixedSize()
    }

    // MARK: Toolbar controls

    /// Icon (and optional title) of a toolbar control; menus get a small chevron.
    private func toolLabel(_ title: String?, systemImage: String, tint: Color? = nil, menu: Bool = false) -> some View {
        HStack(spacing: 5) {
            Image(systemName: systemImage)
                .font(.system(size: StudioTheme.scaleFont(11), weight: .medium))
                .foregroundColor(tint ?? palette.textMain)
            if let title {
                Text(title)
                    .font(.ui(size: 12))
                    .foregroundColor(palette.textMain)
            }
            if menu {
                Image(systemName: "chevron.down")
                    .font(.system(size: StudioTheme.scaleFont(8), weight: .semibold))
                    .foregroundColor(palette.textMuted)
            }
        }
        .padding(.horizontal, 7)
        .frame(height: StudioTheme.scale(24))
        .contentShape(Rectangle())
    }

    /// A toolbar button: rounded hover background, and a filled one while `isOn` (Log open, thumbnails shown).
    private func toolButton(_ title: String?, systemImage: String, help: String, isOn: Bool = false, tint: Color? = nil,
                            action: @escaping () -> Void) -> some View {
        Button(action: action) {
            toolLabel(title, systemImage: systemImage, tint: tint ?? (isOn ? palette.accentBlue : nil))
        }
        .buttonStyle(.plain)
        .modifier(ToolHover(fill: palette.bgSubtle, isOn: isOn))
        .tip(help)
    }

    /// Right-click → Download…: files, folders (with their contents) and stacks (their current version).
    @ViewBuilder
    private func downloadButton(_ targets: [FrameIO.Item]) -> some View {
        if let account = browser.accountID, !targets.isEmpty {
            Button { DownloadQueue.shared.download(targets, account: account) } label: {
                Label(targets.count == 1 ? "Download…" : "Download \(targets.count) Items…", systemImage: "arrow.down.circle")
            }
        }
    }

    /// Right-click → Edit Metadata…: Status, Assignee, Rating and custom fields on every selected file at once.
    @ViewBuilder
    private func metadataButton(_ targets: [FrameIO.Item]) -> some View {
        if let account = browser.accountID, let project = browser.projectID, !targets.isEmpty {
            Button {
                metadataRequest = .init(items: targets, account: account, project: project)
            } label: {
                Label("Edit Metadata…", systemImage: "tag")
            }
            .tip("Set Status, Assignee, Rating and other fields on these files (a folder: every file in it)")
        }
    }

    /// Links the items' files to the queue clips with the same name and size and imports their comments as QC notes.
    @ViewBuilder
    private func importCommentsButton(_ targets: [FrameIO.Item]) -> some View {
        if let account = browser.accountID, !targets.isEmpty {
            Button {
                browser.notify("Importing Frame.io comments…")
                Task {
                    let summary = await FrameIOCommentSync.shared.importComments(targets, account: account)
                    browser.notify(summary)
                }
            } label: {
                Label("Import Comments into QCpie", systemImage: "text.bubble")
            }
            .tip("Adds the Frame.io comments of these files (a folder: every file in it) to the QC notes of the queue clips with the same name and size")
            Button {
                sendNotes(targets, account: account)
            } label: {
                Label("Send QC Notes to Frame.io", systemImage: "arrow.up.message")
            }
            .tip("Adds the QC notes of the queue clips with the same name and size to these files (a folder: every file in it) as comments")
        }
    }

    /// Right-click → Send QC Notes to Frame.io: finds what would go, asks, then sends.
    private func sendNotes(_ targets: [FrameIO.Item], account: String) {
        browser.notify("Finding QC notes to send…")
        Task {
            let plan: FrameIOCommentSync.SendPlan
            do {
                plan = try await FrameIOCommentSync.shared.planSend(targets, account: account)
            } catch {
                browser.notify("Couldn't list the files: \(UploadEngine.describe(error))")
                return
            }
            guard plan.noteCount > 0 else {
                browser.notify(plan.clips.isEmpty && plan.unmatched > 0
                    ? "No queue clip matches these files (same name and size)" : "No QC notes to send: they're all on Frame.io")
                return
            }
            let target = targets.count == 1 ? "“\(targets[0].title)”" : "these \(targets.count) items"
            FrameIOCommentPush.confirm(notes: plan.noteCount, clips: plan.clips.count, onto: target) {
                browser.notify("Sending QC notes…")
                Task { browser.notify(await FrameIOCommentSync.shared.send(plan)) }
            }
        }
    }

    private var toolDivider: some View {
        Rectangle()
            .fill(palette.borderLine)
            .frame(width: 1, height: StudioTheme.scale(16))
            .padding(.horizontal, 4)
    }

    /// Breadcrumbs; the project and parent folders accept drops (move up, or upload there).
    /// One crumb: its title and how deep it is (0 = "Frame.io").
    private struct CrumbEntry {
        let title: String
        let depth: Int
        let crumb: Crumb?
    }

    /// "Frame.io" and the path, without the account when the workspace has the same name ("Wild Island Films ›
    /// Wild Island Films").
    private var crumbEntries: [CrumbEntry] {
        var entries = [CrumbEntry(title: "Frame.io", depth: 0, crumb: nil)]
        for (index, crumb) in browser.path.enumerated() {
            if crumb.level == .account, index + 1 < browser.path.count, browser.path[index + 1].title == crumb.title { continue }
            entries.append(CrumbEntry(title: crumb.title, depth: index + 1, crumb: crumb))
        }
        return entries
    }

    /// Whole names, Finder-style: when the path doesn't fit, its start folds into a "…" button and the deepest folders
    /// stay readable; only the last crumb on its own is ever shortened. Hover shows the full path.
    /// How many fit is worked out from the titles' text widths (`CrumbFitter`), and only that one row is built: a
    /// `ViewThatFits` over six rows re-laid them all out on every resize frame (measured: 80–90 ms a frame in a
    /// 1900 pt window, 10 ms without breadcrumbs).
    private var breadcrumbs: some View {
        let entries = crumbEntries
        return CrumbFitter(titles: entries.map(\.title)) { keep, shorten in
            crumbRow(entries, keep: keep, shortenLast: shorten)
        }
        .lineLimit(1)
        .help(entries.map(\.title).joined(separator: " › "))
    }

    private func crumbRow(_ entries: [CrumbEntry], keep: Int, shortenLast: Bool = false) -> some View {
        let hidden = Array(entries.dropLast(min(keep, entries.count)))
        let shown = Array(entries.suffix(min(keep, entries.count)))
        return HStack(spacing: 2) {
            if !hidden.isEmpty {
                // A plain button + popover, not a Menu: ViewThatFits measures every variant on each resize, and a Menu
                // (an AppKit pop-up button) made that slow.
                Button { hiddenCrumbsOpen = true } label: {
                    Image(systemName: "ellipsis")
                        .font(.system(size: StudioTheme.scaleFont(11), weight: .semibold))
                        .foregroundColor(palette.textMuted)
                        .padding(.horizontal, 6)
                        .frame(height: StudioTheme.scale(24))
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .modifier(ToolHover(fill: palette.bgSubtle))
                .help(hidden.map(\.title).joined(separator: " › "))
                .popover(isPresented: $hiddenCrumbsOpen, arrowEdge: .bottom) { hiddenCrumbsList(hidden) }
                crumbChevron
            }
            ForEach(Array(shown.enumerated()), id: \.element.depth) { index, entry in
                if index > 0 { crumbChevron }
                let isLast = index == shown.count - 1
                crumbButton(entry.title, depth: entry.depth, crumb: entry.crumb, isLast: isLast, shortens: shortenLast && isLast)
            }
        }
    }

    /// The folded start of the path: click a level to go there.
    private func hiddenCrumbsList(_ hidden: [CrumbEntry]) -> some View {
        VStack(alignment: .leading, spacing: 1) {
            ForEach(Array(hidden.enumerated()), id: \.element.depth) { index, entry in
                Button {
                    hiddenCrumbsOpen = false
                    browser.goTo(depth: entry.depth)
                } label: {
                    HStack(spacing: 7) {
                        Image(systemName: crumbIcon(entry.crumb))
                            .font(.system(size: StudioTheme.scaleFont(11)))
                            .foregroundColor(palette.accentBlue)
                            .frame(width: StudioTheme.scale(16))
                        Text(entry.title)
                            .font(.ui(size: 12))
                            .foregroundColor(palette.textMain)
                            .lineLimit(1)
                        Spacer(minLength: 0)
                    }
                    .padding(.leading, CGFloat(index) * 10 + 8)
                    .padding(.trailing, 8)
                    .frame(height: StudioTheme.scale(26))
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .modifier(ToolHover(fill: palette.bgSubtle))
            }
        }
        .padding(6)
        .frame(minWidth: 220, maxWidth: 420, alignment: .leading)
        .background(palette.bgPanel)
    }

    private var crumbChevron: some View {
        Image(systemName: "chevron.right")
            .font(.system(size: StudioTheme.scaleFont(9), weight: .semibold))
            .foregroundColor(palette.textMuted.opacity(0.6))
    }

    private func crumbIcon(_ crumb: Crumb?) -> String {
        switch crumb?.level {
        case nil: return "house"
        case .account?: return "person.crop.circle"
        case .workspace?: return "square.grid.2x2"
        case .project?: return "film.stack"
        case .stack?: return "square.stack.3d.up"
        case .folder?: return "folder"
        }
    }

    private func crumbButton(_ title: String, depth: Int, crumb: Crumb?, isLast: Bool, shortens: Bool = false) -> some View {
        let folder = isLast ? nil : crumb?.listedFolder
        let key = "crumb-\(depth)"
        let titles = Array(browser.path.prefix(depth).filter { $0.level == .project || $0.level == .folder }.map(\.title))
        return Button(action: { browser.goTo(depth: depth) }) {
            Text(title)
                .font(.ui(size: 12, weight: isLast ? .semibold : .regular))
                .foregroundColor(dropTarget == key ? .white : (isLast ? palette.textMain : palette.textMuted))
                .truncationMode(.middle)
                .fixedSize(horizontal: !shortens, vertical: false)
                .padding(.horizontal, 6)
                .frame(height: StudioTheme.scale(24))
                .background(RoundedRectangle(cornerRadius: StudioTheme.cornerRadius).fill(dropTarget == key ? palette.accentBlue : .clear))
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .modifier(ToolHover(fill: palette.bgSubtle, isEnabled: !isLast && dropTarget != key))
        .disabled(isLast)
        .dropIf(folder != nil, isTargeted: targetBinding(key)) { providers in
            guard let folder else { return false }
            return accept(providers, into: folder, titles: titles)
        }
    }

    private typealias Crumb = FrameIOBrowser.Crumb

    // MARK: List

    private var folderList: some View {
        let visibleItems = browser.visibleItems
        return Group {
            if browser.isLoading {
                VStack { Spacer(); ProgressView().controlSize(.small); Spacer() }.frame(maxWidth: .infinity)
            } else if let error = browser.error {
                VStack(spacing: 10) {
                    Spacer()
                    Text(error).font(.ui(size: 12)).foregroundColor(palette.negative).multilineTextAlignment(.center)
                    Button("Try Again", action: browser.reload)
                    Spacer()
                }
                .frame(maxWidth: 520)
            } else if visibleItems.isEmpty && browser.showsFavouriteProjectsOnly && browser.filter.isEmpty
                        && !browser.items.contains(where: browser.isFavourite) {
                noFavouriteProjects
            } else if visibleItems.isEmpty && browser.atProjectList && browser.filter.isEmpty && !browser.items.isEmpty {
                VStack {
                    Spacer()
                    Text(browser.projectStatus == .all ? "No projects" : "No \(browser.projectStatus.title.lowercased()) \(browser.showsFavouriteProjectsOnly ? "favourite " : "")projects")
                        .font(.ui(size: 12)).foregroundColor(palette.textMuted)
                    Spacer()
                }
                .frame(maxWidth: .infinity)
            } else if visibleItems.isEmpty {
                VStack { Spacer(); Text(browser.items.isEmpty ? "Empty" : "No matches").font(.ui(size: 12)).foregroundColor(palette.textMuted); Spacer() }
                    .frame(maxWidth: .infinity)
                    .contentShape(Rectangle())
            } else {
                ScrollViewReader { scroller in
                ScrollView {
                    // Pinned inside the scroll view so the column titles share the rows' width (scroll bar included).
                    LazyVStack(spacing: 0, pinnedViews: [.sectionHeaders]) {
                        Section {
                            ForEach(Array(visibleItems.enumerated()), id: \.element.id) { index, item in
                                if browser.inStack {
                                    versionRow(item, index: browser.filter.isEmpty ? index : (browser.items.firstIndex { $0.id == item.id } ?? index))
                                } else if inFolder {
                                    contentRow(item, striped: index.isMultiple(of: 2))
                                } else {
                                    navigationRow(item, striped: index.isMultiple(of: 2))
                                }
                            }
                        } header: {
                            if browser.atProjectList { projectColumnHeader } else if inFolder || browser.inStack { contentColumnHeader }
                        }
                    }
                    .padding(.bottom, 6)
                    .padding(.top, browser.atProjectList || inFolder || browser.inStack ? 0 : 6)
                    Color.clear
                        .frame(height: 60)
                        .contentShape(Rectangle())
                        .onTapGesture { browser.selection = [] }
                }
                .onChange(of: browser.revealID) { _, id in
                    guard let id else { return }
                    DispatchQueue.main.async {
                        withAnimation(Motion.list) { scroller.scrollTo(id, anchor: .center) }
                        browser.didReveal()   // so pasting the same link again scrolls again
                    }
                }
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .overlay(RoundedRectangle(cornerRadius: Radius.control).stroke(isListTargeted ? palette.accentBlue : .clear, lineWidth: 2).padding(2))
        .dropIf(inFolder, isTargeted: $isListTargeted) { providers in
            guard let folder = browser.currentFolderID else { return false }
            return accept(providers, into: folder, titles: browser.destinationTitles)
        }
        .contextMenu {
            undoMenuItem
            if inFolder {
                Button(action: browser.newFolder) { Label("New Folder", systemImage: "folder.badge.plus") }
                Divider()
                Button(action: shareSelectionOrFolder) { Label("Create Share Link", systemImage: "square.and.arrow.up") }
                Divider()
            }
            if browser.atProjectList {
                Button { showNewProject = true } label: { Label("New Project…", systemImage: "plus.rectangle.on.folder") }
                Divider()
            }
            Button(action: browser.refresh) { Label("Refresh", systemImage: "arrow.clockwise") }
        }
    }

    /// Column titles over the project list (Frame.io's project table, minus Workspace: it's in the breadcrumbs).
    private var projectColumnHeader: some View {
        columnHeader("Project", inset: StudioTheme.scale(22) + 10,
                     columns: ProjectColumn.allCases.map { ($0.title, $0.width) })
    }

    /// Column titles over a folder's contents (aligned with the names) or a stack's versions (over the V badges).
    private var contentColumnHeader: some View {
        columnHeader(browser.inStack ? "Version" : "Name",
                     inset: browser.inStack ? 0 : (showThumbnails ? CGFloat(thumbnailWidth) : StudioTheme.scale(18)) + 10,
                     columns: ContentColumn.allCases.map { ($0.title, $0.width) })
    }

    private func columnHeader(_ name: String, inset: CGFloat, columns: [(title: String, width: CGFloat)]) -> some View {
        VStack(spacing: 0) {
            HStack(spacing: 10) {
                // One line each: squeezed by the fixed-width columns, a wrapping title made the header tall.
                Text(name)
                    .lineLimit(1)
                    .padding(.leading, inset)
                Spacer(minLength: 0)
                ForEach(columns, id: \.title) { column in
                    Text(column.title)
                        .lineLimit(1)
                        .truncationMode(.tail)
                        .frame(width: StudioTheme.scale(column.width), alignment: .leading)
                }
                Color.clear.frame(width: StudioTheme.scale(10))
            }
            .font(.ui(size: 11, weight: .semibold))
            .foregroundColor(palette.textMuted)
            .padding(.horizontal, 20)
            .padding(.vertical, 6)
            Rectangle().fill(palette.borderLine).frame(height: 1)
        }
        .background(palette.bgPanel)
    }

    /// The Favourites view of a project list with no favourite projects yet.
    private var noFavouriteProjects: some View {
        VStack(spacing: 10) {
            Spacer()
            Image(systemName: "star")
                .font(.system(size: StudioTheme.scaleFont(22), weight: .light))
                .foregroundColor(palette.textMuted)
            Text("No favourite projects yet")
                .font(.ui(size: 13, weight: .semibold))
                .foregroundColor(palette.textMain)
            Text("Star the projects you work on to see just those here.")
                .font(.ui(size: 11))
                .foregroundColor(palette.textMuted)
            Button(action: { browser.favouriteProjectsOnly = false }) {
                toolLabel("Show All Projects", systemImage: "square.grid.2x2")
            }
            .buttonStyle(.plain)
            .modifier(ToolHover(fill: palette.bgSubtle))
            Spacer()
        }
        .frame(maxWidth: .infinity)
    }

    /// Accounts, workspaces and projects: click to open. Projects accept uploads into their top level.
    private func navigationRow(_ item: FrameIO.Item, striped: Bool) -> some View {
        let isProject = browser.atProjectList
        let isFavourite = isProject && browser.isFavourite(item)
        let key = item.id
        return Button(action: { browser.open(item) }) {
            HStack(spacing: 10) {
                if isProject {
                    FrameIOProjectIcon(item: item, isLightMode: isLightMode)
                } else {
                    Image(systemName: browser.path.isEmpty ? "person.crop.circle" : "square.grid.2x2")
                        .font(.system(size: StudioTheme.scaleFont(13)))
                        .foregroundColor(palette.accentBlue)
                        .frame(width: StudioTheme.scale(18))
                }
                Text(item.title)
                    .font(.ui(size: 12))
                    .foregroundColor(palette.textMain)
                    .lineLimit(1)
                    .truncationMode(.middle)
                Spacer()
                if isProject {
                    Color.clear.frame(width: StudioTheme.scale(24))   // room for the star overlay
                    ForEach(ProjectColumn.allCases, id: \.self) { column in
                        Text(column.value(for: item))
                            .font(.ui(size: 11))
                            .foregroundColor(column == .status && item.isInactive ? palette.textMuted : palette.textSubtle)
                            .lineLimit(1)
                            .frame(width: StudioTheme.scale(column.width), alignment: .leading)
                    }
                }
                Image(systemName: "chevron.right")
                    .font(.system(size: StudioTheme.scaleFont(10), weight: .semibold))
                    .foregroundColor(palette.textMuted.opacity(0.6))
                    .frame(width: StudioTheme.scale(10))
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 6)
            .modifier(HoverBackground(base: dropTarget == key ? palette.accentBlue.opacity(0.22) : (striped ? palette.bgCardSubtle : Color.clear),
                                      hover: palette.bgSubtle, isActive: dropTarget != key))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .overlay(alignment: .trailing) {
            if isProject {
                Button(action: { browser.toggleFavourite(item) }) {
                    Image(systemName: isFavourite ? "star.fill" : "star")
                        .font(.system(size: StudioTheme.scaleFont(11), weight: .medium))
                        .foregroundColor(isFavourite ? palette.accentBlue : palette.textMuted.opacity(0.45))
                        .frame(width: StudioTheme.scale(24), height: StudioTheme.scale(22))
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .modifier(ToolHover(fill: palette.bgSubtle))
                .tip(isFavourite ? "Remove from Favourites" : "Add to Favourites")
                .padding(.trailing, 20 + StudioTheme.scale(10) + 10 + ProjectColumn.totalWidth)   // left of the columns
            }
        }
        .contextMenu {
            if isProject {
                Button { browser.open(item) } label: { Label("Open", systemImage: "film.stack") }
                Divider()
                if let root = item.rootFolderID {
                    Button { shareRequest = ShareRequest(project: item.id, name: item.title, assetIDs: [root]) } label: {
                        Label("Create Share Link", systemImage: "square.and.arrow.up")
                    }
                    Divider()
                }
                if let link = item.viewURL, let url = URL(string: link) {
                    Button { NSWorkspace.shared.open(url) } label: { Label("Open in Frame.io", systemImage: "arrow.up.forward.square") }
                    Divider()
                    Button { copy(link) } label: { Label("Copy Project URL", systemImage: "link") }
                }
                Divider()
                Button(isFavourite ? "Remove from Favourites" : "Add to Favourites") { browser.toggleFavourite(item) }
            }
        }
        .dropIf(isProject && item.rootFolderID != nil, isTargeted: targetBinding(key)) { providers in
            guard let root = item.rootFolderID else { return false }
            return accept(providers, into: root, titles: [item.title])
        }
    }

    /// Folders and files inside a project: Finder-style selection, double-click to open, drag to move, right-click menu.
    private func contentRow(_ item: FrameIO.Item, striped: Bool) -> some View {
        let isSelected = browser.selection.contains(item.id)
        let isTargeted = dropTarget == item.id
        let isRenaming = browser.renamingID == item.id
        let foreground: Color = isSelected ? .white : palette.textMain
        return HStack(spacing: 10) {
            if showThumbnails {
                FrameIOThumbnail(item: item, width: thumbnailWidth, isLightMode: isLightMode)
            } else {
                Image(systemName: item.isFolder ? "folder.fill" : (item.isVersionStack ? "square.stack.3d.up.fill" : "doc"))
                    .font(.system(size: StudioTheme.scaleFont(13)))
                    .foregroundColor(isSelected ? .white : (item.isFolder || item.isVersionStack ? palette.accentBlue : palette.textMuted))
                    .frame(width: StudioTheme.scale(18))
            }
            if isRenaming {
                renameField(item)
            } else {
                Text(item.title)
                    .font(.ui(size: 12))
                    .foregroundColor(foreground)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            if item.isVersionStack, let count = browser.versionCounts[item.id] {
                versionBadge("V\(count)", isSelected: isSelected)
                    .tip("\(count) versions: showing V\(count), the current one")
            }
            Spacer()
            contentColumns(item, isSelected: isSelected)
            if item.isFolder || item.isVersionStack {
                Image(systemName: "chevron.right")
                    .font(.system(size: StudioTheme.scaleFont(10), weight: .semibold))
                    .foregroundColor(isSelected ? .white : palette.textMuted.opacity(0.6))
                    .frame(width: StudioTheme.scale(10))
                    .contentShape(Rectangle().inset(by: -6))
                    .onTapGesture { browser.open(item) }
            } else {
                Color.clear.frame(width: StudioTheme.scale(10))
            }
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 6)
        .modifier(HoverBackground(
            base: isSelected ? palette.accentBlue : (isTargeted ? palette.accentBlue.opacity(0.22) : (striped ? palette.bgCardSubtle : Color.clear)),
            hover: palette.bgSubtle, isActive: !isSelected && !isTargeted))
        .overlay(Rectangle().stroke(isTargeted ? palette.accentBlue : .clear, lineWidth: 1.5))
        .contentShape(Rectangle())
        .onTapGesture {
            if (NSApp.currentEvent?.clickCount ?? 1) >= 2 {
                // Folders and stacks open; a file previews (like Space).
                if item.isFolder || item.isVersionStack { browser.open(item) } else { FrameIOPreview.shared.preview(item) }
            } else {
                browser.click(item.id)
            }
        }
        .onDrag {
            let ids = browser.targets(for: item).map(\.id)
            return NSItemProvider(object: (FrameIOBrowser.dragPrefix + ids.joined(separator: "\n")) as NSString)
        }
        .dropIf(true, isTargeted: targetBinding(item.id)) { providers in
            if item.isVersionStack || !item.isFolder { return acceptIntoStack(providers, stack: item) }
            return accept(providers, into: item.id, titles: browser.destinationTitles + [item.title])
        }
        .contextMenu { menu(for: item) }
    }

    private func contentColumns(_ item: FrameIO.Item, isSelected: Bool) -> some View {
        ForEach(ContentColumn.allCases, id: \.self) { column in
            Text(column.value(for: item))
                .font(.ui(size: 11))
                .foregroundColor(isSelected ? .white.opacity(0.85) : palette.textMuted)
                .lineLimit(1)
                .frame(width: StudioTheme.scale(column.width), alignment: .leading)
        }
    }

    private func versionBadge(_ text: String, isSelected: Bool) -> some View {
        Text(text)
            .font(.ui(size: 11, weight: .bold))
            .foregroundColor(isSelected ? palette.accentBlue : .white)
            .padding(.horizontal, 5)
            .padding(.vertical, 1)
            .background(Capsule().fill(isSelected ? Color.white : palette.accentBlue))
            .fixedSize()
    }

    /// Inside a stack: its versions, newest first, numbered, with the current one marked.
    private func versionRow(_ item: FrameIO.Item, index: Int) -> some View {
        let isSelected = browser.selection.contains(item.id)
        let number = browser.items.count - index
        let isRenaming = browser.renamingID == item.id
        return HStack(spacing: 10) {
            versionBadge("V\(number)", isSelected: isSelected)
                .frame(width: StudioTheme.scale(34), alignment: .leading)
            if showThumbnails {
                FrameIOThumbnail(item: item, width: thumbnailWidth, isLightMode: isLightMode)
            }
            if isRenaming {
                renameField(item)
            } else {
                Text(item.title)
                    .font(.ui(size: 12, weight: index == 0 ? .semibold : .regular))
                    .foregroundColor(isSelected ? .white : palette.textMain)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            if index == 0 {
                Text("Current")
                    .font(.ui(size: 11, weight: .semibold))
                    .foregroundColor(isSelected ? .white : palette.positive)
            }
            Spacer()
            contentColumns(item, isSelected: isSelected)
            Color.clear.frame(width: StudioTheme.scale(10))
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 7)
        .modifier(HoverBackground(base: isSelected ? palette.accentBlue : (index.isMultiple(of: 2) ? palette.bgCardSubtle : Color.clear),
                                  hover: palette.bgSubtle, isActive: !isSelected))
        .contentShape(Rectangle())
        .onTapGesture {
            // Double-click previews the version (like Space).
            if (NSApp.currentEvent?.clickCount ?? 1) >= 2 { FrameIOPreview.shared.preview(item) } else { browser.click(item.id) }
        }
        .contextMenu {
            let targets = browser.targets(for: item)
            undoMenuItem
            shareButton(targets)
            Divider()
            openInNewTab(targets.count == 1 ? item : nil)
            downloadButton(targets)
            importCommentsButton(targets)
            metadataButton(targets)
            Divider()
            copyURLButton(targets)
            if targets.count == 1 {
                Button { startRename(item) } label: { Label("Rename", systemImage: "character.cursor.ibeam") }
            }
            Divider()
            Button { browser.removeFromStack(targets) } label: {
                Label(targets.count == 1 ? "Remove from Stack" : "Remove \(targets.count) Versions from Stack",
                      systemImage: "square.stack.3d.down.right")
            }
            deleteButton(for: item)
        }
    }

    /// Frame.io files dropped on a stack become its newest versions; dropped on a file, they stack with it (the file is
    /// V1, the dropped ones come after). Queue files upload into the open folder.
    private func acceptIntoStack(_ providers: [NSItemProvider], stack: FrameIO.Item) -> Bool {
        guard let folder = browser.currentFolderID else { return false }
        let titles = browser.destinationTitles
        if Self.acceptFinderFiles(providers, into: folder, titles: titles) { return true }
        guard let provider = providers.first(where: { $0.canLoadObject(ofClass: NSString.self) }) else { return false }
        _ = provider.loadObject(ofClass: NSString.self) { object, _ in
            guard let text = object as? String else { return }
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    if text.hasPrefix(UploadQueue.dragPrefix) {
                        // Queue files dropped on a file row upload into the open folder, as if dropped on the list.
                        Self.startUpload(text, into: folder, titles: titles)
                    } else if text.hasPrefix(FrameIOBrowser.dragPrefix) {
                        let ids = Set(text.dropFirst(FrameIOBrowser.dragPrefix.count).split(separator: "\n").map(String.init))
                        let files = FrameIOBrowser.shared.items.filter { ids.contains($0.id) }
                        if stack.isVersionStack {
                            FrameIOBrowser.shared.addToStack(files, stack: stack)
                        } else {
                            FrameIOBrowser.shared.stackOnto(stack, files)
                        }
                    }
                }
            }
        }
        return true
    }

    /// Same names, order and groups as Frame.io's right-click menu (Create Share Link … Rename); QCpie extras after.
    @ViewBuilder
    private func menu(for item: FrameIO.Item) -> some View {
        let targets = browser.targets(for: item)
        let single = targets.count == 1 ? targets.first : nil
        undoMenuItem
        shareButton(targets)
        Divider()
        openInNewTab(single)
        downloadButton(targets)
        importCommentsButton(targets)
        metadataButton(targets)
        Divider()
        if let single, single.isVersionStack {
            Button { browser.open(single) } label: { Label("Version History", systemImage: "square.stack") }
            Divider()
        }
        copyURLButton(targets)
        Button { copyItems = MoveRequest(items: targets) } label: { Label("Copy to", systemImage: "doc.on.doc") }
        moveToMenu(targets)
        Button { browser.duplicate(targets) } label: { Label("Duplicate", systemImage: "plus.square.on.square") }
        if let single {
            Button { startRename(single) } label: { Label("Rename", systemImage: "character.cursor.ibeam") }
        }
        Divider()
        let files = targets.filter { !$0.isFolder && !$0.isVersionStack }
        if files.count == targets.count, (2...10).contains(files.count) {
            Button { stackItems = MoveRequest(items: files) } label: {
                Label("Stack \(files.count) Files as Versions…", systemImage: "square.stack.3d.up")
            }
        }
        if let single, single.isVersionStack {
            Button { browser.unstack(single) } label: { Label("Unstack", systemImage: "square.stack.3d.down.right") }
        }
        if let single, single.isFolder || single.isVersionStack, !browser.isFavourite(single) {
            Button { browser.addFavourite(single) } label: { Label("Add to Favourites", systemImage: "star") }
        }
        deleteButton(for: item)
    }

    /// Frame.io's Delete, last in its menu; asks first.
    @ViewBuilder
    private func deleteButton(for item: FrameIO.Item) -> some View {
        if let targets = browser.deletable(for: item) {
            Divider()
            Button(role: .destructive) { browser.confirmDelete(targets) } label: {
                Label(targets.count == 1 ? "Delete" : "Delete \(targets.count) Items", systemImage: "trash")
            }
        }
    }

    @ViewBuilder
    private func openInNewTab(_ item: FrameIO.Item?) -> some View {
        if let link = item?.viewURL, let url = URL(string: link) {
            Button { NSWorkspace.shared.open(url) } label: { Label("Open in Frame.io", systemImage: "arrow.up.forward.square") }
        }
    }

    /// Frame.io's names: "Copy Folder URL" on folders, "Copy Asset URL" on files and stacks.
    @ViewBuilder
    private func copyURLButton(_ targets: [FrameIO.Item]) -> some View {
        let links = targets.compactMap(\.viewURL)
        if !links.isEmpty {
            let title = targets.count > 1 ? "Copy URLs"
                : (targets[0].isFolder ? "Copy Folder URL" : "Copy Asset URL")
            Button { copy(links.joined(separator: "\n")) } label: { Label(title, systemImage: "link") }
        }
    }

    /// "Move to ▸": the folders above (to move up) and next to the items, then Choose Folder… for anywhere else.
    @ViewBuilder
    private func moveToMenu(_ targets: [FrameIO.Item]) -> some View {
        let ids = Set(targets.map(\.id))
        let ancestors = Array(browser.path.enumerated()).filter { index, crumb in
            index < browser.path.count - 1 && crumb.listedFolder != nil
        }
        let siblings = browser.items.filter { $0.isFolder && !ids.contains($0.id) }
        Menu {
            ForEach(ancestors.reversed(), id: \.offset) { _, crumb in
                if let folder = crumb.listedFolder {
                    Button { browser.move(targets, to: folder, titled: crumb.title) } label: {
                        Label(crumb.title, systemImage: crumb.level == .project ? "film.stack" : "arrow.turn.left.up")
                    }
                }
            }
            if !ancestors.isEmpty && !siblings.isEmpty { Divider() }
            ForEach(siblings.prefix(30)) { folder in
                Button { browser.move(targets, to: folder.id, titled: folder.title) } label: { Label(folder.title, systemImage: "folder") }
            }
            Divider()
            Button("Choose Folder…") { moveItems = MoveRequest(items: targets) }
        } label: {
            Label("Move to", systemImage: "folder.badge.gearshape")
        }
    }

    // MARK: Actions

    @ViewBuilder
    private var undoMenuItem: some View {
        if let undo = browser.lastUndo {
            Button("Undo: \(undo.message)", action: browser.performUndo)
            Divider()
        }
    }

    /// Toolbar Share: the selection, else the open folder (or stack).
    private func shareSelectionOrFolder() {
        guard let project = browser.projectID else { return }
        let selected = browser.items.filter { browser.selection.contains($0.id) }
        if !selected.isEmpty {
            shareRequest = ShareRequest(project: project, name: selected.count == 1 ? selected[0].title : "\(selected.count) items",
                                        assetIDs: selected.map(\.id), items: selected)
        } else if let current = browser.path.last, let id = current.listedFolder ?? (browser.inStack ? current.id : nil) {
            shareRequest = ShareRequest(project: project, name: current.title, assetIDs: [id])
        }
    }

    @ViewBuilder
    private func shareButton(_ targets: [FrameIO.Item]) -> some View {
        if let project = browser.projectID, !targets.isEmpty {
            Button {
                shareRequest = ShareRequest(project: project, name: targets.count == 1 ? targets[0].title : "\(targets.count) items",
                                            assetIDs: targets.map(\.id), items: targets)
            } label: {
                Label("Create Share Link", systemImage: "square.and.arrow.up")
            }
            Menu {
                if browser.projectShares.isEmpty {
                    Text("No share links in this project yet")
                }
                ForEach(browser.projectShares.prefix(25)) { share in
                    Button(share.name ?? share.shortURL ?? "Untitled share") { browser.addToShare(targets, share: share) }
                }
            } label: {
                Label("Add to Share Links", systemImage: "rectangle.stack.badge.plus")
            }
        }
    }

    private func renameField(_ item: FrameIO.Item) -> some View {
        TextField("", text: $renameText)
            .textFieldStyle(.plain)
            .font(.ui(size: 12))
            .padding(.horizontal, 4)
            .background(RoundedRectangle(cornerRadius: 3).fill(palette.bgMain))
            .focused($renameFocused)
            .onAppear {
                renameText = item.title
                DispatchQueue.main.async { renameFocused = true }
            }
            .onChange(of: renameFocused) { _, focused in
                if !focused { finishRename(item) }
            }
            .onSubmit { renameFocused = false }
    }

    private func startRename(_ item: FrameIO.Item) {
        browser.selection = [item.id]
        browser.renamingID = item.id
    }

    /// Return or clicking away renames; Esc cancels (the shortcut router unfocuses the field for both).
    private func finishRename(_ item: FrameIO.Item) {
        guard browser.renamingID == item.id else { return }
        browser.renamingID = nil
        let cancelled = NSApp.currentEvent?.type == .keyDown && NSApp.currentEvent?.keyCode == 53
        if !cancelled { browser.rename(item, to: renameText) }
    }

    private func copy(_ text: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }

    private func targetBinding(_ key: String) -> Binding<Bool> {
        Binding(
            get: { dropTarget == key },
            set: { inside in
                if inside { dropTarget = key } else if dropTarget == key { dropTarget = nil }
            }
        )
    }

    /// A drop on a folder: queue files start uploading there; Frame.io items dragged from this list move there.
    private func accept(_ providers: [NSItemProvider], into folder: String, titles: [String]) -> Bool {
        guard browser.accountID != nil else { return false }
        if Self.acceptFinderFiles(providers, into: folder, titles: titles) { return true }
        guard let provider = providers.first(where: { $0.canLoadObject(ofClass: NSString.self) }) else { return false }
        _ = provider.loadObject(ofClass: NSString.self) { object, _ in
            guard let text = object as? String else { return }
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    if text.hasPrefix(UploadQueue.dragPrefix) {
                        Self.startUpload(text, into: folder, titles: titles)
                    } else if text.hasPrefix(FrameIOBrowser.dragPrefix) {
                        let ids = Set(text.dropFirst(FrameIOBrowser.dragPrefix.count).split(separator: "\n").map(String.init))
                        let moving = FrameIOBrowser.shared.items.filter { ids.contains($0.id) }
                        FrameIOBrowser.shared.move(moving, to: folder, titled: titles.last ?? "Frame.io")
                    }
                }
            }
        }
        return true
    }

    /// Files and folders dragged from Finder: they join the app's queue, then upload to `folder` (`uploadFromFinder`).
    /// Checked before the text drags, since Finder also offers file names as text.
    private static func acceptFinderFiles(_ providers: [NSItemProvider], into folder: String, titles: [String]) -> Bool {
        let files = providers.filter { $0.hasItemConformingToTypeIdentifier(UTType.fileURL.identifier) }
        guard !files.isEmpty else { return false }
        final class Collector: @unchecked Sendable {
            let lock = NSLock()
            var urls: [URL] = []
        }
        let collector = Collector()
        let group = DispatchGroup()
        for provider in files {
            group.enter()
            _ = provider.loadObject(ofClass: URL.self) { url, _ in
                if let url { collector.lock.withLock { collector.urls.append(url) } }
                group.leave()
            }
        }
        group.notify(queue: .main) {
            MainActor.assumeIsolated {
                let urls = collector.lock.withLock { collector.urls }
                guard !urls.isEmpty, let account = FrameIOBrowser.shared.accountID else { return }
                guard !UploadQueue.shared.isRunning else {
                    FrameIOBrowser.shared.notify("An upload is already running: wait for it to finish or cancel it.", isError: true)
                    return
                }
                UploadQueue.shared.uploadFromFinder(urls, to: .init(account: account, folder: folder, path: titles.joined(separator: " › ")))
            }
        }
        return true
    }

    /// Starts uploading queue files dragged onto a Frame.io folder.
    private static func startUpload(_ text: String, into folder: String, titles: [String]) {
        let paths = text.dropFirst(UploadQueue.dragPrefix.count).split(separator: "\n").map(String.init)
        guard !paths.isEmpty, let account = FrameIOBrowser.shared.accountID else { return }
        guard !UploadQueue.shared.isRunning else {
            FrameIOBrowser.shared.notify("An upload is already running: wait for it to finish or cancel it.", isError: true)
            return
        }
        UploadQueue.shared.start(to: .init(account: account, folder: folder, path: titles.joined(separator: " › ")), paths: Set(paths))
    }

    // MARK: Toast

    @ViewBuilder
    private var toastView: some View {
        if let toast = browser.toast {
            HStack(spacing: 12) {
                Image(systemName: toast.isError ? "exclamationmark.triangle.fill" : "checkmark.circle.fill")
                    .foregroundColor(toast.isError ? palette.negative : palette.positive)
                Text(toast.message)
                    .font(.ui(size: 12))
                    .foregroundColor(palette.textMain)
                    .lineLimit(2)
                if toast.undo != nil, toast.id == browser.lastUndo?.id {
                    Button("Undo", action: browser.performUndo)
                    .font(.ui(size: 12, weight: .semibold))
                    .buttonStyle(.borderless)
                }
                Button(action: browser.dismissToast) {
                    Image(systemName: "xmark").font(.system(size: StudioTheme.scaleFont(9), weight: .semibold))
                }
                .buttonStyle(.borderless)
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 9)
            .background(RoundedRectangle(cornerRadius: Radius.container).fill(palette.bgPanel).shadow(color: .black.opacity(0.25), radius: 8, y: 2))
            .overlay(RoundedRectangle(cornerRadius: Radius.container).stroke(palette.borderLine))
            .padding(.bottom, 16)
            .padding(.horizontal, 20)
            .transition(.move(edge: .bottom).combined(with: .opacity))
            .id(toast.id)
        }
    }
}

/// "Move to…": browse the project's folders and pick where the items go.
private struct FrameIOMoveSheet: View {
    let items: [FrameIO.Item]
    /// Copy to (any folder, including this one) instead of Move to.
    let isCopy: Bool
    let isLightMode: Bool
    let onMove: (_ folder: String, _ title: String) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var path: [FrameIOBrowser.Crumb] = []
    @State private var folders: [FrameIO.Item] = []
    @State private var isLoading = true
    @State private var error: String?

    private var palette: StudioPalette { StudioPalette(isLightMode) }
    private var movingIDs: Set<String> { Set(items.map(\.id)) }
    private var current: FrameIOBrowser.Crumb? { path.last }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text((isCopy ? "Copy " : "Move ") + (items.count == 1 ? "“\(items[0].title)”" : "\(items.count) items") + " to")
                .font(.ui(size: 13, weight: .semibold))
                .lineLimit(1)
                .truncationMode(.middle)
                .padding(16)
            HStack(spacing: 4) {
                ForEach(Array(path.enumerated()), id: \.offset) { index, crumb in
                    if index > 0 {
                        Image(systemName: "chevron.right")
                            .font(.system(size: StudioTheme.scaleFont(9), weight: .semibold))
                            .foregroundColor(palette.textMuted.opacity(0.6))
                    }
                    Button(crumb.title) { path.removeSubrange((index + 1)...); load() }
                        .buttonStyle(.plain)
                        .font(.ui(size: 12, weight: index == path.count - 1 ? .semibold : .regular))
                        .foregroundColor(index == path.count - 1 ? palette.textMain : palette.textMuted)
                        .disabled(index == path.count - 1)
                }
            }
            .lineLimit(1)
            .padding(.horizontal, 16)
            .padding(.bottom, 8)
            Rectangle().fill(palette.borderLine).frame(height: 1)
            Group {
                if isLoading {
                    ProgressView().controlSize(.small).frame(maxWidth: .infinity, maxHeight: .infinity)
                } else if let error {
                    Text(error).font(.ui(size: 11)).foregroundColor(palette.negative).padding(16)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else if folders.isEmpty {
                    Text("No subfolders").font(.ui(size: 11)).foregroundColor(palette.textMuted)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else {
                    ScrollView {
                        LazyVStack(spacing: 0) {
                            ForEach(folders) { folder in
                                let blocked = movingIDs.contains(folder.id)
                                Button(action: {
                                    path.append(.init(level: .folder, id: folder.id, title: folder.title, folderID: folder.id))
                                    load()
                                }) {
                                    HStack(spacing: 10) {
                                        Image(systemName: "folder.fill").foregroundColor(palette.accentBlue)
                                        Text(folder.title).font(.ui(size: 12)).lineLimit(1)
                                        Spacer()
                                        Image(systemName: "chevron.right")
                                            .font(.system(size: StudioTheme.scaleFont(10), weight: .semibold))
                                            .foregroundColor(palette.textMuted.opacity(0.5))
                                    }
                                    .padding(.horizontal, 16)
                                    .padding(.vertical, 6)
                                    .contentShape(Rectangle())
                                }
                                .buttonStyle(.plain)
                                .disabled(blocked)
                                .opacity(blocked ? 0.4 : 1)
                            }
                        }
                        .padding(.vertical, 4)
                    }
                }
            }
            .frame(height: 280)
            Rectangle().fill(palette.borderLine).frame(height: 1)
            HStack {
                Spacer()
                Button("Cancel") { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button(isCopy ? "Copy Here" : "Move Here") {
                    guard let current, let folder = current.listedFolder else { return }
                    onMove(folder, current.title)
                    dismiss()
                }
                .keyboardShortcut(.defaultAction)
                .disabled(current?.listedFolder == nil || (!isCopy && current?.listedFolder == FrameIOBrowser.shared.currentFolderID))
            }
            .padding(16)
        }
        .frame(width: 440)
        .background(palette.bgPanel)
        .onAppear {
            // Start at the open project's root, then the open folder's path.
            path = FrameIOBrowser.shared.path.filter { $0.level == .project || $0.level == .folder }
            load()
        }
    }

    private func load() {
        guard let account = FrameIOBrowser.shared.accountID, let folder = current?.listedFolder else { return }
        isLoading = true
        error = nil
        Task {
            do {
                let children = try await FrameIO.shared.children(account: account, folder: folder, thumbnails: false)
                guard current?.listedFolder == folder else { return }
                folders = children.filter(\.isFolder)
                    .sorted { $0.title.localizedStandardCompare($1.title) == .orderedAscending }
            } catch {
                guard current?.listedFolder == folder else { return }
                self.error = error.localizedDescription
            }
            isLoading = false
        }
    }
}

private extension View {
    /// Accepts drops (Finder files, queue files or Frame.io items) only where `enabled`, so non-targets don't swallow them.
    @ViewBuilder
    func dropIf(_ enabled: Bool, isTargeted: Binding<Bool>, perform: @escaping ([NSItemProvider]) -> Bool) -> some View {
        if enabled {
            onDrop(of: [.fileURL, .utf8PlainText], isTargeted: isTargeted, perform: perform)
        } else {
            self
        }
    }
}

/// Frame.io's New Project dialog: a name, then Create (Return) or Cancel (Esc). The shortcut router leaves sheets'
/// keys alone, so Return and Esc reach these buttons.
private struct FrameIONewProjectSheet: View {
    @ObservedObject private var themeManager = ThemeManager.shared   // accent changes redraw
    let isLightMode: Bool
    let onCreate: (String) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var name = ""
    @FocusState private var focused: Bool

    private var palette: StudioPalette { StudioPalette(isLightMode) }
    private var trimmed: String { name.trimmingCharacters(in: .whitespacesAndNewlines) }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("New Project")
                .font(.ui(size: 15, weight: .semibold))
                .foregroundColor(palette.textMain)
            TextField("Project name", text: $name)
                .textFieldStyle(.roundedBorder)
                .font(.ui(size: 12))
                .focused($focused)
            HStack {
                Spacer()
                Button("Cancel") { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button("Create", action: create)
                    .keyboardShortcut(.defaultAction)
                    .disabled(trimmed.isEmpty)
            }
        }
        .padding(20)
        .frame(width: 340)
        .background(palette.bgPanel)
        .onAppear { DispatchQueue.main.async { focused = true } }
    }

    private func create() {
        guard !trimmed.isEmpty else { return }
        onCreate(trimmed)
        dismiss()
    }
}

/// "Stack as Versions…": puts the files in version order (V1 oldest … last = current) before stacking.
private struct FrameIOStackSheet: View {
    let isLightMode: Bool
    let onStack: ([FrameIO.Item]) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var ordered: [FrameIO.Item]

    init(files: [FrameIO.Item], isLightMode: Bool, onStack: @escaping ([FrameIO.Item]) -> Void) {
        self.isLightMode = isLightMode
        self.onStack = onStack
        _ordered = State(initialValue: files.sorted { $0.title.localizedStandardCompare($1.title) == .orderedAscending })
    }

    private var palette: StudioPalette { StudioPalette(isLightMode) }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Stack \(ordered.count) Files as Versions")
                .font(.ui(size: 13, weight: .semibold))
            Text("The last one becomes the current version. Use the arrows to change the order.")
                .font(.ui(size: 11))
                .foregroundColor(palette.textMuted)
            VStack(spacing: 0) {
                ForEach(Array(ordered.enumerated()), id: \.element.id) { index, file in
                    HStack(spacing: 10) {
                        Text("V\(index + 1)")
                            .font(.ui(size: 11, weight: .bold))
                            .foregroundColor(.white)
                            .padding(.horizontal, 5)
                            .padding(.vertical, 1)
                            .background(Capsule().fill(palette.accentBlue))
                            .frame(width: 34, alignment: .leading)
                        Text(file.title).font(.ui(size: 12)).lineLimit(1).truncationMode(.middle)
                        if index == ordered.count - 1 {
                            Text("Current").font(.ui(size: 11, weight: .semibold)).foregroundColor(palette.positive)
                        }
                        Spacer()
                        Button(action: { ordered.swapAt(index, index - 1) }) { Image(systemName: "chevron.up") }
                            .buttonStyle(.borderless)
                            .disabled(index == 0)
                        Button(action: { ordered.swapAt(index, index + 1) }) { Image(systemName: "chevron.down") }
                            .buttonStyle(.borderless)
                            .disabled(index == ordered.count - 1)
                    }
                    .padding(.horizontal, 10)
                    .padding(.vertical, 6)
                    .background(index.isMultiple(of: 2) ? palette.bgCardSubtle : Color.clear)
                }
            }
            .studioBox(background: palette.bgMain, border: palette.borderLine)
            HStack {
                Spacer()
                Button("Cancel") { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button("Stack") {
                    onStack(ordered)
                    dismiss()
                }
                .keyboardShortcut(.defaultAction)
            }
        }
        .padding(16)
        .frame(width: 460)
        .background(palette.bgPanel)
    }
}

/// "Create Share Link…", modelled on Frame.io's share dialog: the link is created straight away with Frame.io's defaults,
/// then name, access, invites and settings are edited in place. Setting changes are batched into one update (the API
/// allows 10 per minute).
private struct FrameIOShareSheet: View {
    let request: FrameIOBrowserView.ShareRequest
    let isLightMode: Bool
    @Environment(\.dismiss) private var dismiss
    @State private var share: FrameIO.Share?
    @State private var error: String?
    @State private var name = ""
    @FocusState private var nameFocused: Bool
    @State private var secure = false
    @State private var enabled = true
    @State private var comments = true
    @State private var downloads = true
    @State private var allVersions = false
    @State private var passphrase: String?
    /// The passphrase being typed (saved when the field loses focus).
    @State private var passphraseText = ""
    @FocusState private var passphraseFocused: Bool
    @State private var expiry: Date?
    @State private var invitees = ""
    @State private var message = ""
    @State private var notify = true
    @State private var inviteStatus: String?
    @State private var isInviting = false
    @State private var showSettings = false
    @State private var copied = false
    @State private var pending: [String: Any] = [:]
    @State private var saveTask: Task<Void, Never>?
    @State private var isSaving = false

    private var palette: StudioPalette { StudioPalette(isLightMode) }
    private var account: String? { FrameIOBrowser.shared.accountID }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            if let share {
                editor(share)
            } else {
                VStack(spacing: 12) {
                    if let error {
                        Text(error).font(.ui(size: 12)).foregroundColor(palette.negative).multilineTextAlignment(.center)
                        Button("Close") { dismiss() }
                    } else {
                        ProgressView().controlSize(.small)
                        Text("Creating share link…").font(.ui(size: 12)).foregroundColor(palette.textMuted)
                    }
                }
                .frame(maxWidth: .infinity, minHeight: 180)
                .padding(20)
            }
        }
        // Fixed size: macOS sheets don't resize with their content, so Settings is its own page (like Frame.io's).
        .frame(width: 440, height: 600)
        .background(palette.bgPanel)
        .task { await create() }
    }

    // MARK: Editor

    @ViewBuilder
    private func editor(_ share: FrameIO.Share) -> some View {
        if showSettings {
            settingsPage(share)
                .transition(.move(edge: .trailing))
        } else {
            mainPage(share)
                .transition(.move(edge: .leading))
        }
    }

    private func settingsPage(_ share: FrameIO.Share) -> some View {
        VStack(spacing: 0) {
            ZStack {
                Text("Settings").font(.ui(size: 13, weight: .semibold))
                HStack {
                    Button(action: { withAnimation(Motion.list) { showSettings = false } }) {
                        HStack(spacing: 3) {
                            Image(systemName: "chevron.left").font(.system(size: StudioTheme.scaleFont(11), weight: .semibold))
                            Text(name.isEmpty ? "Back" : name).font(.ui(size: 12)).lineLimit(1)
                        }
                        .frame(maxWidth: 150, alignment: .leading)
                    }
                    .buttonStyle(.borderless)
                    Spacer()
                    if isSaving { ProgressView().controlSize(.mini) }
                }
            }
            .padding(.horizontal, 18)
            .padding(.vertical, 14)
            Rectangle().fill(palette.borderLine).frame(height: 1)
            ScrollView {
                VStack(alignment: .leading, spacing: 10) {
                    Text(summary)
                        .font(.ui(size: 11))
                        .foregroundColor(palette.textMuted)
                        .fixedSize(horizontal: false, vertical: true)
                        .padding(.horizontal, 4)
                    settingsGroups
                }
                .padding(18)
            }
            Rectangle().fill(palette.borderLine).frame(height: 1)
            footer(share)
        }
    }

    private func footer(_ share: FrameIO.Share) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 10) {
                if let link = share.shortURL, let url = URL(string: link) {
                    Button(action: { NSWorkspace.shared.open(url) }) {
                        Label("Open in Frame.io", systemImage: "arrow.up.right").font(.ui(size: 12))
                    }
                    .buttonStyle(.borderless)
                }
                Spacer()
                Button("Copy Link", action: copyLink)
                Button("Done") { flushNow(); dismiss() }
                    .keyboardShortcut(.defaultAction)
            }
            .padding(.horizontal, 18)
            .padding(.vertical, 14)
            if let error {
                Text(error)
                    .font(.ui(size: 11))
                    .foregroundColor(palette.negative)
                    .padding(.horizontal, 18)
                    .padding(.bottom, 12)
            }
        }
    }

    private func mainPage(_ share: FrameIO.Share) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            VStack(alignment: .leading, spacing: 12) {
                HStack(spacing: 6) {
                    TextField("Share name", text: $name)
                        .textFieldStyle(.plain)
                        .font(.ui(size: 15, weight: .semibold))
                        .focused($nameFocused)
                        .onChange(of: nameFocused) { _, focused in
                            if !focused { commitName() }
                        }
                    Image(systemName: "pencil")
                        .font(.system(size: StudioTheme.scaleFont(11)))
                        .foregroundColor(palette.textMuted)
                    Spacer()
                    if isSaving { ProgressView().controlSize(.mini) }
                }

                HStack(spacing: 0) {
                    Text(share.shortURL ?? "—")
                        .font(.ui(size: 12))
                        .textSelection(.enabled)
                        .lineLimit(1)
                        .padding(.horizontal, 10)
                    Spacer(minLength: 6)
                    Button(action: copyLink) {
                        Image(systemName: copied ? "checkmark" : "link")
                            .font(.system(size: StudioTheme.scaleFont(12)))
                            .foregroundColor(copied ? palette.positive : palette.textMuted)
                    }
                    .buttonStyle(.borderless)
                    .tip("Copy link")
                    .padding(.trailing, 8)
                    Rectangle().fill(palette.borderLine).frame(width: 1)
                    Menu {
                        Button(action: { set(secure: false) }) {
                            Label("Public: anyone with the link", systemImage: "globe")
                        }
                        Button(action: { set(secure: true) }) {
                            Label(Self.secureUnavailable ? "Secure: not included in your Frame.io plan" : "Secure: only people you invite",
                                  systemImage: "lock")
                        }
                        .disabled(Self.secureUnavailable)
                    } label: {
                        Label(secure ? "Secure" : "Public", systemImage: secure ? "lock" : "globe")
                            .font(.ui(size: 12, weight: .semibold))
                    }
                    .menuStyle(.borderlessButton)
                    .fixedSize()
                    .padding(.horizontal, 10)
                }
                .frame(height: StudioTheme.scale(34))
                .studioBox(background: palette.bgMain, border: palette.borderLine)
                .opacity(enabled ? 1 : 0.5)

                invite
            }
            .padding(18)

            Rectangle().fill(palette.borderLine).frame(height: 1)

            VStack(alignment: .leading, spacing: 14) {
                preview
                settingsLink
            }
            .padding(18)
            .frame(maxHeight: .infinity, alignment: .top)

            Rectangle().fill(palette.borderLine).frame(height: 1)
            footer(share)
        }
    }

    private var invite: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                TextField("Add emails (separate with commas)", text: $invitees)
                    .textFieldStyle(.plain)
                    .font(.ui(size: 12))
                    .padding(.horizontal, 10)
                    .frame(height: StudioTheme.scale(30))
                    .studioBox(background: palette.bgMain, border: palette.borderLine)
                if !emails.isEmpty {
                    Button(isInviting ? "Inviting…" : "Invite", action: sendInvites)
                        .disabled(isInviting)
                }
            }
            if !emails.isEmpty {
                TextField("Message (optional)", text: $message)
                    .textFieldStyle(.plain)
                    .font(.ui(size: 12))
                    .padding(.horizontal, 10)
                    .frame(height: StudioTheme.scale(28))
                    .studioBox(background: palette.bgMain, border: palette.borderLine)
                Toggle("Send an email invitation", isOn: $notify)
                    .toggleStyle(.checkbox)
                    .font(.ui(size: 11))
            }
            if let inviteStatus {
                Text(inviteStatus).font(.ui(size: 11)).foregroundColor(palette.textMuted)
            }
        }
    }

    private var preview: some View {
        ZStack {
            RoundedRectangle(cornerRadius: Radius.segment).fill(palette.bgSubtle)
            if let first = request.items.first {
                FrameIOThumbnail(item: first, width: 200, isLightMode: isLightMode)
            } else {
                Image(systemName: "folder.fill")
                    .font(.system(size: StudioTheme.scaleFont(22)))
                    .foregroundColor(palette.textMuted)
            }
            if request.assetIDs.count > 1 {
                Text("\(request.assetIDs.count) items")
                    .font(.ui(size: 11, weight: .semibold))
                    .foregroundColor(.white)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background(Capsule().fill(Color.black.opacity(0.55)))
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomTrailing)
                    .padding(8)
            }
        }
        .frame(height: 140)
    }

    /// Opens the Settings page (Frame.io's "Settings ›" row).
    private var settingsLink: some View {
        Button(action: { withAnimation(Motion.list) { showSettings = true } }) {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Settings").font(.ui(size: 13, weight: .semibold)).foregroundColor(palette.textMain)
                    Text(summary).font(.ui(size: 11)).foregroundColor(palette.textMuted)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer()
                Image(systemName: "chevron.right").foregroundColor(palette.textMuted)
            }
            .padding(12)
            .background(RoundedRectangle(cornerRadius: Radius.container).fill(palette.bgCardSubtle))
            .overlay(RoundedRectangle(cornerRadius: Radius.container).stroke(palette.borderLine.opacity(0.7), lineWidth: 0.5))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private var settingsGroups: some View {
        VStack(alignment: .leading, spacing: 10) {
                VStack(alignment: .leading, spacing: 14) {
                    settingsGroup("Reviewers can") {
                        switchRow("Comment", value: $comments, key: "commenting_enabled")
                        rowDivider
                        switchRow("Download", value: $downloads, key: "downloading_enabled")
                        rowDivider
                        switchRow("See all versions", detail: "Every version in a stack, not just the current one",
                                  value: $allVersions, key: "show_all_asset_versions")
                    }
                    settingsGroup("Link") {
                        switchRow("Active", detail: "Off stops the link working without deleting it", value: $enabled, key: "enabled")
                        rowDivider
                        settingRow("Passphrase", detail: passphrase == nil ? nil : "Suggested, or type your own. Share it separately") {
                            Toggle("", isOn: Binding(get: { passphrase != nil }, set: { on in
                                passphrase = on ? Self.newPassphrase() : nil
                                passphraseText = passphrase ?? ""
                                queue("passphrase", passphrase ?? NSNull())
                            }))
                            .labelsHidden()
                            .toggleStyle(.switch)
                            .controlSize(.small)
                        }
                        if passphrase != nil {
                            HStack(spacing: 8) {
                                TextField("Passphrase", text: $passphraseText)
                                    .textFieldStyle(.plain)
                                    .font(.system(size: StudioTheme.scaleFont(12), design: .monospaced))
                                    .focused($passphraseFocused)
                                    .onChange(of: passphraseFocused) { _, focused in
                                        if !focused { commitPassphrase() }
                                    }
                                    .padding(.horizontal, 8)
                                    .frame(height: StudioTheme.scale(26))
                                    .background(RoundedRectangle(cornerRadius: 5).fill(palette.bgMain))
                                    .overlay(RoundedRectangle(cornerRadius: 5).stroke(palette.borderLine, lineWidth: 0.5))
                                Button(action: suggestPassphrase) {
                                    Image(systemName: "arrow.triangle.2.circlepath").font(.system(size: StudioTheme.scaleFont(11)))
                                }
                                .buttonStyle(.borderless)
                                .tip("Suggest a new strong passphrase")
                                Button(action: { Self.copy(passphraseText) }) {
                                    Image(systemName: "doc.on.doc").font(.system(size: StudioTheme.scaleFont(11)))
                                }
                                .buttonStyle(.borderless)
                                .tip("Copy passphrase")
                            }
                            .padding(.horizontal, 12)
                            .padding(.bottom, 10)
                            if passphraseText.trimmingCharacters(in: .whitespaces).count < 8 {
                                Text("Use at least 8 characters.")
                                    .font(.ui(size: 11))
                                    .foregroundColor(palette.negative)
                                    .padding(.horizontal, 12)
                                    .padding(.bottom, 8)
                                    .frame(maxWidth: .infinity, alignment: .leading)
                            }
                        }
                        rowDivider
                        settingRow("Expires") {
                            HStack(spacing: 8) {
                                if expiry != nil {
                                    DatePicker("", selection: Binding(get: { expiry ?? Date() }, set: { expiry = $0; queueExpiry() }),
                                               in: Date()..., displayedComponents: [.date, .hourAndMinute])
                                        .labelsHidden()
                                        .datePickerStyle(.compact)
                                        .controlSize(.small)
                                }
                                Toggle("", isOn: Binding(get: { expiry != nil }, set: { on in
                                    expiry = on ? Calendar.current.date(byAdding: .day, value: 7, to: Date()) : nil
                                    queueExpiry()
                                }))
                                .labelsHidden()
                                .toggleStyle(.switch)
                                .controlSize(.small)
                            }
                        }
                    }
                }
        }
    }

    /// A System Settings–style group: small header, rounded box, rows separated by hairlines.
    private func settingsGroup<Rows: View>(_ title: String, @ViewBuilder rows: () -> Rows) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title)
                .font(.ui(size: 11, weight: .semibold))
                .foregroundColor(palette.textMuted)
                .padding(.leading, 4)
            VStack(spacing: 0) { rows() }
                .background(RoundedRectangle(cornerRadius: Radius.container).fill(palette.bgCardSubtle))
                .overlay(RoundedRectangle(cornerRadius: Radius.container).stroke(palette.borderLine.opacity(0.7), lineWidth: 0.5))
        }
    }

    private var rowDivider: some View {
        Rectangle().fill(palette.borderLine.opacity(0.6)).frame(height: 0.5).padding(.leading, 12)
    }

    /// Title (and optional detail) on the left, the control right-aligned, fixed height like System Settings.
    private func settingRow<Control: View>(_ title: String, detail: String? = nil, @ViewBuilder control: () -> Control) -> some View {
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 1) {
                Text(title).font(.ui(size: 12)).foregroundColor(palette.textMain)
                if let detail {
                    Text(detail).font(.ui(size: 11)).foregroundColor(palette.textMuted).lineLimit(1)
                }
            }
            Spacer(minLength: 8)
            control()
        }
        .padding(.horizontal, 12)
        .frame(minHeight: StudioTheme.scale(detail == nil ? 34 : 42))
    }

    private func switchRow(_ title: String, detail: String? = nil, value: Binding<Bool>, key: String) -> some View {
        settingRow(title, detail: detail) {
            Toggle("", isOn: Binding(get: { value.wrappedValue }, set: { value.wrappedValue = $0; queue(key, $0) }))
                .labelsHidden()
                .toggleStyle(.switch)
                .controlSize(.small)
        }
    }

    private var summary: String {
        guard enabled else { return "The link is turned off." }
        var can = ["view"]
        if downloads { can.append("download") }
        if comments { can.append("comment") }
        let list = can.count > 1 ? can.dropLast().joined(separator: ", ") + " and " + can.last! : can[0]
        var text = (secure ? "Invited people can " : "Anyone with the link can ") + list + "."
        if passphrase != nil { text += " Passphrase required." }
        if let expiry { text += " Expires \(expiry.formatted(date: .abbreviated, time: .shortened))." }
        return text
    }

    private var emails: [String] {
        invitees.split(whereSeparator: { ",; \n".contains($0) }).map(String.init).filter { $0.contains("@") }
    }

    // MARK: Network

    private func create() async {
        guard share == nil, let account else { return }
        do {
            let made = try await FrameIO.shared.createShare(account: account, project: request.project, name: request.name,
                                                            assetIDs: request.assetIDs)
            apply(made)
            if let link = made.shortURL { Self.copy(link); flashCopied() }
        } catch {
            self.error = "Couldn't create the share link: \(error.localizedDescription)"
        }
    }

    private func apply(_ made: FrameIO.Share) {
        share = made
        name = made.name ?? request.name
        secure = made.access == "secure"
        enabled = made.enabled
        comments = made.commentingEnabled
        downloads = made.downloadingEnabled
        allVersions = made.showAllAssetVersions ?? false
        passphrase = made.passphrase
        passphraseText = made.passphrase ?? ""
        expiry = made.expirationDate
    }

    private func set(secure value: Bool) {
        secure = value
        queue("access", value ? "secure" : "public")
    }

    private func commitName() {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, trimmed != share?.name else {
            if trimmed.isEmpty { name = share?.name ?? request.name }
            return
        }
        queue("name", trimmed)
    }

    private func commitPassphrase() {
        let text = passphraseText.trimmingCharacters(in: .whitespaces)
        guard passphrase != nil, text != passphrase else { return }
        guard text.count >= 8 else { return }
        passphrase = text
        queue("passphrase", text)
    }

    private func suggestPassphrase() {
        let suggestion = Self.newPassphrase()
        passphraseText = suggestion
        passphrase = suggestion
        queue("passphrase", suggestion)
    }

    private func queueExpiry() {
        queue("expiration", expiry.map { ISO8601DateFormatter().string(from: $0) } ?? NSNull())
    }

    /// Collects changes and sends them together 0.8 s after the last one.
    private func queue(_ key: String, _ value: Any) {
        pending[key] = value
        saveTask?.cancel()
        saveTask = Task {
            try? await Task.sleep(for: .milliseconds(800))
            guard !Task.isCancelled else { return }
            await flush()
        }
    }

    private func flushNow() {
        commitName()
        commitPassphrase()
        guard !pending.isEmpty else { return }
        saveTask?.cancel()
        // Finish the save after the sheet closes.
        let fields = pending
        pending = [:]
        guard let account, let id = share?.id, let body = try? FrameIO.shareUpdate(fields) else { return }
        Task { _ = try? await FrameIO.shared.updateShare(account: account, share: id, body: body) }
    }

    private func flush() async {
        guard !pending.isEmpty, let account, let id = share?.id else { return }
        let fields = pending
        pending = [:]
        isSaving = true
        defer { isSaving = false }
        do {
            let updated = try await FrameIO.shared.updateShare(account: account, share: id, body: FrameIO.shareUpdate(fields))
            share = updated
            error = nil
        } catch {
            self.error = Self.explain(error, changing: fields)
            // Changes sent together with a refused one still get saved.
            var rest = fields
            rest["access"] = nil
            if error.localizedDescription.contains("not included in plan"), fields["access"] != nil, !rest.isEmpty,
               let updated = try? await FrameIO.shared.updateShare(account: account, share: id, body: FrameIO.shareUpdate(rest)) {
                share = updated
            }
            if let share { apply(share) }
        }
    }

    /// Remembered for the session once Frame.io says the plan has no secure links.
    @MainActor private static var secureUnavailable = false

    /// Frame.io answers 422 "feature(s) not included in plan: …" for settings the account's plan doesn't have.
    private static func explain(_ error: Error, changing fields: [String: Any]) -> String {
        let text = error.localizedDescription
        guard text.contains("not included in plan") else { return "Couldn't save: \(text)" }
        if fields["access"] != nil {
            secureUnavailable = true
            return "Secure (invite-only) links aren't included in your Frame.io plan. The link stays Public."
        }
        let feature = text.components(separatedBy: "plan:").last?.trimmingCharacters(in: .whitespaces) ?? "this setting"
        return "Your Frame.io plan doesn't include \(feature.replacingOccurrences(of: "_", with: " ")). The change wasn't saved."
    }

    private func sendInvites() {
        guard let account, let id = share?.id else { return }
        let list = emails
        let note = message.trimmingCharacters(in: .whitespacesAndNewlines)
        isInviting = true
        Task {
            do {
                try await FrameIO.shared.inviteToShare(account: account, share: id, emails: list,
                                                       message: note.isEmpty ? "Shared from QCpie: \(name)" : note, notify: notify)
                inviteStatus = "Invited \(list.joined(separator: ", "))"
                invitees = ""
                message = ""
            } catch {
                inviteStatus = "Couldn't invite: \(error.localizedDescription)"
            }
            isInviting = false
        }
    }

    private func copyLink() {
        guard let link = share?.shortURL else { return }
        Self.copy(link)
        flashCopied()
    }

    private func flashCopied() {
        copied = true
        Task {
            try? await Task.sleep(for: .seconds(1.5))
            copied = false
        }
    }

    private static func copy(_ text: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }

    /// Strong but easy to read out or type: four groups of four from 31 characters without look-alikes (0/O, 1/l/I),
    /// about 79 bits, e.g. "k7mq-x2pt-9hcz-r4wd". Uses the system's secure random generator.
    private static func newPassphrase() -> String {
        let alphabet = Array("abcdefghjkmnpqrstuvwxyz23456789")
        var generator = SystemRandomNumberGenerator()
        return (0..<4).map { _ in String((0..<4).map { _ in alphabet.randomElement(using: &generator)! }) }
            .joined(separator: "-")
    }
}

/// A Frame.io thumbnail for a list row (16:9 box; folders and files without one get an icon). Loaded only when the row
/// is on screen, decoded off the main thread at the displayed size, and kept in a small memory cache.
private struct FrameIOThumbnail: View {
    /// Redraws the row when its list redraws for a new accent (`ThemeManager.revision`).
    var themeRevision = ThemeManager.shared.revision
    let item: FrameIO.Item
    let width: Double
    let isLightMode: Bool
    @State private var image: CGImage?

    private var palette: StudioPalette { StudioPalette(isLightMode) }
    private var size: CGSize { CGSize(width: width, height: (width * 9 / 16).rounded()) }
    /// Above 128 pt the small Frame.io thumbnail looks soft: use the high-quality one.
    private var isLarge: Bool { width > 128 }

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 3).fill(palette.bgSubtle)
            if let image {
                Image(decorative: image, scale: 2)
                    .resizable()
                    .aspectRatio(contentMode: .fit)
            } else {
                Image(systemName: item.isFolder ? "folder.fill" : (item.isVersionStack ? "square.stack.3d.up.fill" : "film"))
                    .font(.system(size: StudioTheme.scaleFont(min(16, width / 4))))
                    .foregroundColor(item.isFolder || item.isVersionStack ? palette.accentBlue : palette.textMuted)
            }
        }
        .frame(width: size.width, height: size.height)
        .clipShape(RoundedRectangle(cornerRadius: 3))
        .task(id: "\(item.thumbnailKey)-\(isLarge)") {
            guard let url = isLarge ? item.largeThumbnailURL : item.thumbnailURL else { image = nil; return }
            image = await FrameIOThumbnailCache.shared.image(for: "\(item.thumbnailKey)-\(isLarge)", url: url,
                                                             maxPixels: isLarge ? 640 : 320)
        }
    }
}

/// A project's icon from Frame.io (the project image), or a Frame.io-style gradient when it has none.
private struct FrameIOProjectIcon: View {
    let item: FrameIO.Item
    let isLightMode: Bool
    @State private var image: CGImage?

    var body: some View {
        let side = StudioTheme.scale(22)
        ZStack {
            if let image {
                Image(decorative: image, scale: 2)
                    .resizable()
                    .aspectRatio(contentMode: .fill)
                    .frame(width: side, height: side)
                    .clipShape(RoundedRectangle(cornerRadius: side * 0.24, style: .continuous))
            } else {
                ProjectGradientIcon(projectID: item.id, side: side)
            }
        }
        .frame(width: side, height: side)
        .task(id: item.image) {
            guard let url = item.projectImageURL else { image = nil; return }
            image = await FrameIOThumbnailCache.shared.image(for: "project-\(item.id)", url: url, maxPixels: 96)
        }
    }
}

/// Frame.io draws a gradient for projects without an image (not exposed by the API). The same look, with the
/// gradient picked from the project id so each project keeps its colours.
private struct ProjectGradientIcon: View {
    let projectID: String
    let side: CGFloat

    private static let gradients: [(Color, Color)] = [
        (Color(red: 0.42, green: 0.55, blue: 1.00), Color(red: 0.40, green: 0.16, blue: 0.94)),   // blue → violet
        (Color(red: 0.86, green: 0.38, blue: 0.62), Color(red: 0.95, green: 0.55, blue: 0.40)),   // pink → orange
        (Color(red: 0.95, green: 0.47, blue: 0.43), Color(red: 0.97, green: 0.62, blue: 0.50)),   // coral → peach
        (Color(red: 0.78, green: 0.35, blue: 0.67), Color(red: 0.95, green: 0.55, blue: 0.38)),   // magenta → orange
        (Color(red: 0.36, green: 0.80, blue: 0.96), Color(red: 0.30, green: 0.36, blue: 0.94))    // cyan → indigo
    ]

    /// FNV-1a: stable across launches (`hashValue` isn't).
    private var index: Int {
        var hash: UInt64 = 0xcbf29ce484222325
        for byte in projectID.utf8 { hash = (hash ^ UInt64(byte)) &* 0x100000001b3 }
        return Int(hash % UInt64(Self.gradients.count))
    }

    var body: some View {
        let (from, to) = Self.gradients[index]
        RoundedRectangle(cornerRadius: side * 0.24, style: .continuous)
            .fill(LinearGradient(colors: [from, to], startPoint: .topLeading, endPoint: .bottomTrailing))
            .overlay(
                Ellipse()
                    .fill(Color.white.opacity(0.18))
                    .frame(width: side * 1.3, height: side * 0.7)
                    .rotationEffect(.degrees(-30))
                    .offset(x: side * 0.25, y: side * 0.3)
                    .blur(radius: side * 0.12)
            )
            .clipShape(RoundedRectangle(cornerRadius: side * 0.24, style: .continuous))
            .frame(width: side, height: side)
    }
}

/// Decoded thumbnails by item (a stack: its current version) and size, capped at 64 MB of decoded pixels.
private actor FrameIOThumbnailCache {
    static let shared = FrameIOThumbnailCache()
    private let cache: NSCache<NSString, CGImageBox> = {
        let cache = NSCache<NSString, CGImageBox>()
        cache.totalCostLimit = 64 * 1024 * 1024   // by decoded bytes: large thumbnails are ~1 MB each
        return cache
    }()
    private var inFlight: [String: Task<CGImage?, Never>] = [:]

    func clear() { cache.removeAllObjects() }

    final class CGImageBox: @unchecked Sendable {
        let image: CGImage
        init(_ image: CGImage) { self.image = image }
    }

    func image(for key: String, url: URL, maxPixels: Int) async -> CGImage? {
        if let cached = cache.object(forKey: key as NSString) { return cached.image }
        if let running = inFlight[key] { return await running.value }
        let task = Task.detached(priority: .utility) { () -> CGImage? in
            guard let (data, _) = try? await URLSession.shared.data(from: url),
                  let source = CGImageSourceCreateWithData(data as CFData, nil) else { return nil }
            let options: [CFString: Any] = [kCGImageSourceCreateThumbnailFromImageAlways: true,
                                            kCGImageSourceThumbnailMaxPixelSize: maxPixels,
                                            kCGImageSourceCreateThumbnailWithTransform: true]
            return CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary)
        }
        inFlight[key] = task
        let image = await task.value
        inFlight[key] = nil
        if let image { cache.setObject(CGImageBox(image), forKey: key as NSString, cost: image.bytesPerRow * image.height) }
        return image
    }
}

/// Row hover highlight kept inside the row, so moving the pointer redraws one row instead of the whole list.
/// One favourites page tab: its name and count; double-click to rename (Return or clicking away saves, Esc cancels:
/// the shortcut router unfocuses the field for both). A dragged favourite chip dropped here moves to this page.
private struct FavouritePageTab: View {
    let name: String
    let count: Int
    let isSelected: Bool
    let canDelete: Bool
    let isLightMode: Bool
    @Binding var dragging: String?
    let onSelect: () -> Void
    let onRename: (String) -> Void
    let onDelete: () -> Void
    let onDropFavourite: (String) -> Void

    @State private var isRenaming = false
    @State private var draft = ""
    @State private var isHovered = false
    @State private var isDropTarget = false
    @FocusState private var focused: Bool

    private var palette: StudioPalette { StudioPalette(isLightMode) }

    var body: some View {
        HStack(spacing: 4) {
            if isRenaming {
                TextField("", text: $draft)
                    .textFieldStyle(.plain)
                    .font(.ui(size: 11, weight: .semibold))
                    .frame(width: max(60, CGFloat(draft.count) * 7))
                    .focused($focused)
                    .onAppear { draft = name; DispatchQueue.main.async { focused = true } }
                    .onChange(of: focused) { _, isFocused in
                        guard !isFocused else { return }
                        let cancelled = NSApp.currentEvent?.type == .keyDown && NSApp.currentEvent?.keyCode == 53
                        if !cancelled { onRename(draft) }
                        isRenaming = false
                    }
            } else {
                Text(name)
                    .font(.ui(size: 11, weight: isSelected ? .semibold : .medium))
                    .foregroundColor(isSelected || isHovered ? palette.textMain : palette.textMuted)
                    .lineLimit(1)
            }
            if count > 0 && !isRenaming {
                Text("\(count)")
                    .font(.ui(size: 11, weight: .semibold))
                    .monospacedDigit()
                    .foregroundColor(isSelected ? palette.accentBlue : palette.textMuted)
            }
        }
        .padding(.horizontal, 6)
        .frame(height: StudioTheme.scale(24))
        // No box: the page shown is underlined in the accent colour (a drop target or hover gets a faint line).
        .overlay(alignment: .bottom) {
            Capsule()
                .fill(isSelected || isDropTarget ? palette.accentBlue : palette.textMuted.opacity(isHovered ? 0.35 : 0))
                .frame(height: isSelected || isDropTarget ? 2 : 1)
                .padding(.horizontal, 4)
        }
        .contentShape(Rectangle())
        .onTapGesture(count: 2) { startRename() }
        .onTapGesture(perform: onSelect)
        .onHover { isHovered = $0 }
        .contextMenu {
            Button("Rename…", action: startRename)
            if canDelete {
                Button(role: .destructive, action: onDelete) {
                    Text(count > 0 ? "Delete Page (its \(count) favourite\(count == 1 ? "" : "s") move to the page before)" : "Delete Page")
                }
            }
        }
        .onDrop(of: [.utf8PlainText], delegate: FavouritePageDropDelegate(dragging: $dragging, isTargeted: $isDropTarget, onDrop: onDropFavourite))
        .help("\(name): click to show, double-click to rename, drop a favourite here to move it")
    }

    private func startRename() {
        draft = name
        isRenaming = true
    }
}

/// A favourite chip dropped on a page tab.
private struct FavouritePageDropDelegate: DropDelegate {
    @Binding var dragging: String?
    @Binding var isTargeted: Bool
    let onDrop: (String) -> Void

    func validateDrop(info: DropInfo) -> Bool { dragging != nil }
    func dropEntered(info: DropInfo) { isTargeted = true }
    func dropExited(info: DropInfo) { isTargeted = false }
    func dropUpdated(info: DropInfo) -> DropProposal? { DropProposal(operation: .move) }

    func performDrop(info: DropInfo) -> Bool {
        isTargeted = false
        guard let dragging else { return false }
        withAnimation(Motion.snap) { onDrop(dragging) }
        self.dragging = nil
        return true
    }
}

/// Reorders favourites live as a dragged chip passes over the others (only favourite drags: `dragging` is set by them).
private struct FavouriteDropDelegate: DropDelegate {
    let target: String
    @Binding var dragging: String?
    let move: (String, String) -> Void

    func validateDrop(info: DropInfo) -> Bool { dragging != nil }

    func dropEntered(info: DropInfo) {
        guard let dragging, dragging != target else { return }
        withAnimation(Motion.snap) { move(dragging, target) }
    }

    func dropUpdated(info: DropInfo) -> DropProposal? { DropProposal(operation: .move) }

    func performDrop(info: DropInfo) -> Bool {
        dragging = nil
        return true
    }
}

/// Picks how many trailing crumbs fit the width it's given and builds just that row. Owns the width, so a resize
/// redraws the breadcrumbs only, not the browser. Widths come from the titles' text (same font as the crumbs) plus each
/// crumb's padding and chevron.
private struct CrumbFitter<Row: View>: View {
    let titles: [String]
    @ViewBuilder let row: (_ keep: Int, _ shortenLast: Bool) -> Row
    /// How many crumbs fit (and whether the last must shorten): changes only when that answer does, so a resize
    /// doesn't rebuild the row every frame.
    @State private var fitted: Fit?
    @State private var width: CGFloat = 0

    struct Fit: Equatable {
        let keep: Int
        let shorten: Bool
    }

    var body: some View {
        let fit = fitted ?? Fit(keep: titles.count, shorten: false)
        row(min(fit.keep, titles.count), fit.shorten)
            .frame(maxWidth: .infinity, alignment: .leading)
            .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { new in
                width = new
                refit()
            }
            .onChange(of: titles) { _, _ in refit() }
    }

    private func refit() {
        let next = Self.fit(titles, in: width)
        if next != fitted { fitted = next }
    }

    @MainActor private static func textWidth(_ title: String, size: CGFloat, bold: Bool) -> CGFloat {
        CrumbTextWidths.width(title, size: size, bold: bold)
    }

    @MainActor private static func fit(_ titles: [String], in available: CGFloat) -> Fit {
        guard available > 0, !titles.isEmpty else { return Fit(keep: titles.count, shorten: false) }
        let size = (TypeScale.snap(12) * TypeScale.factor).rounded()
        let chevron = StudioTheme.scaleFont(9) + 8   // the chevron and the row spacing around it
        let ellipsis = StudioTheme.scaleFont(11) + 12 + chevron
        let widths = titles.indices.map { textWidth(titles[$0], size: size, bold: $0 == titles.count - 1) + 12 }
        for keep in stride(from: titles.count, through: 1, by: -1) {
            let shown = widths.suffix(keep).reduce(0, +) + CGFloat(keep - 1) * chevron
            if shown + (keep < titles.count ? ellipsis : 0) <= available { return Fit(keep: keep, shorten: false) }
        }
        return Fit(keep: 1, shorten: true)
    }
}

/// Crumb title widths by font size, weight and title (the same titles are measured on every resize frame).
@MainActor
private enum CrumbTextWidths {
    private static var cache: [String: CGFloat] = [:]

    static func width(_ title: String, size: CGFloat, bold: Bool) -> CGFloat {
        let key = "\(size)|\(bold)|\(title)"
        if let cached = cache[key] { return cached }
        let font = bold ? NSFont.systemFont(ofSize: size, weight: .semibold) : NSFont.systemFont(ofSize: size)
        let width = ceil((title as NSString).size(withAttributes: [.font: font]).width)
        if cache.count > 2_000 { cache = [:] }
        cache[key] = width
        return width
    }
}

/// One favourite in the Favourites bar: icon, name and where it lives; × on hover.
private struct FavouriteChip: View {
    let favourite: FrameIOBrowser.Favourite
    let isCurrent: Bool
    let isLightMode: Bool
    /// The List layout: chips fill the list's width.
    var fullWidth = false
    /// Being dragged to reorder: dimmed in place.
    var isDragging = false
    /// The favourites pages, for Move to Page.
    var pages: [String] = []
    var onMoveToPage: (Int) -> Void = { _ in }
    let onOpen: () -> Void
    let onRemove: () -> Void
    @State private var isHovered = false

    private var palette: StudioPalette { StudioPalette(isLightMode) }
    private var level: FrameIOBrowser.Level { favourite.path.last?.level ?? .folder }

    var body: some View {
        HStack(spacing: 7) {
            icon
            VStack(alignment: .leading, spacing: 0) {
                Text(favourite.title)
                    .font(.ui(size: 11, weight: .semibold))
                    .foregroundColor(palette.textMain)
                    .lineLimit(1)
                    .truncationMode(.middle)
                if !favourite.location.isEmpty {
                    Text(favourite.location)
                        .font(.ui(size: 11))
                        .foregroundColor(palette.textMuted)
                        .lineLimit(1)
                        .truncationMode(.head)
                }
            }
            if fullWidth { Spacer(minLength: 4) }
            Button(action: onRemove) {
                Image(systemName: "xmark")
                    .font(.system(size: StudioTheme.scaleFont(8), weight: .bold))
                    .foregroundColor(palette.textMuted)
                    .frame(width: 16, height: 16)
                    .background(Circle().fill(palette.bgSubtle))
                    .contentShape(Circle())
            }
            .buttonStyle(.plain)
            .opacity(isHovered ? 1 : 0)
            .allowsHitTesting(isHovered)
            .help("Remove from Favourites")
        }
        .padding(.leading, 7)
        .padding(.trailing, 5)
        .frame(height: StudioTheme.scale(34))
        .frame(maxWidth: fullWidth ? .infinity : 240, alignment: .leading)
        .opacity(isDragging ? 0.45 : 1)
        .background(RoundedRectangle(cornerRadius: Radius.container, style: .continuous)
            .fill(isCurrent ? palette.accentBlue.opacity(0.18) : (isHovered ? palette.bgSubtle : palette.bgCardSubtle)))
        .overlay(RoundedRectangle(cornerRadius: Radius.container, style: .continuous)
            .stroke(isCurrent ? palette.accentBlue.opacity(0.7) : palette.borderLine, lineWidth: 1))
        .contentShape(RoundedRectangle(cornerRadius: Radius.container, style: .continuous))
        .onTapGesture(perform: onOpen)
        .onHover { isHovered = $0 }
        .animation(Motion.hover, value: isHovered)
        .contextMenu {
            Button(action: onOpen) { Label("Open", systemImage: "arrow.right.circle") }
            if pages.count > 1 {
                Menu {
                    ForEach(Array(pages.enumerated()), id: \.offset) { index, name in
                        Button(name) { onMoveToPage(index) }
                            .disabled(index == favourite.page)
                    }
                } label: { Label("Move to Page", systemImage: "rectangle.stack") }
            }
            Divider()
            Button(action: onRemove) { Label("Remove from Favourites", systemImage: "star.slash") }
        }
        .help(([favourite.location, favourite.title].filter { !$0.isEmpty }).joined(separator: " › "))
    }

    @ViewBuilder
    private var icon: some View {
        switch level {
        case .project:
            ProjectGradientIcon(projectID: favourite.path.last?.id ?? "", side: StudioTheme.scale(20))
        case .stack:
            Image(systemName: "square.stack.3d.up.fill")
                .font(.system(size: StudioTheme.scaleFont(13)))
                .foregroundColor(palette.accentBlue)
                .frame(width: StudioTheme.scale(20))
        default:
            Image(systemName: "folder.fill")
                .font(.system(size: StudioTheme.scaleFont(13)))
                .foregroundColor(palette.accentBlue)
                .frame(width: StudioTheme.scale(20))
        }
    }
}

private struct HoverBackground: ViewModifier {
    let base: Color
    let hover: Color
    /// False while the row is selected or a drop target (their colour wins).
    let isActive: Bool
    @State private var isHovered = false

    func body(content: Content) -> some View {
        content
            .background(isActive && isHovered ? hover : base)
            .onHover { isHovered = $0 }
    }
}

/// Toolbar controls and breadcrumbs: a rounded background on hover (and while `isOn`), like Finder's toolbar.
private struct ToolHover: ViewModifier {
    let fill: Color
    var isOn = false
    var isEnabled = true
    @State private var isHovered = false

    func body(content: Content) -> some View {
        content
            .background(
                RoundedRectangle(cornerRadius: StudioTheme.cornerRadius)
                    .fill(isOn || (isEnabled && isHovered) ? fill : .clear)
            )
            .onHover { isHovered = $0 }
            .animation(Motion.hover, value: isHovered)
    }
}

/// Project list columns after the name (fixed widths, scaled with Button Size).
private enum ProjectColumn: CaseIterable {
    case updated, storage, created, status

    var title: String {
        switch self {
        case .updated: return "Last Updated"
        case .storage: return "Storage"
        case .created: return "Creation Date"
        case .status: return "Status"
        }
    }

    var width: CGFloat {
        switch self {
        case .updated: return 90
        case .storage: return 80
        case .created: return 160
        case .status: return 64
        }
    }

    /// The columns plus the 10 pt row spacing before each.
    @MainActor static var totalWidth: CGFloat { allCases.reduce(0) { $0 + StudioTheme.scale($1.width) + 10 } }

    func value(for item: FrameIO.Item) -> String {
        switch self {
        case .updated: return item.updatedDate?.formatted(.relative(presentation: .numeric, unitsStyle: .narrow)) ?? "—"
        case .storage: return item.storage.map { ByteCountFormatter.string(fromByteCount: $0, countStyle: .file) } ?? "—"
        case .created: return item.createdDate?.formatted(date: .abbreviated, time: .shortened) ?? "—"
        case .status: return item.status == nil ? "—" : (item.isInactive ? "Inactive" : "Active")
        }
    }
}

/// Folder and stack contents columns after the name, in the project table's order (fixed widths, scaled with Button Size).
private enum ContentColumn: CaseIterable {
    case updated, size, created, kind

    var title: String {
        switch self {
        case .updated: return "Last Updated"
        case .size: return "Size"
        case .created: return "Creation Date"
        case .kind: return "Type"
        }
    }

    var width: CGFloat {
        switch self {
        case .updated: return 90
        case .size: return 80
        case .created: return 160
        case .kind: return 64
        }
    }

    func value(for item: FrameIO.Item) -> String {
        switch self {
        case .updated: return item.updatedDate?.formatted(.relative(presentation: .numeric, unitsStyle: .narrow)) ?? "—"
        case .size: return item.isFolder ? "—" : item.displaySize.map { ByteCountFormatter.string(fromByteCount: $0, countStyle: .file) } ?? "—"
        case .created: return item.createdDate?.formatted(date: .abbreviated, time: .shortened) ?? "—"
        case .kind:
            if item.isFolder { return "Folder" }
            if item.isVersionStack { return "Stack" }
            let ext = (item.title as NSString).pathExtension
            return ext.isEmpty ? "File" : ext.uppercased()
        }
    }
}

/// The Assets & Queue panel's chevron at the far left of the Frame.io header (⌘⇧← too). Its own view, so toggling the
/// panel doesn't redraw the browser.
private struct QueueSleeveToggle: View {
    let isLightMode: Bool
    @AppStorage("uploadQueueOpen") private var isOpen = true

    var body: some View {
        SleeveToggle(side: .leading, isOpen: isOpen, isLightMode: isLightMode,
                     help: isOpen ? "Hide Assets & Queue panel (⌘⇧←)." : "Reveal Assets & Queue panel (⌘⇧←).") {
            isOpen.toggle()
        }
    }
}

/// The right drawer's chevron at the far right of the Frame.io header (⌘⇧→ too): opens / closes the drawer, whose own
/// tabs pick Media Info, Downloads or Log. Starting a download opens it on Downloads, a running one shows its percentage
/// here, and Frame.io rows dropped on it download. The only part of the header that observes `DownloadQueue` (its
/// 5 Hz progress mustn't redraw the browser's list).
private struct DrawerTabs: View {
    @ObservedObject private var themeManager = ThemeManager.shared   // accent changes redraw
    let isLightMode: Bool
    @AppStorage("uploadLogOpen") private var isOpen = false
    @AppStorage("uploadDrawerTab") private var tab = "info"
    @ObservedObject private var downloads = DownloadQueue.shared
    @State private var isDropTarget = false

    private var palette: StudioPalette { StudioPalette(isLightMode) }

    var body: some View {
        HStack(spacing: 2) {
            if downloads.isRunning {
                Text("\(downloads.percent)%")
                    .font(.ui(size: 11, weight: .semibold))
                    .monospacedDigit()
                    .foregroundColor(palette.accentBlue)
                    .padding(.leading, 6)
            }
            SleeveToggle(side: .trailing, isOpen: isOpen, isLightMode: isLightMode,
                         help: isOpen ? "Close the drawer (⌘⇧→)." : "Open Media Info, Downloads & Log (⌘⇧→).") {
                isOpen.toggle()
            }
        }
        .background(RoundedRectangle(cornerRadius: StudioTheme.cornerRadius).fill(isDropTarget ? palette.accentBlue.opacity(0.25) : .clear))
        .onDrop(of: [.utf8PlainText], isTargeted: $isDropTarget, perform: DownloadQueue.acceptDrop)
        .onChange(of: downloads.startCount) {
            withAnimation(Motion.sleeve) { tab = "downloads"; isOpen = true }
        }
    }
}
