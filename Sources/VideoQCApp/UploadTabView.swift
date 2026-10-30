import SwiftUI
import AppKit
import AuthenticationServices
import UniformTypeIdentifiers
import VideoQCLib

// MARK: - Upload tab

extension ContentView {
    /// The app's queue on the left (same files as Play, Inspect and Scan), the Frame.io destination on the right.
    var uploadTabView: some View {
        UploadTabView(isLightMode: isLightMode, assets: AnyView(deliveryAssetsSection(forTab: .upload)),
                      nodes: playerTreeNodes, queueVersion: queueVersion,
                      collapsedFolderIDs: $playerCollapsedFolderIDs, onClearQueue: clearQueue,
                      onClearFolder: { clearFolder(node: $0) }, onToast: showToast,
                      onPlay: { url in
                          selectedTab = .player
                          playerEngine.loadVideo(url: url, into: .slotA, autoplay: true)
                      },
                      onDrop: { handleDrop(providers: $0, forTab: .upload) })
    }
}

/// Owns the left panel's width, so dragging the divider re-renders this tab only, not the window.
struct UploadTabView: View {
    var isLightMode: Bool
    var assets: AnyView
    var nodes: [FileSystemTreeNode]
    var queueVersion: Int
    @Binding var collapsedFolderIDs: Set<String>
    var onClearQueue: () -> Void
    var onClearFolder: (FileSystemTreeNode) -> Void
    var onToast: (String) -> Void
    var onPlay: (URL) -> Void
    var onDrop: ([NSItemProvider]) -> Bool
    @AppStorage("uploadPanelWidth") private var panelWidth: Double = 380
    @AppStorage("uploadLogOpen") private var isDrawerOpen = false   // the Media Info, Downloads & Log drawer (key kept from when it was Log only)
    @AppStorage("uploadDrawerWidth") private var drawerWidth: Double = 360

    private var palette: StudioPalette { StudioPalette(isLightMode) }

    var body: some View {
        // A layout, not a GeometryReader: the reader re-ran this whole body (and rebuilt the browser) on every resize
        // frame just to clamp the widths; `UploadColumns` clamps them while placing, so resizing only moves things.
        UploadColumns(panelWidth: panelWidth, drawerWidth: drawerWidth, hasDrawer: isDrawerOpen && !benchHides("drawer")) {
            VStack(alignment: .leading, spacing: 18) {
                if !benchHides("assets") { assets }
                // Rebuilt only when the queue, its folders, light mode or the theme change (it redraws itself for
                // uploads and selection): dragging a divider re-ran it per mouse move, flattening the whole tree.
                if !benchHides("queue") {
                    EquatableRow(key: QueuePanelKey(queueVersion: queueVersion, collapsed: collapsedFolderIDs, isLightMode: isLightMode,
                                                    theme: ThemeManager.shared.revision)) {
                        UploadQueuePanel(isLightMode: isLightMode, nodes: nodes, collapsedFolderIDs: $collapsedFolderIDs,
                                         onClearQueue: onClearQueue, onClearFolder: onClearFolder, onPlay: onPlay)
                    }
                    .equatable()
                }
            }
            .padding(22)
            .frame(maxHeight: .infinity)
            .background(palette.bgPanel)
            .overlay(Rectangle().fill(palette.borderLine).frame(width: 1), alignment: .trailing)
            .overlay(alignment: .trailing) {
                // The range is the widest the panel can be; `UploadColumns` narrows it to what the window allows.
                PanelResizeHandle(width: $panelWidth, range: UploadColumns.panelRange, defaultWidth: 380, isLightMode: isLightMode,
                                  help: "Drag to resize the Assets & Queue panel. Double-click to reset (380 pt).")
            }
            .onDrop(of: [UTType.fileURL.identifier], isTargeted: nil, perform: onDrop)

            if benchHides("browser") { Color.clear } else { FrameIOBrowserView(isLightMode: isLightMode) }
            if isDrawerOpen && !benchHides("drawer") {
                UploadSideDrawer(isLightMode: isLightMode, onToast: onToast)
                    .overlay(Rectangle().fill(palette.borderLine).frame(width: 1), alignment: .leading)
                    .overlay(alignment: .leading) {
                        PanelResizeHandle(width: $drawerWidth, range: UploadColumns.drawerRange, defaultWidth: 360, isLightMode: isLightMode,
                                          help: "Drag to resize the drawer. Double-click to reset (360 pt).",
                                          edge: .leading)
                    }
                    .transition(.move(edge: .trailing).combined(with: .opacity))
            }
        }
        .task(id: queueVersion) {
            UploadQueue.shared.sync(with: UploadQueuePanel.rows(in: nodes), version: queueVersion)
        }
    }
}

/// The Upload tab's columns: queue panel | Frame.io browser | drawer. Widths are clamped to the window here, while
/// placing (queue 300…900 and leaving the browser 420; drawer 300…800 and leaving the browser 360), so a resize never
/// re-runs the tab's body.
struct UploadColumns: Layout {
    static let panelRange: ClosedRange<Double> = 300...900
    static let drawerRange: ClosedRange<Double> = 300...800

    var panelWidth: Double
    var drawerWidth: Double
    var hasDrawer: Bool

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        proposal.replacingUnspecifiedDimensions()
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        guard !subviews.isEmpty else { return }
        let total = bounds.width
        let left = min(max(panelWidth, 300), max(300, min(900, total - 420)))
        let drawer = hasDrawer && subviews.count > 2 ? min(max(drawerWidth, 300), max(300, min(800, total - left - 360))) : 0
        let middle = max(0, total - left - drawer)
        let widths = [left, middle, drawer]
        var x = bounds.minX
        for (index, subview) in subviews.enumerated() {
            let width = index < widths.count ? widths[index] : 0
            subview.place(at: CGPoint(x: x, y: bounds.minY), proposal: ProposedViewSize(width: width, height: bounds.height))
            x += width
        }
    }
}

/// What the Upload queue panel is drawn from (its closures don't change what it shows).
private struct QueuePanelKey: Equatable {
    let queueVersion: Int
    let collapsed: Set<String>
    let isLightMode: Bool
    let theme: Int
}

/// The queue as upload rows (folder headers and files, styled like the Play queue) plus the upload controls.
struct UploadQueuePanel: View {
    @ObservedObject private var themeManager = ThemeManager.shared   // accent changes redraw
    var isLightMode: Bool
    var nodes: [FileSystemTreeNode]
    @Binding var collapsedFolderIDs: Set<String>
    var onClearQueue: () -> Void
    var onClearFolder: (FileSystemTreeNode) -> Void
    var onPlay: (URL) -> Void
    @ObservedObject private var queue = UploadQueue.shared
    /// Last row clicked without Shift: the other end of a Shift-click range.
    @State private var anchor: String?
    @AppStorage("queueDisplayMode") private var displayMode: String = "inline"
    @AppStorage("playerThumbnailSize") private var thumbnailSize: Double = 52.0

    private var palette: StudioPalette { StudioPalette(isLightMode) }

    /// Every file under the tree with the folders between the queue's folder and the file.
    static func rows(in nodes: [FileSystemTreeNode], folders: [String] = []) -> [(url: URL, folders: [String])] {
        nodes.flatMap { node -> [(url: URL, folders: [String])] in
            node.isDirectory ? rows(in: node.children, folders: folders + [node.name]) : [(node.url, folders)]
        }
    }

    private var visibleNodes: [FileSystemTreeNode] {
        FileSystemTreeBuilder.flatten(nodes: nodes, collapsedIDs: collapsedFolderIDs, hiddenIDs: [], hideAllFolders: false,
                                      filterText: "", kindMask: MediaKindFilter.all)
    }

