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
    @Published private(set) var path: [Crumb] = []
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
    /// The open project's share links (newest first), for "Add to Share Link".
    @Published private(set) var projectShares: [FrameIO.Share] = []
    private var sharesProject: String?
    /// Number of versions per stack in the open folder (fetched after listing; drives the "V3" badges).
    @Published private(set) var versionCounts: [String: Int] = [:]

    private var loadToken = 0
    private var anchor: String?

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

    /// The listing after the name filter.
    var visibleItems: [FrameIO.Item] {
        let query = filter.trimmingCharacters(in: .whitespaces)
        return query.isEmpty ? items : items.filter { $0.title.localizedCaseInsensitiveContains(query) }
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
            if signedIn == true { await loadUser(); reload() }
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
                await loadUser()
                path = []
                reload()
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

    func goTo(depth: Int) {
        guard depth < path.count else { return }
        path.removeSubrange(depth...)
        reload()
    }

    // MARK: Favourites

    private static let favouritesKey = "frameioFavourites"

    private static func loadFavourites() -> [Favourite] {
        guard let data = UserDefaults.standard.data(forKey: favouritesKey) else { return [] }
        return (try? JSONDecoder().decode([Favourite].self, from: data)) ?? []
    }

    private func saveFavourites() {
        UserDefaults.standard.set(try? JSONEncoder().encode(favourites), forKey: Self.favouritesKey)
    }

    var isCurrentFavourite: Bool { favourites.contains { $0.path == path } }

    /// Stars or unstars the open project, folder or stack.
    func toggleCurrentFavourite() {
        guard path.last.map({ [.project, .folder, .stack].contains($0.level) }) == true else { return }
        if isCurrentFavourite { favourites.removeAll { $0.path == path } } else { favourites.append(Favourite(path: path)) }
        saveFavourites()
    }

    /// Adds a project (from the project list), or a folder or stack of the open folder (right-click → Add to Favourites).
    func addFavourite(_ item: FrameIO.Item) {
        let crumb: Crumb
        if path.last?.level == .workspace {
            crumb = Crumb(level: .project, id: item.id, title: item.title, folderID: item.rootFolderID)
        } else if item.isVersionStack {
            crumb = Crumb(level: .stack, id: item.id, title: item.title, folderID: nil)
        } else {
            crumb = Crumb(level: .folder, id: item.id, title: item.title, folderID: item.rootFolderID)
        }
        let favourite = Favourite(path: path + [crumb])
        guard !favourites.contains(favourite) else { return }
        favourites.append(favourite)
        saveFavourites()
        show(Toast(message: "Added “\(item.title)” to Favourites"))
    }

    func isFavourite(_ item: FrameIO.Item) -> Bool { favourites.contains { $0.path.last?.id == item.id } }

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
                // A stack lists its versions newest first: keep that order (it is the version order).
                items = crumbs.last?.level == .stack ? loaded : Self.sorted(loaded)
                selection.formIntersection(items.map(\.id))
                isLoading = false
                if crumbs.last?.level == .stack, let stack = crumbs.last { versionCounts[stack.id] = loaded.count }
                loadVersionCounts(items.filter(\.isVersionStack))
                if projectID != sharesProject { loadShares() }
            } catch {
                guard token == loadToken else { return }
                items = []
                loadedPath = crumbs
                isLoading = false
                handle(error)
            }
        }
    }

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

    /// Fetches the version count of each stack in the open folder (one call each, the first 25).
    private func loadVersionCounts(_ stacks: [FrameIO.Item]) {
        guard let account = accountID else { return }
        for stack in stacks.prefix(25) where versionCounts[stack.id] == nil {
            Task {
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
    var isLightMode: Bool
    @AppStorage("uploadLogOpen") private var showLog = false
    @ObservedObject private var browser = FrameIOBrowser.shared
    /// Row or breadcrumb under a drag.
    @State private var dropTarget: String?
    @State private var isListTargeted = false
    @State private var renameText = ""
    @FocusState private var renameFocused: Bool
    @State private var moveItems: MoveRequest?
    @State private var stackItems: MoveRequest?
    @State private var copyItems: MoveRequest?
    @State private var shareRequest: ShareRequest?
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
                header
                Rectangle().fill(palette.borderLine).frame(height: 1)
                toolbar
                Rectangle().fill(palette.borderLine).frame(height: 1)
                folderList
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(palette.bgMain)
        .overlay(alignment: .bottom) { toastView }
        .onAppear { browser.start() }
        .sheet(item: $shareRequest, onDismiss: { browser.loadShares() }) { request in
            FrameIOShareSheet(request: request, isLightMode: isLightMode)
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
                    .background(RoundedRectangle(cornerRadius: 6).fill(palette.primaryBtnBg))
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

    private var header: some View {
        HStack(spacing: 10) {
            breadcrumbs
            Spacer(minLength: 12)
            if inFolder {
                Button(action: browser.newFolder) {
                    Label("New Folder", systemImage: "folder.badge.plus").font(.ui(size: 12))
                }
                .buttonStyle(.borderless)
            }
            Button(action: browser.refresh) {
                Image(systemName: "arrow.clockwise").font(.system(size: StudioTheme.scaleFont(11)))
            }
            .buttonStyle(.borderless)
            .help("Refresh")
            Button(action: { withAnimation(.easeInOut(duration: 0.15)) { showLog.toggle() } }) {
                Label("Log", systemImage: "list.bullet.rectangle").font(.ui(size: 12))
                    .foregroundColor(showLog ? palette.accentBlue : palette.textMain)
            }
            .buttonStyle(.borderless)
            .help("Show the upload log")
            Menu {
                Button("Sign Out", action: browser.signOut)
            } label: {
                Text(browser.userName.isEmpty ? "Frame.io" : browser.userName).font(.ui(size: 12))
            }
            .menuStyle(.borderlessButton)
            .fixedSize()
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 10)
        .background(palette.bgPanel)
    }

    /// Filter field, favourite star for the open place, and the Favourites menu.
    private var toolbar: some View {
        HStack(spacing: 10) {
            HStack(spacing: 6) {
                Image(systemName: "magnifyingglass")
                    .font(.system(size: StudioTheme.scaleFont(10)))
                    .foregroundColor(palette.textMuted)
                TextField("Filter by name", text: $browser.filter)
                    .textFieldStyle(.plain)
                    .font(.ui(size: 11))
                if !browser.filter.isEmpty {
                    Button(action: { browser.filter = "" }) {
                        Image(systemName: "xmark.circle.fill")
                            .font(.system(size: StudioTheme.scaleFont(10)))
                            .foregroundColor(palette.textMuted)
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 5)
            .frame(maxWidth: 280)
            .studioBox(background: palette.bgSubtle, border: palette.borderLine)
            if !browser.filter.isEmpty {
                Text("\(browser.visibleItems.count) of \(browser.items.count)")
                    .font(.ui(size: 10))
                    .foregroundColor(palette.textMuted)
            }
            Spacer()
            HStack(spacing: 6) {
                Button(action: { showThumbnails.toggle() }) {
                    Image(systemName: showThumbnails ? "photo.on.rectangle" : "list.bullet")
                        .font(.system(size: StudioTheme.scaleFont(11)))
                        .foregroundColor(showThumbnails ? palette.accentBlue : palette.textMuted)
                }
                .buttonStyle(.borderless)
                .help(showThumbnails ? "Show as list" : "Show thumbnails")
                if showThumbnails {
                    Slider(value: $thumbnailWidth, in: 48...256)
                        .controlSize(.mini)
                        .frame(width: 70)
                        .help("Thumbnail size")
                }
            }
            if let undo = browser.lastUndo {
                Button(action: browser.performUndo) {
                    Label("Undo", systemImage: "arrow.uturn.backward").font(.ui(size: 12))
                }
                .buttonStyle(.borderless)
                .help("Undo: \(undo.message) (⌘Z)")
            }
            if browser.projectID != nil, browser.currentFolderID != nil || browser.inStack {
                Button(action: shareSelectionOrFolder) {
                    Label("Share", systemImage: "square.and.arrow.up").font(.ui(size: 12))
                }
                .buttonStyle(.borderless)
                .help(browser.selection.isEmpty ? "Create a share link for this folder" : "Create a share link for the selected items")
            }
            if browser.path.last.map({ [.project, .folder, .stack].contains($0.level) }) == true {
                Button(action: browser.toggleCurrentFavourite) {
                    Image(systemName: browser.isCurrentFavourite ? "star.fill" : "star")
                        .font(.system(size: StudioTheme.scaleFont(12)))
                        .foregroundColor(browser.isCurrentFavourite ? .yellow : palette.textMuted)
                }
                .buttonStyle(.borderless)
                .help(browser.isCurrentFavourite ? "Remove from Favourites" : "Add this place to Favourites")
            }
            Menu {
                if browser.favourites.isEmpty {
                    Text("Star a project or folder to add it here")
                } else {
                    ForEach(browser.favourites) { favourite in
                        Button(favourite.location.isEmpty ? favourite.title : "\(favourite.title)  —  \(favourite.location)") {
                            browser.open(favourite)
                        }
                    }
                    Divider()
                    Menu("Remove") {
                        ForEach(browser.favourites) { favourite in
                            Button(favourite.title) { browser.removeFavourite(favourite) }
                        }
                    }
                }
            } label: {
                Label("Favourites", systemImage: "star.square.on.square").font(.ui(size: 12))
            }
            .menuStyle(.borderlessButton)
            .fixedSize()
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 7)
        .background(palette.bgPanel)
    }

    /// Breadcrumbs; the project and parent folders accept drops (move up, or upload there).
    private var breadcrumbs: some View {
        HStack(spacing: 4) {
            crumbButton("Frame.io", depth: 0, crumb: nil, isLast: browser.path.isEmpty)
            ForEach(Array(browser.path.enumerated()), id: \.offset) { index, crumb in
                Image(systemName: "chevron.right")
                    .font(.system(size: StudioTheme.scaleFont(9), weight: .semibold))
                    .foregroundColor(palette.textMuted.opacity(0.6))
                crumbButton(crumb.title, depth: index + 1, crumb: crumb, isLast: index == browser.path.count - 1)
            }
        }
        .lineLimit(1)
    }

    private func crumbButton(_ title: String, depth: Int, crumb: Crumb?, isLast: Bool) -> some View {
        let folder = isLast ? nil : crumb?.listedFolder
        let key = "crumb-\(depth)"
        let titles = Array(browser.path.prefix(depth).filter { $0.level == .project || $0.level == .folder }.map(\.title))
        return Button(action: { browser.goTo(depth: depth) }) {
            Text(title)
                .font(.ui(size: 12, weight: isLast ? .semibold : .regular))
                .foregroundColor(dropTarget == key ? .white : (isLast ? palette.textMain : palette.textMuted))
                .truncationMode(.middle)
                .padding(.horizontal, 4)
                .padding(.vertical, 2)
                .background(RoundedRectangle(cornerRadius: 4).fill(dropTarget == key ? palette.accentBlue : .clear))
        }
        .buttonStyle(.plain)
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
            } else if visibleItems.isEmpty {
                VStack { Spacer(); Text(browser.items.isEmpty ? "Empty" : "No matches").font(.ui(size: 12)).foregroundColor(palette.textMuted); Spacer() }
                    .frame(maxWidth: .infinity)
                    .contentShape(Rectangle())
            } else {
                ScrollView {
                    LazyVStack(spacing: 0) {
                        ForEach(Array(visibleItems.enumerated()), id: \.element.id) { index, item in
                            if browser.inStack {
                                versionRow(item, index: browser.filter.isEmpty ? index : (browser.items.firstIndex { $0.id == item.id } ?? index))
                            } else if inFolder {
                                contentRow(item, striped: index.isMultiple(of: 2))
                            } else {
                                navigationRow(item, striped: index.isMultiple(of: 2))
                            }
                        }
                    }
                    .padding(.vertical, 6)
                    Color.clear
                        .frame(height: 60)
                        .contentShape(Rectangle())
                        .onTapGesture { browser.selection = [] }
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .overlay(RoundedRectangle(cornerRadius: 4).stroke(isListTargeted ? palette.accentBlue : .clear, lineWidth: 2).padding(2))
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
            Button(action: browser.refresh) { Label("Refresh", systemImage: "arrow.clockwise") }
        }
    }

    /// Accounts, workspaces and projects: click to open. Projects accept uploads into their top level.
    private func navigationRow(_ item: FrameIO.Item, striped: Bool) -> some View {
        let isProject = browser.path.last?.level == .workspace
        let key = item.id
        return Button(action: { browser.open(item) }) {
            HStack(spacing: 10) {
                Image(systemName: browser.path.isEmpty ? "person.crop.circle" : (isProject ? "film.stack" : "square.grid.2x2"))
                    .font(.system(size: StudioTheme.scaleFont(13)))
                    .foregroundColor(palette.accentBlue)
                    .frame(width: StudioTheme.scale(18))
                Text(item.title)
                    .font(.ui(size: 12))
                    .foregroundColor(palette.textMain)
                    .lineLimit(1)
                    .truncationMode(.middle)
                if isProject && browser.isFavourite(item) {
                    Image(systemName: "star.fill")
                        .font(.system(size: StudioTheme.scaleFont(9)))
                        .foregroundColor(.yellow)
                }
                Spacer()
                Image(systemName: "chevron.right")
                    .font(.system(size: StudioTheme.scaleFont(10), weight: .semibold))
                    .foregroundColor(palette.textMuted.opacity(0.6))
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 6)
            .modifier(HoverBackground(base: dropTarget == key ? palette.accentBlue.opacity(0.22) : (striped ? palette.bgCardSubtle : Color.clear),
                                      hover: palette.bgSubtle, isActive: dropTarget != key))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
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
                if browser.isFavourite(item) {
                    Button("Remove from Favourites") {
                        if let favourite = browser.favourites.first(where: { $0.path.last?.id == item.id }) {
                            browser.removeFavourite(favourite)
                        }
                    }
                } else {
                    Button("Add to Favourites") { browser.addFavourite(item) }
                }
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
                    .help("\(count) versions: showing V\(count), the current one")
            }
            Spacer()
            if let size = item.displaySize, !item.isFolder {
                Text(ByteCountFormatter.string(fromByteCount: size, countStyle: .file))
                    .font(.ui(size: 11))
                    .foregroundColor(isSelected ? .white.opacity(0.85) : palette.textMuted)
            }
            if item.isFolder || item.isVersionStack {
                Image(systemName: "chevron.right")
                    .font(.system(size: StudioTheme.scaleFont(10), weight: .semibold))
                    .foregroundColor(isSelected ? .white : palette.textMuted.opacity(0.6))
                    .contentShape(Rectangle().inset(by: -6))
                    .onTapGesture { browser.open(item) }
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
                if item.isFolder || item.isVersionStack { browser.open(item) }
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

    private func versionBadge(_ text: String, isSelected: Bool) -> some View {
        Text(text)
            .font(.ui(size: 10, weight: .bold))
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
                    .font(.ui(size: 10, weight: .semibold))
                    .foregroundColor(isSelected ? .white : palette.positive)
            }
            Spacer()
            if let size = item.fileSize {
                Text(ByteCountFormatter.string(fromByteCount: size, countStyle: .file))
                    .font(.ui(size: 11))
                    .foregroundColor(isSelected ? .white.opacity(0.85) : palette.textMuted)
            }
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 7)
        .modifier(HoverBackground(base: isSelected ? palette.accentBlue : (index.isMultiple(of: 2) ? palette.bgCardSubtle : Color.clear),
                                  hover: palette.bgSubtle, isActive: !isSelected))
        .contentShape(Rectangle())
        .onTapGesture { browser.click(item.id) }
        .contextMenu {
            let targets = browser.targets(for: item)
            undoMenuItem
            shareButton(targets)
            Divider()
            openInNewTab(targets.count == 1 ? item : nil)
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
        }
    }

    /// Frame.io files dropped on a stack become its newest versions; dropped on a file, they stack with it (the file is
    /// V1, the dropped ones come after). Queue files upload into the open folder.
    private func acceptIntoStack(_ providers: [NSItemProvider], stack: FrameIO.Item) -> Bool {
        guard let folder = browser.currentFolderID,
              let provider = providers.first(where: { $0.canLoadObject(ofClass: NSString.self) }) else { return false }
        let titles = browser.destinationTitles
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
        guard browser.accountID != nil,
              let provider = providers.first(where: { $0.canLoadObject(ofClass: NSString.self) }) else { return false }
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
            .background(RoundedRectangle(cornerRadius: 8).fill(palette.bgPanel).shadow(color: .black.opacity(0.25), radius: 8, y: 2))
            .overlay(RoundedRectangle(cornerRadius: 8).stroke(palette.borderLine))
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
                self.error = error.localizedDescription
            }
            isLoading = false
        }
    }
}

private extension View {
    /// Accepts drops (queue files or Frame.io items) only where `enabled`, so non-targets don't swallow them.
    @ViewBuilder
    func dropIf(_ enabled: Bool, isTargeted: Binding<Bool>, perform: @escaping ([NSItemProvider]) -> Bool) -> some View {
        if enabled {
            onDrop(of: [.utf8PlainText], isTargeted: isTargeted, perform: perform)
        } else {
            self
        }
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
                            .font(.ui(size: 10, weight: .bold))
                            .foregroundColor(.white)
                            .padding(.horizontal, 5)
                            .padding(.vertical, 1)
                            .background(Capsule().fill(palette.accentBlue))
                            .frame(width: 34, alignment: .leading)
                        Text(file.title).font(.ui(size: 12)).lineLimit(1).truncationMode(.middle)
                        if index == ordered.count - 1 {
                            Text("Current").font(.ui(size: 10, weight: .semibold)).foregroundColor(palette.positive)
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
                    Button(action: { withAnimation(.easeInOut(duration: 0.2)) { showSettings = false } }) {
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
                    .help("Copy link")
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
            RoundedRectangle(cornerRadius: 6).fill(palette.bgSubtle)
            if let first = request.items.first {
                FrameIOThumbnail(item: first, width: 200, isLightMode: isLightMode)
            } else {
                Image(systemName: "folder.fill")
                    .font(.system(size: StudioTheme.scaleFont(22)))
                    .foregroundColor(palette.textMuted)
            }
            if request.assetIDs.count > 1 {
                Text("\(request.assetIDs.count) items")
                    .font(.ui(size: 10, weight: .semibold))
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
        Button(action: { withAnimation(.easeInOut(duration: 0.2)) { showSettings = true } }) {
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
            .background(RoundedRectangle(cornerRadius: 8).fill(palette.bgCardSubtle))
            .overlay(RoundedRectangle(cornerRadius: 8).stroke(palette.borderLine.opacity(0.7), lineWidth: 0.5))
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
                                .help("Suggest a new strong passphrase")
                                Button(action: { Self.copy(passphraseText) }) {
                                    Image(systemName: "doc.on.doc").font(.system(size: StudioTheme.scaleFont(11)))
                                }
                                .buttonStyle(.borderless)
                                .help("Copy passphrase")
                            }
                            .padding(.horizontal, 12)
                            .padding(.bottom, 10)
                            if passphraseText.trimmingCharacters(in: .whitespaces).count < 8 {
                                Text("Use at least 8 characters.")
                                    .font(.ui(size: 10))
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
                .background(RoundedRectangle(cornerRadius: 8).fill(palette.bgCardSubtle))
                .overlay(RoundedRectangle(cornerRadius: 8).stroke(palette.borderLine.opacity(0.7), lineWidth: 0.5))
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
                    Text(detail).font(.ui(size: 10)).foregroundColor(palette.textMuted).lineLimit(1)
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

/// Decoded thumbnails by item (a stack: its current version) and size, capped at 64 MB of decoded pixels.
private actor FrameIOThumbnailCache {
    static let shared = FrameIOThumbnailCache()
    private let cache: NSCache<NSString, CGImageBox> = {
        let cache = NSCache<NSString, CGImageBox>()
        cache.totalCostLimit = 64 * 1024 * 1024   // by decoded bytes: large thumbnails are ~1 MB each
        return cache
    }()
    private var inFlight: [String: Task<CGImage?, Never>] = [:]

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
