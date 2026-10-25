import SwiftUI
import AppKit
import UniformTypeIdentifiers
import VideoQCLib

public struct PlayerQueuePanelView: View, Equatable {
    public var isLightMode: Bool
    public var themeId: String
    public var buttonZoom: UIButtonZoomLevel = ThemeManager.shared.buttonZoom
    public var folderURL: URL?
    public var videoFiles: [URL]
    public var playerTreeNodes: [FileSystemTreeNode]
    @Binding public var playerFilterText: String
    @Binding public var mediaKindFilter: Int
    @Binding public var playerCollapsedFolderIDs: Set<String>
    public var hiddenFolderIDs: Set<String>
    public var hideAllFolders: Bool
    public var fileTagsMap: [URL: FinderTagColor]
    public var isScanning: Bool
    public var isAutoplayEnabled: Bool
    public var drawsWaveforms: Bool
    public var queueVersion: Int = 0
    public var tagsVersion: Int = 0
    
    // Slot selection / metadata for rows
    public var slotAURL: URL?
    public var slotAResolution: String
    public var slotAFps: Double
    public var slotACodec: String
    
    public var slotBURL: URL?
    public var slotBResolution: String
    public var slotBFps: Double
    public var slotBCodec: String
    
    public var activeTarget: SlotTarget
    public var activeNotesURL: URL? = nil
    public var activeNotesCount: Int = 0
    
    @Binding public var queueScrollTarget: URL?
    
    // Action Callbacks:
    public var onSelectAssets: (_ append: Bool) -> Void
    public var onRefreshAssets: () -> Void
    public var onClearQueue: () -> Void
    public var onToggleHideFolders: () -> Void
    public var onToggleAutoplay: () -> Void
    public var onToggleWaveforms: () -> Void
    public var onToggleAllPlayerFolders: () -> Void
    public var onToggleFolderCollapse: (_ folderID: String) -> Void
    public var onHideFolder: (_ folderID: String) -> Void
    public var onClearFolder: (_ node: FileSystemTreeNode) -> Void
    public var onLoadVideo: (_ url: URL, _ target: SlotTarget) -> Void
    public var onSwapSlots: () -> Void
    public var onClearSlotB: () -> Void
    public var onOpenProperties: (_ url: URL) -> Void
    public var onOpenNotes: (_ url: URL) -> Void
    public var onSetReadAsSequence: (_ url: URL, _ asSequence: Bool) -> Void = { _, _ in }
    public var onSetSequenceFPS: (_ url: URL, _ fps: Double) -> Void = { _, _ in }
    public var onToggleTag: (_ tag: FinderTagColor, _ url: URL) -> Void
    public var onClearTag: (_ url: URL) -> Void
    public var onDrop: (_ providers: [NSItemProvider]) -> Bool
    
    public nonisolated static func == (lhs: PlayerQueuePanelView, rhs: PlayerQueuePanelView) -> Bool {
        MainActor.assumeIsolated {
            lhs.queueVersion == rhs.queueVersion &&
            lhs.tagsVersion == rhs.tagsVersion &&
            lhs.buttonZoom == rhs.buttonZoom &&
            lhs.isLightMode == rhs.isLightMode &&
            lhs.themeId == rhs.themeId &&
            lhs.folderURL == rhs.folderURL &&
            lhs.playerFilterText == rhs.playerFilterText &&
            lhs.mediaKindFilter == rhs.mediaKindFilter &&
            lhs.playerCollapsedFolderIDs == rhs.playerCollapsedFolderIDs &&
            lhs.hiddenFolderIDs == rhs.hiddenFolderIDs &&
            lhs.hideAllFolders == rhs.hideAllFolders &&
            lhs.isScanning == rhs.isScanning &&
            lhs.isAutoplayEnabled == rhs.isAutoplayEnabled &&
            lhs.drawsWaveforms == rhs.drawsWaveforms &&
            isSameURL(lhs.slotAURL, rhs.slotAURL) &&
            lhs.slotAResolution == rhs.slotAResolution &&
            lhs.slotAFps == rhs.slotAFps &&
            lhs.slotACodec == rhs.slotACodec &&
            isSameURL(lhs.slotBURL, rhs.slotBURL) &&
            lhs.slotBResolution == rhs.slotBResolution &&
            lhs.slotBFps == rhs.slotBFps &&
            lhs.slotBCodec == rhs.slotBCodec &&
            lhs.activeTarget == rhs.activeTarget &&
            isSameURL(lhs.activeNotesURL, rhs.activeNotesURL) &&
            lhs.activeNotesCount == rhs.activeNotesCount &&
            lhs.queueScrollTarget == rhs.queueScrollTarget
        }
    }
    