    var body: some View {
        let jobs = Dictionary(queue.jobs.map { ($0.url.path, $0) }, uniquingKeysWith: { a, _ in a })
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: StudioTheme.scale(5)) {
                Text(queue.selection.isEmpty ? "Queue (\(queue.jobs.count))" : "Queue (\(queue.selection.count) of \(queue.jobs.count) selected)")
                    .font(.ui(size: 12, weight: .semibold))
                    .foregroundColor(palette.textMuted)
                if FileSystemTreeBuilder.hasSubfolders(in: nodes) {
                    Button(action: toggleAllFolders) {
                        Image(systemName: collapsedFolderIDs.isEmpty ? "chevron.down.circle" : "chevron.right.circle")
                            .font(.system(size: StudioTheme.scaleFont(10), weight: .bold))
                            .foregroundColor(palette.textMuted)
                    }
                    .buttonStyle(.plain)
                }
                Spacer()
                QueueViewOptionsButton(isLightMode: isLightMode)
            }

            if nodes.isEmpty {
                VStack(spacing: 8) {
                    Spacer()
                    Image(systemName: "icloud.and.arrow.up")
                        .font(.system(size: StudioTheme.scaleFont(24)))
                        .foregroundColor(palette.textMuted)
                    Text("Nothing to Upload")
                        .font(.ui(size: 10, weight: .semibold))
                        .foregroundColor(palette.textMuted)
                    Text("Select or drop a folder: the same queue is used in every tab.")
                        .font(.ui(size: 9))
                        .foregroundColor(palette.textSubtle)
                        .multilineTextAlignment(.center)
                    Spacer()
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .padding(12)
                .studioBox(background: palette.bgCardSubtle, border: palette.borderLine)
            } else {
                ScrollView {
                    LazyVStack(spacing: displayMode == "inline" ? 2 : 4) {
                        ForEach(visibleNodes) { node in
                            if node.isDirectory {
                                folderRow(node)
                            } else if let job = jobs[node.url.path] {
                                UploadQueueRow(job: job, depth: node.depth, isSelected: !queue.isRunning && queue.selection.contains(node.url.path),
                                               thumbnailWidth: displayMode == "inline" ? nil : thumbnailSize, isLightMode: isLightMode)
                                    .equatable()
                                    .onTapGesture {
                                        // Double-click plays it (the first click already selected it).
                                        if (NSApp.currentEvent?.clickCount ?? 1) >= 2 { onPlay(node.url) } else { click([node.url.path]) }
                                    }
                                    .onDrag { dragProvider([node.url.path]) }
                                    .contextMenu {
                                        Button("Play") { onPlay(node.url) }
                                        Button("Reveal in Finder") { NSWorkspace.shared.activateFileViewerSelecting([node.url]) }
                                        Button("Copy Path") {
                                            NSPasteboard.general.clearContents()
                                            NSPasteboard.general.setString(node.url.path, forType: .string)
                                        }
                                    }
                            }
                        }
                    }
                    Color.clear
                        .frame(height: 40)
                        .contentShape(Rectangle())
                        .onTapGesture { queue.selection = []; anchor = nil }
                }
                .clipped()
                .frame(maxHeight: .infinity)

                Button(action: onClearQueue) {
                    HStack(spacing: 4) {
                        Image(systemName: "xmark").font(.system(size: StudioTheme.scaleFont(8), weight: .bold))
                        Text("Clear List").font(.ui(size: 9, weight: .semibold))
                    }
                    .foregroundColor(palette.textMuted)
                    .frame(maxWidth: .infinity, alignment: .center)
                    .padding(.top, 6)
                }
                .buttonStyle(TransportIconButtonStyle())
                .disabled(queue.isRunning)
            }

            UploadControls(isLightMode: isLightMode, subfolders: nodes.filter(\.isDirectory).map(\.name))
                .padding(.top, 10)
        }
        .frame(maxHeight: .infinity)
    }

    private func folderRow(_ node: FileSystemTreeNode) -> some View {
        let isCollapsed = collapsedFolderIDs.contains(node.id)
        let files = node.videoURLs.map(\.path)
        let isSelected = !queue.isRunning && !files.isEmpty && files.allSatisfy(queue.selection.contains)
        return HStack(spacing: 6) {
            Image(systemName: isCollapsed ? "chevron.right" : "chevron.down")
                .font(.system(size: StudioTheme.scaleFont(9), weight: .bold))
                .foregroundColor(isSelected ? .white : palette.textMuted)
                .frame(width: 12)
                .contentShape(Rectangle().inset(by: -4))
                .onTapGesture {
                    if isCollapsed { collapsedFolderIDs.remove(node.id) } else { collapsedFolderIDs.insert(node.id) }
                }
            Image(systemName: "folder")
                .font(.system(size: StudioTheme.scaleFont(11), weight: .medium))
                .foregroundColor(isSelected ? .white : palette.textSubtle)
                .frame(width: 14, height: 14)
            Text(node.name)
                .font(.ui(size: 10, weight: .semibold))
                .foregroundColor(isSelected ? .white : palette.textMain)
                .lineLimit(1)
            Spacer()
            Text("\(node.videoCount)")
                .font(.ui(size: 8, weight: .semibold))
                .foregroundColor(isSelected ? .white : palette.textSubtle)
                .padding(.horizontal, 5)
                .padding(.vertical, 1)
                .background(RoundedRectangle(cornerRadius: 3).fill(isSelected ? Color.white.opacity(0.2) : palette.bgSubtle))
        }
        .padding(.leading, CGFloat(node.depth * 14) + 6)
        .padding(.trailing, 8)
        .padding(.vertical, 5)
        .background(RoundedRectangle(cornerRadius: StudioTheme.cornerRadius).fill(isSelected ? palette.accentBlue : .clear))
        .contentShape(Rectangle())
        .onTapGesture { click(files) }
        .onDrag { dragProvider(files) }
        .contextMenu {
            // Like the Play queue's Clear Folder; on a selected folder, clears every selected folder.
            let selected = selectedFolders(in: nodes)
            let targets = selected.contains { $0.id == node.id } ? selected : [node]
            Button(targets.count > 1 ? "Clear \(targets.count) Folders" : "Clear Folder") {
                for folder in targets { onClearFolder(folder) }
            }
            .disabled(queue.isRunning)
            Divider()
            Button("Reveal in Finder") { NSWorkspace.shared.activateFileViewerSelecting([node.url]) }
        }
    }

    /// The outermost folders whose files are all selected.
    private func selectedFolders(in nodes: [FileSystemTreeNode]) -> [FileSystemTreeNode] {
        nodes.flatMap { node -> [FileSystemTreeNode] in
            guard node.isDirectory else { return [] }
            let files = node.videoURLs.map(\.path)
            if !files.isEmpty && files.allSatisfy(queue.selection.contains) { return [node] }
            return selectedFolders(in: node.children)
        }
    }

    private func dragProvider(_ paths: [String]) -> NSItemProvider {
        let dragged = queue.isRunning ? [] : queue.dragPaths(for: paths)
        return NSItemProvider(object: (UploadQueue.dragPrefix + dragged.joined(separator: "\n")) as NSString)
    }

    /// Finder selection: click selects (a folder selects everything in it), ⌘-click adds or removes, ⇧-click selects
    /// the range from the last clicked row, in queue order.
    private func click(_ paths: [String]) {
        guard let first = paths.first, !queue.isRunning else { return }
        let flags = NSEvent.modifierFlags
        if flags.contains(.shift), let anchor {
            let order = Self.rows(in: nodes).map(\.url.path)
            let ends = [anchor, first, paths.last ?? first].compactMap { order.firstIndex(of: $0) }
            if let low = ends.min(), let high = ends.max() {
                let range = order[low...high]
                queue.selection = flags.contains(.command) ? queue.selection.union(range) : Set(range)
                return
            }
        }
        if flags.contains(.command) {
            let all = paths.allSatisfy(queue.selection.contains)
            if all { queue.selection.subtract(paths) } else { queue.selection.formUnion(paths) }
        } else {
            let clicked = Set(paths)
            queue.selection = queue.selection == clicked ? [] : clicked
        }
        anchor = first
    }

    private func toggleAllFolders() {
        if collapsedFolderIDs.isEmpty {
            func ids(_ node: FileSystemTreeNode) -> [String] {
                node.isDirectory ? [node.id] + node.children.flatMap(ids) : []
            }
            collapsedFolderIDs = Set(nodes.flatMap(ids))
        } else {
            collapsedFolderIDs = []
        }
    }

    static func bytes(_ count: Int64) -> String {
        ByteCountFormatter.string(fromByteCount: count, countStyle: .file)
    }
}

