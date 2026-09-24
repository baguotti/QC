import SwiftUI
import AppKit
import AVFoundation
import UniformTypeIdentifiers
import VideoQCLib


// MARK: - Exposure Scrubber Control (After Effects Style)

struct ExposureScrubberView: View {
    @ObservedObject var engine: PlayerEngine
    var isLightMode: Bool = false
    
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
            .explain("Reset Exposure to +0.0 EV")
            
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
                .explain("Change Exposure (EV): Drag left/right to adjust, click aperture to reset (Current: \(formattedEV))")
    }
}
}

// MARK: - Subtle Studio Volume Slider

struct StudioVolumeSlider: View {
    @Binding var volume: Float
    @Binding var isMuted: Bool
    var accentColor: Color
    var textMuted: Color
    var isLightMode: Bool
    
    @State private var isDragging: Bool = false
    @State private var isHovered: Bool = false
    
    private var sliderWidth: CGFloat { StudioTheme.scale(70) }
    private var trackHeight: CGFloat { StudioTheme.scale(3) }
    private var thumbDiameter: CGFloat { StudioTheme.scale(8) }
    
    private var currentThumbDiameter: CGFloat {
        (isHovered || isDragging) ? StudioTheme.scale(9) : thumbDiameter
    }
    
    private var thumbColor: Color {
        if isMuted {
            return textMuted.opacity(0.6)
        }
        return isLightMode ? Color(white: 0.22) : Color.white
    }
    
    var body: some View {
        GeometryReader { geo in
            let width = geo.size.width
            let usableWidth = max(1, width - thumbDiameter)
            let clampedVal = CGFloat(max(0, min(1, volume)))
            let thumbCenter = (thumbDiameter / 2) + clampedVal * usableWidth
            let fillWidth = (clampedVal <= 0.001) ? 0 : min(width, thumbCenter + (thumbDiameter / 2) * clampedVal)
            
            ZStack(alignment: .leading) {
                // Background Track & Active Fill, clipped to capsule shape
                ZStack(alignment: .leading) {
                    Capsule()
                        .fill(isLightMode ? Color.black.opacity(0.12) : Color.white.opacity(0.16))
                        .frame(width: width, height: trackHeight)
                    
                    if fillWidth > 0 {
                        Rectangle()
                            .fill(isMuted ? textMuted.opacity(0.4) : accentColor)
                            .frame(width: fillWidth, height: trackHeight)
                    }
                }
                .clipShape(Capsule())
                .frame(width: width, height: trackHeight)
                .position(x: width / 2, y: geo.size.height / 2)
                
                // Subtle Knob / Ball
                Circle()
                    .fill(thumbColor)
                    .frame(width: currentThumbDiameter, height: currentThumbDiameter)
                    .overlay(
                        Circle()
                            .strokeBorder(isLightMode ? Color.black.opacity(0.15) : Color.white.opacity(0.25), lineWidth: 0.5)
                    )
                    .shadow(color: Color.black.opacity(isLightMode ? 0.2 : 0.4), radius: 1, x: 0, y: 0.5)
                    .position(x: thumbCenter, y: geo.size.height / 2)
                    .animation(.easeInOut(duration: 0.12), value: isHovered)
                    .animation(.easeInOut(duration: 0.12), value: isDragging)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
            .contentShape(Rectangle())
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { gesture in
                        isDragging = true
                        updateVolume(location: gesture.location.x, width: width)
                    }
                    .onEnded { gesture in
                        updateVolume(location: gesture.location.x, width: width)
                        isDragging = false
                    }
            )
        }
        .frame(width: sliderWidth, height: StudioTheme.scale(18))
        .onHover { hovering in
            isHovered = hovering
        }
    }
    
    private func updateVolume(location: CGFloat, width: CGFloat) {
        let usableWidth = max(1, width - thumbDiameter)
        let localX = location - (thumbDiameter / 2)
        let fraction = max(0, min(1, localX / usableWidth))
        volume = Float(fraction)
        if isMuted && volume > 0 {
            isMuted = false
        }
    }
}