    @ObservedObject private var themeManager = ThemeManager.shared
    
    private var bgMain: Color { StudioTheme.bgMain(isLightMode) }
    private var bgPanel: Color { StudioTheme.bgPanel(isLightMode) }
    private var bgSubtle: Color { StudioTheme.bgSubtle(isLightMode) }
    private var bgCardHeader: Color { StudioTheme.bgCardHeader(isLightMode) }
    private var bgCardSubtle: Color { StudioTheme.bgCardSubtle(isLightMode) }
    private var borderLine: Color { StudioTheme.borderLine(isLightMode) }
    private var borderStrong: Color { StudioTheme.borderStrong(isLightMode) }
    private var textMain: Color { StudioTheme.textMain(isLightMode) }
    private var textMuted: Color { StudioTheme.textMuted(isLightMode) }
    private var textSubtle: Color { StudioTheme.textSubtle(isLightMode) }
    private var accentPositive: Color { StudioTheme.positive }
    private var accentSlotB: Color { StudioTheme.slotBAccent }
    private var accentBlue: Color { StudioTheme.accentBlue(isLightMode) }
    @AppStorage("queueDisplayMode") private var queueDisplayMode: String = "inline"
    @AppStorage("playerThumbnailSize") private var playerThumbnailSize: Double = 52.0
    @State private var showViewOptionsPopover: Bool = false
    
    private var hasSubfolders: Bool {
        FileSystemTreeBuilder.hasSubfolders(in: playerTreeNodes)
    }
    
    private var flattenedNodes: [FileSystemTreeNode] {
        FileSystemTreeBuilder.flatten(
            nodes: playerTreeNodes,
            collapsedIDs: playerCollapsedFolderIDs,
            hiddenIDs: hiddenFolderIDs,
            hideAllFolders: hideAllFolders,
            filterText: playerFilterText,
            kindMask: kindMask
        )
    }
    
    private var presentKinds: Int { MediaKindFilter.presentMask(of: videoFiles) }
    private var kindMask: Int { MediaKindFilter.effectiveMask(mediaKindFilter, present: presentKinds) }
    
    private var filteredFiles: [URL] {
        let treeOrder = FileSystemTreeBuilder.orderedVideoURLs(from: playerTreeNodes)
        let baseFiles = treeOrder.isEmpty ? videoFiles : treeOrder
        let mask = kindMask
        let query = playerFilterText.trimmingCharacters(in: .whitespacesAndNewlines)
        if query.isEmpty && mask == MediaKindFilter.all {
            return baseFiles
        }
        return baseFiles.filter {
            MediaKindFilter.allows($0, mask: mask) && (query.isEmpty || $0.lastPathComponent.localizedCaseInsensitiveContains(query))
        }
    }

    /// Queue list rows: the folder tree when there are subfolders, otherwise the flat file list as depth-0 nodes.
    /// File rows are identified by path in both layouts (same id as the tree builder's file nodes).
    private var queueRows: [FileSystemTreeNode] {
        if hasSubfolders { return flattenedNodes }
        return filteredFiles.map { url in
            FileSystemTreeNode(id: url.path, name: url.lastPathComponent, url: url, isDirectory: false, relativePath: url.lastPathComponent, depth: 0)
        }
    }
    
    public var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            // Asset Picker Section
            deliveryAssetsSection
            