/// Destination, Keep subfolders, progress and the Upload button. Its own view: it observes the Frame.io browser (for the
/// destination), so typing in the Frame.io filter or selecting there doesn't redraw the queue list.
private struct UploadControls: View {
    @ObservedObject private var themeManager = ThemeManager.shared   // accent changes redraw
    var isLightMode: Bool
    /// The queue's top-level subfolders (named in "Keep subfolders").
    var subfolders: [String]
    @ObservedObject private var queue = UploadQueue.shared
    @ObservedObject private var browser = FrameIOBrowser.shared

    private var palette: StudioPalette { StudioPalette(isLightMode) }

    var body: some View { controls }


    private var controls: some View {
        VStack(alignment: .leading, spacing: 10) {
            destinationCard

            if queue.runCount > 0 {
                UploadProgressCard(isLightMode: isLightMode)
            }

            if !queue.isRunning, let saved = queue.resumable {
                resumeCard(saved)
            }

            HStack(spacing: 8) {
                if queue.isRunning {
                    actionButton("Pause", primary: true, action: queue.pause)
                        .explain("Stops sending. Nothing is lost: Resume continues from where it stopped, even after quitting QCpie.")
                    actionButton("Cancel", primary: false, action: queue.cancel)
                        .explain("Stops the upload and removes its unfinished files from Frame.io.")
                } else if queue.resumable != nil {
                    actionButton("Resume", primary: true, action: queue.resume)
                        .disabled(browser.signedIn != true)
                        .explain("Continues the paused or interrupted upload from the next unsent part of each file.")
                    actionButton("Discard", primary: false, action: queue.cancel)
                        .explain("Forgets this upload and removes its unfinished files from Frame.io.")
                } else {
                    actionButton(queue.selection.isEmpty ? "Upload All (\(queue.jobs.count))" : "Upload Selected (\(queue.selection.count))",
                                 primary: true, action: start)
                        .disabled(browser.destination == nil || queue.jobs.isEmpty)
                        .explain(queue.selection.isEmpty
                                 ? "Uploads every file in the queue to the open Frame.io folder. Files already there (same name and size) are skipped."
                                 : "Uploads the selected files to the open Frame.io folder. Files already there (same name and size) are skipped.")
                }
            }
        }
    }

    /// Where the upload goes and how: the destination, then a "Keep subfolders" switch (off = all in one folder).
    private var destinationCard: some View {
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                Image(systemName: browser.destination == nil ? "questionmark.folder" : "folder.fill")
                    .font(.system(size: StudioTheme.scaleFont(12)))
                    .foregroundColor(browser.destination == nil ? palette.textMuted : palette.accentBlue)
                    .frame(width: 16)
                VStack(alignment: .leading, spacing: 1) {
                    Text("Upload to")
                        .font(.ui(size: 10))
                        .foregroundColor(palette.textMuted)
                    Text(destinationText)
                        .font(.ui(size: 12, weight: browser.destination == nil ? .regular : .semibold))
                        .foregroundColor(browser.destination == nil ? palette.textMuted : palette.textMain)
                        .lineLimit(1)
                        .truncationMode(.head)
                }
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 9)

            Rectangle().fill(palette.borderLine.opacity(0.6)).frame(height: 0.5).padding(.leading, 36)

            HStack(spacing: 8) {
                Image(systemName: queue.keepStructure ? "folder.badge.plus" : "tray.full")
                    .font(.system(size: StudioTheme.scaleFont(11)))
                    .foregroundColor(palette.textMuted)
                    .frame(width: 16)
                VStack(alignment: .leading, spacing: 1) {
                    Text("Keep subfolders")
                        .font(.ui(size: 12))
                        .foregroundColor(palette.textMain)
                    Text(structureDetail)
                        .font(.ui(size: 10))
                        .foregroundColor(palette.textMuted)
                        .lineLimit(1)
                        .truncationMode(.tail)
                }
                Spacer(minLength: 8)
                Toggle("", isOn: $queue.keepStructure)
                    .labelsHidden()
                    .toggleStyle(.switch)
                    .controlSize(.small)
                    .disabled(queue.isRunning)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 9)
        }
        .background(RoundedRectangle(cornerRadius: 8).fill(palette.bgCardSubtle))
        .overlay(RoundedRectangle(cornerRadius: 8).stroke(palette.borderLine.opacity(0.7), lineWidth: 0.5))
        .explain("Off: every file goes straight into the chosen Frame.io folder. On: the queue's subfolders are recreated inside it.")
    }

    /// An upload that stopped before the end (paused, quit, crash or failed files) and where it was going.
    private func resumeCard(_ saved: UploadResumeStore.SavedRun) -> some View {
        HStack(spacing: 8) {
            Image(systemName: "pause.circle.fill")
                .font(.system(size: StudioTheme.scaleFont(14)))
                .foregroundColor(palette.accentBlue)
            VStack(alignment: .leading, spacing: 1) {
                let files = saved.jobs.reduce(0) { $0 + $1.files.count }   // an image sequence is many files
                Text("\(files) file\(files == 1 ? "" : "s") left · \(UploadQueuePanel.bytes(queue.resumableBytes))")
                    .font(.ui(size: 12, weight: .semibold))
                    .foregroundColor(palette.textMain)
                Text("To \(saved.destinationPath) · Resume picks up where it stopped")
                    .font(.ui(size: 10))
                    .foregroundColor(palette.textMuted)
                    .lineLimit(1)
                    .truncationMode(.head)
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 9)
        .background(RoundedRectangle(cornerRadius: 8).fill(palette.bgCardSubtle))
        .overlay(RoundedRectangle(cornerRadius: 8).stroke(palette.borderLine.opacity(0.7), lineWidth: 0.5))
    }

    /// Names the queue's own subfolders, so the choice is concrete.
    private var structureDetail: String {
        guard queue.keepStructure else { return "Off: every file goes straight into this folder" }
        let names = subfolders
        guard !names.isEmpty else { return "The queue has no subfolders" }
        let shown = names.prefix(3).map { "\($0)/" }.joined(separator: ", ")
        return "Recreates " + shown + (names.count > 3 ? " …" : "")
    }

    private func actionButton(_ title: String, primary: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(title)
                .font(.ui(size: 12, weight: .semibold))
                .foregroundColor(primary ? palette.primaryBtnFg : palette.textMain)
                .frame(maxWidth: .infinity)
                .frame(height: StudioTheme.scale(30))
                .studioBox(background: primary ? palette.primaryBtnBg : palette.bgSubtle, border: primary ? .clear : palette.borderLine)
        }
        .buttonStyle(.plain)
    }

    private var destinationText: String {
        guard browser.destination != nil else {
            return browser.signedIn == true ? "Open a Frame.io project or folder" : "Sign in to Frame.io"
        }
        return browser.path.filter { $0.level == .project || $0.level == .folder }.map(\.title).joined(separator: " › ")
    }

    private func start() {
        guard let account = browser.accountID, let destination = browser.destination else { return }
        queue.start(to: .init(account: account, folder: destination.folderID ?? destination.id, path: destinationText))
    }

}