extension ContentView {
    
    // MARK: ==================== TAB 1: PLAYER ====================
    
    @ViewBuilder
    var playerTabView: some View {
        GeometryReader { mainGeo in
            let availableWidth = mainGeo.size.width - (showNotesDrawer ? 340.0 : 0.0)
            let maxQueueWidth = max(240.0, min(800.0, availableWidth - 400.0))
            let effectiveQueueWidth = max(240.0, min(maxQueueWidth, playerQueueWidth > 0 ? playerQueueWidth : 360.0))
            
            HStack(spacing: 0) {
                if showPlayerQueue {
                    playerQueuePanel
                        .frame(width: effectiveQueueWidth)
                        .overlay(
                            Rectangle()
                                .fill(borderLine)
                                .frame(width: 1),
                            alignment: .trailing
                        )
                        .overlay(alignment: .trailing) {
                            playerQueueResizeHandle(maxWidth: maxQueueWidth)
                        }
                        .transition(.move(edge: .leading).combined(with: .opacity))
                        .layoutPriority(1)
                }
                playerProgramMonitorPanel
                    .layoutPriority(0)
                if showNotesDrawer {
                    playerNotesDrawerPanel
                        .layoutPriority(1)
                }
            }
        }
        .clipped()
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
            themeId: "\(themeManager.currentTheme.id)_\(themeManager.currentTheme.blueHex)",
            buttonZoom: themeManager.buttonZoom,
            folderURL: folderURL,
            videoFiles: videoFiles,
            playerTreeNodes: playerTreeNodes,
            playerFilterText: $playerFilterText,
            playerCollapsedFolderIDs: $playerCollapsedFolderIDs,
            hiddenFolderIDs: hiddenFolderIDs,
            hideAllFolders: hideAllFolders,
            fileTagsMap: fileTagsMap,
            isScanning: scannerState.isScanning,
            isAutoplayEnabled: playerEngine.isAutoplayEnabled,
            queueVersion: queueVersion,
            tagsVersion: tagsVersion,
            slotAURL: playerEngine.activeURL ?? playerEngine.slotA.url,
            slotAResolution: playerEngine.slotA.resolution,
            slotAFps: playerEngine.slotA.fps,
            slotACodec: playerEngine.slotA.codec,
            slotBURL: playerEngine.slotBURL ?? playerEngine.slotB.url,
            slotBResolution: playerEngine.slotB.resolution,
            slotBFps: playerEngine.slotB.fps,
            slotBCodec: playerEngine.slotB.codec,
            activeTarget: playerEngine.activeTarget,
            activeNotesURL: playerEngine.activeNotesURL,
            activeNotesCount: playerEngine.activeNotes.count,
            queueScrollTarget: $queueScrollTarget,
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
                openProperties(for: url, showModal: false)
                playerDrawerTab = .mediaInfo
                withAnimation(.spring(response: 0.32, dampingFraction: 0.78)) {
                    showNotesDrawer = true
                }
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
    
    // MARK: - Left Panel: Queue Resize Handle Divider
    private func playerQueueResizeHandle(maxWidth: Double) -> some View {
        ZStack {
            // Hit target: generous 28 pt wide grab area (14 pt on each side of the border line)
            Rectangle()
                .fill(Color.clear)
                .frame(width: 28)
                .contentShape(Rectangle())
            
            // Visual border highlight line (1px on hover, 2px during active drag)
            Rectangle()
                .fill(isDraggingQueueResize ? accentBlue : (isHoveringQueueResize ? borderStrong : Color.clear))
                .frame(width: isDraggingQueueResize ? 2 : 1)
        }
        .frame(width: 28)
        .offset(x: 14)
        .zIndex(200)
        .onHover { isHovered in
            if !isDraggingQueueResize {
                if isHovered != isHoveringQueueResize {
                    isHoveringQueueResize = isHovered
                    if isHovered {
                        NSCursor.resizeLeftRight.push()
                    } else {
                        NSCursor.pop()
                    }
                }
            } else {
                isHoveringQueueResize = isHovered
            }
        }
        .onTapGesture(count: 2) {
            withAnimation(.spring(response: 0.28, dampingFraction: 0.82)) {
                playerQueueWidth = min(maxWidth, 360.0)
            }
        }
        .gesture(
            DragGesture(minimumDistance: 1, coordinateSpace: .global)
                .onChanged { value in
                    if !isDraggingQueueResize {
                        isDraggingQueueResize = true
                        dragStartQueueWidth = playerQueueWidth
                    }
                    let newWidth = dragStartQueueWidth + Double(value.translation.width)
                    let clamped = max(240.0, min(maxWidth, newWidth))
                    if abs(playerQueueWidth - clamped) > 0.5 {
                        playerQueueWidth = clamped
                    }
                }
                .onEnded { _ in
                    isDraggingQueueResize = false
                    UserDefaults.standard.set(playerQueueWidth, forKey: "playerQueueWidth")
                    if !isHoveringQueueResize {
                        NSCursor.pop()
                    }
                }
        )
        .onDisappear {
            if isHoveringQueueResize || isDraggingQueueResize {
                isHoveringQueueResize = false
                isDraggingQueueResize = false
                NSCursor.pop()
            }
        }
        .explain("Drag to resize Assets & Queue panel. Double-click to reset width (360px).")
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
                .clipped()
            }
            .frame(minWidth: 400, maxWidth: .infinity, maxHeight: .infinity)
            .clipped()
            .onDrop(of: [UTType.fileURL.identifier], isTargeted: nil) { providers in
                handleDrop(providers: providers, forTab: .player)
            }
    }
    