            // Search Filter
            if !videoFiles.isEmpty {
                HStack(spacing: 6) {
                    Image(systemName: "magnifyingglass")
                        .font(.system(size: StudioTheme.scaleFont(10)))
                        .foregroundColor(textMuted)
                    
                    ZStack(alignment: .leading) {
                        if playerFilterText.isEmpty {
                            Text("Filter assets...")
                                .font(.ui(size: 11, weight: .semibold))
                                .foregroundColor(textMuted)
                                .allowsHitTesting(false)
                        }
                        TextField("", text: $playerFilterText)
                            .font(.ui(size: 11, weight: .medium))
                            .textFieldStyle(.plain)
                            .foregroundColor(textMain)
                            .onSubmit {
                                NSApp.keyWindow?.makeFirstResponder(nil)
                            }
                    }
                    
                    if !playerFilterText.isEmpty {
                        Button(action: { playerFilterText = "" }) {
                            Image(systemName: "xmark.circle.fill")
                                .font(.system(size: StudioTheme.scaleFont(10)))
                                .foregroundColor(textMuted)
                        }
                        .buttonStyle(.plain)
                    }
                    
                    let present = presentKinds
                    if present.nonzeroBitCount > 1 {
                        MediaKindFilterChips(mask: $mediaKindFilter, present: present, isLightMode: isLightMode)
                    }
                }
                .padding(.horizontal, 8)
                .padding(.vertical, 6)
                .studioBox(background: bgSubtle, border: borderLine)
            }
            
