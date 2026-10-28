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
    var onPlay: (URL) -> Void
    var onDrop: ([NSItemProvider]) -> Bool
    @AppStorage("uploadPanelWidth") private var panelWidth: Double = 380
    @AppStorage("uploadLogOpen") private var showLog = false

    private var palette: StudioPalette { StudioPalette(isLightMode) }

    var body: some View {
        GeometryReader { geo in
            let maxWidth = max(300, min(900, Double(geo.size.width) - 420))
            HStack(spacing: 0) {
                VStack(alignment: .leading, spacing: 18) {
                    assets
                    UploadQueuePanel(isLightMode: isLightMode, nodes: nodes, collapsedFolderIDs: $collapsedFolderIDs,
                                     onClearQueue: onClearQueue, onPlay: onPlay)
                }
                .padding(22)
                .frame(width: min(max(panelWidth, 300), maxWidth))
                .frame(maxHeight: .infinity)
                .background(palette.bgPanel)
                .overlay(Rectangle().fill(palette.borderLine).frame(width: 1), alignment: .trailing)
                .overlay(alignment: .trailing) {
                    PanelResizeHandle(width: $panelWidth, range: 300...maxWidth, defaultWidth: 380, isLightMode: isLightMode,
                                      help: "Drag to resize the Assets & Queue panel. Double-click to reset (380 pt).")
                }
                .onDrop(of: [UTType.fileURL.identifier], isTargeted: nil, perform: onDrop)

                FrameIOBrowserView(isLightMode: isLightMode)
                if showLog {
                    UploadLogDrawer(isLightMode: isLightMode)
                        .frame(width: 340)
                        .overlay(Rectangle().fill(palette.borderLine).frame(width: 1), alignment: .leading)
                        .transition(.move(edge: .trailing).combined(with: .opacity))
                }
            }
        }
        .task(id: queueVersion) {
            UploadQueue.shared.sync(with: UploadQueuePanel.rows(in: nodes))
        }
    }
}

