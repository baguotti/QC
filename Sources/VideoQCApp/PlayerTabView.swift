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
            isScanning: scannerState.isScanning,
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
                scanResults: scannerState.scanResults,
                isLightMode: isLightMode,
                hoverExplanation: $hoverExplanation,
                onExportScreenshot: { preset in exportCurrentFrameScreenshot(preset: preset) },
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
            let frameNum = (slotName == "Slot B") ? Int(round(CMTimeGetSeconds(playerEngine.slotB.currentTime) * max(1.0, playerEngine.slotB.fps))) : frameA
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



