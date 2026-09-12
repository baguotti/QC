import SwiftUI
import AppKit
import AVFoundation
import UniformTypeIdentifiers
import VideoQCLib


// MARK: - Exposure Scrubber Control (After Effects Style)

struct ExposureScrubberView: View {
    @ObservedObject var engine: PlayerEngine
    var isLightMode: Bool = false
    var hoverExplanation: Binding<String>? = nil
    
    @State private var isDragging: Bool = false
    @State private var dragStartEV: Double = 0.0
    @State private var isHoveringNumber: Bool = false
    
    private var formattedEV: String {
        let val = abs(engine.exposureEV) < 0.05 ? 0.0 : engine.exposureEV
        return String(format: "%+.1f", val)
    }
    
    private var isNonZero: Bool {
        abs(engine.exposureEV) >= 0.05
    }
    
    // AE blue accent for the scrubbable number
    private var scrubberBlue: Color {
        StudioTheme.accentBlue(isLightMode)
    }
    
    private var iconColor: Color {
        if isNonZero {
            return scrubberBlue
        } else {
            return isLightMode ? Color(white: 0.12) : Color.white
        }
    }
    
    var body: some View {
        HStack(spacing: 2) {
            // Aperture Reset Button
            Button(action: {
                withAnimation(.easeOut(duration: 0.12)) {
                    engine.resetExposure()
                }
            }) {
                Image(systemName: "camera.aperture")
                    .font(.system(size: StudioTheme.scaleFont(12), weight: .semibold))
                    .foregroundColor(iconColor)
                    .frame(width: StudioTheme.scale(22), height: StudioTheme.scale(26))
                    .contentShape(Rectangle())
            }
            .buttonStyle(TransportIconButtonStyle())
            .explain("Reset Exposure to +0.0 EV", binding: hoverExplanation)
            
            // Drag-Scrub Number
            Text(formattedEV)
                .font(.system(size: StudioTheme.scaleFont(11), weight: .bold, design: .monospaced))
                .foregroundColor(scrubberBlue)
                .frame(height: StudioTheme.scale(26))
                .contentShape(Rectangle())
                .gesture(
                    DragGesture(minimumDistance: 1)
                        .onChanged { value in
                            if !isDragging {
                                isDragging = true
                                dragStartEV = engine.exposureEV
                            }
                            // 35 pt horizontal drag = 1.0 EV
                            let delta = Double(value.translation.width) / 35.0
                            let target = min(5.0, max(-5.0, dragStartEV + delta))
                            let stepped = (target * 10.0).rounded() / 10.0
                            if abs(engine.exposureEV - stepped) > 0.001 {
                                engine.exposureEV = stepped
                            }
                        }
                        .onEnded { _ in
                            isDragging = false
                        }
                )
                .onTapGesture(count: 2) {
                    withAnimation(.easeOut(duration: 0.12)) {
                        engine.resetExposure()
                    }
                }
                .onHover { hovering in
                    if hovering != isHoveringNumber {
                        isHoveringNumber = hovering
                        if hovering {
                            NSCursor.resizeLeftRight.push()
                        } else {
                            NSCursor.pop()
                        }
                    }
                }
                .onDisappear {
                    if isHoveringNumber {
                        isHoveringNumber = false
                        NSCursor.pop()
                    }
                }
                .explain("Change Exposure (EV): Drag left/right to adjust, click aperture to reset (Current: \(formattedEV))", binding: hoverExplanation)
        }
    }
}

// MARK: - Equatable Isolated Video Queue File Row

public struct PlayerQueueFileRowView: View, Equatable {
    public let url: URL
    public let depth: Int
    public let isSlotA: Bool
    public let isSlotB: Bool
    public let hasSlotB: Bool
    public let currentTag: FinderTagColor?
    public let slotAResolution: String
    public let slotAFps: Double
    public let slotACodec: String
    public let slotBResolution: String
    public let slotBFps: Double
    public let slotBCodec: String
    public let isLightMode: Bool
    public let displayMode: String
    public let thumbnailSize: Double
    public let themeId: String
    public var buttonZoom: UIButtonZoomLevel = ThemeManager.shared.buttonZoom
    public var hoverExplanation: Binding<String>?
    
    // Callbacks
    public let onLoadVideo: (_ url: URL, _ target: SlotTarget) -> Void
    public let onClearSlotB: () -> Void
    public let onSwapSlots: () -> Void
    public let onOpenProperties: (_ url: URL) -> Void
    public let onToggleTag: (_ tag: FinderTagColor, _ url: URL) -> Void
    public let onClearTag: (_ url: URL) -> Void
    
    public nonisolated static func == (lhs: PlayerQueueFileRowView, rhs: PlayerQueueFileRowView) -> Bool {
        MainActor.assumeIsolated {
            lhs.buttonZoom == rhs.buttonZoom &&
            lhs.url == rhs.url &&
            lhs.depth == rhs.depth &&
            lhs.isSlotA == rhs.isSlotA &&
            lhs.isSlotB == rhs.isSlotB &&
            lhs.hasSlotB == rhs.hasSlotB &&
            lhs.currentTag == rhs.currentTag &&
            lhs.slotAResolution == rhs.slotAResolution &&
            lhs.slotAFps == rhs.slotAFps &&
            lhs.slotACodec == rhs.slotACodec &&
            lhs.slotBResolution == rhs.slotBResolution &&
            lhs.slotBFps == rhs.slotBFps &&
            lhs.slotBCodec == rhs.slotBCodec &&
            lhs.isLightMode == rhs.isLightMode &&
            lhs.displayMode == rhs.displayMode &&
            lhs.thumbnailSize == rhs.thumbnailSize &&
            lhs.themeId == rhs.themeId
        }
    }
    
    @ObservedObject private var themeManager = ThemeManager.shared
    
    private var bgSubtle: Color { StudioTheme.bgSubtle(isLightMode) }
    private var borderLine: Color { StudioTheme.borderLine(isLightMode) }
    private var textMain: Color { StudioTheme.textMain(isLightMode) }
    private var textMuted: Color { StudioTheme.textMuted(isLightMode) }
    private var textSubtle: Color { StudioTheme.textSubtle(isLightMode) }
    private var accentPositive: Color { StudioTheme.positive }
    private var accentSlotB: Color { StudioTheme.slotBAccent }
    
    public var body: some View {
        let isSelected = isSlotA || isSlotB
        let rowBg: Color = {
            if isSlotA {
                return accentPositive.opacity(0.18)
            } else if isSlotB {
                return accentSlotB.opacity(0.18)
            } else {
                return Color.clear
            }
        }()
        let rowBorder: Color = {
            if isSlotA {
                return accentPositive.opacity(0.80)
            } else if isSlotB {
                return accentSlotB.opacity(0.80)
            } else {
                return Color.clear
            }
        }()
        
        let thumbHeight = round(CGFloat(thumbnailSize) * 9.0 / 16.0)
        let rowHeight: CGFloat = (displayMode == "inline" ? StudioTheme.scale(28) : (displayMode == "large" ? StudioTheme.scale(64) : max(StudioTheme.scale(32), thumbHeight + StudioTheme.scale(14))))
        
        HStack(spacing: 6) {
            Button(action: {
                if NSEvent.modifierFlags.contains(.option) {
                    onLoadVideo(url, .slotB)
                } else {
                    onLoadVideo(url, .slotA)
                }
            }) {
                switch displayMode {
                case "large":
                    largeThumbnailRowContent(isSelected: isSelected)
                case "thumbnail":
                    thumbnailRowContent(isSelected: isSelected)
                default:
                    inlineRowContent(isSelected: isSelected)
                }
            }
            .buttonStyle(.plain)
            
            queueActionButtons
        }
        .frame(maxWidth: .infinity)
        .frame(height: rowHeight)
        .studioBox(background: rowBg, border: rowBorder)
        .contentShape(Rectangle())
        .explain(url.path, binding: hoverExplanation)
        .help(url.lastPathComponent)
        .contextMenu {
            Button(action: {
                onOpenProperties(url)
            }) {
                Label("Media Info", systemImage: "info.circle")
            }
            .keyboardShortcut("i", modifiers: .control)
            Divider()
            Button("Copy Path") {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(url.path, forType: .string)
            }
            Button("Reveal in Finder") {
                NSWorkspace.shared.activateFileViewerSelecting([url])
            }
            Divider()
            Button("Set as Slot A (Master)") {
                onLoadVideo(url, .slotA)
            }
            Button("Set as Slot B (Compare)") {
                onLoadVideo(url, .slotB)
            }
            if hasSlotB {
                Divider()
                Button("Swap Slot A ⇄ B") {
                    onSwapSlots()
                }
                Button("Clear Slot B (Single Mode)") {
                    onClearSlotB()
                }
            }
            Divider()
            Menu("Tags") {
                ForEach(FinderTagColor.allCases) { tag in
                    Button(action: {
                        onToggleTag(tag, url)
                    }) {
                        HStack {
                            Text(tag.rawValue)
                            if currentTag == tag {
                                Image(systemName: "checkmark")
                            }
                        }
                    }
                }
                Divider()
                Button(action: {
                    onClearTag(url)
                }) {
                    Text("Remove Tag")
                }
            }
        }
    }
    
    @ViewBuilder
    private func inlineRowContent(isSelected: Bool) -> some View {
        HStack(spacing: 6) {
            Rectangle()
                .fill(isSlotA ? accentPositive : (isSlotB ? accentSlotB : Color.clear))
                .frame(width: 3)
            
            if depth > 0 {
                Spacer().frame(width: CGFloat(depth * 12))
            }
            
            if let tag = currentTag {
                Circle()
                    .fill(tag.color)
                    .frame(width: 6, height: 6)
            }
            
            Text(url.lastPathComponent)
                .font(.system(size: 10.5, weight: isSelected ? .bold : .medium, design: .monospaced))
                .foregroundColor(isSelected ? textMain : textSubtle)
                .lineLimit(1)
            
            if isSlotA && !slotAResolution.isEmpty {
                Text("• \(slotAResolution) \(slotACodec)")
                    .font(.system(size: 8, weight: .bold, design: .monospaced))
                    .foregroundColor(accentPositive)
                    .lineLimit(1)
            } else if isSlotB && !slotBResolution.isEmpty {
                Text("• \(slotBResolution) \(slotBCodec)")
                    .font(.system(size: 8, weight: .bold, design: .monospaced))
                    .foregroundColor(accentSlotB)
                    .lineLimit(1)
            }
            
            Spacer(minLength: 4)
        }
        .padding(.leading, 6)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .contentShape(Rectangle())
    }
    
