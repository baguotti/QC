import SwiftUI
import AppKit
import AuthenticationServices
import UniformTypeIdentifiers
import ImageIO

/// The browser's listing: rows, columns, selection, drag and drop, context menus.
extension FrameIOBrowserView {
    // MARK: List

    var folderList: some View {
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
    var projectColumnHeader: some View {
        columnHeader("Project", inset: StudioTheme.scale(22) + 10,
                     columns: ProjectColumn.allCases.map { ($0.title, $0.width) })
    }

    /// Column titles over a folder's contents (aligned with the names) or a stack's versions (over the V badges).
    var contentColumnHeader: some View {
        columnHeader(browser.inStack ? "Version" : "Name",
                     inset: browser.inStack ? 0 : (showThumbnails ? CGFloat(thumbnailWidth) : StudioTheme.scale(18)) + 10,
                     columns: ContentColumn.allCases.map { ($0.title, $0.width) })
    }

    func columnHeader(_ name: String, inset: CGFloat, columns: [(title: String, width: CGFloat)]) -> some View {
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
    var noFavouriteProjects: some View {
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
    func navigationRow(_ item: FrameIO.Item, striped: Bool) -> some View {
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
    func contentRow(_ item: FrameIO.Item, striped: Bool) -> some View {
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

    func contentColumns(_ item: FrameIO.Item, isSelected: Bool) -> some View {
        ForEach(ContentColumn.allCases, id: \.self) { column in
            Text(column.value(for: item))
                .font(.ui(size: 11))
                .foregroundColor(isSelected ? .white.opacity(0.85) : palette.textMuted)
                .lineLimit(1)
                .frame(width: StudioTheme.scale(column.width), alignment: .leading)
        }
    }

    func versionBadge(_ text: String, isSelected: Bool) -> some View {
        Text(text)
            .font(.ui(size: 11, weight: .bold))
            .foregroundColor(isSelected ? palette.accentBlue : .white)
            .padding(.horizontal, 5)
            .padding(.vertical, 1)
            .background(Capsule().fill(isSelected ? Color.white : palette.accentBlue))
            .fixedSize()
    }

    /// Inside a stack: its versions, newest first, numbered, with the current one marked.
    func versionRow(_ item: FrameIO.Item, index: Int) -> some View {
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
    func acceptIntoStack(_ providers: [NSItemProvider], stack: FrameIO.Item) -> Bool {
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
    func menu(for item: FrameIO.Item) -> some View {
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
    func deleteButton(for item: FrameIO.Item) -> some View {
        if let targets = browser.deletable(for: item) {
            Divider()
            Button(role: .destructive) { browser.confirmDelete(targets) } label: {
                Label(targets.count == 1 ? "Delete" : "Delete \(targets.count) Items", systemImage: "trash")
            }
        }
    }

    @ViewBuilder
    func openInNewTab(_ item: FrameIO.Item?) -> some View {
        if let link = item?.viewURL, let url = URL(string: link) {
            Button { NSWorkspace.shared.open(url) } label: { Label("Open in Frame.io", systemImage: "arrow.up.forward.square") }
        }
    }

    /// Frame.io's names: "Copy Folder URL" on folders, "Copy Asset URL" on files and stacks.
    @ViewBuilder
    func copyURLButton(_ targets: [FrameIO.Item]) -> some View {
        let links = targets.compactMap(\.viewURL)
        if !links.isEmpty {
            let title = targets.count > 1 ? "Copy URLs"
                : (targets[0].isFolder ? "Copy Folder URL" : "Copy Asset URL")
            Button { copy(links.joined(separator: "\n")) } label: { Label(title, systemImage: "link") }
        }
    }

    /// "Move to ▸": the folders above (to move up) and next to the items, then Choose Folder… for anywhere else.
    @ViewBuilder
    func moveToMenu(_ targets: [FrameIO.Item]) -> some View {
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
}