    // MARK: - Review & Media Info Drawer Panel
    @ViewBuilder
    private var playerNotesDrawerPanel: some View {
        let activeURL = (playerEngine.activeTarget == .slotB && playerEngine.slotB.url != nil) ? playerEngine.slotB.url : (playerEngine.activeURL ?? playerEngine.slotA.url)
        let activeName = (playerEngine.activeTarget == .slotB && playerEngine.slotB.url != nil) ? (playerEngine.slotB.url?.lastPathComponent ?? "Deliverable") : playerEngine.activeFileName
        let standardizedActiveURL = activeURL?.standardizedFileURL
        let matchedAsset = specsState.deliverableAssets.first { $0.fileURL.standardizedFileURL == standardizedActiveURL } ?? propertiesAsset
        
        NotesDrawerPanelView(
            isPresented: $showNotesDrawer,
            selectedDrawerTab: $playerDrawerTab,
            notes: playerEngine.activeNotes,
            mediaName: activeName.isEmpty ? (activeURL?.lastPathComponent ?? "Deliverable") : activeName,
            mediaURL: activeURL,
            mediaAsset: matchedAsset,
            clock: playerEngine.clock,
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
            onClearAllNotes: {
                clearAllNotes()
            },
            onToast: { msg in
                showToast(msg)
            },
            onCopySpecs: { specsText in
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(specsText, forType: .string)
                showToast("Media specs copied to clipboard")
            },
            onRevealInFinder: { url in
                NSWorkspace.shared.activateFileViewerSelecting([url])
            },
            onLoadSlotA: { url in
                playerEngine.loadVideo(url: url, into: .slotA, autoplay: false)
                showToast("Loaded into A: \(url.lastPathComponent)")
            },
            onLoadSlotB: { url in
                playerEngine.loadVideo(url: url, into: .slotB, autoplay: false)
                showToast("Loaded into B: \(url.lastPathComponent)")
            }
        )
        .transition(.move(edge: .trailing).combined(with: .opacity))
    }
    
    // MARK: - Monitor Header
    