/// A queue file row (list or thumbnail, like the Play queue): name and size, or upload progress / result.
private struct UploadQueueRow: View, Equatable {
    /// Redraws the row when its list redraws for a new accent (`ThemeManager.revision`).
    var themeRevision = ThemeManager.shared.revision
    let job: UploadQueue.Job
    let depth: Int
    let isSelected: Bool
    /// Thumbnail width in thumbnail view, nil in list view.
    let thumbnailWidth: Double?
    let isLightMode: Bool

    private var palette: StudioPalette { StudioPalette(isLightMode) }
    private var fraction: Double { Double(job.sent) / Double(max(job.size, 1)) }

    var body: some View {
        Group {
            if let thumbnailWidth {
                thumbnailRow(width: CGFloat(thumbnailWidth))
            } else {
                listRow
            }
        }
        .padding(.leading, 9)
        .padding(.trailing, 8)
        .frame(maxWidth: .infinity)
        .background(alignment: .leading) {
            if job.status == .uploading || job.status == .paused {
                GeometryReader { geo in
                    Rectangle()
                        .fill(palette.accentBlue.opacity(job.status == .paused ? 0.07 : 0.14))
                        .frame(width: geo.size.width * CGFloat(fraction))
                }
            }
        }
        .background(RoundedRectangle(cornerRadius: StudioTheme.cornerRadius).fill(isSelected ? palette.accentBlue : .clear))
        .contentShape(Rectangle())
        .tip(failure ?? job.url.path)
    }

    private var listRow: some View {
        HStack(spacing: 6) {
            if depth > 0 { Spacer().frame(width: CGFloat(depth * 12)) }
            statusIcon
                .font(.system(size: StudioTheme.scaleFont(8.5), weight: .semibold))
                .frame(width: 12)
            name(size: 10.5)
            Spacer(minLength: 4)
            trailing
        }
        .frame(height: StudioTheme.scale(28))
    }

    private func thumbnailRow(width: CGFloat) -> some View {
        let height = (width * 9 / 16).rounded()
        return HStack(spacing: 8) {
            if depth > 0 { Spacer().frame(width: CGFloat(depth * 12)) }
            AssetThumbnailView(fileURL: job.url, width: width, height: height, cornerRadius: width >= 64 ? 3.5 : 2.5)
            VStack(alignment: .leading, spacing: 3) {
                name(size: width >= 64 ? 11 : 10.5)
                HStack(spacing: 4) {
                    statusIcon.font(.system(size: StudioTheme.scaleFont(7.5), weight: .semibold))
                    Text(detail)
                        .font(.ui(size: 8, weight: .semibold))
                        .foregroundColor(tone(failure != nil ? palette.negative : palette.textMuted.opacity(0.85)))
                        .lineLimit(1)
                }
            }
            Spacer(minLength: 4)
            if job.status == .uploading || job.status == .paused { trailing }
        }
        .frame(height: max(StudioTheme.scale(32), height + StudioTheme.scale(14)))
    }

    private func name(size: CGFloat) -> some View {
        HStack(spacing: 6) {
            Text(job.url.lastPathComponent)
                .font(.ui(size: size, weight: .medium))
                .foregroundColor(isSelected ? .white : palette.textSubtle)
                .lineLimit(1)
                .truncationMode(.middle)
            if job.files.count > 1 {
                Text("Seq \(job.files.count)")
                    .font(.ui(size: 7.5, weight: .semibold))
                    .foregroundColor(tone(palette.textMuted))
                    .padding(.horizontal, 3)
                    .padding(.vertical, 1)
                    .overlay(RoundedRectangle(cornerRadius: 2).stroke(tone(palette.textMuted.opacity(0.6)), lineWidth: 0.75))
                    .fixedSize()
            }
        }
    }

    /// Thumbnail view's second line: format and size, or the upload result.
    private var detail: String {
        let size = UploadQueuePanel.bytes(job.size)
        switch job.status {
        case .uploading: return "\(UploadQueuePanel.bytes(job.sent)) of \(size)"
        case .paused: return "Paused · \(UploadQueuePanel.bytes(job.sent)) of \(size)"
        case .done: return "Uploaded · \(size)"
        case .skipped: return "Already on Frame.io · \(size)"
        case .cancelled: return "Cancelled · \(size)"
        case .failed(let message): return "Failed: \(message)"
        case .queued: return "\(job.url.pathExtension.uppercased()) · \(size)"
        }
    }

    /// Text and icons turn white on the selection highlight.
    private func tone(_ color: Color) -> Color { isSelected ? .white : color }

    private var failure: String? {
        if case .failed(let message) = job.status { return message }
        return nil
    }

    @ViewBuilder
    private var trailing: some View {
        switch job.status {
        case .uploading:
            Text("\(Int(fraction * 100))%")
                .font(.ui(size: 9, weight: .semibold))
                .foregroundColor(tone(palette.accentBlue))
        case .paused:
            Text("Paused · \(Int(fraction * 100))%")
                .font(.ui(size: 9, weight: .semibold))
                .foregroundColor(tone(palette.textMuted))
        case .skipped:
            Text("Already There").font(.ui(size: 9)).foregroundColor(tone(palette.textMuted))
        case .failed:
            Text("Failed").font(.ui(size: 9, weight: .semibold)).foregroundColor(tone(palette.negative))
        default:
            Text(UploadQueuePanel.bytes(job.size)).font(.ui(size: 9)).foregroundColor(tone(palette.textMuted))
        }
    }

    @ViewBuilder
    private var statusIcon: some View {
        switch job.status {
        case .queued:
            Image(systemName: QCUtilities.mediaKind(of: job.url)?.symbolName ?? "doc").foregroundColor(tone(palette.textMuted))
        case .uploading:
            Image(systemName: "arrow.up").foregroundColor(tone(palette.accentBlue))
        case .paused:
            Image(systemName: "pause.fill").foregroundColor(tone(palette.textMuted))
        case .done:
            Image(systemName: "checkmark").foregroundColor(tone(palette.positive))
        case .skipped:
            Image(systemName: "checkmark").foregroundColor(tone(palette.textMuted))
        case .cancelled:
            Image(systemName: "minus").foregroundColor(tone(palette.textMuted))
        case .failed:
            Image(systemName: "exclamationmark.triangle.fill").foregroundColor(tone(palette.negative))
        }
    }
}

/// Upload status above the button: progress, sizes, time left and a live speed graph. Redrawn at the 5 Hz tick.
private struct UploadProgressCard: View {
    @ObservedObject private var themeManager = ThemeManager.shared   // accent changes redraw
    var isLightMode: Bool
    @ObservedObject private var queue = UploadQueue.shared

    private var failedCount: Int {
        queue.jobs.filter { job in
            guard queue.runIDs.contains(job.id), case .failed = job.status else { return false }
            return true
        }.count
    }

    /// Stopped by Pause (or a quit): rows of this run wait for Resume.
    private var isPaused: Bool {
        !queue.isRunning && queue.jobs.contains { queue.runIDs.contains($0.id) && $0.status == .paused }
    }

    var body: some View {
        TransferProgressCard(isLightMode: isLightMode, title: title, done: queue.sentBytes, total: queue.totalBytes,
                             transferred: queue.transferredBytes, isRunning: queue.isRunning, failed: failedCount > 0,
                             isPaused: isPaused, bytesPerSecond: queue.bytesPerSecond, history: queue.speedHistory,
                             started: queue.runStarted, finished: queue.runFinished)
    }

    private var title: String {
        if queue.isRunning {
            return "Uploading \(min(queue.runFinishedCount + 1, queue.runCount)) of \(queue.runCount)"
        }
        if isPaused { return "Paused · \(queue.runFinishedCount) of \(queue.runCount) done" }
        if failedCount > 0 { return "\(failedCount) of \(queue.runCount) failed" }
        if queue.runFinishedCount < queue.runCount { return "Cancelled" }
        return queue.runCount == 1 ? "Upload complete" : "All \(queue.runCount) uploaded"
    }
}

