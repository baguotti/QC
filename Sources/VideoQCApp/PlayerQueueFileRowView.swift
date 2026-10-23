import SwiftUI
import AppKit
import UniformTypeIdentifiers
import VideoQCLib

public struct PlayerQueueFileRowView: View, Equatable {
    public let url: URL
    public let depth: Int
    public let isSlotA: Bool
    public let isSlotB: Bool
    public let hasSlotB: Bool
    public let notesCount: Int
    public var hasNotes: Bool { notesCount > 0 }
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
    /// Set when the file starts a sequence read as one clip, or is a frame of a sequence read as single images.
    public var sequenceInfo: QueueSequenceInfo? = nil
    
    // Callbacks
    public let onLoadVideo: (_ url: URL, _ target: SlotTarget) -> Void
    public let onClearSlotB: () -> Void
    public let onSwapSlots: () -> Void
    public let onOpenProperties: (_ url: URL) -> Void
    public let onOpenNotes: (_ url: URL) -> Void
    public let onToggleTag: (_ tag: FinderTagColor, _ url: URL) -> Void
    public let onClearTag: (_ url: URL) -> Void
    public var onSetReadAsSequence: (_ url: URL, _ asSequence: Bool) -> Void = { _, _ in }
    public var onSetSequenceFPS: (_ url: URL, _ fps: Double) -> Void = { _, _ in }
    