    private var playerMonitorHeader: some View {
        HStack(spacing: 12) {
            // Left sleeve toggle button (Hide / Reveal Assets & Queue)
            Button(action: {
                withAnimation(.spring(response: 0.32, dampingFraction: 0.78)) {
                    showPlayerQueue.toggle()
                }
            }) {
                Image(systemName: showPlayerQueue ? "chevron.left" : "chevron.right")
                    .font(.system(size: StudioTheme.scaleFont(11), weight: .bold))
                    .frame(width: StudioTheme.scale(24), height: StudioTheme.scale(26))
                    .foregroundColor(textMain)
                    .contentShape(Rectangle())
            }
            .buttonStyle(TransportIconButtonStyle())
            .explain(showPlayerQueue ? "Hide Assets & Queue panel (⌘⇧←)." : "Reveal Assets & Queue panel (⌘⇧←).")

            if playerEngine.slotB.url != nil {
                Color.clear
                    .frame(width: StudioTheme.scale(56), height: StudioTheme.scale(26))
                
                Spacer()
                
                // Centered Comparison Controls Toolbar
                PlayerComparisonBar(
                    engine: playerEngine,
                    isLightMode: isLightMode
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
            
            // Trailing: Fullscreen Controls & Review Sleeve Toggle
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
                .explain("Review Fullscreen with HUD & timeline controls (⇧F).")
                
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
                .explain("Clean Video Fullscreen with zero UI (F). Press ESC to exit.")
                
                // Review Sleeve Toggle Arrow Button
                Button(action: {
                    withAnimation(.spring(response: 0.32, dampingFraction: 0.78)) {
                        if !showNotesDrawer {
                            playerDrawerTab = currentFileHasNotes ? .notes : .mediaInfo
                        }
                        showNotesDrawer.toggle()
                    }
                }) {
                    Image(systemName: showNotesDrawer ? "chevron.right" : "chevron.left")
                        .font(.system(size: StudioTheme.scaleFont(11), weight: .bold))
                        .frame(width: StudioTheme.scale(24), height: StudioTheme.scale(26))
                        .foregroundColor(playerEngine.activeURL == nil ? textMuted : textMain)
                        .contentShape(Rectangle())
                }
                .buttonStyle(TransportIconButtonStyle())
                .disabled(playerEngine.activeURL == nil)
                .explain(showNotesDrawer ? "Collapse review sleeve (⌘⇧→)." : "Bring out review sleeve (Media Info & Notes) (⌘⇧→).")
            }
            .frame(width: StudioTheme.scale(92), alignment: .trailing)
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
            .explain("Add review note at playhead (N).")
            
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
                .explain(hasNotes ? "Jump to previous note ([)." : "No notes logged")
                
                Button(action: {
                    withAnimation(.easeInOut(duration: 0.15)) {
                        if showNotesDrawer && playerDrawerTab == .notes {
                            showNotesDrawer = false
                        } else {
                            playerDrawerTab = .notes
                            showNotesDrawer = true
                        }
                    }
                }) {
                    let isNotesActive = showNotesDrawer && playerDrawerTab == .notes
                    HStack(spacing: 3) {
                        Image(systemName: isNotesActive ? "bubble.left.fill" : "bubble.left")
                            .font(.system(size: StudioTheme.scaleFont(9), weight: .semibold))
                        SlotText(
                            hasNotes ? "\(notesCount)" : "NOTES",
                            mode: hasNotes ? .character : .word,
                            direction: .up,
                            font: .system(size: StudioTheme.scaleFont(9), weight: .bold, design: .monospaced),
                            foregroundColor: isNotesActive ? accentBlue : (hasNotes ? textMain : textMuted)
                        )
                    }
                    .frame(height: StudioTheme.scale(24))
                    .padding(.horizontal, 4)
                    .foregroundColor(isNotesActive ? accentBlue : (hasNotes ? textMain : textMuted))
                    .contentShape(Rectangle())
                }
                .buttonStyle(TransportIconButtonStyle())
                .disabled(playerEngine.activeURL == nil)
                .explain(hasNotes ? "Toggle Review Notes drawer (\(notesCount) notes)." : "Toggle Review Notes drawer.")
                
                Button(action: { playerEngine.jumpToNextNote() }) {
                    Image(systemName: "chevron.right.to.line")
                        .font(.system(size: StudioTheme.scaleFont(9), weight: .bold))
                        .frame(width: StudioTheme.scale(18), height: StudioTheme.scale(24))
                        .foregroundColor(hasNotes ? textMain : textMuted)
                        .contentShape(Rectangle())
                }
                .buttonStyle(TransportIconButtonStyle())
                .disabled(!hasNotes)
                .explain(hasNotes ? "Jump to next note (])." : "No notes logged")
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
        let hasGlitches = scannerState.scanResults.contains(where: { $0.isFlagged && !$0.glitchSegments.isEmpty })
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
                hasGlitches ? "Jump to previous line glitch (⇧M / cycles backwards through findings of Tab 3)." : "No line glitches found in Tab 3 to cycle through."
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
                hasGlitches ? "Jump to next line glitch (M / cycles forwards through findings of Tab 3)." : "No line glitches found in Tab 3 to cycle through."
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
        .explain(activeURL != nil ? "Tag current file with native macOS Finder color tags (1-7: Red, Green, Blue, Yellow, Orange, Purple, Gray; 0: Clear)." : "Load a file to apply Finder tags.")
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
                .frame(minWidth: 100, alignment: .leading)
                
                Spacer(minLength: 4)
                
                // Left-Center: Compact Review Notes Controls: [+ NOTE] and < 💬 count >
                playerNotesGroup
                
                Spacer(minLength: 4)
                
                // Center Clearance Area for Shuttle Badge (ensures no collision when badge is visible)
                Color.clear.frame(width: 48, height: 24)
                    .allowsHitTesting(false)
                
                Spacer(minLength: 4)
                
                // Right-Center: Compact Line Finding Navigation & Tags
                HStack(spacing: 6) {
                    playerLineGlitchGroup
                    Rectangle()
                        .fill(borderLine.opacity(0.45))
                        .frame(width: 1, height: 14)
                    playerTagsButton
                }
                
                Spacer(minLength: 4)
                
                // Right: Duration Timecode / Total Frames
                playerDurationLabel
                    .frame(minWidth: 80, alignment: .trailing)
            }
        }
        .frame(height: 24)
    }
    