            // Asset List
            VStack(alignment: .leading, spacing: 6) {
                // One row when it fits, otherwise the tools wrap under the title (large Button Size, narrow panel).
                ViewThatFits(in: .horizontal) {
                    HStack(spacing: StudioTheme.scale(5)) {
                        queueTitle
                        Spacer(minLength: StudioTheme.scale(8))
                        queueTools
                    }
                    VStack(alignment: .leading, spacing: StudioTheme.scale(4)) {
                        queueTitle
                        queueTools
                    }
                }
                
                if videoFiles.isEmpty {
                    VStack(spacing: 8) {
                        Spacer()
                        Image(systemName: "video")
                            .font(.system(size: StudioTheme.scaleFont(24)))
                            .foregroundColor(textMuted)
                        Text("No Video Files Loaded")
                            .font(.ui(size: 10, weight: .semibold))
                            .foregroundColor(textMuted)
                        Text("Select or drop a folder to populate playback queue.")
                            .font(.ui(size: 9))
                            .foregroundColor(textSubtle)
                            .multilineTextAlignment(.center)
                        Spacer()
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .padding(12)
                    .studioBox(background: bgCardSubtle, border: borderLine)
                } else {
                    ScrollViewReader { scrollProxy in
                        ScrollView {
                            LazyVStack(spacing: queueDisplayMode == "inline" ? 2 : 4) {
                                // One ForEach keyed by path for both layouts: separate tree/flat ForEach branches tagging
                                // rows with the same ids left rows of the first layout orphaned in the lazy stack
                                // (stale highlight and indent until the panel was rebuilt).
                                ForEach(queueRows) { node in
                                    if node.isDirectory {
                                        folderRow(node: node)
                                    } else {
                                        let isSelA = isSameURL(slotAURL, node.url)
                                        let isSelB = isSameURL(slotBURL, node.url)
                                        let count = fileNotesCount(url: node.url)
                                        makeFileRow(url: node.url, depth: node.depth, isSlotA: isSelA, isSlotB: isSelB, notesCount: count)
                                    }
                                }
                            }
                        }
                        .clipped()
                        .onDrop(of: [UTType.fileURL.identifier], isTargeted: nil) { providers in
                            onDrop(providers)
                        }
                        .onChange(of: queueScrollTarget) { _, targetURL in
                            if let targetURL = targetURL {
                                withAnimation(.easeInOut(duration: 0.15)) {
                                    scrollProxy.scrollTo(targetURL.path, anchor: nil)
                                }
                            }
                        }
                        .onChange(of: slotAURL) { _, newURL in
                            if let newURL = newURL {
                                revealFolderContaining(url: newURL)
                            }
                        }
                        .onChange(of: slotBURL) { _, newURL in
                            if let newURL = newURL, activeTarget == .slotB {
                                revealFolderContaining(url: newURL)
                            }
                        }
                    }
                }
            }
            .frame(maxHeight: .infinity)
            
            if !videoFiles.isEmpty {
                Button(action: onClearQueue) {
                    HStack(spacing: 4) {
                        Image(systemName: "xmark")
                            .font(.system(size: StudioTheme.scaleFont(8), weight: .bold))
                        Text("Clear List")
                            .font(.ui(size: 9, weight: .semibold))
                    }
                    .foregroundColor(textMuted)
                    .frame(maxWidth: .infinity, alignment: .center)
                    .padding(.top, 6)
                }
                .buttonStyle(TransportIconButtonStyle())
                .disabled(isScanning)
                .explain("Removes all files from the queue and closes the player.")
            }
        }
        .padding(22)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(bgPanel)
        .onDrop(of: [UTType.fileURL.identifier], isTargeted: nil) { providers in
            onDrop(providers)
        }
    }
    
    private var queueTitle: some View {
        HStack(spacing: StudioTheme.scale(5)) {
            Text("Queue (\(filteredFiles.count))")
                .font(.ui(size: 12, weight: .semibold))
                .foregroundColor(textMuted)
            
            if hasSubfolders && !hideAllFolders {
                Button(action: onToggleAllPlayerFolders) {
                    Image(systemName: playerCollapsedFolderIDs.isEmpty ? "chevron.down.circle" : "chevron.right.circle")
                        .font(.system(size: StudioTheme.scaleFont(10), weight: .bold))
                        .foregroundColor(textMuted)
                }
                .buttonStyle(.plain)
                .explain(playerCollapsedFolderIDs.isEmpty ? "Collapse all folders in playback queue." : "Expand all folders in playback queue.")
            }
            
        }
        .fixedSize()
    }
    
    private var queueTools: some View {
        HStack(spacing: StudioTheme.scale(5)) {
            
            // View Mode Options Popover (Thumbnail View / List View / Thumbnail Size Slider)
            Button(action: { showViewOptionsPopover.toggle() }) {
                HStack(spacing: StudioTheme.scale(4)) {
                    Image(systemName: queueDisplayMode == "thumbnail" ? "square.grid.2x2" : "list.bullet")
                        .font(.system(size: StudioTheme.scaleFont(10.5), weight: .medium))
                    Image(systemName: "chevron.down")
                        .font(.system(size: StudioTheme.scaleFont(8), weight: .semibold))
                }
                .padding(.horizontal, StudioTheme.scale(5))
                .frame(height: StudioTheme.scale(26))
                .foregroundColor(textMain)
            }
            .buttonStyle(TransportIconButtonStyle())
            .explain("Queue display options: Switch between List and Thumbnail view, and adjust thumbnail size.")
            .popover(isPresented: $showViewOptionsPopover, arrowEdge: .bottom) {
                viewOptionsPopoverContent
            }
            
            // Hide / Show Folders Toggle (Moved before Autoplay)
            let isHidden = hideAllFolders || !hiddenFolderIDs.isEmpty
            let canToggle = hasSubfolders || !videoFiles.isEmpty
            Button(action: onToggleHideFolders) {
                HStack(spacing: StudioTheme.scale(4)) {
                    Image(systemName: isHidden ? "folder" : "folder.badge.minus")
                        .font(.system(size: StudioTheme.scaleFont(10.5), weight: .medium))
                    SlotText(
                        isHidden ? "Show" : "Hide",
                        mode: .word,
                        direction: .up,
                        font: .ui(size: 11, weight: .medium),
                        foregroundColor: canToggle ? (isHidden ? accentBlue : textMain) : textSubtle,
                        tracking: 0,
                        stagger: 0.018,
                        rollDistance: 12,
                        trigger: isHidden
                    )
                }
                .padding(.horizontal, StudioTheme.scale(5))
                .frame(height: StudioTheme.scale(26))
                .foregroundColor(canToggle ? (isHidden ? accentBlue : textMain) : textSubtle)
            }
            .buttonStyle(TransportIconButtonStyle())
            .fixedSize()
            .disabled(isScanning || !canToggle)
            .explain(isHidden ? "Show all folder headers in asset lists." : "Hide folder headers and display assets in a flat list.")
            
            // Autoplay Toggle Button
            Button(action: onToggleAutoplay) {
                HStack(spacing: StudioTheme.scale(4)) {
                    Image(systemName: isAutoplayEnabled ? "play.fill" : "play.slash.fill")
                        .font(.system(size: StudioTheme.scaleFont(10.5), weight: .medium))
                    SlotText(
                        "Auto",
                        mode: .word,
                        direction: .up,
                        font: .ui(size: 11, weight: .medium),
                        foregroundColor: isAutoplayEnabled ? accentBlue : textMuted,
                        tracking: 0,
                        stagger: 0.018,
                        rollDistance: 12,
                        trigger: isAutoplayEnabled
                    )
                }
                .padding(.horizontal, StudioTheme.scale(5))
                .frame(height: StudioTheme.scale(26))
                .foregroundColor(isAutoplayEnabled ? accentBlue : textMuted)
            }
            .buttonStyle(TransportIconButtonStyle())
            .fixedSize()
            .explain(isAutoplayEnabled ? "Autoplay: ON (Videos play from start when clicked or navigating with ↑/↓) [A]" : "Autoplay: OFF (Videos load paused at frame 0) [A]")
            
            // Waveform Toggle: audio is only decoded for the timeline when this is on
            Button(action: onToggleWaveforms) {
                HStack(spacing: StudioTheme.scale(4)) {
                    Image(systemName: "waveform")
                        .font(.system(size: StudioTheme.scaleFont(10.5), weight: .medium))
                    SlotText(
                        "Wave",
                        mode: .word,
                        direction: .up,
                        font: .ui(size: 11, weight: .medium),
                        foregroundColor: drawsWaveforms ? accentBlue : textMuted,
                        tracking: 0,
                        stagger: 0.018,
                        rollDistance: 12,
                        trigger: drawsWaveforms
                    )
                }
                .padding(.horizontal, StudioTheme.scale(5))
                .frame(height: StudioTheme.scale(26))
                .foregroundColor(drawsWaveforms ? accentBlue : textMuted)
            }
            .buttonStyle(TransportIconButtonStyle())
            .fixedSize()
            .explain(drawsWaveforms ? "Waveform: ON (audio waveform under the timeline; scroll over it to resize) [W]" : "Waveform: OFF (click to draw the audio waveform under the timeline) [W]")
        }
        .fixedSize()
    }
    
    private var deliveryAssetsSection: some View {
        AssetSourcePanel(folderURL: folderURL, files: videoFiles, isBusy: isScanning, isLightMode: isLightMode,
                         onSelect: onSelectAssets, onRefresh: onRefreshAssets)
    }
    
    private func folderRow(node: FileSystemTreeNode) -> some View {
        let isCollapsed = playerCollapsedFolderIDs.contains(node.id)
        
        return HStack(spacing: 6) {
            Image(systemName: isCollapsed ? "chevron.right" : "chevron.down")
                .font(.system(size: StudioTheme.scaleFont(9), weight: .bold))
                .foregroundColor(textMuted)
                .frame(width: 12)
            
            Image(systemName: "folder")
                .font(.system(size: StudioTheme.scaleFont(11), weight: .medium))
                .foregroundColor(textSubtle)
                .frame(width: 14, height: 14)
            
            Text(node.name)
                .font(.ui(size: 10, weight: .semibold))
                .foregroundColor(textMain)
                .lineLimit(1)
            
            Spacer()
            
            Text("\(node.videoCount)")
                .font(.ui(size: 8, weight: .semibold))
                .foregroundColor(textSubtle)
                .padding(.horizontal, 5)
                .padding(.vertical, 1)
                .background(RoundedRectangle(cornerRadius: 3).fill(bgSubtle))
        }
        .padding(.leading, CGFloat(node.depth * 14) + 6)
        .padding(.trailing, 8)
        .padding(.vertical, 5)
        .contentShape(Rectangle())
        .onTapGesture {
            onToggleFolderCollapse(node.id)
        }
        .explain(node.url.path)
        .help(node.name)
        .contextMenu {
            Button("Hide Folder") {
                onHideFolder(node.id)
            }
            Button("Clear Folder") {
                onClearFolder(node)
            }
            Divider()
            Button("Copy Path") {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(node.url.path, forType: .string)
            }
            Button("Reveal in Finder") {
                NSWorkspace.shared.activateFileViewerSelecting([node.url])
            }
        }
    }
    
    private func fileNotesCount(url: URL) -> Int {
        if let notesURL = activeNotesURL, isSameURL(url, notesURL) {
            return activeNotesCount
        }
        // Cache only: counts are prewarmed off the main thread by ContentView.loadFinderTagsForQueue().
        return QCNotesManager.cachedNotesCount(for: url) ?? 0
    }
    
    private func makeFileRow(url: URL, depth: Int = 0, isSlotA: Bool, isSlotB: Bool, notesCount: Int) -> some View {
        PlayerQueueFileRowView(
            url: url,
            depth: depth,
            isSlotA: isSlotA,
            isSlotB: isSlotB,
            hasSlotB: slotBURL != nil,
            notesCount: notesCount,
            currentTag: fileTagsMap[url],
            slotAResolution: slotAResolution,
            slotAFps: slotAFps,
            slotACodec: slotACodec,
            slotBResolution: slotBResolution,
            slotBFps: slotBFps,
            slotBCodec: slotBCodec,
            isLightMode: isLightMode,
            displayMode: queueDisplayMode,
            thumbnailSize: playerThumbnailSize,
            themeId: themeId,
            buttonZoom: buttonZoom,
            sequenceInfo: QueueSequenceInfo.lookup(url),
            onLoadVideo: onLoadVideo,
            onClearSlotB: onClearSlotB,
            onSwapSlots: onSwapSlots,
            onOpenProperties: onOpenProperties,
            onOpenNotes: onOpenNotes,
            onToggleTag: onToggleTag,
            onClearTag: onClearTag,
            onSetReadAsSequence: onSetReadAsSequence,
            onSetSequenceFPS: onSetSequenceFPS
        )
        .equatable()
    }
    
    // MARK: - Queue View Options Popover (Thumbnail View / List View / Size Slider)
    private var viewOptionsPopoverContent: some View {
        VStack(alignment: .leading, spacing: 2) {
            // Thumbnail View
            Button(action: {
                queueDisplayMode = "thumbnail"
            }) {
                HStack(spacing: 7) {
                    if queueDisplayMode == "thumbnail" {
                        Image(systemName: "checkmark")
                            .font(.system(size: StudioTheme.scaleFont(9.5), weight: .bold))
                            .foregroundColor(textMain)
                            .frame(width: 14, alignment: .center)
                    } else {
                        Spacer().frame(width: 14)
                    }
                    Image(systemName: "square.grid.2x2")
                        .font(.system(size: StudioTheme.scaleFont(11), weight: .medium))
                        .foregroundColor(textMain)
                        .frame(width: 16, alignment: .center)
                    Text("Thumbnail View")
                        .font(.system(size: StudioTheme.scaleFont(11.5), weight: .medium))
                        .foregroundColor(textMain)
                    Spacer()
                }
                .padding(.horizontal, 6)
                .padding(.vertical, 5)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            
            // List View
            Button(action: {
                queueDisplayMode = "inline"
            }) {
                HStack(spacing: 7) {
                    if queueDisplayMode == "inline" {
                        Image(systemName: "checkmark")
                            .font(.system(size: StudioTheme.scaleFont(9.5), weight: .bold))
                            .foregroundColor(textMain)
                            .frame(width: 14, alignment: .center)
                    } else {
                        Spacer().frame(width: 14)
                    }
                    Image(systemName: "list.bullet")
                        .font(.system(size: StudioTheme.scaleFont(11), weight: .medium))
                        .foregroundColor(textMain)
                        .frame(width: 16, alignment: .center)
                    Text("List View")
                        .font(.system(size: StudioTheme.scaleFont(11.5), weight: .medium))
                        .foregroundColor(textMain)
                    Spacer()
                }
                .padding(.horizontal, 6)
                .padding(.vertical, 5)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            
            Rectangle()
                .fill(borderLine.opacity(0.8))
                .frame(height: 1)
                .padding(.vertical, 4)
                .padding(.horizontal, 4)
            
            // Thumbnail Size Slider
            Slider(
                value: Binding(
                    get: { playerThumbnailSize },
                    set: { newValue in
                        playerThumbnailSize = newValue
                        if queueDisplayMode != "thumbnail" {
                            queueDisplayMode = "thumbnail"
                        }
                    }
                ),
                in: 36...110
            )
            .controlSize(.small)
            .padding(.horizontal, 8)
            .padding(.vertical, 3)
        }
        .padding(6)
        .frame(width: 185)
        .background(bgPanel)
    }
    
    private func revealFolderContaining(url: URL) {
        withAnimation(.easeInOut(duration: 0.2)) {
            FileSystemTreeBuilder.expandAncestors(of: url, in: playerTreeNodes, collapsedIDs: &playerCollapsedFolderIDs)
        }
    }
}
