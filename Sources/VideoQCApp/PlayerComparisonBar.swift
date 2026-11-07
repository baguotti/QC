import SwiftUI
import AppKit
import AVFoundation
import UniformTypeIdentifiers
import VideoQCLib

struct PlayerComparisonBar: View {
    @ObservedObject var engine: PlayerEngine
    @ObservedObject private var themeManager = ThemeManager.shared
    var isLightMode: Bool = false
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
                .explain("Gang Playhead Link: Lock transport controls and scrubbers between Slot A and Slot B (Currently: \(engine.isLinked ? "ON" : "OFF")).")
                
                // Audio Solo Selector
                Button(action: {
                    engine.audioSlot = (engine.audioSlot == .slotA ? .slotB : .slotA)
                    onInteraction?()
                }) {
                    HStack(spacing: StudioTheme.scale(3)) {
                        Image(systemName: "speaker.wave.2.fill")
                            .font(.system(size: StudioTheme.scaleFont(11), weight: .bold))
                        Text(engine.audioSlot == .slotA ? "A" : "B")
                            .font(.ui(size: 10, weight: .semibold))
                    }
                    .frame(height: StudioTheme.scale(26))
                    .padding(.horizontal, StudioTheme.scale(4))
                    .foregroundColor(engine.audioSlot == .slotA ? accentPositive : accentSlotB)
                    .contentShape(Rectangle())
                }
                .buttonStyle(TransportIconButtonStyle())
                .explain("Solo Audio Output: Playing audio from Slot \(engine.audioSlot == .slotA ? "A (Master)" : "B (Compare)"). Click to switch.")
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
                .explain("Swap Slots (X): Swap Slot A (Master) and Slot B (Compare).")
                
                // Clear B Button
                Button(action: {
                    engine.clearSlotB()
                    onInteraction?()
                }) {
                    HStack(spacing: StudioTheme.scale(4)) {
                        Image(systemName: "xmark")
                            .font(.system(size: StudioTheme.scaleFont(9), weight: .bold))
                        Text("Clear B")
                            .font(.ui(size: 10, weight: .semibold))
                    }
                    .frame(height: StudioTheme.scale(26))
                    .padding(.horizontal, StudioTheme.scale(4))
                    .foregroundColor(alertRed)
                    .contentShape(Rectangle())
                }
                .buttonStyle(TransportIconButtonStyle())
                .explain("Clear Slot B: Close comparison video and return to single-video mode.")
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
        .explain(explanationText)
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
            }
            .clipShape(RoundedRectangle(cornerRadius: StudioTheme.scale(2)))
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
            }
            .clipShape(RoundedRectangle(cornerRadius: StudioTheme.scale(2)))
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

// MARK: - Timecode & Zoom Interactive Menu Views with Subtle Hover