    // MARK: - Transport Bar
    
    private var playerTransportBar: some View {
        HStack(spacing: 0) {
            // Left: Audio Volume & Mute (Flexible proportional width - matches right to keep center dead-centered)
            HStack(spacing: 8) {
                let speakerIcon: String = {
                    if playerEngine.isMuted {
                        return "speaker.slash.fill"
                    } else if playerEngine.volume > 0.66 {
                        return "speaker.wave.3.fill"
                    } else if playerEngine.volume > 0.33 {
                        return "speaker.wave.2.fill"
                    } else if playerEngine.volume > 0.001 {
                        return "speaker.wave.1.fill"
                    } else {
                        return "speaker.fill"
                    }
                }()
                
                Button(action: { playerEngine.isMuted.toggle() }) {
                    Image(systemName: speakerIcon)
                        .font(.system(size: StudioTheme.scaleFont(11)))
                        .foregroundColor(playerEngine.isMuted ? alertRed : textMain)
                        .frame(width: StudioTheme.scale(18), height: StudioTheme.scale(18), alignment: .leading)
                }
                .buttonStyle(TransportIconButtonStyle())
                .frame(width: StudioTheme.scale(18), height: StudioTheme.scale(18))
                .transaction { transaction in
                    transaction.animation = nil
                }
                .explain(playerEngine.isMuted ? "Unmute audio" : "Mute audio")
                
                StudioVolumeSlider(
                    volume: $playerEngine.volume,
                    isMuted: $playerEngine.isMuted,
                    accentColor: accentBlue,
                    textMuted: textMuted,
                    isLightMode: isLightMode
                )
                .explain(playerEngine.isMuted ? "Volume: Muted (\(Int((playerEngine.volume * 100).rounded()))%)" : "Volume: \(Int((playerEngine.volume * 100).rounded()))%")
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            
            // Center: Playback, Shuttle & Frame Controls (Camera screengrab moved next to Exposure)
            PlayerTransportDeckView(
                engine: playerEngine,
                transportState: playerEngine.transportState,
                scanResults: scannerState.scanResults,
                isLightMode: isLightMode,
                onExportScreenshot: { preset in exportCurrentFrameScreenshot(preset: preset) },
                showNotesAndGlitches: false
            )
            .equatable()
            .layoutPriority(1)
            
            // Right: Balanced spacer matching left width to keep center transport deck dead-centered
            Color.clear
                .frame(maxWidth: .infinity, alignment: .trailing)
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
        withAnimation(.easeInOut(duration: 0.2)) {
            FileSystemTreeBuilder.expandAncestors(of: url, in: playerTreeNodes, collapsedIDs: &playerCollapsedFolderIDs)
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
    
    private func exportCurrentFrameScreenshot(preset initialPreset: ScreenshotPreset = .jpgMedium) {
        playerEngine.lastScreenshotPreset = initialPreset
        let isABActive = playerEngine.slotB.url != nil && (playerEngine.compareMode != .single || playerEngine.isBlinkCompareB)
        let currentTarget = playerEngine.activeTarget
        let currentSlot: SlotTarget = (currentTarget == .slotB && playerEngine.slotB.url != nil) ? .slotB : .slotA
        guard let activeURL = (currentSlot == .slotA) ? playerEngine.slotA.url : playerEngine.slotB.url else { return }
        
        var selectedPreset = initialPreset
        let baseNameA = playerEngine.slotA.url?.deletingPathExtension().lastPathComponent ?? "videoA"
        let frameA = playerEngine.currentFrame
        
        let defaultFileName: String
        let panelTitle: String
        
        if isABActive && playerEngine.compareMode != .single {
            let baseNameB = playerEngine.slotB.url?.deletingPathExtension().lastPathComponent ?? "videoB"
            let suffix: String
            switch playerEngine.compareMode {
            case .splitVertical: suffix = "_splitV"
            case .splitHorizontal: suffix = "_splitH"
            case .sideBySide: suffix = "_sideBySide"
            case .sideBySideVertical: suffix = "_sideBySideV"
            case .difference: suffix = "_diff"
            case .overlay: suffix = "_overlay"
            case .single: suffix = ""
            }
            defaultFileName = "\(baseNameA)_vs_\(baseNameB)_f\(frameA)\(suffix).\(initialPreset.fileExtension)"
            panelTitle = "Save Frame Screenshot [\(playerEngine.compareMode.rawValue)]"
        } else {
            let slotName = (playerEngine.isBlinkCompareB || currentSlot == .slotB) ? "Slot B" : "Slot A"
            let url = (slotName == "Slot B") ? (playerEngine.slotB.url ?? activeURL) : activeURL
            let baseName = url.deletingPathExtension().lastPathComponent
            let frameNum: Int
            if slotName == "Slot B" {
                let offsetSecs = Double(playerEngine.slotB.slipOffsetFrames) / max(1.0, playerEngine.slotB.fps)
                let secsB = playerEngine.isLinked ? max(0.0, CMTimeGetSeconds(playerEngine.slotA.currentTime) + offsetSecs) : CMTimeGetSeconds(playerEngine.slotB.currentTime)
                frameNum = Int(round(secsB * max(1.0, playerEngine.slotB.fps)))
            } else {
                frameNum = frameA
            }
            defaultFileName = "\(baseName)_frame_\(frameNum).\(initialPreset.fileExtension)"
            panelTitle = "Save Frame Screenshot (\(slotName))"
        }
        
        let savePanel = NSSavePanel()
        savePanel.title = panelTitle
        savePanel.prompt = "Save"
        savePanel.canCreateDirectories = true
        savePanel.nameFieldStringValue = defaultFileName
        savePanel.allowedContentTypes = [initialPreset.utType]
        
        if let parentDir = folderURL {
            savePanel.directoryURL = parentDir
        }
        
        // Accessory View with Preset Selector
        let accessoryView = NSView(frame: NSRect(x: 0, y: 0, width: 280, height: 32))
        let label = NSTextField(labelWithString: "Preset:")
        label.frame = NSRect(x: 0, y: 6, width: 60, height: 20)
        label.alignment = .right
        label.font = .systemFont(ofSize: 12)
        accessoryView.addSubview(label)
        
        let popUp = NSPopUpButton(frame: NSRect(x: 66, y: 4, width: 190, height: 24), pullsDown: false)
        for preset in ScreenshotPreset.allCases {
            popUp.addItem(withTitle: preset.rawValue)
        }
        popUp.selectItem(withTitle: initialPreset.rawValue)
        
        @MainActor
        final class FormatChangeTarget: NSObject {
            weak var panel: NSSavePanel?
            var onSelectionChanged: ((ScreenshotPreset) -> Void)?
            
            @objc func onPopUpChanged(_ sender: NSPopUpButton) {
                let idx = sender.indexOfSelectedItem
                guard idx >= 0 && idx < ScreenshotPreset.allCases.count else { return }
                let newPreset = ScreenshotPreset.allCases[idx]
                onSelectionChanged?(newPreset)
                if let panel = panel {
                    panel.allowedContentTypes = [newPreset.utType]
                    let currentName = panel.nameFieldStringValue
                    let base = (currentName as NSString).deletingPathExtension
                    panel.nameFieldStringValue = "\(base).\(newPreset.fileExtension)"
                }
            }
        }
        
        let target = FormatChangeTarget()
        target.panel = savePanel
        target.onSelectionChanged = { [weak playerEngine] newPreset in
            selectedPreset = newPreset
            playerEngine?.lastScreenshotPreset = newPreset
        }
        popUp.target = target
        popUp.action = #selector(FormatChangeTarget.onPopUpChanged(_:))
        accessoryView.addSubview(popUp)
        savePanel.accessoryView = accessoryView
        
        if savePanel.runModal() == .OK, let targetURL = savePanel.url {
            let idx = popUp.indexOfSelectedItem
            let finalPreset = (idx >= 0 && idx < ScreenshotPreset.allCases.count) ? ScreenshotPreset.allCases[idx] : selectedPreset
            playerEngine.lastScreenshotPreset = finalPreset
            Task { @MainActor in
                do {
                    guard let composited = await playerEngine.captureCompositedScreenshotImage() else {
                        throw NSError(domain: "PlayerEngine", code: -1, userInfo: [NSLocalizedDescriptionKey: "Failed to capture video frame at current playhead."])
                    }
                    let data = try playerEngine.encodeScreenshot(image: composited, preset: finalPreset)
                    try data.write(to: targetURL, options: .atomic)
                    ScreenshotSoundPlayer.shared.play()
                } catch {
                    print("[Screenshot] Export error: \(error.localizedDescription)")
                }
            }
        }
        _ = target
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
                .explain("Finder Tag: \(tag.rawValue)")
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
            .explain("Remove Finder tag")
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .background(bgPanel)
    }
    
    // MARK: - Fullscreen Video Presentation Overlays
    
    var fullscreenPlayerOverlay: some View {
        FullscreenPlayerView(
            engine: playerEngine,
            scanResults: scannerState.scanResults,
            videoFiles: videoFiles,
            isLightMode: isLightMode,
            onExit: { exitFullscreen() },
            onJumpNext: { jumpToNextGlitchFinding() },
            onJumpPrev: { jumpToPreviousGlitchFinding() },
            onAddNote: { openAddNoteModal() },
            onExportScreenshot: { preset in exportCurrentFrameScreenshot(preset: preset) }
        )
    }
    
    var cleanVideoFullscreenOverlay: some View {
        CleanVideoFullscreenView(
            engine: playerEngine,
            isLightMode: isLightMode,
            onExit: { exitFullscreen() }
        )
    }
}

// MARK: - Reusable Player Comparison Bar

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
                            .font(.system(size: StudioTheme.scaleFont(9), weight: .black, design: .monospaced))
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
                        Text("CLEAR B")
                            .font(.system(size: StudioTheme.scaleFont(9), weight: .bold, design: .monospaced))
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

struct PlayerTimecodeMenuView: View {
    @ObservedObject var playerEngine: PlayerEngine
    var accentBlue: Color
    @State private var isHovered: Bool = false
    
    var body: some View {
        Menu {
            timecodeMenuItems
        } label: {
            // Hover styling is applied per element: the live readout draws in its own host.
            HStack(spacing: 4) {
                PlayerTimecodeReadout(
                    clock: playerEngine.clock,
                    displayTimeAsFrames: playerEngine.displayTimeAsFrames,
                    totalFrames: playerEngine.totalFrames,
                    accentBlue: accentBlue,
                    isHovered: isHovered
                )
                
                Image(systemName: "chevron.down")
                    .font(.system(size: 8, weight: .bold))
                    .foregroundColor(accentBlue.opacity(0.8))
                    .opacity(isHovered ? 1.0 : 0.82)
                    .brightness(isHovered ? 0.05 : 0.0)
                    .animation(.easeInOut(duration: 0.12), value: isHovered)
            }
            .onHover { isHovered = $0 }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .contextMenu {
            timecodeMenuItems
        }
    }
    
    // Static titles: values are read at click time so the menu is not rebuilt on every frame.
    @ViewBuilder
    private var timecodeMenuItems: some View {
        Button(action: {
            let text = playerEngine.displayTimeAsFrames ? "\(playerEngine.currentFrame)" : playerEngine.currentTimecode
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(text, forType: .string)
        }) {
            Label("Copy Value", systemImage: "doc.on.doc")
        }
        Divider()
        Button(action: {
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(playerEngine.currentTimecode, forType: .string)
        }) {
            Label("Copy SMPTE Timecode", systemImage: "clock")
        }
        Button(action: {
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString("\(playerEngine.currentFrame)", forType: .string)
        }) {
            Label("Copy Frame Number", systemImage: "number")
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

/// Timecode menu readout; the live value is drawn outside SwiftUI's update cycle (see `PlaybackClockText`).
private struct PlayerTimecodeReadout: View {
    let clock: PlaybackClock
    let displayTimeAsFrames: Bool
    let totalFrames: Int
    let accentBlue: Color
    let isHovered: Bool
    
    private static let font = Font.system(size: 13, weight: .bold, design: .monospaced)
    
    var body: some View {
        if displayTimeAsFrames {
            let digitCount = max(4, String(max(totalFrames, 999)).count)
            let frameColWidth = CGFloat(digitCount) * 8.2
            
            HStack(spacing: 4) {
                PlaybackClockText(
                    clock: clock,
                    value: .frameNumber,
                    template: String(repeating: "0", count: digitCount),
                    fontSize: 13,
                    color: accentBlue,
                    alignment: .trailing,
                    hoverState: isHovered
                )
                .frame(minWidth: frameColWidth, alignment: .trailing)
                
                Text("frames")
                    .font(Self.font)
                    .foregroundColor(accentBlue)
                    .opacity(isHovered ? 1.0 : 0.82)
                    .brightness(isHovered ? 0.05 : 0.0)
                    .animation(.easeInOut(duration: 0.12), value: isHovered)
            }
        } else {
            PlaybackClockText(
                clock: clock,
                value: .timecode,
                template: "00:00:00:00",
                fontSize: 13,
                color: accentBlue,
                tracking: 0.5,
                hoverState: isHovered
            )
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



