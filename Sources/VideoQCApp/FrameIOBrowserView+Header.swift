import SwiftUI
import AppKit
import AuthenticationServices
import UniformTypeIdentifiers
import ImageIO

/// The browser's header: breadcrumbs, favourites and the toolbar controls.
extension FrameIOBrowserView {
    // MARK: Header

    /// The Assets & Queue chevron, where you are, and the actions that don't depend on it: refresh, Frame.io's
    /// status, the account, and the right drawer's chevron at the far right. Sized like the Play and Inspect headers.
    var header: some View {
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

    /// Filter, then what applies to the open place: Favourites / All (project list), view, undo, share and its star.
    var toolbar: some View {
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
                    Text("All Projects").tag(false)
                    Text("Favourites").tag(true)
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
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 6)
        .background(palette.bgPanel)
    }

    var filterField: some View {
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
    var favouritesBar: some View {
        HStack(spacing: 10) {
            favouritePageTabs
            Rectangle().fill(palette.borderLine).frame(width: 1, height: StudioTheme.scale(20))
            if isListLayout {
                Text("Click a page to list its favourites")
                    .font(.ui(size: 11))
                    .foregroundColor(palette.textSubtle)
                    .lineLimit(1)
                Spacer(minLength: 0)
            } else if browser.pageFavourites.isEmpty {
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
            favouritesLayoutSwitch
        }
        .padding(.horizontal, 14)
        // Fixed: a chip row's height, empty or not, so switching pages doesn't move the list below.
        .frame(height: StudioTheme.scale(34) + 12)
        .background(palette.bgPanel)
    }

    /// A chip that opens its place, and drags to reorder (in the bar or the list).
    func favouriteChip(_ favourite: FrameIOBrowser.Favourite, fullWidth: Bool = false) -> some View {
        FavouriteChip(favourite: favourite, isCurrent: favourite.path == browser.path, isLightMode: isLightMode, fullWidth: fullWidth,
                      isDragging: draggingFavourite == favourite.id, pages: browser.favouritePages,
                      onMoveToPage: { browser.moveFavourite(favourite.id, toPage: $0) },
                      onOpen: {
                          listOpenPage = nil
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

    static let favouritesLayouts: [(id: String, title: String, icon: String)] = [
        ("bar", "Bar", "rectangle.split.3x1"), ("list", "List", "list.bullet")
    ]

    var isListLayout: Bool { favouritesLayout == "list" }

    /// Bar / List, two quiet icons at the row's end (the row keeps its height either way, so nothing below moves).
    var favouritesLayoutSwitch: some View {
        HStack(spacing: 1) {
            ForEach(Self.favouritesLayouts, id: \.id) { layout in
                let isOn = (isListLayout ? "list" : "bar") == layout.id
                Button {
                    listOpenPage = nil
                    withAnimation(Motion.fade) { favouritesLayout = layout.id }
                } label: {
                    Image(systemName: layout.icon)
                        .font(.system(size: StudioTheme.scaleFont(10), weight: .medium))
                        .foregroundColor(isOn ? palette.textMain : palette.textSubtle)
                        .frame(width: StudioTheme.scale(22), height: StudioTheme.scale(20))
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .modifier(ToolHover(fill: palette.bgSubtle, isOn: isOn))
                .help("Show favourites as a \(layout.title.lowercased())")
            }
        }
        .fixedSize()
    }

    /// The List layout: the page's chips, stacked, dropping down under the page's tab (page tabs stay in the row).
    var favouritesList: some View {
        VStack(alignment: .leading, spacing: 8) {
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
    var favouritePageTabs: some View {
        HStack(spacing: 3) {
            Image(systemName: "star.fill")
                .font(.system(size: StudioTheme.scaleFont(10), weight: .semibold))
                .foregroundColor(palette.accentBlue)
                .padding(.trailing, 3)
            ForEach(Array(browser.favouritePages.enumerated()), id: \.offset) { index, name in
                FavouritePageTab(name: name, count: browser.favouriteCount(onPage: index),
                                 isSelected: index == browser.currentFavouritePage, canDelete: browser.favouritePages.count > 1,
                                 isLightMode: isLightMode, dragging: $draggingFavourite,
                                 onSelect: {
                                     browser.favouritePage = index
                                     // List layout: the page's favourites drop down under its tab (click again to close).
                                     if isListLayout { listOpenPage = listOpenPage == index ? nil : index }
                                 },
                                 onRename: { browser.renameFavouritePage(index, to: $0) },
                                 onDelete: { browser.deleteFavouritePage(index) },
                                 onDropFavourite: { browser.moveFavourite($0, toPage: index) })
                .popover(isPresented: Binding(get: { isListLayout && listOpenPage == index },
                                              set: { if !$0, listOpenPage == index { listOpenPage = nil } }),
                         arrowEdge: .bottom) { favouritesList }
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
    func toolLabel(_ title: String?, systemImage: String, tint: Color? = nil, menu: Bool = false) -> some View {
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
    func toolButton(_ title: String?, systemImage: String, help: String, isOn: Bool = false, tint: Color? = nil,
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
    func downloadButton(_ targets: [FrameIO.Item]) -> some View {
        if let account = browser.accountID, !targets.isEmpty {
            Button { DownloadQueue.shared.download(targets, account: account) } label: {
                Label(targets.count == 1 ? "Download…" : "Download \(targets.count) Items…", systemImage: "arrow.down.circle")
            }
        }
    }

    /// Right-click → Edit Metadata…: Status, Assignee, Rating and custom fields on every selected file at once.
    @ViewBuilder
    func metadataButton(_ targets: [FrameIO.Item]) -> some View {
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
    func importCommentsButton(_ targets: [FrameIO.Item]) -> some View {
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
    func sendNotes(_ targets: [FrameIO.Item], account: String) {
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

    var toolDivider: some View {
        Rectangle()
            .fill(palette.borderLine)
            .frame(width: 1, height: StudioTheme.scale(16))
            .padding(.horizontal, 4)
    }

    /// Breadcrumbs; the project and parent folders accept drops (move up, or upload there).
    /// One crumb: its title and how deep it is (0 = "Frame.io").
    struct CrumbEntry {
        let title: String
        let depth: Int
        let crumb: Crumb?
    }

    /// "Frame.io" and the path, without the account when the workspace has the same name ("Wild Island Films ›
    /// Wild Island Films").
    var crumbEntries: [CrumbEntry] {
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
    var breadcrumbs: some View {
        let entries = crumbEntries
        return CrumbFitter(titles: entries.map(\.title)) { keep, shorten in
            crumbRow(entries, keep: keep, shortenLast: shorten)
        }
        .lineLimit(1)
        .help(entries.map(\.title).joined(separator: " › "))
    }

    func crumbRow(_ entries: [CrumbEntry], keep: Int, shortenLast: Bool = false) -> some View {
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
    func hiddenCrumbsList(_ hidden: [CrumbEntry]) -> some View {
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

    var crumbChevron: some View {
        Image(systemName: "chevron.right")
            .font(.system(size: StudioTheme.scaleFont(9), weight: .semibold))
            .foregroundColor(palette.textMuted.opacity(0.6))
    }

    func crumbIcon(_ crumb: Crumb?) -> String {
        switch crumb?.level {
        case nil: return "house"
        case .account?: return "person.crop.circle"
        case .workspace?: return "square.grid.2x2"
        case .project?: return "film.stack"
        case .stack?: return "square.stack.3d.up"
        case .folder?: return "folder"
        }
    }

    func crumbButton(_ title: String, depth: Int, crumb: Crumb?, isLast: Bool, shortens: Bool = false) -> some View {
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
}