/// The queue as upload rows (folder headers and files, styled like the Play queue) plus the upload controls.
struct UploadQueuePanel: View {
    var isLightMode: Bool
    var nodes: [FileSystemTreeNode]
    @Binding var collapsedFolderIDs: Set<String>
    var onClearQueue: () -> Void
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
                                    .onTapGesture { click([node.url.path]) }
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
            Button("Reveal in Finder") { NSWorkspace.shared.activateFileViewerSelecting([node.url]) }
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
                    actionButton("Discard", primary: false, action: queue.cancel)
                        .explain("Forgets this upload and removes its unfinished files from Frame.io.")
                } else {
                    actionButton(queue.selection.isEmpty ? "Upload All (\(queue.jobs.count))" : "Upload Selected (\(queue.selection.count))",
                                 primary: true, action: start)
                        .disabled(browser.destination == nil || queue.jobs.isEmpty)
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
                Text("\(saved.jobs.count) file\(saved.jobs.count == 1 ? "" : "s") left · \(UploadQueuePanel.bytes(queue.resumableBytes))")
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
        .help(failure ?? job.url.path)
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
    var isLightMode: Bool
    @ObservedObject private var queue = UploadQueue.shared

    private var palette: StudioPalette { StudioPalette(isLightMode) }
    private var fraction: Double { min(1, Double(queue.sentBytes) / Double(max(queue.totalBytes, 1))) }
    private var elapsed: TimeInterval {
        guard let started = queue.runStarted else { return 0 }
        return (queue.runFinished ?? Date()).timeIntervalSince(started)
    }
    private var average: Double { elapsed > 0 ? Double(queue.transferredBytes) / elapsed : 0 }
    private var failedCount: Int {
        queue.jobs.filter { job in
            guard queue.runIDs.contains(job.id), case .failed = job.status else { return false }
            return true
        }.count
    }

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
                    .foregroundColor(failedCount > 0 && !queue.isRunning ? palette.negative : palette.accentBlue)
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
                Text("\(UploadLogFormat.bytes(queue.sentBytes)) of \(UploadLogFormat.bytes(queue.totalBytes))")
                Spacer()
                Text(timeText)
            }
            .font(.ui(size: 10))
            .foregroundColor(palette.textMuted)

            if queue.isRunning || queue.transferredBytes > 0 {
                VStack(alignment: .leading, spacing: 5) {
                    HStack(alignment: .firstTextBaseline, spacing: 6) {
                        Text(UploadLogFormat.speed(queue.isRunning ? queue.bytesPerSecond : average))
                            .font(.ui(size: 13, weight: .semibold))
                            .foregroundColor(palette.textMain)
                        Text(UploadLogFormat.megabits(queue.isRunning ? queue.bytesPerSecond : average))
                            .font(.ui(size: 10))
                            .foregroundColor(palette.textMuted)
                        Spacer()
                        Text(queue.isRunning ? "now" : "average")
                            .font(.ui(size: 10))
                            .foregroundColor(palette.textMuted)
                    }
                    SpeedGraph(samples: queue.speedHistory, color: palette.accentBlue)
                        .frame(height: StudioTheme.scale(30))
                    HStack {
                        Text("avg \(UploadLogFormat.speed(average))")
                        Spacer()
                        Text("peak \(UploadLogFormat.speed(queue.speedHistory.max() ?? 0))")
                    }
                    .font(.ui(size: 10))
                    .foregroundColor(palette.textMuted)
                }
            }
        }
        .padding(12)
        .studioBox(background: palette.bgCardSubtle, border: palette.borderLine)
    }

    private var title: String {
        if queue.isRunning {
            return "Uploading \(min(queue.runFinishedCount + 1, queue.runCount)) of \(queue.runCount)"
        }
        if failedCount > 0 { return "\(failedCount) of \(queue.runCount) failed" }
        if queue.runFinishedCount < queue.runCount { return "Cancelled" }
        return queue.runCount == 1 ? "Upload complete" : "All \(queue.runCount) uploaded"
    }

    private var timeText: String {
        guard queue.isRunning else { return "took \(UploadLogFormat.duration(elapsed))" }
        let remaining = Double(queue.totalBytes - queue.sentBytes)
        guard elapsed > 3, queue.bytesPerSecond > 0 else { return "\(UploadLogFormat.duration(elapsed)) elapsed" }
        return "about \(UploadLogFormat.duration(remaining / queue.bytesPerSecond)) left"
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

/// Right-hand drawer: what was uploaded where, when, how long it took and how fast. Selectable and copyable as text.
private struct UploadLogDrawer: View {
    var isLightMode: Bool
    @ObservedObject private var queue = UploadQueue.shared

    private var palette: StudioPalette { StudioPalette(isLightMode) }

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 10) {
                Text("Upload Log").font(.ui(size: 12, weight: .semibold))
                Spacer()
                Button("Copy") { Self.copy(queue.log) }
                    .font(.ui(size: 12))
                    .buttonStyle(.borderless)
                    .disabled(queue.log.isEmpty)
                    .help("Copy the whole log as text")
                Button("Clear", action: queue.clearLog)
                    .font(.ui(size: 12))
                    .buttonStyle(.borderless)
                    .disabled(queue.log.isEmpty || queue.isRunning)
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 10)
            .background(palette.bgPanel)
            Rectangle().fill(palette.borderLine).frame(height: 1)

            if queue.log.isEmpty {
                VStack {
                    Spacer()
                    Text("Uploads will be listed here.").font(.ui(size: 11)).foregroundColor(palette.textMuted)
                    Spacer()
                }
                .frame(maxWidth: .infinity)
            } else {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 16) {
                        ForEach(queue.log) { run in
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
    let run: UploadLogRun
    let isLightMode: Bool

    private var palette: StudioPalette { StudioPalette(isLightMode) }
    private var failed: Int { run.entries.filter { $0.outcome == .failed }.count }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 6) {
                Circle().fill(statusColor).frame(width: 7, height: 7)
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
                .help("Copy this upload as text")
            }

            HStack(alignment: .top, spacing: 6) {
                Image(systemName: "folder.fill")
                    .font(.system(size: StudioTheme.scaleFont(11)))
                    .foregroundColor(palette.accentBlue)
                Text(run.destination)
                    .font(.ui(size: 12, weight: .semibold))
                    .foregroundColor(palette.textMain)
                    .fixedSize(horizontal: false, vertical: true)
            }

            HStack(alignment: .top, spacing: 0) {
                stat("Files", UploadLogFormat.files(run))
                stat("Size", UploadLogFormat.bytes(run.uploadedBytes))
                stat("Time", run.finished.map { UploadLogFormat.duration($0.timeIntervalSince(run.started)) } ?? "—")
                stat("Avg Speed", UploadLogFormat.averageSpeed(run) ?? "—")
            }

            Rectangle().fill(palette.borderLine).frame(height: 1)

            VStack(alignment: .leading, spacing: 9) {
                ForEach(run.entries) { entry in
                    entryRow(entry)
                }
            }
        }
        .padding(12)
        .studioBox(background: palette.bgCardSubtle, border: palette.borderLine)
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
        guard let finished = run.finished, run.uploadedBytes > 0 else { return nil }
        let seconds = finished.timeIntervalSince(run.started)
        return seconds > 0 ? speed(Double(run.uploadedBytes) / seconds) : nil
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
        var header = ["Frame.io upload, \(dateTime(run.started)): \(status(run))", "To: \(run.destination)"]
        var totals = ["Files: \(files(run))", "Size: \(bytes(run.uploadedBytes))"]
        if let finished = run.finished { totals.append("Time: \(duration(finished.timeIntervalSince(run.started)))") }
        if let average = averageSpeed(run) { totals.append("Avg speed: \(average)") }
        header.append(totals.joined(separator: " · "))
        let mark: [UploadLogEntry.Outcome: String] = [.uploaded: "✓", .skipped: "=", .failed: "✗", .cancelled: "–"]
        let lines = run.entries.map { "\(mark[$0.outcome] ?? "") \($0.name) (\(bytes($0.bytes))): \(entryLine($0, in: run))" }
        return (header + [""] + lines).joined(separator: "\n")
    }
}

