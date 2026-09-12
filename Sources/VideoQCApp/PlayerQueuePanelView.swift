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
    @Binding public var playerCollapsedFolderIDs: Set<String>
    public var hiddenFolderIDs: Set<String>
    public var hideAllFolders: Bool
    public var fileTagsMap: [URL: FinderTagColor]
    public var isScanning: Bool
    public var isAutoplayEnabled: Bool
    
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
    
    @Binding public var queueScrollTarget: URL?
    public var hoverExplanation: Binding<String>?
    
    // Action Callbacks:
    public var onSelectAssets: (_ append: Bool) -> Void
    public var onRefreshAssets: () -> Void
    public var onToggleHideFolders: () -> Void
    public var onToggleAutoplay: () -> Void
    public var onToggleAllPlayerFolders: () -> Void
    public var onToggleFolderCollapse: (_ folderID: String) -> Void
    public var onHideFolder: (_ folderID: String) -> Void
    public var onClearFolder: (_ node: FileSystemTreeNode) -> Void
    public var onLoadVideo: (_ url: URL, _ target: SlotTarget) -> Void
    public var onSwapSlots: () -> Void
    public var onClearSlotB: () -> Void
    public var onOpenProperties: (_ url: URL) -> Void
    public var onToggleTag: (_ tag: FinderTagColor, _ url: URL) -> Void
    public var onClearTag: (_ url: URL) -> Void
    public var onDrop: (_ providers: [NSItemProvider]) -> Bool
    
    public nonisolated static func == (lhs: PlayerQueuePanelView, rhs: PlayerQueuePanelView) -> Bool {
        MainActor.assumeIsolated {
            lhs.buttonZoom == rhs.buttonZoom &&
            lhs.isLightMode == rhs.isLightMode &&
            lhs.themeId == rhs.themeId &&
            lhs.folderURL == rhs.folderURL &&
            lhs.videoFiles == rhs.videoFiles &&
            lhs.playerTreeNodes == rhs.playerTreeNodes &&
            lhs.playerFilterText == rhs.playerFilterText &&
            lhs.playerCollapsedFolderIDs == rhs.playerCollapsedFolderIDs &&
            lhs.hiddenFolderIDs == rhs.hiddenFolderIDs &&
            lhs.hideAllFolders == rhs.hideAllFolders &&
            lhs.fileTagsMap == rhs.fileTagsMap &&
            lhs.isScanning == rhs.isScanning &&
            lhs.isAutoplayEnabled == rhs.isAutoplayEnabled &&
            isSameURL(lhs.slotAURL, rhs.slotAURL) &&
            lhs.slotAResolution == rhs.slotAResolution &&
            lhs.slotAFps == rhs.slotAFps &&
            lhs.slotACodec == rhs.slotACodec &&
            isSameURL(lhs.slotBURL, rhs.slotBURL) &&
            lhs.slotBResolution == rhs.slotBResolution &&
            lhs.slotBFps == rhs.slotBFps &&
            lhs.slotBCodec == rhs.slotBCodec &&
            lhs.activeTarget == rhs.activeTarget &&
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
            filterText: playerFilterText
        )
    }
    
    private var filteredFiles: [URL] {
        let treeOrder = FileSystemTreeBuilder.orderedVideoURLs(from: playerTreeNodes)
        let baseFiles = treeOrder.isEmpty ? videoFiles : treeOrder
        if playerFilterText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return baseFiles
        }
        return baseFiles.filter { $0.lastPathComponent.localizedCaseInsensitiveContains(playerFilterText) }
    }
    
    public var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            // Asset Picker Section
            deliveryAssetsSection
            
            // Search Filter
            if !videoFiles.isEmpty {
                HStack(spacing: 6) {
                    Image(systemName: "magnifyingglass")
                        .font(.system(size: 10))
                        .foregroundColor(textMuted)
                    
                    ZStack(alignment: .leading) {
                        if playerFilterText.isEmpty {
                            Text("FILTER ASSETS...")
                                .font(.system(size: 11, weight: .bold, design: .monospaced))
                                .foregroundColor(textMuted)
                                .allowsHitTesting(false)
                        }
                        TextField("", text: $playerFilterText)
                            .font(.system(size: 11, weight: .medium, design: .monospaced))
                            .textFieldStyle(.plain)
                            .foregroundColor(textMain)
                            .onSubmit {
                                NSApp.keyWindow?.makeFirstResponder(nil)
                            }
                    }
                    
                    if !playerFilterText.isEmpty {
                        Button(action: { playerFilterText = "" }) {
                            Image(systemName: "xmark.circle.fill")
                                .font(.system(size: 10))
                                .foregroundColor(textMuted)
                        }
                        .buttonStyle(.plain)
                    }
                }
                .padding(.horizontal, 8)
                .padding(.vertical, 6)
                .studioBox(background: bgSubtle, border: borderLine)
            }
            
            // Asset List
            VStack(alignment: .leading, spacing: 6) {
                HStack(spacing: StudioTheme.scale(5)) {
                    Text("QUEUE (\(filteredFiles.count))")
                        .font(.system(size: StudioTheme.scaleFont(10), weight: .black, design: .monospaced))
                        .foregroundColor(textMuted)
                    
                    if hasSubfolders && !hideAllFolders {
                        Button(action: onToggleAllPlayerFolders) {
                            Image(systemName: playerCollapsedFolderIDs.isEmpty ? "chevron.down.circle" : "chevron.right.circle")
                                .font(.system(size: StudioTheme.scaleFont(10), weight: .bold))
                                .foregroundColor(textMuted)
                        }
                        .buttonStyle(.plain)
                        .explain(playerCollapsedFolderIDs.isEmpty ? "Collapse all folders in playback queue." : "Expand all folders in playback queue.", binding: hoverExplanation)
                    }
                    
                    Spacer()
                    
                    // View Mode Options Popover (Thumbnail View / List View / Thumbnail Size Slider)
                    Button(action: { showViewOptionsPopover.toggle() }) {
                        HStack(spacing: StudioTheme.scale(3)) {
                            Image(systemName: queueDisplayMode == "thumbnail" ? "square.grid.2x2" : "list.bullet")
                                .font(.system(size: StudioTheme.scaleFont(8), weight: .bold))
                            Image(systemName: "chevron.down")
                                .font(.system(size: StudioTheme.scaleFont(6), weight: .bold))
                        }
                        .padding(.horizontal, StudioTheme.scale(5))
                        .frame(height: StudioTheme.scale(18))
                        .foregroundColor(textMain)
                        .studioBox(
                            background: showViewOptionsPopover ? (isLightMode ? Color.white : bgCardHeader) : bgSubtle,
                            border: showViewOptionsPopover ? borderStrong : borderLine
                        )
                    }
                    .buttonStyle(.plain)
                    .explain("Queue display options: Switch between List and Thumbnail view, and adjust thumbnail size.", binding: hoverExplanation)
                    .popover(isPresented: $showViewOptionsPopover, arrowEdge: .bottom) {
                        viewOptionsPopoverContent
                    }
                    
                    // Hide / Show Folders Toggle (Moved before Autoplay)
                    let isHidden = hideAllFolders || !hiddenFolderIDs.isEmpty
                    let canToggle = hasSubfolders || !videoFiles.isEmpty
                    Button(action: onToggleHideFolders) {
                        HStack(spacing: StudioTheme.scale(3)) {
                            Image(systemName: isHidden ? "folder" : "folder.badge.minus")
                                .font(.system(size: StudioTheme.scaleFont(7.5), weight: .bold))
                            SlotText(
                                isHidden ? "SHOW" : "HIDE",
                                mode: .character,
                                direction: .up,
                                font: .system(size: StudioTheme.scaleFont(8), weight: .black, design: .monospaced),
                                foregroundColor: canToggle ? (isHidden ? accentBlue : textMain) : textSubtle,
                                tracking: 0.3,
                                stagger: 0.018,
                                rollDistance: 9,
                                trigger: isHidden
                            )
                        }
                        .padding(.horizontal, StudioTheme.scale(4))
                        .frame(height: StudioTheme.scale(18))
                        .foregroundColor(canToggle ? (isHidden ? accentBlue : textMain) : textSubtle)
                        .studioBox(
                            background: isHidden ? accentBlue.opacity(0.18) : bgSubtle,
                            border: isHidden ? accentBlue : borderLine
                        )
                    }
                    .buttonStyle(.plain)
                    .disabled(isScanning || !canToggle)
                    .explain(isHidden ? "Show all folder headers in asset lists." : "Hide folder headers and display assets in a flat list.", binding: hoverExplanation)
                    
                    // Autoplay Toggle Button
                    Button(action: onToggleAutoplay) {
                        HStack(spacing: StudioTheme.scale(3)) {
                            Image(systemName: isAutoplayEnabled ? "play.fill" : "play.slash.fill")
                                .font(.system(size: StudioTheme.scaleFont(7), weight: .bold))
                            SlotText(
                                "AUTO",
                                mode: .character,
                                direction: .up,
                                font: .system(size: StudioTheme.scaleFont(8), weight: .black, design: .monospaced),
                                foregroundColor: isAutoplayEnabled ? accentPositive : textMuted,
                                tracking: 0.3,
                                stagger: 0.018,
                                rollDistance: 9,
                                trigger: isAutoplayEnabled
                            )
                        }
                        .padding(.horizontal, StudioTheme.scale(4))
                        .frame(height: StudioTheme.scale(18))
                        .foregroundColor(isAutoplayEnabled ? accentPositive : textMuted)
                        .studioBox(background: isAutoplayEnabled ? accentPositive.opacity(0.18) : bgSubtle,
                                   border: isAutoplayEnabled ? accentPositive : borderLine)
                    }
                    .buttonStyle(.plain)
                    .explain(isAutoplayEnabled ? "Autoplay: ON (Videos play from start when clicked or navigating with ↑/↓) [A]" : "Autoplay: OFF (Videos load paused at frame 0) [A]", binding: hoverExplanation)
                }
                
                if videoFiles.isEmpty {
                    VStack(spacing: 8) {
                        Spacer()
                        Image(systemName: "video")
                            .font(.system(size: 24))
                            .foregroundColor(textMuted)
                        Text("NO VIDEO FILES LOADED")
                            .font(.system(size: 10, weight: .bold, design: .monospaced))
                            .foregroundColor(textMuted)
                        Text("Select or drop a folder to populate playback queue.")
                            .font(.system(size: 9, design: .monospaced))
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
                            VStack(spacing: queueDisplayMode == "inline" ? 2 : 4) {
                                if hasSubfolders {
                                    ForEach(flattenedNodes) { node in
                                        if node.isDirectory {
                                            folderRow(node: node)
                                                .id("\(node.id)_\(themeId)")
                                        } else {
                                            let isSelA = isSameURL(slotAURL, node.url)
                                            let isSelB = isSameURL(slotBURL, node.url)
                                            makeFileRow(url: node.url, depth: node.depth, isSlotA: isSelA, isSlotB: isSelB)
                                                .id("\(node.url.path)_\(isSelA ? "A" : "_")_\(isSelB ? "B" : "_")_\(queueDisplayMode)_\(Int(playerThumbnailSize))_\(themeId)")
                                        }
                                    }
                                } else {
                                    ForEach(filteredFiles, id: \.self) { url in
                                        let isSelA = isSameURL(slotAURL, url)
                                        let isSelB = isSameURL(slotBURL, url)
                                        makeFileRow(url: url, depth: 0, isSlotA: isSelA, isSlotB: isSelB)
                                            .id("\(url.path)_\(isSelA ? "A" : "_")_\(isSelB ? "B" : "_")_\(queueDisplayMode)_\(Int(playerThumbnailSize))_\(themeId)")
                                    }
                                }
                            }
                        }
                        .clipped()
                        .studioBox(background: bgCardSubtle, border: borderLine)
                        .onDrop(of: [UTType.fileURL.identifier], isTargeted: nil) { providers in
                            onDrop(providers)
                        }
                        .onChange(of: queueScrollTarget) { _, targetURL in
                            if let targetURL = targetURL {
                                withAnimation(.easeInOut(duration: 0.15)) {
                                    scrollProxy.scrollTo(targetURL, anchor: nil)
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
        }
        .padding(22)
        .frame(minWidth: 280, idealWidth: 380, maxWidth: 650)
        .background(bgPanel)
        .onDrop(of: [UTType.fileURL.identifier], isTargeted: nil) { providers in
            onDrop(providers)
        }
    }
    
    private var deliveryAssetsSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 6) {
                Text("01")
                    .font(.system(size: 9, weight: .bold, design: .monospaced))
                    .foregroundColor(textMain)
                Text("// LOAD ASSETS")
                    .font(.system(size: 9, weight: .bold, design: .monospaced))
                    .foregroundColor(textMuted)
                    .tracking(1.0)
            }
            
            VStack(alignment: .leading, spacing: StudioTheme.scale(8)) {
                // Action Toolbar: SELECT/CHANGE, ADD, HIDE/SHOW, plus trailing Asset Count
                HStack(spacing: StudioTheme.scale(5)) {
                    let isSelectEmpty = (folderURL == nil && videoFiles.isEmpty)
                    Button(action: { onSelectAssets(false) }) {
                        HStack(spacing: StudioTheme.scale(4)) {
                            Image(systemName: isSelectEmpty ? "folder.badge.plus" : "arrow.triangle.2.circlepath")
                                .font(.system(size: StudioTheme.scaleFont(9), weight: .bold))
                            Text(isSelectEmpty ? "SELECT" : "CHANGE")
                                .font(.system(size: StudioTheme.scaleFont(9), weight: .bold, design: .monospaced))
                                .lineLimit(1)
                        }
                        .padding(.horizontal, StudioTheme.scale(9))
                        .frame(height: StudioTheme.scale(24))
                        .foregroundColor(isSelectEmpty ? accentBlue : textMain)
                        .studioBox(
                            background: isSelectEmpty ? accentBlue.opacity(0.12) : bgSubtle,
                            border: isSelectEmpty ? accentBlue.opacity(0.4) : borderLine
                        )
                    }
                    .buttonStyle(.plain)
                    .disabled(isScanning)
                    .explain(isSelectEmpty ? "Opens file picker to select video files or a folder to inspect." : "Replaces currently loaded assets with a new folder or file selection.", binding: hoverExplanation)
                    
                    Button(action: { onSelectAssets(true) }) {
                        HStack(spacing: StudioTheme.scale(4)) {
                            Image(systemName: "plus")
                                .font(.system(size: StudioTheme.scaleFont(9), weight: .bold))
                            Text("ADD")
                                .font(.system(size: StudioTheme.scaleFont(9), weight: .bold, design: .monospaced))
                                .lineLimit(1)
                        }
                        .padding(.horizontal, StudioTheme.scale(8))
                        .frame(height: StudioTheme.scale(24))
                        .foregroundColor(textMain)
                        .studioBox(background: bgSubtle, border: borderLine)
                    }
                    .buttonStyle(.plain)
                    .disabled(isScanning)
                    .explain("Opens file picker to add more video files or folders to current list without losing existing assets.", binding: hoverExplanation)
                    
                    let canRefresh = (folderURL != nil || !videoFiles.isEmpty)
                    Button(action: onRefreshAssets) {
                        HStack(spacing: StudioTheme.scale(4)) {
                            Image(systemName: "arrow.clockwise")
                                .font(.system(size: StudioTheme.scaleFont(9), weight: .bold))
                            Text("REFRESH")
                                .font(.system(size: StudioTheme.scaleFont(9), weight: .bold, design: .monospaced))
                                .lineLimit(1)
                        }
                        .padding(.horizontal, StudioTheme.scale(8))
                        .frame(height: StudioTheme.scale(24))
                        .foregroundColor(canRefresh ? textMain : textSubtle)
                        .studioBox(background: bgSubtle, border: borderLine)
                    }
                    .buttonStyle(.plain)
                    .disabled(isScanning || !canRefresh)
                    .explain("Rescans loaded folders and files to detect added, removed, or modified videos.", binding: hoverExplanation)
                    
                    Spacer(minLength: 4)
                    
                    if !videoFiles.isEmpty {
                        HStack(spacing: StudioTheme.scale(4)) {
                            Circle()
                                .fill(accentPositive)
                                .frame(width: StudioTheme.scale(5), height: StudioTheme.scale(5))
                            Text("\(videoFiles.count) \(videoFiles.count == 1 ? "FILE" : "FILES")")
                                .font(.system(size: StudioTheme.scaleFont(9), weight: .bold, design: .monospaced))
                                .foregroundColor(textMuted)
                        }
                        .padding(.horizontal, StudioTheme.scale(7))
                        .frame(height: StudioTheme.scale(24))
                        .studioBox(background: bgSubtle.opacity(0.4), border: borderLine.opacity(0.6))
                    }
                }
                
                if let folder = folderURL {
                    VStack(alignment: .leading, spacing: 3) {
                        Text(folder.lastPathComponent.uppercased())
                            .font(.system(size: 12, weight: .black, design: .monospaced))
                            .foregroundColor(textMain)
                            .lineLimit(1)
                        Text("\(videoFiles.count) ASSET(S) FOUND IN DIRECTORY")
                            .font(.system(size: 9, weight: .bold, design: .monospaced))
                            .foregroundColor(textMuted)
                    }
                    .padding(10)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .studioBox(background: bgCardSubtle, border: borderLine)
                    .contentShape(Rectangle())
                    .explain(folder.path, binding: hoverExplanation)
                    .contextMenu {
                        Button("Copy Path") {
                            NSPasteboard.general.clearContents()
                            NSPasteboard.general.setString(folder.path, forType: .string)
                        }
                        Button("Reveal in Finder") {
                            NSWorkspace.shared.activateFileViewerSelecting([folder])
                        }
                    }
                } else if !videoFiles.isEmpty {
                    VStack(alignment: .leading, spacing: 3) {
                        Text("LOOSE ASSET SELECTION")
                            .font(.system(size: 11, weight: .bold, design: .monospaced))
                            .foregroundColor(textMain)
                            .lineLimit(1)
                        Text("\(videoFiles.count) FILE(S) LOADED")
                            .font(.system(size: 9, weight: .bold, design: .monospaced))
                            .foregroundColor(textMuted)
                    }
                    .padding(10)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .studioBox(background: bgCardSubtle, border: borderLine)
                    .contentShape(Rectangle())
                }
            }
        }
    }
    
    private func folderRow(node: FileSystemTreeNode) -> some View {
        let isCollapsed = playerCollapsedFolderIDs.contains(node.id)
        
        return HStack(spacing: 6) {
            Image(systemName: isCollapsed ? "chevron.right" : "chevron.down")
                .font(.system(size: 9, weight: .bold))
                .foregroundColor(textMuted)
                .frame(width: 12)
            
            Image(systemName: "folder")
                .font(.system(size: 11, weight: .medium))
                .foregroundColor(textSubtle)
                .frame(width: 14, height: 14)
            
            Text(node.name.uppercased())
                .font(.system(size: 10, weight: .bold, design: .monospaced))
                .foregroundColor(textMain)
                .lineLimit(1)
            
            Spacer()
            
            Text("\(node.videoCount)")
                .font(.system(size: 8, weight: .black, design: .monospaced))
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
        .explain(node.url.path, binding: hoverExplanation)
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
    
    private func makeFileRow(url: URL, depth: Int = 0, isSlotA: Bool, isSlotB: Bool) -> some View {
        PlayerQueueFileRowView(
            url: url,
            depth: depth,
            isSlotA: isSlotA,
            isSlotB: isSlotB,
            hasSlotB: slotBURL != nil,
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
            hoverExplanation: hoverExplanation,
            onLoadVideo: onLoadVideo,
            onClearSlotB: onClearSlotB,
            onSwapSlots: onSwapSlots,
            onOpenProperties: onOpenProperties,
            onToggleTag: onToggleTag,
            onClearTag: onClearTag
        )
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
                            .font(.system(size: 9.5, weight: .bold))
                            .foregroundColor(textMain)
                            .frame(width: 14, alignment: .center)
                    } else {
                        Spacer().frame(width: 14)
                    }
                    Image(systemName: "square.grid.2x2")
                        .font(.system(size: 11, weight: .medium))
                        .foregroundColor(textMain)
                        .frame(width: 16, alignment: .center)
                    Text("Thumbnail View")
                        .font(.system(size: 11.5, weight: .medium))
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
                            .font(.system(size: 9.5, weight: .bold))
                            .foregroundColor(textMain)
                            .frame(width: 14, alignment: .center)
                    } else {
                        Spacer().frame(width: 14)
                    }
                    Image(systemName: "list.bullet")
                        .font(.system(size: 11, weight: .medium))
                        .foregroundColor(textMain)
                        .frame(width: 16, alignment: .center)
                    Text("List View")
                        .font(.system(size: 11.5, weight: .medium))
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
