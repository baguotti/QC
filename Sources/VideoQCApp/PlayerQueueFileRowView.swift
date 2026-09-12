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