/// Progress of an upload or download run: percentage, bar, sizes, time left, and the live speed with its graph.
struct TransferProgressCard: View {
    @ObservedObject private var themeManager = ThemeManager.shared   // accent changes redraw
    var isLightMode: Bool
    var title: String
    var done: Int64
    var total: Int64
    /// Bytes actually moved over the network (the average speed comes from this).
    var transferred: Int64
    var isRunning: Bool
    var failed: Bool
    var isPaused = false
    var bytesPerSecond: Double
    var history: [Double]
    var started: Date?
    var finished: Date?

    private var palette: StudioPalette { StudioPalette(isLightMode) }
    private var fraction: Double { min(1, Double(done) / Double(max(total, 1))) }
    private var elapsed: TimeInterval {
        guard let started else { return 0 }
        return (finished ?? Date()).timeIntervalSince(started)
    }
    private var average: Double { elapsed > 0 ? Double(transferred) / elapsed : 0 }

    var body: some View {
        VStack(alignment: .leading, spacing: 9) {
            HStack(alignment: .firstTextBaseline) {
                Text(title)
                    .font(.ui(size: 13, weight: .semibold))
                    .foregroundColor(palette.textMain)
                Spacer()
                Text("\(Int((fraction * 100).rounded(.down)))%")
                    .font(.system(size: StudioTheme.scaleFont(17), weight: .semibold, design: .rounded))
                    .monospacedDigit()
                    .foregroundColor(failed && !isRunning ? palette.negative : palette.accentBlue)
            }

            GeometryReader { geo in
                ZStack(alignment: .leading) {
                    Capsule().fill(palette.bgSubtle)
                    Capsule()
                        .fill(LinearGradient(colors: [palette.accentBlue.opacity(0.7), palette.accentBlue],
                                             startPoint: .leading, endPoint: .trailing))
                        .frame(width: max(fraction > 0 ? 8 : 0, geo.size.width * CGFloat(fraction)))
                }
            }
            .frame(height: StudioTheme.scale(8))

            HStack {
                Text("\(UploadLogFormat.bytes(done)) of \(UploadLogFormat.bytes(total))")
                Spacer()
                Text(timeText)
            }
            .font(.ui(size: 10))
            .foregroundColor(palette.textMuted)

            if isRunning || transferred > 0 {
                VStack(alignment: .leading, spacing: 5) {
                    HStack(alignment: .firstTextBaseline, spacing: 6) {
                        Text(UploadLogFormat.speed(isRunning ? bytesPerSecond : average))
                            .font(.ui(size: 13, weight: .semibold))
                            .foregroundColor(palette.textMain)
                        Text(UploadLogFormat.megabits(isRunning ? bytesPerSecond : average))
                            .font(.ui(size: 10))
                            .foregroundColor(palette.textMuted)
                        Spacer()
                        Text(isRunning ? "now" : "average")
                            .font(.ui(size: 10))
                            .foregroundColor(palette.textMuted)
                    }
                    SpeedGraph(samples: history, color: palette.accentBlue)
                        .frame(height: StudioTheme.scale(30))
                    HStack {
                        Text("avg \(UploadLogFormat.speed(average))")
                        Spacer()
                        Text("peak \(UploadLogFormat.speed(history.max() ?? 0))")
                    }
                    .font(.ui(size: 10))
                    .foregroundColor(palette.textMuted)
                }
            }
        }
        .padding(12)
        .studioBox(background: palette.bgCardSubtle, border: palette.borderLine)
    }

    private var timeText: String {
        if isPaused { return "paused" }
        guard isRunning else { return "took \(UploadLogFormat.duration(elapsed))" }
        let remaining = Double(total - done)
        guard elapsed > 3, bytesPerSecond > 0 else { return "\(UploadLogFormat.duration(elapsed)) elapsed" }
        return "about \(UploadLogFormat.duration(remaining / bytesPerSecond)) left"
    }
}

/// Area graph of the upload speed samples, scaled to the fastest one.
private struct SpeedGraph: View {
    let samples: [Double]
    let color: Color

    var body: some View {
        Canvas { context, size in
            guard samples.count > 1, let peak = samples.max(), peak > 0 else { return }
            let step = size.width / CGFloat(max(samples.count - 1, 1))
            var line = Path()
            for (index, value) in samples.enumerated() {
                let point = CGPoint(x: CGFloat(index) * step, y: size.height * (1 - CGFloat(value / peak) * 0.92))
                if index == 0 { line.move(to: point) } else { line.addLine(to: point) }
            }
            var area = line
            area.addLine(to: CGPoint(x: CGFloat(samples.count - 1) * step, y: size.height))
            area.addLine(to: CGPoint(x: 0, y: size.height))
            area.closeSubpath()
            context.fill(area, with: .linearGradient(Gradient(colors: [color.opacity(0.35), color.opacity(0.03)]),
                                                     startPoint: .zero, endPoint: CGPoint(x: 0, y: size.height)))
            context.stroke(line, with: .color(color), lineWidth: 1.25)
        }
        .background(RoundedRectangle(cornerRadius: 3).fill(color.opacity(0.04)))
    }
}

/// The Upload tab's right drawer: the selected queue file's Media Info (the Player's panel), Downloads and the upload
/// Log, switched like the Player's review sleeve.
private struct UploadSideDrawer: View {
    var isLightMode: Bool
    var onToast: (String) -> Void
    @AppStorage("uploadDrawerTab") private var tab = "info"
    @State private var isDropTarget = false
    /// Pages slide in from the side of their tab: set just before `tab` changes.
    @State private var forward = true
    /// The queue's selection, heard without observing the queue (its upload progress mustn't redraw the drawer).
    @State private var selection: Set<String> = []
    @StateObject private var mediaInfo = MediaInfoLoader()

    static let tabs = ["info", "downloads", "log"]
    private var palette: StudioPalette { StudioPalette(isLightMode) }
    /// Media Info shows a file when exactly one is selected.
    private var inspectedFile: URL? { selection.count == 1 ? selection.first.map { URL(fileURLWithPath: $0) } : nil }