    @ViewBuilder
    private func thumbnailRowContent(isSelected: Bool) -> some View {
        let thumbWidth = CGFloat(thumbnailSize)
        let thumbHeight = round(CGFloat(thumbnailSize) * 9.0 / 16.0)
        let isLarge = thumbnailSize >= 64
        HStack(spacing: 8) {
            Rectangle()
                .fill(isSlotA ? accentPositive : (isSlotB ? accentSlotB : Color.clear))
                .frame(width: 3)
            
            if depth > 0 {
                Spacer().frame(width: CGFloat(depth * 12))
            }
            
            AssetThumbnailView(
                fileURL: url,
                width: thumbWidth,
                height: thumbHeight,
                cornerRadius: isLarge ? 3.5 : 2.5
            )
            
            VStack(alignment: .leading, spacing: isLarge ? 3 : 2) {
                HStack(spacing: 5) {
                    if let tag = currentTag {
                        Circle()
                            .fill(tag.color)
                            .frame(width: 6, height: 6)
                    }
                    Text(url.lastPathComponent)
                        .font(.system(size: isLarge ? 11 : 10.5, weight: isSelected ? .bold : .medium, design: .monospaced))
                        .foregroundColor(isSelected ? textMain : textSubtle)
                        .lineLimit(1)
                }
                
                if isSlotA && !slotAResolution.isEmpty {
                    Text("\(slotAResolution) • \(String(format: "%.1f", slotAFps))fps • \(slotACodec)")
                        .font(.system(size: isLarge ? 8.5 : 8, weight: .bold, design: .monospaced))
                        .foregroundColor(accentPositive)
                        .lineLimit(1)
                } else if isSlotB && !slotBResolution.isEmpty {
                    Text("\(slotBResolution) • \(String(format: "%.1f", slotBFps))fps • \(slotBCodec)")
                        .font(.system(size: isLarge ? 8.5 : 8, weight: .bold, design: .monospaced))
                        .foregroundColor(accentSlotB)
                        .lineLimit(1)
                } else {
                    Text(url.pathExtension.uppercased())
                        .font(.system(size: 8, weight: .bold, design: .monospaced))
                        .foregroundColor(textMuted.opacity(0.8))
                        .lineLimit(1)
                }
            }
            
            Spacer(minLength: 4)
        }
        .padding(.leading, 6)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .contentShape(Rectangle())
    }
    
    @ViewBuilder
    private func largeThumbnailRowContent(isSelected: Bool) -> some View {
        HStack(spacing: 8) {
            Rectangle()
                .fill(isSlotA ? accentPositive : (isSlotB ? accentSlotB : Color.clear))
                .frame(width: 3)
            
            if depth > 0 {
                Spacer().frame(width: CGFloat(depth * 12))
            }
            
            AssetThumbnailView(
                fileURL: url,
                width: 80,
                height: 46,
                cornerRadius: 3.5
            )
            
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 5) {
                    if let tag = currentTag {
                        Circle()
                            .fill(tag.color)
                            .frame(width: 6, height: 6)
                    }
                    Text(url.lastPathComponent)
                        .font(.system(size: 11, weight: isSelected ? .bold : .medium, design: .monospaced))
                        .foregroundColor(isSelected ? textMain : textSubtle)
                        .lineLimit(1)
                }
                
                if isSlotA && !slotAResolution.isEmpty {
                    Text("\(slotAResolution) • \(String(format: "%.1f", slotAFps))fps • \(slotACodec)")
                        .font(.system(size: 8.5, weight: .bold, design: .monospaced))
                        .foregroundColor(accentPositive)
                        .lineLimit(1)
                } else if isSlotB && !slotBResolution.isEmpty {
                    Text("\(slotBResolution) • \(String(format: "%.1f", slotBFps))fps • \(slotBCodec)")
                        .font(.system(size: 8.5, weight: .bold, design: .monospaced))
                        .foregroundColor(accentSlotB)
                        .lineLimit(1)
                } else {
                    Text(url.pathExtension.uppercased())
                        .font(.system(size: 8, weight: .bold, design: .monospaced))
                        .foregroundColor(textMuted.opacity(0.8))
                        .lineLimit(1)
                }
            }
            
            Spacer(minLength: 4)
        }
        .padding(.leading, 6)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .contentShape(Rectangle())
    }
    
    @ViewBuilder
    private var queueActionButtons: some View {
        HStack(spacing: StudioTheme.scale(4)) {
            if isSlotA {
                Text("A: MASTER")
                    .font(.system(size: StudioTheme.scaleFont(8), weight: .black, design: .monospaced))
                    .padding(.horizontal, StudioTheme.scale(5))
                    .padding(.vertical, displayMode == "inline" ? StudioTheme.scale(2) : StudioTheme.scale(3))
                    .foregroundColor(accentPositive)
                    .studioBox(background: accentPositive.opacity(0.18), border: accentPositive.opacity(0.8))
            } else {
                Button(action: { onLoadVideo(url, .slotA) }) {
                    Text("+A")
                        .font(.system(size: StudioTheme.scaleFont(8), weight: .bold, design: .monospaced))
                        .padding(.horizontal, StudioTheme.scale(4))
                        .padding(.vertical, displayMode == "inline" ? StudioTheme.scale(1) : StudioTheme.scale(2))
                        .foregroundColor(textMuted)
                        .studioBox(background: bgSubtle, border: borderLine)
                }
                .buttonStyle(.plain)
                .explain("Load as Slot A (Master)", binding: hoverExplanation)
            }
            
            if isSlotB {
                HStack(spacing: StudioTheme.scale(2)) {
                    Text("B: COMPARE")
                        .font(.system(size: StudioTheme.scaleFont(8), weight: .black, design: .monospaced))
                        .padding(.horizontal, StudioTheme.scale(5))
                        .padding(.vertical, displayMode == "inline" ? StudioTheme.scale(2) : StudioTheme.scale(3))
                        .foregroundColor(accentSlotB)
                        .studioBox(background: accentSlotB.opacity(0.18), border: accentSlotB.opacity(0.8))
                    
                    Button(action: { onClearSlotB() }) {
                        Image(systemName: "xmark")
                            .font(.system(size: StudioTheme.scaleFont(7), weight: .bold))
                            .frame(width: StudioTheme.scale(14), height: StudioTheme.scale(14))
                            .foregroundColor(textMuted)
                    }
                    .buttonStyle(.plain)
                    .explain("Clear Slot B", binding: hoverExplanation)
                }
            } else {
                Button(action: { onLoadVideo(url, .slotB) }) {
                    Text("+B")
                        .font(.system(size: StudioTheme.scaleFont(8), weight: .bold, design: .monospaced))
                        .padding(.horizontal, StudioTheme.scale(4))
                        .padding(.vertical, displayMode == "inline" ? StudioTheme.scale(1) : StudioTheme.scale(2))
                        .foregroundColor(textMuted)
                        .studioBox(background: bgSubtle, border: borderLine)
                }
                .buttonStyle(.plain)
                .explain("Load as Slot B (Compare / ⌥+Click)", binding: hoverExplanation)
            }
        }
        .padding(.trailing, StudioTheme.scale(6))
    }
}

// MARK: - Equatable Isolated Video Queue Panel

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
        guard !playerCollapsedFolderIDs.isEmpty else { return }
        let targetPath = url.standardizedFileURL.path
        
        var idsToExpand: Set<String> = []
        func checkNode(_ node: FileSystemTreeNode) {
            guard node.isDirectory else { return }
            let dirPath = node.url.standardizedFileURL.path
            let isAncestor = targetPath.hasPrefix(dirPath + "/") || node.videoURLs.contains(where: { $0.standardizedFileURL.path == targetPath })
            if isAncestor {
                idsToExpand.insert(node.id)
                for child in node.children {
                    checkNode(child)
                }
            }
        }
        
        for root in playerTreeNodes {
            checkNode(root)
        }
        
        let intersection = playerCollapsedFolderIDs.intersection(idsToExpand)
        if !intersection.isEmpty {
            withAnimation(.easeInOut(duration: 0.2)) {
                playerCollapsedFolderIDs.subtract(intersection)
            }
        }
    }
}

extension ContentView {
    
    // MARK: ==================== TAB 1: PLAYER ====================
    
    @ViewBuilder
    var playerTabView: some View {
        HStack(spacing: 0) {
            HSplitView {
                playerQueuePanel
                playerProgramMonitorPanel
            }
            if showNotesDrawer {
                playerNotesDrawerPanel
            }
        }
        .onDrop(of: [UTType.fileURL.identifier], isTargeted: nil) { providers in
            handleDrop(providers: providers, forTab: .player)
        }
        .onAppear {
            // Automatically select first file if none loaded
            if playerEngine.activeURL == nil, let first = videoFiles.first {
                playerEngine.loadVideo(url: first)
            }
        }
    }
    
    // MARK: - Left Panel: Video Queue & Explorer
    private var playerQueuePanel: some View {
        PlayerQueuePanelView(
            isLightMode: isLightMode,
            themeId: themeManager.currentTheme.id,
            buttonZoom: themeManager.buttonZoom,
            folderURL: folderURL,
            videoFiles: videoFiles,
            playerTreeNodes: playerTreeNodes,
            playerFilterText: $playerFilterText,
            playerCollapsedFolderIDs: $playerCollapsedFolderIDs,
            hiddenFolderIDs: hiddenFolderIDs,
            hideAllFolders: hideAllFolders,
            fileTagsMap: fileTagsMap,
            isScanning: isScanning,
            isAutoplayEnabled: playerEngine.isAutoplayEnabled,
            slotAURL: playerEngine.activeURL ?? playerEngine.slotA.url,
            slotAResolution: playerEngine.slotA.resolution,
            slotAFps: playerEngine.slotA.fps,
            slotACodec: playerEngine.slotA.codec,
            slotBURL: playerEngine.slotBURL ?? playerEngine.slotB.url,
            slotBResolution: playerEngine.slotB.resolution,
            slotBFps: playerEngine.slotB.fps,
            slotBCodec: playerEngine.slotB.codec,
            activeTarget: playerEngine.activeTarget,
            queueScrollTarget: $queueScrollTarget,
            hoverExplanation: $hoverExplanation,
            onSelectAssets: { append in
                selectAssets(forTab: .player, append: append)
            },
            onRefreshAssets: {
                refreshPlayerAssets()
            },
            onToggleHideFolders: {
                toggleHideFolders()
            },
            onToggleAutoplay: {
                playerEngine.isAutoplayEnabled.toggle()
            },
            onToggleAllPlayerFolders: {
                toggleAllPlayerFolders()
            },
            onToggleFolderCollapse: { folderID in
                if playerCollapsedFolderIDs.contains(folderID) {
                    playerCollapsedFolderIDs.remove(folderID)
                } else {
                    playerCollapsedFolderIDs.insert(folderID)
                }
            },
            onHideFolder: { folderID in
                hideSpecificFolder(id: folderID)
            },
            onClearFolder: { node in
                clearFolder(node: node)
            },
            onLoadVideo: { url, target in
                playerEngine.loadVideo(url: url, into: target, autoplay: true)
            },
            onSwapSlots: {
                playerEngine.swapSlots()
            },
            onClearSlotB: {
                playerEngine.clearSlotB()
            },
            onOpenProperties: { url in
                openProperties(for: url)
            },
            onToggleTag: { tag, url in
                toggleFinderTag(tag, for: url)
            },
            onClearTag: { url in
                setFinderTag(nil, for: url)
            },
            onDrop: { providers in
                handleDrop(providers: providers, forTab: .player)
            }
        )
        .equatable()
    }
    