    public nonisolated static func == (lhs: PlayerQueueFileRowView, rhs: PlayerQueueFileRowView) -> Bool {
        MainActor.assumeIsolated {
            lhs.sequenceInfo == rhs.sequenceInfo &&
            lhs.buttonZoom == rhs.buttonZoom &&
            lhs.url == rhs.url &&
            lhs.depth == rhs.depth &&
            lhs.isSlotA == rhs.isSlotA &&
            lhs.isSlotB == rhs.isSlotB &&
            lhs.hasSlotB == rhs.hasSlotB &&
            lhs.notesCount == rhs.notesCount &&
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
    
    /// fps is 0 for stills and audio (no frame rate to show).
    private static func specLine(_ resolution: String, _ fps: Double, _ codec: String) -> String {
        fps > 0 ? "\(resolution) • \(String(format: "%.1f", fps))fps • \(codec)" : "\(resolution) • \(codec)"
    }
    
    private var bgSubtle: Color { StudioTheme.bgSubtle(isLightMode) }
    private var borderLine: Color { StudioTheme.borderLine(isLightMode) }
    private var textMain: Color { StudioTheme.textMain(isLightMode) }
    private var textMuted: Color { StudioTheme.textMuted(isLightMode) }
    private var textSubtle: Color { StudioTheme.textSubtle(isLightMode) }
    private var accentPositive: Color { StudioTheme.positive }
    private var accentSlotB: Color { StudioTheme.slotBAccent }
    private var playheadColor: Color { StudioTheme.accentBlue(isLightMode) }
    private var bgPanel: Color { StudioTheme.bgPanel(isLightMode) }
    
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
        .explain(url.path)
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
            if let info = sequenceInfo {
                Divider()
                if info.isReadAsSequence {
                    Button("Show as Individual Images") { onSetReadAsSequence(url, false) }
                    Menu("Frame Rate (\(QueueSequenceInfo.rateLabel(info.fps)))") {
                        ForEach(QueueSequenceInfo.rates, id: \.self) { rate in
                            Button(action: { onSetSequenceFPS(url, rate) }) {
                                if abs(rate - info.fps) < 0.001 {
                                    Label(QueueSequenceInfo.rateLabel(rate), systemImage: "checkmark")
                                } else {
                                    Text(QueueSequenceInfo.rateLabel(rate))
                                }
                            }
                        }
                    }
                } else {
                    Button("Read as Image Sequence (\(info.frameCount) frames)") { onSetReadAsSequence(url, true) }
                }
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
    
    private var badgeTextColor: Color {
        ThemeManager.shared.currentTheme.contrastTextColor(for: .blue)
    }
    
    @ViewBuilder
    private var notesBadge: some View {
        if notesCount > 0 {
            HStack(spacing: 3.5) {
                Image(systemName: "bubble.left.fill")
                    .font(.system(size: 7.5, weight: .bold))
                Text("\(notesCount)")
                    .font(.ui(size: 8.5, weight: .semibold))
            }
            .foregroundColor(badgeTextColor)
            .padding(.horizontal, 5)
            .frame(height: 15.5)
            .background(
                RoundedRectangle(cornerRadius: 3.5)
                    .fill(playheadColor)
            )
            .overlay(
                RoundedRectangle(cornerRadius: 3.5)
                    .stroke(playheadColor.opacity(0.85), lineWidth: 0.6)
            )
            .help("\(notesCount) \(notesCount == 1 ? "review note" : "review notes") — click to open them")
            .contentShape(Rectangle())
            // High priority so the click opens the notes instead of the row's load action.
            .highPriorityGesture(TapGesture().onEnded { onOpenNotes(url) })
        }
    }
    
    @ViewBuilder
    private func fileNameLabel(fontSize: CGFloat, isSelected: Bool) -> some View {
        HStack(spacing: 6) {
            Text(sequenceInfo?.label ?? url.lastPathComponent)
                .font(.ui(size: fontSize, weight: isSelected ? .semibold : .medium))
                .foregroundColor(isSelected ? textMain : textSubtle)
                .lineLimit(1)
                .truncationMode(.middle)
            
            if let info = sequenceInfo, info.isReadAsSequence {
                Text("SEQ \(info.frameCount)")
                    .font(.system(size: 7.5, weight: .black, design: .monospaced))
                    .foregroundColor(textMuted)
                    .padding(.horizontal, 3)
                    .padding(.vertical, 1)
                    .overlay(RoundedRectangle(cornerRadius: 2).stroke(textMuted.opacity(0.6), lineWidth: 0.75))
                    .fixedSize()
            }
            
            if notesCount > 0 {
                notesBadge
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
            
            if let kind = QCUtilities.mediaKind(of: url) {
                Image(systemName: sequenceInfo?.isReadAsSequence == true ? "photo.stack" : kind.symbolName)
                    .font(.system(size: 8.5, weight: .semibold))
                    .foregroundColor(isSlotA ? accentPositive : (isSlotB ? accentSlotB : textMuted))
                    .frame(width: 12)
            }
            
            fileNameLabel(fontSize: 10.5, isSelected: isSelected)
            
            if isSlotA && !slotAResolution.isEmpty {
                Text("• \(slotAResolution) \(slotACodec)")
                    .font(.ui(size: 8, weight: .semibold))
                    .foregroundColor(accentPositive)
                    .lineLimit(1)
            } else if isSlotB && !slotBResolution.isEmpty {
                Text("• \(slotBResolution) \(slotBCodec)")
                    .font(.ui(size: 8, weight: .semibold))
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
                    fileNameLabel(fontSize: isLarge ? 11 : 10.5, isSelected: isSelected)
                }
                
                if isSlotA && !slotAResolution.isEmpty {
                    Text(Self.specLine(slotAResolution, slotAFps, slotACodec))
                        .font(.ui(size: isLarge ? 8.5 : 8, weight: .semibold))
                        .foregroundColor(accentPositive)
                        .lineLimit(1)
                } else if isSlotB && !slotBResolution.isEmpty {
                    Text(Self.specLine(slotBResolution, slotBFps, slotBCodec))
                        .font(.ui(size: isLarge ? 8.5 : 8, weight: .semibold))
                        .foregroundColor(accentSlotB)
                        .lineLimit(1)
                } else {
                    Text(url.pathExtension.uppercased())
                        .font(.ui(size: 8, weight: .semibold))
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
                    fileNameLabel(fontSize: 11, isSelected: isSelected)
                }
                
                if isSlotA && !slotAResolution.isEmpty {
                    Text(Self.specLine(slotAResolution, slotAFps, slotACodec))
                        .font(.ui(size: 8.5, weight: .semibold))
                        .foregroundColor(accentPositive)
                        .lineLimit(1)
                } else if isSlotB && !slotBResolution.isEmpty {
                    Text(Self.specLine(slotBResolution, slotBFps, slotBCodec))
                        .font(.ui(size: 8.5, weight: .semibold))
                        .foregroundColor(accentSlotB)
                        .lineLimit(1)
                } else {
                    Text(url.pathExtension.uppercased())
                        .font(.ui(size: 8, weight: .semibold))
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
                        .font(.ui(size: StudioTheme.scaleFont(8), weight: .semibold))
                        .padding(.horizontal, StudioTheme.scale(4))
                        .padding(.vertical, displayMode == "inline" ? StudioTheme.scale(1) : StudioTheme.scale(2))
                        .foregroundColor(textMuted)
                }
                .buttonStyle(TransportIconButtonStyle())
                .explain("Load as Slot A (Master)")
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
                    .explain("Clear Slot B")
                }
            } else {
                Button(action: { onLoadVideo(url, .slotB) }) {
                    Text("+B")
                        .font(.ui(size: StudioTheme.scaleFont(8), weight: .semibold))
                        .padding(.horizontal, StudioTheme.scale(4))
                        .padding(.vertical, displayMode == "inline" ? StudioTheme.scale(1) : StudioTheme.scale(2))
                        .foregroundColor(textMuted)
                }
                .buttonStyle(TransportIconButtonStyle())
                .explain("Load as Slot B (Compare / ⌥+Click)")
            }
        }
        .padding(.trailing, StudioTheme.scale(6))
    }
}

/// Queue row data for an image sequence (see `ImageSequenceStore`).
public struct QueueSequenceInfo: Equatable, Sendable {
    public let label: String?
    public let frameCount: Int
    public let fps: Double
    public let isReadAsSequence: Bool
    
    static let rates: [Double] = [23.976, 24, 25, 29.97, 30, 48, 50, 59.94, 60]
    
    static func rateLabel(_ fps: Double) -> String {
        fps.truncatingRemainder(dividingBy: 1) == 0 ? "\(Int(fps)) fps" : String(format: "%.3g fps", fps)
    }
    
    @MainActor
    static func lookup(_ url: URL) -> QueueSequenceInfo? {
        let store = ImageSequenceStore.shared
        if let seq = store.sequence(for: url) {
            return QueueSequenceInfo(label: seq.displayName, frameCount: seq.frameURLs.count, fps: store.fps(for: seq), isReadAsSequence: true)
        }
        if let seq = store.sequence(containing: url) {
            return QueueSequenceInfo(label: nil, frameCount: seq.frameURLs.count, fps: store.fps(for: seq), isReadAsSequence: false)
        }
        return nil
    }
}