    var body: some View {
        VStack(spacing: 0) {
            DrawerTabBar(isLightMode: isLightMode, tab: tab, onSelect: select)
            Rectangle().fill(palette.borderLine).frame(height: 1)
            ZStack(alignment: .top) {
                switch tab {
                case "downloads": DownloadsDrawer(isLightMode: isLightMode).transition(slide)
                case "log": UploadLogDrawer(isLightMode: isLightMode).transition(slide)
                default:
                    MediaInfoPanel(url: inspectedFile, loader: mediaInfo, isLightMode: isLightMode,
                                   emptyTitle: selection.count > 1 ? "\(selection.count) Files Selected" : "No File Selected",
                                   emptyMessage: "Select one file in the queue to inspect its tracks and metadata.",
                                   onToast: onToast)
                        .transition(slide)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .clipped()
            .overlay(RoundedRectangle(cornerRadius: 4).stroke(isDropTarget ? palette.accentBlue : .clear, lineWidth: 2).padding(2))
            // Frame.io rows dropped on any page download (the Downloads page opens when they start).
            .onDrop(of: [.utf8PlainText], isTargeted: $isDropTarget, perform: DownloadQueue.acceptDrop)
            // `tab` is @AppStorage: its writes don't carry `withAnimation`, so animate on the value.
            .animation(.spring(response: 0.32, dampingFraction: 0.84), value: tab)
        }
        .onReceive(UploadQueue.shared.$selection.removeDuplicates()) { selection = $0 }
        // Read only while Media Info shows (coming back to it reads the file again).
        .task(id: [tab, inspectedFile?.path ?? ""]) {
            guard tab == "info" || !Self.tabs.contains(tab) else { return }
            await mediaInfo.load(inspectedFile, asset: nil)
        }
    }

    private var slide: AnyTransition {
        .asymmetric(insertion: .move(edge: forward ? .trailing : .leading), removal: .move(edge: forward ? .leading : .trailing))
            .combined(with: .opacity)
    }

    private func select(_ id: String) {
        guard id != tab else { return }
        forward = (Self.tabs.firstIndex(of: id) ?? 0) > (Self.tabs.firstIndex(of: tab) ?? 0)
        // A turn later: the leaving page's transition is the one from the render before the switch.
        DispatchQueue.main.async { tab = id }
    }
}

/// The drawer's Media Info | Downloads | Log switcher (the review sleeve's pill). Observes downloads for its
/// percentage on its own, so the other pages don't redraw at the download's 5 Hz.
private struct DrawerTabBar: View {
    @ObservedObject private var themeManager = ThemeManager.shared   // accent changes redraw
    var isLightMode: Bool
    var tab: String
    var onSelect: (String) -> Void
    @ObservedObject private var downloads = DownloadQueue.shared

    private var palette: StudioPalette { StudioPalette(isLightMode) }
    var body: some View {
        HStack(spacing: 4) {
            tabButton("info", "Media Info", badge: nil)
            tabButton("downloads", "Downloads", badge: downloads.isRunning ? "\(downloads.percent)%" : nil)
            tabButton("log", "Log", badge: nil)
        }
        .padding(3)
        .background(RoundedRectangle(cornerRadius: 8).fill(palette.bgSubtle)
            .overlay(RoundedRectangle(cornerRadius: 8).stroke(palette.borderLine, lineWidth: 1)))
        .padding(.horizontal, 12)
        .padding(.vertical, 9)
        .background(palette.bgPanel)
    }

    private func tabButton(_ id: String, _ title: String, badge: String?) -> some View {
        let isSelected = tab == id || (id == "info" && !UploadSideDrawer.tabs.contains(tab))
        return Button(action: { onSelect(id) }) {
            HStack(spacing: 5) {
                Text(title).font(.ui(size: 11, weight: isSelected ? .semibold : .medium)).lineLimit(1)
                if let badge {
                    Text(badge)
                        .font(.ui(size: 9, weight: .semibold))
                        .monospacedDigit()
                        .foregroundColor(palette.accentBlue)
                }
            }
            .frame(maxWidth: .infinity)
            .frame(height: 25)
            .foregroundColor(isSelected ? (isLightMode ? Color.black : Color.white) : palette.textMuted)
            .background {
                if isSelected {
                    RoundedRectangle(cornerRadius: 6)
                        .fill(isLightMode ? palette.bgPanel : Color(white: 0.22))
                        .overlay(RoundedRectangle(cornerRadius: 6).stroke(isLightMode ? palette.borderStrong : Color.white.opacity(0.18), lineWidth: 1))
                        .shadow(color: Color.black.opacity(isLightMode ? 0.08 : 0.25), radius: 2, y: 1)
                }
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}

/// Frame.io downloads (right-click → Download…): the progress card with its speed graph, then each file.
private struct DownloadsDrawer: View {
    @ObservedObject private var themeManager = ThemeManager.shared   // accent changes redraw
    var isLightMode: Bool
    @ObservedObject private var queue = DownloadQueue.shared

    private var palette: StudioPalette { StudioPalette(isLightMode) }

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 10) {
                Text(queue.isPreparing ? "Listing files…" : "Downloads").font(.ui(size: 12, weight: .semibold))
                Spacer()
                if queue.isRunning || queue.isPaused {
                    if queue.isRunning {
                        Button("Pause", action: queue.pause).font(.ui(size: 12)).buttonStyle(.borderless)
                            .tip("Pause: what's downloaded so far is kept until you resume (quitting QCpie removes unfinished downloads)")
                    } else {
                        Button("Resume", action: queue.resume).font(.ui(size: 12)).buttonStyle(.borderless)
                            .tip("Continue the paused downloads: only the missing parts are fetched")
                    }
                    Button("Cancel", action: queue.cancel).font(.ui(size: 12)).buttonStyle(.borderless)
                        .tip("Stop and remove the unfinished files")
                } else {
                    if queue.failedCount > 0 {
                        Button("Retry Failed", action: queue.retryFailed).font(.ui(size: 12)).buttonStyle(.borderless)
                            .tip("Download the files that failed again")
                    }
                    Button("Clear", action: queue.clearFinished)
                        .font(.ui(size: 12))
                        .buttonStyle(.borderless)
                        .tip("Remove finished, failed and cancelled downloads from the list (the files stay on disk)")
                        .disabled(!queue.hasFinished)
                }
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 10)
            .background(palette.bgPanel)
            Rectangle().fill(palette.borderLine).frame(height: 1)

            if let error = queue.lastError {
                Text(error)
                    .font(.ui(size: 11))
                    .foregroundColor(palette.negative)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 16)
                    .padding(.vertical, 8)
            }
            if queue.jobs.isEmpty {
                VStack(spacing: 6) {
                    Spacer()
                    Image(systemName: "arrow.down.circle")
                        .font(.system(size: StudioTheme.scaleFont(20), weight: .light))
                        .foregroundColor(palette.textMuted)
                    Text(queue.isPreparing ? "Listing the folder's files…" : "Drag Frame.io files or folders here, or right-click → Download…")
                        .font(.ui(size: 11))
                        .foregroundColor(palette.textMuted)
                        .multilineTextAlignment(.center)
                    Spacer()
                }
                .frame(maxWidth: .infinity)
                .padding(.horizontal, 20)
            } else {
                ScrollView {
                    VStack(alignment: .leading, spacing: 10) {
                        TransferProgressCard(isLightMode: isLightMode, title: title, done: queue.receivedBytes, total: queue.totalBytes,
                                             transferred: queue.transferredBytes, isRunning: queue.isRunning,
                                             failed: queue.failedCount > 0, isPaused: queue.isPaused, bytesPerSecond: queue.bytesPerSecond,
                                             history: queue.speedHistory, started: queue.runStarted, finished: queue.runFinished)
                        LazyVStack(spacing: 0) {
                            ForEach(queue.jobs) { job in
                                DownloadRow(job: job, isLightMode: isLightMode).equatable()
                            }
                        }
                    }
                    .padding(12)
                }
            }
        }
        .background(palette.bgMain)
    }

    private var title: String {
        let count = queue.jobs.count
        if queue.isRunning { return "Downloading \(min(queue.finishedCount + 1, count)) of \(count)" }
        if queue.isPaused { return "Paused · \(queue.finishedCount) of \(count) done" }
        if queue.failedCount > 0 { return "\(queue.failedCount) of \(count) failed" }
        if queue.finishedCount < count { return "Stopped" }
        return count == 1 ? "Download complete" : "All \(count) downloaded"
    }
}

private struct DownloadRow: View, Equatable {
    /// Redraws the row when its list redraws for a new accent (`ThemeManager.revision`).
    var themeRevision = ThemeManager.shared.revision
    let job: DownloadQueue.Job
    let isLightMode: Bool

    private var palette: StudioPalette { StudioPalette(isLightMode) }
    private var fraction: Double { Double(job.received) / Double(max(job.size, 1)) }