    // MARK: - Right Panel: Program Monitor & Timeline
    private var playerProgramMonitorPanel: some View {
        VStack(spacing: 0) {
                // Monitor Header Bar
                playerMonitorHeader
                    .padding(.horizontal, 16)
                    .padding(.vertical, 10)
                    .studioBox(background: bgCardHeader, border: borderLine)
                
                // Program Monitor Viewport Canvas
                GeometryReader { vpGeo in
                    ZStack(alignment: .topLeading) {
                        if playerEngine.slotA.url != nil || playerEngine.slotB.url != nil {
                            VideoViewportView(engine: playerEngine, isLightMode: isLightMode)
                                .frame(maxWidth: .infinity, maxHeight: .infinity)
                        } else {
                            VStack(spacing: 12) {
                                Image(systemName: "play.rectangle.fill")
                                    .font(.system(size: 40))
                                    .foregroundColor(textMuted)
                                Text("NO VIDEO SELECTED")
                                    .font(.system(size: 13, weight: .black, design: .monospaced))
                                    .foregroundColor(textMain)
                                Text("Click a file from the queue on the left to begin inspecting.")
                                    .font(.system(size: 10, design: .monospaced))
                                    .foregroundColor(textSubtle)
                            }
                            .frame(maxWidth: .infinity, maxHeight: .infinity)
                            .background(bgMain)
                        }
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .onDrop(of: [UTType.fileURL.identifier], isTargeted: nil) { providers, location in
                        handleViewportDrop(providers: providers, location: location, viewportWidth: vpGeo.size.width)
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .studioBox(background: isLightMode ? Color(white: 0.88) : Color(white: 0.08), border: borderLine)
                
                // Timeline Scrubber & Transport Controls (Rigidly locked height to prevent any layout jitter)
                VStack(spacing: 8) {
                    // Timecode, Play Info & Zoom (centered above timeline)
                    playerTimecodeBar
                        .frame(height: StudioTheme.scale(24))
                    
                    // Timeline Scrubber
                    TimelineScrubberView(engine: playerEngine, isLightMode: isLightMode)
                        .frame(height: 52)
                        .disabled(playerEngine.activeURL == nil)
                    
                    // Transport Strip
                    playerTransportBar
                        .frame(height: StudioTheme.scale(28))
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 12)
                .studioBox(background: bgCardHeader, border: borderLine)
            }
            .frame(minWidth: 500, maxWidth: .infinity, maxHeight: .infinity)
            .onDrop(of: [UTType.fileURL.identifier], isTargeted: nil) { providers in
                handleDrop(providers: providers, forTab: .player)
            }
    }
    
    // MARK: - Notes Drawer Panel (Right Side)
    private var playerNotesDrawerPanel: some View {
        NotesDrawerPanelView(
                isPresented: $showNotesDrawer,
                notes: playerEngine.activeNotes,
                mediaName: playerEngine.activeURL?.lastPathComponent ?? "Deliverable",
                currentTimecode: playerEngine.currentTimecode,
                currentFrame: playerEngine.currentFrame,
                isLightMode: isLightMode,
                onSeekToFrame: { frame in
                    playerEngine.seek(toFrame: frame)
                    playerEngine.pause()
                },
                onAddNote: {
                    openAddNoteModal()
                },
                onSaveNote: { note in
                    addNote(note)
                },
                onToggleResolved: { id in
                    toggleNoteResolved(id: id)
                },
                onDeleteNote: { id in
                    deleteNote(id: id)
                },
                onToast: { msg in
                    showToast(msg)
                }
            )
            .transition(.move(edge: .trailing).combined(with: .opacity))
    }
    
    // MARK: - Monitor Header
    
    private var playerMonitorHeader: some View {
        HStack(spacing: 12) {
            if playerEngine.slotB.url != nil {
                Color.clear
                    .frame(width: StudioTheme.scale(60), height: StudioTheme.scale(26))
                
                Spacer()
                
                // Centered Comparison Controls Toolbar
                PlayerComparisonBar(
                    engine: playerEngine,
                    isLightMode: isLightMode,
                    hoverExplanation: $hoverExplanation
                )
                
                Spacer()
            } else {
                // Single Slot Filename & Specs (100% v0.2.4 appearance)
                VStack(alignment: .leading, spacing: 2) {
                    Text(playerEngine.activeFileName.isEmpty ? "NO ACTIVE ASSET" : playerEngine.activeFileName.uppercased())
                        .font(.system(size: 12, weight: .black, design: .monospaced))
                        .foregroundColor(textMain)
                        .lineLimit(1)
                    
                    if !playerEngine.activeResolution.isEmpty {
                        Text("\(playerEngine.activeResolution) // \(String(format: "%.1f", playerEngine.activeFps)) FPS // \(playerEngine.activeCodec)")
                            .font(.system(size: 9, weight: .bold, design: .monospaced))
                            .foregroundColor(textMuted)
                    }
                }
                
                Spacer()
            }
            
            // Trailing: Fullscreen Controls (Visible in both Single & A/B mode)
            HStack(spacing: 4) {
                // Review Fullscreen Button
                Button(action: { enterFullscreen(mode: .review) }) {
                    Image(systemName: "rectangle.inset.filled.and.cursorarrow")
                        .font(.system(size: StudioTheme.scaleFont(12), weight: .bold))
                        .frame(width: StudioTheme.scale(28), height: StudioTheme.scale(26))
                        .foregroundColor(playerEngine.activeURL == nil ? textMuted : textMain)
                        .contentShape(Rectangle())
                }
                .buttonStyle(TransportIconButtonStyle())
                .disabled(playerEngine.activeURL == nil)
                .explain("Review Fullscreen with HUD & timeline controls (⇧F).", binding: $hoverExplanation)
                
                // Clean Video Fullscreen Button
                Button(action: { enterFullscreen(mode: .videoOnly) }) {
                    Image(systemName: "arrow.up.left.and.arrow.down.right")
                        .font(.system(size: StudioTheme.scaleFont(12), weight: .bold))
                        .frame(width: StudioTheme.scale(28), height: StudioTheme.scale(26))
                        .foregroundColor(playerEngine.activeURL == nil ? textMuted : textMain)
                        .contentShape(Rectangle())
                }
                .buttonStyle(TransportIconButtonStyle())
                .disabled(playerEngine.activeURL == nil)
                .explain("Clean Video Fullscreen with zero UI (F). Press ESC to exit.", binding: $hoverExplanation)
            }
            .frame(width: StudioTheme.scale(60), alignment: .trailing)
        }
    }
    
    // MARK: - Viewport Drop Zone Handler
    
    func handleViewportDrop(providers: [NSItemProvider], location: CGPoint, viewportWidth: CGFloat) -> Bool {
        let target: SlotTarget = (location.x < viewportWidth / 2.0) ? .slotA : .slotB
        return handleDrop(providers: providers, forTab: .player, targetSlot: target)
    }
    
    // MARK: - Review Navigation Strip (Notes, Line Glitches, Finder Tags)
    
    // MARK: - Review Navigation & Timecode Bar
    
    // 1. Compact Review Notes Controls: [+ NOTE] and < 💬 count >
    private var playerNotesGroup: some View {
        HStack(spacing: StudioTheme.scale(2)) {
            Button(action: { openAddNoteModal() }) {
                HStack(spacing: StudioTheme.scale(3)) {
                    Image(systemName: "plus")
                        .font(.system(size: StudioTheme.scaleFont(9), weight: .bold))
                    Text("NOTE")
                        .font(.system(size: StudioTheme.scaleFont(9), weight: .bold, design: .monospaced))
                }
                .frame(height: StudioTheme.scale(24))
                .padding(.horizontal, StudioTheme.scale(5))
                .foregroundColor(playerEngine.activeURL == nil ? textMuted : textMain)
                .contentShape(Rectangle())
            }
            .buttonStyle(TransportIconButtonStyle())
            .disabled(playerEngine.activeURL == nil)
            .explain("Add review note at playhead (N).", binding: $hoverExplanation)
            
            let notesCount = playerEngine.activeNotes.count
            let hasNotes = notesCount > 0
            
            HStack(spacing: 1) {
                Button(action: { playerEngine.jumpToPreviousNote() }) {
                    Image(systemName: "chevron.left.to.line")
                        .font(.system(size: StudioTheme.scaleFont(9), weight: .bold))
                        .frame(width: StudioTheme.scale(18), height: StudioTheme.scale(24))
                        .foregroundColor(hasNotes ? textMain : textMuted)
                        .contentShape(Rectangle())
                }
                .buttonStyle(TransportIconButtonStyle())
                .disabled(!hasNotes)
                .explain(hasNotes ? "Jump to previous note ([)." : "No notes logged", binding: $hoverExplanation)
                
                Button(action: {
                    withAnimation(.easeInOut(duration: 0.15)) {
                        showNotesDrawer.toggle()
                    }
                }) {
                    HStack(spacing: 3) {
                        Image(systemName: showNotesDrawer ? "text.bubble.fill" : "text.bubble")
                            .font(.system(size: StudioTheme.scaleFont(9), weight: .semibold))
                        SlotText(
                            hasNotes ? "\(notesCount)" : "NOTES",
                            mode: hasNotes ? .character : .word,
                            direction: .up,
                            font: .system(size: StudioTheme.scaleFont(9), weight: .bold, design: .monospaced),
                            foregroundColor: showNotesDrawer ? accentBlue : (hasNotes ? textMain : textMuted)
                        )
                    }
                    .frame(height: StudioTheme.scale(24))
                    .padding(.horizontal, 4)
                    .foregroundColor(showNotesDrawer ? accentBlue : (hasNotes ? textMain : textMuted))
                    .contentShape(Rectangle())
                }
                .buttonStyle(TransportIconButtonStyle())
                .disabled(playerEngine.activeURL == nil)
                .explain(hasNotes ? "Toggle Review Notes drawer (\(notesCount) notes)." : "Toggle Review Notes drawer.", binding: $hoverExplanation)
                
                Button(action: { playerEngine.jumpToNextNote() }) {
                    Image(systemName: "chevron.right.to.line")
                        .font(.system(size: StudioTheme.scaleFont(9), weight: .bold))
                        .frame(width: StudioTheme.scale(18), height: StudioTheme.scale(24))
                        .foregroundColor(hasNotes ? textMain : textMuted)
                        .contentShape(Rectangle())
                }
                .buttonStyle(TransportIconButtonStyle())
                .disabled(!hasNotes)
                .explain(hasNotes ? "Jump to next note (])." : "No notes logged", binding: $hoverExplanation)
            }
        }
    }
    
    // 2. Center Shuttle Speed Badge (Simplified: icon + number only; hidden on 1x play and pause)
    @ViewBuilder
    private var playerCenterShuttleBadge: some View {
        if let (icon, text) = shuttleBadgeContent {
            HStack(spacing: 3) {
                Image(systemName: icon)
                    .font(.system(size: 10, weight: .bold))
                Text(text)
                    .font(.system(size: 11, weight: .bold, design: .monospaced))
                    .monospacedDigit()
            }
            .foregroundColor(accentBlue)
            .lineLimit(1)
        }
    }
    
    private var shuttleBadgeContent: (icon: String, text: String)? {
        guard playerEngine.isPlaying || playerEngine.rate != 0.0 else { return nil }
        
        if playerEngine.isSlowStepping {
            let isFwd = playerEngine.shuttleStateText.contains("FWD")
            let parts = playerEngine.shuttleStateText.components(separatedBy: " ")
            let fps = parts.count >= 3 ? parts[2] : ""
            let text = fps.isEmpty ? "SLOW" : "\(fps) FPS"
            return (icon: isFwd ? "forward.fill" : "backward.fill", text: text)
        }
        
        let rate = playerEngine.rate
        if rate > 1.0 {
            return (icon: "forward.fill", text: "\(Int(rate))x")
        } else if rate < 0.0 {
            return (icon: "backward.fill", text: "\(Int(abs(rate)))x")
        }
        
        // For normal 1x play (rate == 1.0) or paused, show nothing
        return nil
    }
    
    // 3. Compact Line Finding Navigation: < LINE >
    private var playerLineGlitchGroup: some View {
        let hasGlitches = scanResults.contains(where: { $0.isFlagged && !$0.glitchSegments.isEmpty })
        return HStack(spacing: 1) {
            Button(action: { jumpToPreviousGlitchFinding() }) {
                Image(systemName: "chevron.left.to.line")
                    .font(.system(size: StudioTheme.scaleFont(9), weight: .bold))
                    .frame(width: StudioTheme.scale(18), height: StudioTheme.scale(24))
                    .foregroundColor(hasGlitches ? alertRed : textMuted)
                    .contentShape(Rectangle())
            }
            .buttonStyle(TransportIconButtonStyle())
            .disabled(!hasGlitches)
            .explain(
                hasGlitches ? "Jump to previous line glitch (⇧M / cycles backwards through findings of Tab 3)." : "No line glitches found in Tab 3 to cycle through.",
                binding: $hoverExplanation
            )
            
            Text("LINE")
                .font(.system(size: StudioTheme.scaleFont(9), weight: .bold, design: .monospaced))
                .foregroundColor(hasGlitches ? alertRed : textMuted)
                .padding(.horizontal, 3)
            
            Button(action: { jumpToNextGlitchFinding() }) {
                Image(systemName: "chevron.right.to.line")
                    .font(.system(size: StudioTheme.scaleFont(9), weight: .bold))
                    .frame(width: StudioTheme.scale(18), height: StudioTheme.scale(24))
                    .foregroundColor(hasGlitches ? alertRed : textMuted)
                    .contentShape(Rectangle())
            }
            .buttonStyle(TransportIconButtonStyle())
            .disabled(!hasGlitches)
            .explain(
                hasGlitches ? "Jump to next line glitch (M / cycles forwards through findings of Tab 3)." : "No line glitches found in Tab 3 to cycle through.",
                binding: $hoverExplanation
            )
        }
    }
    
    // 4. Finder Tags Button
    private var playerTagsButton: some View {
        let activeURL = playerEngine.activeURL
        let activeTag = activeURL.flatMap { fileTagsMap[$0] }
        return Button(action: {
            showTagPickerPopover.toggle()
        }) {
            HStack(spacing: 4) {
                if let tag = activeTag {
                    Circle()
                        .fill(tag.color)
                        .frame(width: StudioTheme.scale(7), height: StudioTheme.scale(7))
                } else {
                    Image(systemName: "tag.fill")
                        .font(.system(size: StudioTheme.scaleFont(9), weight: .bold))
                }
                Text("TAGS")
                    .font(.system(size: StudioTheme.scaleFont(9), weight: .bold, design: .monospaced))
            }
            .frame(height: StudioTheme.scale(24))
            .padding(.horizontal, 5)
            .foregroundColor(activeTag?.color ?? (activeURL == nil ? textMuted : textMain.opacity(0.85)))
            .contentShape(Rectangle())
        }
        .buttonStyle(TransportIconButtonStyle())
        .disabled(activeURL == nil)
        .explain(activeURL != nil ? "Tag current file with native macOS Finder color tags (1-7: Red, Green, Blue, Yellow, Orange, Purple, Gray; 0: Clear)." : "Load a file to apply Finder tags.", binding: $hoverExplanation)
        .popover(isPresented: $showTagPickerPopover, arrowEdge: .top) {
            tagPickerPopoverView(for: activeURL)
        }
    }
    
    // 5. Timecode Menu (Tightly aligned, no dead space)
    private var playerTimecodeMenu: some View {
        PlayerTimecodeMenuView(playerEngine: playerEngine, accentBlue: accentBlue)
    }
    
    // 6. Zoom Dropdown Menu (Compact "Fit" sizing)
    private var playerZoomMenu: some View {
        PlayerZoomMenuView(
            playerEngine: playerEngine,
            bgSubtle: bgSubtle,
            borderLine: borderLine,
            textMain: textMain,
            textMuted: textMuted
        )
    }
    
    // 7. Duration / Total Frames Label
    private var playerDurationLabel: some View {
        Text(playerEngine.displayTimeAsFrames ? "\(playerEngine.totalFrames) frames" : playerEngine.durationTimecode)
            .font(.system(size: 11, weight: .medium, design: .monospaced))
            .foregroundColor(textMuted)
            .lineLimit(1)
    }
    
    // MARK: - Timecode Bar (above timeline)
    
    private var playerTimecodeBar: some View {
        ZStack(alignment: .center) {
            // Absolute Center: Shuttle Speed Indicator (hidden on 1x play and pause)
            playerCenterShuttleBadge
            
            // Balanced Distribution Across the Bar
            HStack(spacing: 0) {
                // Left: Timecode + Zoom (tightly paired with 8pt spacing)
                HStack(spacing: 8) {
                    playerTimecodeMenu
                    playerZoomMenu
                }
                .frame(minWidth: 160, alignment: .leading)
                
                Spacer()
                
                // Left-Center: Compact Review Notes Controls: [+ NOTE] and < 💬 count >
                playerNotesGroup
                
                Spacer()
                
                // Center Clearance Area for Shuttle Badge (ensures no collision when badge is visible)
                Color.clear.frame(width: 64, height: 24)
                    .allowsHitTesting(false)
                
                Spacer()
                
                // Right-Center: Compact Line Finding Navigation & Tags
                HStack(spacing: 6) {
                    playerLineGlitchGroup
                    Rectangle()
                        .fill(borderLine.opacity(0.45))
                        .frame(width: 1, height: 14)
                    playerTagsButton
                }
                
                Spacer()
                
                // Right: Duration Timecode / Total Frames
                playerDurationLabel
                    .frame(minWidth: 160, alignment: .trailing)
            }
        }
        .frame(height: 24)
    }
    
    // MARK: - Transport Bar
    
    private var playerTransportBar: some View {
        HStack(spacing: 0) {
            // Left: Audio Volume & Mute (Fixed proportional width - matches right)
            HStack(spacing: 8) {
                let speakerIcon: String = {
                    if playerEngine.isMuted || playerEngine.volume <= 0.001 {
                        return "speaker.slash.fill"
                    } else if playerEngine.volume > 0.66 {
                        return "speaker.wave.3.fill"
                    } else if playerEngine.volume > 0.33 {
                        return "speaker.wave.2.fill"
                    } else {
                        return "speaker.wave.1.fill"
                    }
                }()
                
                Button(action: { playerEngine.isMuted.toggle() }) {
                    Image(systemName: speakerIcon)
                        .font(.system(size: StudioTheme.scaleFont(11)))
                        .foregroundColor(playerEngine.isMuted ? alertRed : textMain)
                        .frame(width: StudioTheme.scale(18), height: StudioTheme.scale(18), alignment: .center)
                }
                .buttonStyle(TransportIconButtonStyle())
                .frame(width: StudioTheme.scale(18), height: StudioTheme.scale(18))
                .explain(playerEngine.isMuted ? "Unmute audio" : "Mute audio", binding: $hoverExplanation)
                
                Slider(value: Binding(
                    get: { Double(playerEngine.volume) },
                    set: { playerEngine.volume = Float($0) }
                ), in: 0...1)
                .frame(width: StudioTheme.scale(70))
                .tint(accentBlue)
                .disabled(playerEngine.isMuted)
            }
            .frame(width: StudioTheme.scale(210), alignment: .leading)
            
            Spacer()
            
            // Center: Playback, Shuttle & Frame Controls (Camera screengrab moved next to Exposure)
            PlayerTransportDeckView(
                engine: playerEngine,
                scanResults: scanResults,
                isLightMode: isLightMode,
                hoverExplanation: $hoverExplanation,
                onExportScreenshot: { exportCurrentFrameScreenshot() },
                showNotesAndGlitches: false
            )
            
            Spacer()
            
            // Right: Balanced spacer to keep center transport deck dead-centered
            Spacer()
                .frame(width: StudioTheme.scale(210))
        }
        .frame(height: StudioTheme.scale(28))
    }
    
    var hasPlayerSubfolders: Bool {
        FileSystemTreeBuilder.hasSubfolders(in: playerTreeNodes)
    }
    
    var flattenedPlayerNodes: [FileSystemTreeNode] {
        FileSystemTreeBuilder.flatten(
            nodes: playerTreeNodes,
            collapsedIDs: playerCollapsedFolderIDs,
            hiddenIDs: hiddenFolderIDs,
            hideAllFolders: hideAllFolders,
            filterText: playerFilterText
        )
    }
    
    var filteredPlayerFiles: [URL] {
        let treeOrder = FileSystemTreeBuilder.orderedVideoURLs(from: playerTreeNodes)
        let baseFiles = treeOrder.isEmpty ? videoFiles : treeOrder
        if playerFilterText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return baseFiles
        }
        return baseFiles.filter { $0.lastPathComponent.localizedCaseInsensitiveContains(playerFilterText) }
    }
    
    func revealPlayerFolderContaining(url: URL) {
        guard !playerCollapsedFolderIDs.isEmpty else { return }
        let targetPath = url.standardizedFileURL.path
        
        var idsToExpand: Set<String> = []
        func checkNode(_ node: FileSystemTreeNode) {
            guard node.isDirectory else { return }
            let dirPath = node.url.standardizedFileURL.path
            let isAncestor = targetPath.hasPrefix(dirPath + "/") || node.videoURLs.contains(where: { $0.standardizedFileURL.path == targetPath })
            if isAncestor {
                idsToExpand.insert(node.id)
                for child in node.children {
                    checkNode(child)
                }
            }
        }
        
        for root in playerTreeNodes {
            checkNode(root)
        }
        
        let intersection = playerCollapsedFolderIDs.intersection(idsToExpand)
        if !intersection.isEmpty {
            withAnimation(.easeInOut(duration: 0.2)) {
                playerCollapsedFolderIDs.subtract(intersection)
            }
        }
    }
    
    private func toggleAllPlayerFolders() {
        if playerCollapsedFolderIDs.isEmpty {
            func collectFolderIDs(_ node: FileSystemTreeNode) -> [String] {
                var ids: [String] = []
                if node.isDirectory {
                    ids.append(node.id)
                    for child in node.children {
                        ids.append(contentsOf: collectFolderIDs(child))
                    }
                }
                return ids
            }
            playerCollapsedFolderIDs = Set(playerTreeNodes.flatMap { collectFolderIDs($0) })
        } else {
            playerCollapsedFolderIDs.removeAll()
        }
    }
    
    // MARK: - Screenshot Capture & Export
    
    @MainActor
    private final class ScreenshotSoundPlayer {
        static let shared = ScreenshotSoundPlayer()
        private var sound: NSSound?
        
        private init() {
            prepareSound()
        }
        
        private func locateSoundURL() -> URL? {
            if let url = Bundle.main.url(forResource: "Click", withExtension: "aac") {
                return url
            }
            let appBundleResourceURL = Bundle.main.bundleURL.appendingPathComponent("Contents/Resources/Click.aac")
            if FileManager.default.fileExists(atPath: appBundleResourceURL.path) {
                return appBundleResourceURL
            }
            let devPaths = [
                URL(fileURLWithPath: FileManager.default.currentDirectoryPath).appendingPathComponent("Resources/Click.aac"),
                URL(fileURLWithPath: FileManager.default.currentDirectoryPath).appendingPathComponent("_icon/Click.aac")
            ]
            for url in devPaths {
                if FileManager.default.fileExists(atPath: url.path) {
                    return url
                }
            }
            return nil
        }
        
        private func prepareSound() {
            if let url = locateSoundURL() {
                sound = NSSound(contentsOf: url, byReference: true)
            }
        }
        
        func play() {
            if let sound = sound {
                sound.stop()
                sound.play()
                return
            }
            if let url = locateSoundURL(), let newSound = NSSound(contentsOf: url, byReference: true) {
                sound = newSound
                newSound.play()
                return
            }
            NSSound(named: "Tink")?.play()
        }
    }
    
    private func exportCurrentFrameScreenshot() {
        let currentTarget = playerEngine.activeTarget
        let currentSlot: SlotTarget = (currentTarget == .slotB && playerEngine.slotB.url != nil) ? .slotB : .slotA
        guard let url = (currentSlot == .slotA) ? playerEngine.slotA.url : playerEngine.slotB.url else { return }
        
        let baseName = url.deletingPathExtension().lastPathComponent
        let frameNum = (currentSlot == .slotA) ? playerEngine.currentFrame : Int(round(CMTimeGetSeconds(playerEngine.slotB.currentTime) * max(1.0, playerEngine.slotB.fps)))
        let defaultFileName = "\(baseName)_frame_\(frameNum).jpg"
        
        let savePanel = NSSavePanel()
        savePanel.title = "Save Frame Screenshot (\(currentSlot == .slotA ? "Slot A" : "Slot B"))"
        savePanel.prompt = "Save"
        savePanel.canCreateDirectories = true
        savePanel.nameFieldStringValue = defaultFileName
        savePanel.allowedContentTypes = [.jpeg]
        
        if let parentDir = folderURL {
            savePanel.directoryURL = parentDir
        }
        
        if savePanel.runModal() == .OK, let targetURL = savePanel.url {
            Task { @MainActor in
                do {
                    try await playerEngine.exportCurrentFrameAsJPEG(for: currentSlot, to: targetURL, quality: 0.65)
                    ScreenshotSoundPlayer.shared.play()
                } catch {
                    print("[Screenshot] Export error: \(error.localizedDescription)")
                }
            }
        }
    }
    
    // MARK: - Tag Picker Popover
    
    private func tagPickerPopoverView(for url: URL?) -> some View {
        let currentTag = url.flatMap { fileTagsMap[$0] }
        return HStack(spacing: 12) {
            ForEach(FinderTagColor.allCases) { tag in
                Button(action: {
                    if let url = url {
                        toggleFinderTag(tag, for: url)
                    }
                    showTagPickerPopover = false
                }) {
                    ZStack {
                        Circle()
                            .fill(tag.color)
                            .frame(width: 20, height: 20)
                            .shadow(color: tag.color.opacity(currentTag == tag ? 0.6 : 0.2), radius: 3, x: 0, y: 1)
                        
                        if currentTag == tag {
                            Image(systemName: "checkmark")
                                .font(.system(size: 9, weight: .black))
                                .foregroundColor(.white)
                        }
                    }
                    .contentShape(Circle())
                }
                .buttonStyle(.plain)
                .explain("Finder Tag: \(tag.rawValue)", binding: $hoverExplanation)
            }
            
            Divider()
                .frame(height: 16)
            
            Button(action: {
                if let url = url {
                    setFinderTag(nil, for: url)
                }
                showTagPickerPopover = false
            }) {
                Image(systemName: "xmark.circle.fill")
                    .font(.system(size: 16))
                    .foregroundColor(currentTag != nil ? textMain : textMuted)
            }
            .buttonStyle(.plain)
            .disabled(currentTag == nil)
            .explain("Remove Finder tag", binding: $hoverExplanation)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .background(bgPanel)
    }
    
    // MARK: - Fullscreen Video Presentation Overlays
    
    var fullscreenPlayerOverlay: some View {
        FullscreenPlayerView(
            engine: playerEngine,
            scanResults: scanResults,
            videoFiles: videoFiles,
            onExit: { exitFullscreen() },
            onJumpNext: { jumpToNextGlitchFinding() },
            onJumpPrev: { jumpToPreviousGlitchFinding() },
            onAddNote: { openAddNoteModal() },
            onExportScreenshot: { exportCurrentFrameScreenshot() }
        )
    }
    
    var cleanVideoFullscreenOverlay: some View {
        CleanVideoFullscreenView(
            engine: playerEngine,
            onExit: { exitFullscreen() }
        )
    }
}

// MARK: - Reusable Player Comparison Bar

struct PlayerComparisonBar: View {
    @ObservedObject var engine: PlayerEngine
    @ObservedObject private var themeManager = ThemeManager.shared
    var isLightMode: Bool = false
    var hoverExplanation: Binding<String>? = nil
    var onInteraction: (() -> Void)? = nil
    
    private var textMain: Color { StudioTheme.textMain(isLightMode) }
    private var textMuted: Color { StudioTheme.textMuted(isLightMode) }
    private var bgSubtle: Color { StudioTheme.bgSubtle(isLightMode) }
    private var borderLine: Color { StudioTheme.borderLine(isLightMode) }
    private var accentPositive: Color { StudioTheme.positive }
    private var accentSlotB: Color { StudioTheme.slotBAccent }
    private var alertRed: Color { StudioTheme.negative }
    
    var body: some View {
        HStack(spacing: StudioTheme.scale(8)) {
            // Group 1: Comparison View Modes (Icons, no boxes)
            HStack(spacing: StudioTheme.scale(4)) {
                modeBtn(mode: .single, icon: "rectangle", helpText: "Single Mode: Display Slot A Master video in full viewport.")
                modeBtn(mode: .splitVertical, icon: "rectangle.split.2x1", helpText: "Split Wipe (Vertical): Interactive vertical split divider comparing Slot A and Slot B.")
                modeBtn(mode: .splitHorizontal, icon: "rectangle.split.1x2", helpText: "Split Wipe (Horizontal): Interactive horizontal split divider comparing Slot A and Slot B.")
                modeBtn(mode: .sideBySide, icon: "square.split.2x1", helpText: "Side-by-Side (Horizontal): Scaled dual video comparison side by side (Left: Slot A, Right: Slot B).")
                modeBtn(mode: .sideBySideVertical, icon: "square.split.1x2", helpText: "Side-by-Side (Vertical): Scaled dual video comparison stacked vertically (Top: Slot A, Bottom: Slot B).")
                modeBtn(mode: .difference, icon: "circle.lefthalf.filled", helpText: "Difference Mode: RGB subtraction blend (|A - B|). Identical pixels appear black; discrepancies glow.")
                modeBtn(mode: .overlay, icon: "square.2.layers.3d", helpText: "50% Opacity Overlay: Slot B reference video is overlaid on top of Slot A at 50% opacity.")
            }
            
            Rectangle()
                .fill(borderLine.opacity(0.6))
                .frame(width: 1, height: StudioTheme.scale(14))
                .padding(.horizontal, StudioTheme.scale(2))
            
            // Group 2: Playback Sync & Audio Solo (Icons, no boxes)
            HStack(spacing: StudioTheme.scale(4)) {
                // Gang Link Toggle
                Button(action: {
                    engine.isLinked.toggle()
                    onInteraction?()
                }) {
                    Image(systemName: "link")
                        .font(.system(size: StudioTheme.scaleFont(12), weight: .bold))
                        .frame(width: StudioTheme.scale(26), height: StudioTheme.scale(26))
                        .foregroundColor(engine.isLinked ? textMain : textMuted)
                        .contentShape(Rectangle())
                }
                .buttonStyle(TransportIconButtonStyle())
                .explain("Gang Playhead Link: Lock transport controls and scrubbers between Slot A and Slot B (Currently: \(engine.isLinked ? "ON" : "OFF")).", binding: hoverExplanation)
                
                // Audio Solo Selector
                Button(action: {
                    engine.audioSlot = (engine.audioSlot == .slotA ? .slotB : .slotA)
                    onInteraction?()
                }) {
                    HStack(spacing: StudioTheme.scale(3)) {
                        Image(systemName: "speaker.wave.2.fill")
                            .font(.system(size: StudioTheme.scaleFont(11), weight: .bold))
                        Text(engine.audioSlot == .slotA ? "A" : "B")
                            .font(.system(size: StudioTheme.scaleFont(9), weight: .black, design: .monospaced))
                    }
                    .frame(height: StudioTheme.scale(26))
                    .padding(.horizontal, StudioTheme.scale(4))
                    .foregroundColor(engine.audioSlot == .slotA ? accentPositive : accentSlotB)
                    .contentShape(Rectangle())
                }
                .buttonStyle(TransportIconButtonStyle())
                .explain("Solo Audio Output: Playing audio from Slot \(engine.audioSlot == .slotA ? "A (Master)" : "B (Compare)"). Click to switch.", binding: hoverExplanation)
            }
            
            Rectangle()
                .fill(borderLine.opacity(0.6))
                .frame(width: 1, height: StudioTheme.scale(14))
                .padding(.horizontal, StudioTheme.scale(2))
            
            // Group 4: Slot Operations (Swap / Toggle Clip Names / Clear, Border-free)
            HStack(spacing: StudioTheme.scale(4)) {
                // Swap Button (Grey icon)
                Button(action: {
                    engine.swapSlots()
                    onInteraction?()
                }) {
                    Image(systemName: "arrow.left.arrow.right")
                        .font(.system(size: StudioTheme.scaleFont(11), weight: .bold))
                        .frame(width: StudioTheme.scale(26), height: StudioTheme.scale(26))
                        .foregroundColor(textMuted)
                        .contentShape(Rectangle())
                }
                .buttonStyle(TransportIconButtonStyle())
                .explain("Swap Slots (X): Swap Slot A (Master) and Slot B (Compare).", binding: hoverExplanation)
                
                // Clear B Button
                Button(action: {
                    engine.clearSlotB()
                    onInteraction?()
                }) {
                    HStack(spacing: StudioTheme.scale(4)) {
                        Image(systemName: "xmark")
                            .font(.system(size: StudioTheme.scaleFont(9), weight: .bold))
                        Text("CLEAR B")
                            .font(.system(size: StudioTheme.scaleFont(9), weight: .bold, design: .monospaced))
                    }
                    .frame(height: StudioTheme.scale(26))
                    .padding(.horizontal, StudioTheme.scale(4))
                    .foregroundColor(alertRed)
                    .contentShape(Rectangle())
                }
                .buttonStyle(TransportIconButtonStyle())
                .explain("Clear Slot B: Close comparison video and return to single-video mode.", binding: hoverExplanation)
            }
        }
    }
    
    private struct DottedVerticalLine: Shape {
        func path(in rect: CGRect) -> Path {
            var p = Path()
            p.move(to: CGPoint(x: rect.midX, y: rect.minY))
            p.addLine(to: CGPoint(x: rect.midX, y: rect.maxY))
            return p
        }
    }
    
    private struct DottedHorizontalLine: Shape {
        func path(in rect: CGRect) -> Path {
            var p = Path()
            p.move(to: CGPoint(x: rect.minX, y: rect.midY))
            p.addLine(to: CGPoint(x: rect.maxX, y: rect.midY))
            return p
        }
    }
    
    private func modeBtn(mode: CompareMode, icon: String, helpText: String) -> some View {
        let requiresMatching = (mode == .splitVertical || mode == .splitHorizontal || mode == .difference || mode == .overlay)
        let isLocked = engine.slotB.url != nil && requiresMatching && !engine.hasMatchingAspectRatios
        let isActive = engine.compareMode == mode
        
        let explanationText: String
        if isLocked {
            let descA = engine.slotA.aspectRatioDescription
            let descB = engine.slotB.aspectRatioDescription
            explanationText = "Locked: Split wipe and overlay modes require matching aspect ratios. Slot A is \(descA), Slot B is \(descB). Use Side-by-Side (H) or (V) to compare."
        } else if mode == .single && engine.slotB.url != nil {
            explanationText = engine.isBlinkCompareB
                ? "Single Mode: Viewing Slot B (Press Tab or click to toggle to Slot A Master)."
                : "Single Mode: Viewing Slot A Master (Press Tab or click to toggle to Slot B)."
        } else if isActive && engine.slotB.url != nil {
            explanationText = "\(helpText) (Active - Click to swap Slot A and Slot B)."
        } else {
            explanationText = helpText
        }
        
        return Button(action: {
            if isLocked { return }
            if mode == .single && engine.compareMode == .single && engine.slotB.url != nil {
                engine.isBlinkCompareB.toggle()
            } else if engine.compareMode == mode && engine.slotB.url != nil {
                engine.swapSlots()
            } else {
                engine.isBlinkCompareB = false
                engine.compareMode = mode
            }
            onInteraction?()
        }) {
            ZStack(alignment: .topTrailing) {
                modeIconView(mode: mode, icon: icon, isActive: isActive)
                    .frame(width: StudioTheme.scale(26), height: StudioTheme.scale(26))
                    .contentShape(Rectangle())
                    .opacity(isLocked ? 0.35 : 1.0)
                
                if isLocked {
                    Image(systemName: "lock.fill")
                        .font(.system(size: StudioTheme.scaleFont(7), weight: .bold))
                        .foregroundColor(textMuted.opacity(0.85))
                        .offset(x: -1, y: 1)
                }
            }
        }
        .buttonStyle(TransportIconButtonStyle())
        .explain(explanationText, binding: hoverExplanation)
    }
    
    @ViewBuilder
    private func modeIconView(mode: CompareMode, icon: String, isActive: Bool) -> some View {
        switch mode {
        case .single:
            Image(systemName: icon)
                .font(.system(size: StudioTheme.scaleFont(13), weight: isActive ? .black : .bold))
                .foregroundColor(!isActive ? textMuted : (engine.isBlinkCompareB ? accentSlotB : accentPositive))
            
        case .splitVertical:
            ZStack {
                RoundedRectangle(cornerRadius: StudioTheme.scale(2))
                    .strokeBorder(
                        isActive ? AnyShapeStyle(
                            LinearGradient(
                                stops: [
                                    .init(color: accentPositive, location: 0.0),
                                    .init(color: accentPositive, location: 0.49),
                                    .init(color: accentSlotB, location: 0.51),
                                    .init(color: accentSlotB, location: 1.0)
                                ],
                                startPoint: .leading,
                                endPoint: .trailing
                            )
                        ) : AnyShapeStyle(textMuted),
                        lineWidth: StudioTheme.scale(1.3)
                    )
                
                DottedVerticalLine()
                    .stroke(
                        isActive ? accentSlotB : textMuted,
                        style: StrokeStyle(lineWidth: StudioTheme.scale(1.25), dash: [StudioTheme.scale(2), StudioTheme.scale(1.5)])
                    )
                    .padding(.vertical, StudioTheme.scale(1.5))
            }
            .frame(width: StudioTheme.scale(16), height: StudioTheme.scale(12))
            
        case .splitHorizontal:
            ZStack {
                RoundedRectangle(cornerRadius: StudioTheme.scale(2))
                    .strokeBorder(
                        isActive ? AnyShapeStyle(
                            LinearGradient(
                                stops: [
                                    .init(color: accentPositive, location: 0.0),
                                    .init(color: accentPositive, location: 0.49),
                                    .init(color: accentSlotB, location: 0.51),
                                    .init(color: accentSlotB, location: 1.0)
                                ],
                                startPoint: .top,
                                endPoint: .bottom
                            )
                        ) : AnyShapeStyle(textMuted),
                        lineWidth: StudioTheme.scale(1.3)
                    )
                
                DottedHorizontalLine()
                    .stroke(
                        isActive ? accentSlotB : textMuted,
                        style: StrokeStyle(lineWidth: StudioTheme.scale(1.25), dash: [StudioTheme.scale(2), StudioTheme.scale(1.5)])
                    )
                    .padding(.horizontal, StudioTheme.scale(1.5))
            }
            .frame(width: StudioTheme.scale(16), height: StudioTheme.scale(12))
            
        case .sideBySide:
            HStack(spacing: StudioTheme.scale(2)) {
                RoundedRectangle(cornerRadius: StudioTheme.scale(1.5))
                    .strokeBorder(isActive ? accentPositive : textMuted, lineWidth: StudioTheme.scale(1.35))
                    .background(RoundedRectangle(cornerRadius: StudioTheme.scale(1.5)).fill(isActive ? accentPositive.opacity(0.12) : Color.clear))
                    .frame(width: StudioTheme.scale(10), height: StudioTheme.scale(8.5))
                
                RoundedRectangle(cornerRadius: StudioTheme.scale(1.5))
                    .strokeBorder(isActive ? accentSlotB : textMuted, lineWidth: StudioTheme.scale(1.35))
                    .background(RoundedRectangle(cornerRadius: StudioTheme.scale(1.5)).fill(isActive ? accentSlotB.opacity(0.12) : Color.clear))
                    .frame(width: StudioTheme.scale(10), height: StudioTheme.scale(8.5))
            }
            .frame(width: StudioTheme.scale(22), height: StudioTheme.scale(14))
            
        case .sideBySideVertical:
            VStack(spacing: StudioTheme.scale(2)) {
                RoundedRectangle(cornerRadius: StudioTheme.scale(1.5))
                    .strokeBorder(isActive ? accentPositive : textMuted, lineWidth: StudioTheme.scale(1.35))
                    .background(RoundedRectangle(cornerRadius: StudioTheme.scale(1.5)).fill(isActive ? accentPositive.opacity(0.12) : Color.clear))
                    .frame(width: StudioTheme.scale(10), height: StudioTheme.scale(8.5))
                
                RoundedRectangle(cornerRadius: StudioTheme.scale(1.5))
                    .strokeBorder(isActive ? accentSlotB : textMuted, lineWidth: StudioTheme.scale(1.35))
                    .background(RoundedRectangle(cornerRadius: StudioTheme.scale(1.5)).fill(isActive ? accentSlotB.opacity(0.12) : Color.clear))
                    .frame(width: StudioTheme.scale(10), height: StudioTheme.scale(8.5))
            }
            .frame(width: StudioTheme.scale(16), height: StudioTheme.scale(19))
            
        case .difference:
            if !isActive {
                Image(systemName: icon)
                    .font(.system(size: StudioTheme.scaleFont(13), weight: .bold))
                    .foregroundColor(textMuted)
            } else {
                Image(systemName: icon)
                    .font(.system(size: StudioTheme.scaleFont(13), weight: .black))
                    .foregroundStyle(
                        LinearGradient(
                            stops: [
                                .init(color: accentPositive, location: 0.0),
                                .init(color: accentPositive, location: 0.49),
                                .init(color: accentSlotB, location: 0.51),
                                .init(color: accentSlotB, location: 1.0)
                            ],
                            startPoint: .leading,
                            endPoint: .trailing
                        )
                    )
            }
            
        case .overlay:
            if !isActive {
                Image(systemName: icon)
                    .font(.system(size: StudioTheme.scaleFont(13), weight: .bold))
                    .foregroundColor(textMuted)
            } else {
                Image(systemName: icon)
                    .font(.system(size: StudioTheme.scaleFont(13), weight: .black))
                    .foregroundStyle(
                        LinearGradient(
                            stops: [
                                .init(color: accentSlotB, location: 0.0),
                                .init(color: accentSlotB, location: 0.49),
                                .init(color: accentPositive, location: 0.51),
                                .init(color: accentPositive, location: 1.0)
                            ],
                            startPoint: .top,
                            endPoint: .bottom
                        )
                    )
            }
        }
    }
}

// MARK: - Dedicated Studio Fullscreen Player View

struct FullscreenPlayerView: View {
    @ObservedObject var engine: PlayerEngine
    var scanResults: [VideoQCResult]
    var videoFiles: [URL] = []
    var onExit: () -> Void
    var onJumpNext: () -> Void
    var onJumpPrev: () -> Void
    var onAddNote: (() -> Void)? = nil
    var onExportScreenshot: (() -> Void)? = nil
    
    @State private var showControls: Bool = true
    @State private var isHoveringControls: Bool = false
    @State private var hideTask: Task<Void, Never>? = nil
    
    private var accentPositive: Color { StudioTheme.positive }
    private var accentSlotB: Color { StudioTheme.slotBAccent }
    private var alertRed: Color { StudioTheme.negative }
    private var accentBlue: Color { StudioTheme.accentBlue(false) }
    
    var body: some View {
        ZStack {
            Color.black
                .ignoresSafeArea()
            
            // Fullscreen Video Viewport
            if engine.activeURL != nil {
                VideoViewportView(
                    engine: engine,
                    isLightMode: false,
                    allowScrollZoom: true,
                    onSingleClick: {
                        engine.togglePlayPause()
                        userDidInteract()
                    },
                    onDoubleClick: {
                        onExit()
                    }
                )
                .ignoresSafeArea()
            }
            
            // Floating Overlay Controls
            if showControls {
                VStack(spacing: 0) {
                    topBar
                        .transition(.move(edge: .top).combined(with: .opacity))
                    
                    Spacer()
                    
                    bottomBar
                        .transition(.move(edge: .bottom).combined(with: .opacity))
                }
                .transition(.opacity)
            }
        }
        .onContinuousHover { phase in
            switch phase {
            case .active(_):
                userDidInteract()
            case .ended:
                break
            }
        }
        .onAppear {
            userDidInteract()
        }
        .onDisappear {
            hideTask?.cancel()
        }
    }
    
    private func userDidInteract() {
        if !showControls {
            withAnimation(.easeInOut(duration: 0.15)) {
                showControls = true
            }
        }
        
        hideTask?.cancel()
        if engine.isPlaying && !isHoveringControls {
            hideTask = Task { @MainActor in
                try? await Task.sleep(nanoseconds: 3_000_000_000)
                if !Task.isCancelled && engine.isPlaying && !isHoveringControls {
                    withAnimation(.easeInOut(duration: 0.3)) {
                        showControls = false
                    }
                    NSCursor.setHiddenUntilMouseMoves(true)
                }
            }
        }
    }
    
    // MARK: - Top Bar
    
    private var topBar: some View {
        HStack(alignment: .center, spacing: 14) {
            if engine.slotB.url != nil {
                Spacer()
                
                // Centered Comparison Controls Toolbar
                PlayerComparisonBar(
                    engine: engine,
                    isLightMode: false,
                    onInteraction: { userDidInteract() }
                )
                
                Spacer()
            } else {
                VStack(alignment: .leading, spacing: 2) {
                    Text(engine.activeFileName.isEmpty ? "NO ACTIVE ASSET" : engine.activeFileName.uppercased())
                        .font(.system(size: 13, weight: .black, design: .monospaced))
                        .foregroundColor(.white)
                        .lineLimit(1)
                    
                    if !engine.activeResolution.isEmpty {
                        Text("\(engine.activeResolution) // \(String(format: "%.1f", engine.activeFps)) FPS // \(engine.activeCodec)")
                            .font(.system(size: 10, weight: .bold, design: .monospaced))
                            .foregroundColor(Color(white: 0.6))
                    }
                }
                
                Spacer()
                
                // Compare B selector in Fullscreen
                Menu {
                    let candidateFiles = videoFiles.filter { $0 != engine.slotA.url }
                    if !candidateFiles.isEmpty {
                        Section("Queue Deliverables") {
                            ForEach(candidateFiles, id: \.self) { file in
                                Button(file.lastPathComponent) {
                                    engine.loadVideo(url: file, into: .slotB, autoplay: true)
                                    userDidInteract()
                                }
                            }
                        }
                        Divider()
                    }
                    Button("Open Compare File from Disk...") {
                        openCompareFileInFullscreen()
                    }
                } label: {
                    HStack(spacing: StudioTheme.scale(5)) {
                        Image(systemName: "square.split.2x1")
                            .font(.system(size: StudioTheme.scaleFont(10), weight: .bold))
                        Text("[ + COMPARE (B) ]")
                            .font(.system(size: StudioTheme.scaleFont(11), weight: .bold, design: .monospaced))
                    }
                    .padding(.horizontal, StudioTheme.scale(10))
                    .padding(.vertical, StudioTheme.scale(6))
                    .background(Color(white: 0.15).opacity(0.85))
                    .foregroundColor(accentSlotB)
                    .border(accentSlotB.opacity(0.6), width: 1)
                }
                .buttonStyle(.plain)
                .help("Select a clip to compare side-by-side with current video in Slot B")
                
                Spacer()
            }
            
            Button(action: onExit) {
                HStack(spacing: StudioTheme.scale(6)) {
                    Image(systemName: "arrow.down.right.and.arrow.up.left")
                        .font(.system(size: StudioTheme.scaleFont(10), weight: .bold))
                    Text("[ EXIT FULLSCREEN (ESC) ]")
                        .font(.system(size: StudioTheme.scaleFont(11), weight: .bold, design: .monospaced))
                }
                .padding(.horizontal, StudioTheme.scale(14))
                .padding(.vertical, StudioTheme.scale(8))
                .background(Color(white: 0.15).opacity(0.85))
                .foregroundColor(.white)
                .border(Color(white: 0.35), width: 1)
            }
            .buttonStyle(.plain)
            .help("Exit Fullscreen (ESC / F)")
        }
        .padding(.horizontal, 24)
        .padding(.vertical, 16)
        .background(
            LinearGradient(
                colors: [Color.black.opacity(0.85), Color.black.opacity(0.0)],
                startPoint: .top,
                endPoint: .bottom
            )
        )
        .onHover { isHovering in
            isHoveringControls = isHovering
            if isHovering { userDidInteract() }
        }
    }
    
    private func openCompareFileInFullscreen() {
        let panel = NSOpenPanel()
        panel.title = "Select Video to Compare (Slot B)"
        panel.allowedContentTypes = [.movie, .video, .quickTimeMovie, .mpeg4Movie]
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        if panel.runModal() == .OK, let url = panel.url {
            engine.loadVideo(url: url, into: .slotB)
            userDidInteract()
        }
    }
    
    // MARK: - Bottom Control Bar
    
    private var bottomBar: some View {
        VStack(spacing: 12) {
            // Timeline Scrubber
            TimelineScrubberView(engine: engine, isLightMode: false)
                .frame(height: 52)
            
            // Transport & Timecode Bar
            HStack(spacing: 12) {
                // Left: Timecode / Frame Count + Shuttle Speed (Fixed 280px width)
                HStack(spacing: 8) {
                    if engine.displayTimeAsFrames {
                        let maxNum = max(engine.totalFrames, engine.currentFrame, 999)
                        let digitCount = max(4, String(maxNum).count)
                        let frameColWidth = CGFloat(digitCount) * 8.8
                        
                        HStack(spacing: 4) {
                            Text("\(engine.currentFrame)")
                                .font(.system(size: 14, weight: .bold, design: .monospaced))
                                .monospacedDigit()
                                .foregroundColor(accentBlue)
                                .frame(minWidth: frameColWidth, alignment: .trailing)
                            
                            Text("frames")
                                .font(.system(size: 14, weight: .bold, design: .monospaced))
                                .foregroundColor(accentBlue)
                        }
                        .frame(width: 130, alignment: .leading)
                        .contentShape(Rectangle())
                        .contextMenu {
                            Button(action: {
                                NSPasteboard.general.clearContents()
                                NSPasteboard.general.setString("\(engine.currentFrame)", forType: .string)
                            }) {
                                Label("Copy Frame (\(engine.currentFrame))", systemImage: "doc.on.doc")
                            }
                            Button(action: {
                                NSPasteboard.general.clearContents()
                                NSPasteboard.general.setString(engine.currentTimecode, forType: .string)
                            }) {
                                Label("Copy SMPTE (\(engine.currentTimecode))", systemImage: "clock")
                            }
                        }
                    } else {
                        Text(engine.currentTimecode)
                            .font(.system(size: 14, weight: .bold, design: .monospaced))
                            .monospacedDigit()
                            .foregroundColor(accentBlue)
                            .frame(width: 120, alignment: .leading)
                            .contentShape(Rectangle())
                            .contextMenu {
                                Button(action: {
                                    NSPasteboard.general.clearContents()
                                    NSPasteboard.general.setString(engine.currentTimecode, forType: .string)
                                }) {
                                    Label("Copy Timecode (\(engine.currentTimecode))", systemImage: "doc.on.doc")
                                }
                                Button(action: {
                                    NSPasteboard.general.clearContents()
                                    NSPasteboard.general.setString("\(engine.currentFrame)", forType: .string)
                                }) {
                                    Label("Copy Frame Number (\(engine.currentFrame))", systemImage: "number")
                                }
                            }
                    }
                    
                    if engine.shuttleStateText != "PAUSE" && (engine.isPlaying || engine.rate != 0) {
                        Text(engine.shuttleStateText)
                            .font(.system(size: 10, weight: .bold, design: .monospaced))
                            .monospacedDigit()
                            .foregroundColor(accentBlue)
                            .tracking(0.5)
                    }
                }
                .frame(width: 280, alignment: .leading)
                
                Spacer()
                
                // Center: Transport Buttons
                PlayerTransportDeckView(
                    engine: engine,
                    scanResults: scanResults,
                    isLightMode: false,
                    hoverExplanation: nil,
                    hideGlitchNavWhenEmpty: true,
                    onJumpPrevGlitch: onJumpPrev,
                    onJumpNextGlitch: onJumpNext,
                    onAddNote: onAddNote,
                    onJumpPrevNote: { engine.jumpToPreviousNote() },
                    onJumpNextNote: { engine.jumpToNextNote() },
                    onExportScreenshot: onExportScreenshot,
                    showNotesAndGlitches: true
                )
                
                Spacer()
                
                // Right: Duration Timecode & Exit Fullscreen Button (Fixed 280px width)
                HStack(spacing: 12) {
                    Text(engine.displayTimeAsFrames ? "\(engine.totalFrames) frames" : engine.durationTimecode)
                        .font(.system(size: 13, weight: .bold, design: .monospaced))
                        .monospacedDigit()
                        .foregroundColor(Color(white: 0.6))
                        .frame(width: 120, alignment: .trailing)
                    
                    Button(action: onExit) {
                        Image(systemName: "arrow.down.right.and.arrow.up.left")
                            .font(.system(size: StudioTheme.scaleFont(11), weight: .bold))
                            .frame(width: StudioTheme.scale(32), height: StudioTheme.scale(30))
                            .foregroundColor(.white)
                            .studioBox(background: Color(white: 0.15), border: Color(white: 0.35))
                    }
                    .buttonStyle(.plain)
                    .help("Exit Fullscreen (ESC / F)")
                }
                .frame(width: 280, alignment: .trailing)
            }
            .frame(height: StudioTheme.scale(32))
        }
        .padding(.horizontal, 24)
        .padding(.top, 12)
        .padding(.bottom, 22)
        .background(
            LinearGradient(
                colors: [Color.black.opacity(0.0), Color.black.opacity(0.92)],
                startPoint: .top,
                endPoint: .bottom
            )
        )
        .onHover { isHovering in
            isHoveringControls = isHovering
            if isHovering { userDidInteract() }
        }
    }
    
}

// MARK: - Pure Video Fullscreen View (Zero UI)

struct CleanVideoFullscreenView: View {
    @ObservedObject var engine: PlayerEngine
    var onExit: () -> Void
    
    @State private var hideCursorTask: Task<Void, Never>? = nil
    
    var body: some View {
        ZStack {
            Color.black
                .ignoresSafeArea()
            
            if engine.activeURL != nil {
                VideoViewportView(
                    engine: engine,
                    isLightMode: false,
                    allowScrollZoom: false,
                    onSingleClick: {
                        engine.togglePlayPause()
                    },
                    onDoubleClick: {
                        onExit()
                    }
                )
                .ignoresSafeArea()
            }
        }
        .onContinuousHover { phase in
            switch phase {
            case .active(_):
                resetCursorTimer()
            case .ended:
                break
            }
        }
        .onAppear {
            engine.setZoomFit()
            resetCursorTimer()
        }
        .onDisappear {
            hideCursorTask?.cancel()
        }
    }
    
    private func resetCursorTimer() {
        hideCursorTask?.cancel()
        if engine.isPlaying {
            hideCursorTask = Task { @MainActor in
                try? await Task.sleep(nanoseconds: 2_000_000_000)
                if !Task.isCancelled && engine.isPlaying {
                    NSCursor.setHiddenUntilMouseMoves(true)
                }
            }
        }
    }
}

// MARK: - Timecode & Zoom Interactive Menu Views with Subtle Hover

struct PlayerTimecodeMenuView: View {
    @ObservedObject var playerEngine: PlayerEngine
    var accentBlue: Color
    @State private var isHovered: Bool = false
    
    var body: some View {
        Menu {
            Button(action: {
                let text = playerEngine.displayTimeAsFrames ? "\(playerEngine.currentFrame)" : playerEngine.currentTimecode
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(text, forType: .string)
            }) {
                Label("Copy Value (\(playerEngine.displayTimeAsFrames ? "\(playerEngine.currentFrame)" : playerEngine.currentTimecode))", systemImage: "doc.on.doc")
            }
            Divider()
            Button(action: {
                let text = playerEngine.currentTimecode
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(text, forType: .string)
            }) {
                Label("Copy SMPTE (\(playerEngine.currentTimecode))", systemImage: "clock")
            }
            Button(action: {
                let text = "\(playerEngine.currentFrame)"
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(text, forType: .string)
            }) {
                Label("Copy Frame Number (\(playerEngine.currentFrame))", systemImage: "number")
            }
            Divider()
            Button(action: { playerEngine.displayTimeAsFrames = false }) {
                HStack {
                    Text("SMPTE Timecode (HH:MM:SS:FF)")
                    if !playerEngine.displayTimeAsFrames {
                        Image(systemName: "checkmark")
                    }
                }
            }
            Button(action: { playerEngine.displayTimeAsFrames = true }) {
                HStack {
                    Text("Frames (Frame Count)")
                    if playerEngine.displayTimeAsFrames {
                        Image(systemName: "checkmark")
                    }
                }
            }
        } label: {
            HStack(spacing: 4) {
                if playerEngine.displayTimeAsFrames {
                    let maxNum = max(playerEngine.totalFrames, playerEngine.currentFrame, 999)
                    let digitCount = max(4, String(maxNum).count)
                    let frameColWidth = CGFloat(digitCount) * 8.2
                    
                    Text("\(playerEngine.currentFrame)")
                        .font(.system(size: 13, weight: .bold, design: .monospaced))
                        .monospacedDigit()
                        .foregroundColor(accentBlue)
                        .frame(minWidth: frameColWidth, alignment: .trailing)
                    
                    Text("frames")
                        .font(.system(size: 13, weight: .bold, design: .monospaced))
                        .foregroundColor(accentBlue)
                } else {
                    Text(playerEngine.currentTimecode)
                        .font(.system(size: 13, weight: .bold, design: .monospaced))
                        .monospacedDigit()
                        .foregroundColor(accentBlue)
                        .tracking(0.5)
                        .lineLimit(1)
                }
                
                Image(systemName: "chevron.down")
                    .font(.system(size: 8, weight: .bold))
                    .foregroundColor(accentBlue.opacity(0.8))
            }
            .opacity(isHovered ? 1.0 : 0.82)
            .brightness(isHovered ? 0.05 : 0.0)
            .animation(.easeInOut(duration: 0.12), value: isHovered)
            .onHover { isHovered = $0 }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .contextMenu {
            Button(action: {
                let text = playerEngine.displayTimeAsFrames ? "\(playerEngine.currentFrame)" : playerEngine.currentTimecode
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(text, forType: .string)
            }) {
                Label("Copy Value (\(playerEngine.displayTimeAsFrames ? "\(playerEngine.currentFrame)" : playerEngine.currentTimecode))", systemImage: "doc.on.doc")
            }
            Divider()
            Button(action: {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(playerEngine.currentTimecode, forType: .string)
            }) {
                Label("Copy SMPTE (\(playerEngine.currentTimecode))", systemImage: "clock")
            }
            Button(action: {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString("\(playerEngine.currentFrame)", forType: .string)
            }) {
                Label("Copy Frame Number (\(playerEngine.currentFrame))", systemImage: "number")
            }
            Divider()
            Button(action: { playerEngine.displayTimeAsFrames = false }) {
                HStack {
                    Text("SMPTE Timecode (HH:MM:SS:FF)")
                    if !playerEngine.displayTimeAsFrames {
                        Image(systemName: "checkmark")
                    }
                }
            }
            Button(action: { playerEngine.displayTimeAsFrames = true }) {
                HStack {
                    Text("Frames (Frame Count)")
                    if playerEngine.displayTimeAsFrames {
                        Image(systemName: "checkmark")
                    }
                }
            }
        }
    }
}

struct PlayerZoomMenuView: View {
    @ObservedObject var playerEngine: PlayerEngine
    var bgSubtle: Color
    var borderLine: Color
    var textMain: Color
    var textMuted: Color
    @State private var isHovered: Bool = false
    
    var body: some View {
        Menu {
            Button("Fit") { playerEngine.setZoomFit() }
            Divider()
            Button("10%") { playerEngine.setZoomLevel(0.10) }
            Button("25%") { playerEngine.setZoomLevel(0.25) }
            Button("50%") { playerEngine.setZoomLevel(0.50) }
            Button("75%") { playerEngine.setZoomLevel(0.75) }
            Button("100%") { playerEngine.setZoomLevel(1.0) }
            Button("150%") { playerEngine.setZoomLevel(1.50) }
            Button("200%") { playerEngine.setZoomLevel(2.0) }
            Button("400%") { playerEngine.setZoomLevel(4.0) }
        } label: {
            HStack(spacing: 4) {
                Text(playerEngine.isFitZoom ? "Fit" : "\(Int(round(playerEngine.zoomScale * 100)))%")
                    .font(.system(size: 11, weight: .medium, design: .monospaced))
                    .foregroundColor(textMain)
                    .lineLimit(1)
                    .frame(maxWidth: .infinity, alignment: .center)
                
                Image(systemName: "chevron.down")
                    .font(.system(size: 8, weight: .bold))
                    .foregroundColor(textMuted)
            }
            .padding(.horizontal, 6)
            .frame(width: 62, height: 22)
            .studioBox(background: bgSubtle, border: isHovered ? borderLine.opacity(0.8) : borderLine)
            .opacity(isHovered ? 1.0 : 0.82)
            .brightness(isHovered ? 0.05 : 0.0)
            .animation(.easeInOut(duration: 0.12), value: isHovered)
            .onHover { isHovered = $0 }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .frame(width: 62)
    }
}