    var body: some View {
        HStack(spacing: 8) {
            icon.font(.system(size: StudioTheme.scaleFont(9), weight: .semibold)).frame(width: 12)
            VStack(alignment: .leading, spacing: 2) {
                Text(job.name)
                    .font(.ui(size: 11, weight: .medium))
                    .foregroundColor(palette.textMain)
                    .lineLimit(1)
                    .truncationMode(.middle)
                Text(detail)
                    .font(.ui(size: 10))
                    .foregroundColor(failure != nil ? palette.negative : palette.textMuted)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            Spacer(minLength: 4)
            if job.status == .done {
                Button(action: { DownloadQueue.shared.revealInFinder(job) }) {
                    Image(systemName: "magnifyingglass")
                        .font(.system(size: StudioTheme.scaleFont(10)))
                        .foregroundColor(palette.textMuted)
                        .frame(width: 22, height: 22)
                        .contentShape(Rectangle())
                }
                .buttonStyle(TransportIconButtonStyle())
                .tip("Show in Finder")
            } else if job.status == .downloading {
                Text("\(Int(fraction * 100))%")
                    .font(.ui(size: 10, weight: .semibold))
                    .monospacedDigit()
                    .foregroundColor(palette.accentBlue)
            }
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 6)
        .background(alignment: .leading) {
            if job.status == .downloading {
                GeometryReader { geo in
                    Rectangle().fill(palette.accentBlue.opacity(0.12)).frame(width: geo.size.width * CGFloat(fraction))
                }
            }
        }
        .tip(failure ?? job.localURL?.path ?? job.name)
        .contextMenu {
            if let url = job.localURL {
                Button { NSWorkspace.shared.activateFileViewerSelecting([url]) } label: { Label("Reveal in Finder", systemImage: "folder") }
                Button { NSWorkspace.shared.open(url) } label: { Label("Open", systemImage: "arrow.up.forward.app") }
                Divider()
                Button {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(url.path, forType: .string)
                } label: { Label("Copy Path", systemImage: "doc.on.doc") }
            } else {
                Button { DownloadQueue.shared.revealDestination(job) } label: { Label("Reveal Destination Folder", systemImage: "folder") }
            }
        }
    }

    private var failure: String? {
        if case .failed(let message) = job.status { return message }
        return nil
    }

    private var detail: String {
        let size = UploadLogFormat.bytes(job.size)
        let place = ([job.destination.lastPathComponent] + job.folders).joined(separator: " › ")
        switch job.status {
        case .queued: return "\(size) · to \(place)"
        case .downloading: return "\(UploadLogFormat.bytes(job.received)) of \(size)"
        case .paused: return "Paused · \(UploadLogFormat.bytes(job.received)) of \(size)"
        case .done: return "Downloaded · \(size) · \(place)"
        case .cancelled: return "Cancelled · \(size)"
        case .failed(let message): return message
        }
    }

    @ViewBuilder
    private var icon: some View {
        switch job.status {
        case .queued: Image(systemName: "arrow.down").foregroundColor(palette.textMuted)
        case .downloading: Image(systemName: "arrow.down").foregroundColor(palette.accentBlue)
        case .paused: Image(systemName: "pause.fill").foregroundColor(palette.textMuted)
        case .done: Image(systemName: "checkmark").foregroundColor(palette.positive)
        case .cancelled: Image(systemName: "minus").foregroundColor(palette.textMuted)
        case .failed: Image(systemName: "exclamationmark.triangle.fill").foregroundColor(palette.negative)
        }
    }
}

private struct UploadLogDrawer: View {
    @ObservedObject private var themeManager = ThemeManager.shared   // accent changes redraw
    var isLightMode: Bool
    @ObservedObject private var log = TransferLog.shared
    @AppStorage("transferLogFilter") private var filter = "all"

    private var runs: [UploadLogRun] {
        switch filter {
        case "upload": return log.runs.filter { $0.kind == .upload }
        case "download": return log.runs.filter { $0.kind == .download }
        default: return log.runs
        }
    }

    private var palette: StudioPalette { StudioPalette(isLightMode) }

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 10) {
                Picker("", selection: $filter) {
                    Text("All").tag("all")
                    Image(systemName: "arrow.up").tip("Uploads").tag("upload")
                    Image(systemName: "arrow.down").tip("Downloads").tag("download")
                }
                .labelsHidden()
                .pickerStyle(.segmented)
                .controlSize(.small)
                .fixedSize()
                .tip("Show all transfers, uploads only or downloads only")
                Spacer()
                Button("Copy") { Self.copy(runs) }
                    .font(.ui(size: 12))
                    .buttonStyle(.borderless)
                    .disabled(runs.isEmpty)
                    .tip(filter == "all" ? "Copy the whole log as text" : "Copy the \(filter)s shown as text")
                Button("Clear", action: log.clear)
                    .font(.ui(size: 12))
                    .buttonStyle(.borderless)
                    .tip("Delete the log's history (finished uploads and downloads)")
                    .disabled(log.runs.isEmpty || log.isRecording)
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 10)
            .background(palette.bgPanel)
            Rectangle().fill(palette.borderLine).frame(height: 1)

            if runs.isEmpty {
                VStack {
                    Spacer()
                    Text(filter == "upload" ? "No uploads yet." : filter == "download" ? "No downloads yet." : "Uploads and downloads will be listed here.")
                        .font(.ui(size: 11)).foregroundColor(palette.textMuted)
                    Spacer()
                }
                .frame(maxWidth: .infinity)
            } else {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 16) {
                        ForEach(runs) { run in
                            UploadLogRunView(run: run, isLightMode: isLightMode).equatable()
                        }
                    }
                    .padding(16)
                    .textSelection(.enabled)
                }
            }
        }
        .frame(maxHeight: .infinity)
        .background(palette.bgMain)
    }

    static func copy(_ runs: [UploadLogRun]) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(runs.map(UploadLogFormat.text).joined(separator: "\n\n"), forType: .string)
    }
}

private struct UploadLogRunView: View, Equatable {
    /// Redraws the row when its list redraws for a new accent (`ThemeManager.revision`).
    var themeRevision = ThemeManager.shared.revision
    let run: UploadLogRun
    let isLightMode: Bool

    private var palette: StudioPalette { StudioPalette(isLightMode) }
    private var failed: Int { run.entries.filter { $0.outcome == .failed }.count }
    private var isDownload: Bool { run.kind == .download }
    /// Uploads in the play accent, downloads in slot B's: told apart at a glance.
    private var kindColor: Color { isDownload ? palette.accentSlotB : palette.accentBlue }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 6) {
                HStack(spacing: 3) {
                    Image(systemName: isDownload ? "arrow.down" : "arrow.up")
                        .font(.system(size: StudioTheme.scaleFont(8), weight: .heavy))
                    Text(isDownload ? "DOWNLOAD" : "UPLOAD")
                        .font(.ui(size: 10, weight: .bold))
                        .underline(true, color: kindColor)
                }
                .foregroundColor(kindColor)
                Circle().fill(statusColor).frame(width: 7, height: 7)
                    .padding(.leading, 2)
                Text(UploadLogFormat.status(run))
                    .font(.ui(size: 11, weight: .semibold))
                    .foregroundColor(statusColor)
                Spacer()
                Text(UploadLogFormat.dateTime(run.started))
                    .font(.ui(size: 10))
                    .foregroundColor(palette.textMuted)
                Button(action: { UploadLogDrawer.copy([run]) }) {
                    Image(systemName: "doc.on.doc").font(.system(size: StudioTheme.scaleFont(10)))
                }
                .buttonStyle(.borderless)
                .tip(isDownload ? "Copy this download as text" : "Copy this upload as text")
            }

            HStack(alignment: .top, spacing: 6) {
                Image(systemName: isDownload ? "internaldrive" : "icloud.and.arrow.up")
                    .font(.system(size: StudioTheme.scaleFont(11)))
                    .foregroundColor(kindColor)
                    .tip(isDownload ? "Downloaded from Frame.io to this folder on this Mac" : "Uploaded to this Frame.io folder")
                Text(run.destination)
                    .font(.ui(size: 12, weight: .semibold))
                    .foregroundColor(palette.textMain)
                    .fixedSize(horizontal: false, vertical: true)
            }

            HStack(alignment: .top, spacing: 0) {
                stat("Files", UploadLogFormat.files(run))
                stat("Size", UploadLogFormat.bytes(run.transferredBytes))
                stat("Time", run.finished.map { UploadLogFormat.duration($0.timeIntervalSince(run.started)) } ?? "—")
                stat("Avg Speed", UploadLogFormat.averageSpeed(run) ?? "—")
            }

            Rectangle().fill(palette.borderLine).frame(height: 1)

            VStack(alignment: .leading, spacing: 9) {
                ForEach(run.entries) { entry in
                    entryRow(entry)
                        .contentShape(Rectangle())
                        .contextMenu { entryMenu(entry) }
                }
            }
        }
        .padding(12)
        .padding(.leading, 3)
        .studioBox(background: palette.bgCardSubtle, border: palette.borderLine)
        .overlay(alignment: .leading) {
            UnevenRoundedRectangle(topLeadingRadius: StudioTheme.cornerRadius, bottomLeadingRadius: StudioTheme.cornerRadius)
                .fill(kindColor)
                .frame(width: 3)
        }
    }

    @ViewBuilder
    private func entryMenu(_ entry: UploadLogEntry) -> some View {
        if let path = entry.localPath {
            let url = URL(fileURLWithPath: path)
            Button {
                let exists = FileManager.default.fileExists(atPath: path)
                NSWorkspace.shared.activateFileViewerSelecting([exists ? url : url.deletingLastPathComponent()])
            } label: { Label("Reveal in Finder", systemImage: "folder") }
            Button { NSWorkspace.shared.open(url) } label: { Label("Open", systemImage: "arrow.up.forward.app") }
            Divider()
        }
        Button {
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(entry.localPath ?? entry.name, forType: .string)
        } label: { Label(entry.localPath == nil ? "Copy Name" : "Copy Path", systemImage: "doc.on.doc") }
    }

    private func stat(_ label: String, _ value: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(label.uppercased())
                .font(.ui(size: 8, weight: .semibold))
                .foregroundColor(palette.textMuted)
            Text(value)
                .font(.ui(size: 11, weight: .semibold))
                .foregroundColor(palette.textMain)
                .lineLimit(1)
                .minimumScaleFactor(0.8)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func entryRow(_ entry: UploadLogEntry) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack(spacing: 6) {
                Image(systemName: icon(entry.outcome))
                    .font(.system(size: StudioTheme.scaleFont(9), weight: .bold))
                    .foregroundColor(color(entry.outcome))
                    .frame(width: 12)
                Text(entry.name)
                    .font(.ui(size: 11, weight: .medium))
                    .foregroundColor(palette.textMain)
                    .lineLimit(1)
                    .truncationMode(.middle)
                Spacer(minLength: 6)
                Text(UploadLogFormat.bytes(entry.bytes))
                    .font(.ui(size: 10))
                    .foregroundColor(palette.textMuted)
            }
            Text(UploadLogFormat.entryLine(entry, in: run))
                .font(.ui(size: 10))
                .foregroundColor(entry.outcome == .failed ? palette.negative : palette.textMuted)
                .padding(.leading, 18)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private var statusColor: Color {
        if run.finished == nil { return palette.accentBlue }
        if failed > 0 { return palette.negative }
        if run.entries.contains(where: { $0.outcome == .cancelled }) { return palette.textMuted }
        return palette.positive
    }

    private func icon(_ outcome: UploadLogEntry.Outcome) -> String {
        switch outcome {
        case .uploaded: return "checkmark"
        case .skipped: return "equal"
        case .failed: return "exclamationmark.triangle.fill"
        case .cancelled: return "minus"
        }
    }

    private func color(_ outcome: UploadLogEntry.Outcome) -> Color {
        switch outcome {
        case .uploaded: return palette.positive
        case .failed: return palette.negative
        default: return palette.textMuted
        }
    }
}

/// The log's wording, shared by the drawer, the progress card and the copied text.
enum UploadLogFormat {
    static func dateTime(_ date: Date) -> String {
        date.formatted(.dateTime.day().month(.abbreviated).year().hour().minute())
    }

    static func time(_ date: Date) -> String {
        date.formatted(.dateTime.hour().minute().second())
    }

    static func duration(_ seconds: TimeInterval) -> String {
        let total = Int(seconds.rounded())
        if total < 60 { return "\(max(total, 0))s" }
        if total < 3600 { return "\(total / 60)m \(total % 60)s" }
        return "\(total / 3600)h \(total % 3600 / 60)m"
    }

    static func bytes(_ count: Int64) -> String {
        ByteCountFormatter.string(fromByteCount: count, countStyle: .file)
    }

    static func speed(_ bytesPerSecond: Double) -> String {
        "\(bytes(Int64(bytesPerSecond)))/s"
    }

    static func megabits(_ bytesPerSecond: Double) -> String {
        "\(Int((bytesPerSecond * 8 / 1_000_000).rounded())) Mbit/s"
    }

    static func status(_ run: UploadLogRun) -> String {
        guard run.finished != nil else { return "In Progress" }
        let failed = run.entries.filter { $0.outcome == .failed }.count
        if failed > 0 { return "\(failed) Failed" }
        if run.entries.contains(where: { $0.outcome == .cancelled }) { return "Cancelled" }
        return "Completed"
    }

    static func files(_ run: UploadLogRun) -> String {
        let uploaded = run.entries.filter { $0.outcome == .uploaded }.count
        let skipped = run.entries.filter { $0.outcome == .skipped }.count
        return skipped > 0 ? "\(uploaded) + \(skipped) there" : "\(uploaded)"
    }

    static func averageSpeed(_ run: UploadLogRun) -> String? {
        guard let finished = run.finished, run.transferredBytes > 0 else { return nil }
        let seconds = finished.timeIntervalSince(run.started)
        return seconds > 0 ? speed(Double(run.transferredBytes) / seconds) : nil
    }

    /// The subfolder under the run's destination the file went to, if any.
    static func subfolder(_ entry: UploadLogEntry, in run: UploadLogRun) -> String? {
        guard entry.destination.count > run.destination.count, entry.destination.hasPrefix(run.destination) else { return nil }
        return String(entry.destination.dropFirst(run.destination.count)).trimmingCharacters(in: CharacterSet(charactersIn: " ›"))
    }

    static func entryLine(_ entry: UploadLogEntry, in run: UploadLogRun) -> String {
        var parts: [String] = []
        if let folder = subfolder(entry, in: run) { parts.append("in \(folder)") }
        switch entry.outcome {
        case .uploaded:
            parts += [duration(entry.duration), speed(entry.bytesPerSecond), "done \(time(entry.finished))"]
        case .skipped:
            parts += ["already on Frame.io"]
        case .cancelled:
            parts += ["cancelled at \(time(entry.finished))"]
        case .failed:
            parts += ["failed at \(time(entry.finished))", entry.message ?? ""]
        }
        return parts.filter { !$0.isEmpty }.joined(separator: " · ")
    }

    static func text(_ run: UploadLogRun) -> String {
        var header = ["Frame.io \(run.kind == .download ? "download" : "upload"), \(dateTime(run.started)): \(status(run))",
                      "To: \(run.destination)"]
        var totals = ["Files: \(files(run))", "Size: \(bytes(run.transferredBytes))"]
        if let finished = run.finished { totals.append("Time: \(duration(finished.timeIntervalSince(run.started)))") }
        if let average = averageSpeed(run) { totals.append("Avg speed: \(average)") }
        header.append(totals.joined(separator: " · "))
        let mark: [UploadLogEntry.Outcome: String] = [.uploaded: "✓", .skipped: "=", .failed: "✗", .cancelled: "–"]
        let lines = run.entries.map { "\(mark[$0.outcome] ?? "") \($0.name) (\(bytes($0.bytes))): \(entryLine($0, in: run))" }
        return (header + [""] + lines).joined(separator: "\n")
    }
}

