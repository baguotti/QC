import SwiftUI
import AppKit
import AVFoundation
import UniformTypeIdentifiers
import VideoQCLib

extension ContentView {
    
    // MARK: ==================== TAB 1: PLAYER ====================
    
    @ViewBuilder
    var playerTabView: some View {
        GeometryReader { mainGeo in
            let drawerWidth = NotesDrawerPanelView.width(tab: playerDrawerTab, hasSubtitles: !playerEngine.subtitleCues.isEmpty)
            let availableWidth = mainGeo.size.width - (showNotesDrawer ? drawerWidth : 0.0)
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
            themeId: "\(themeManager.currentTheme.id)_\(themeManager.currentTheme.playHex)",
            buttonZoom: themeManager.buttonZoom,
            folderURL: folderURL,
            videoFiles: videoFiles,
            playerTreeNodes: playerTreeNodes,
            playerFilterText: $playerFilterText,
            mediaKindFilter: $mediaKindFilter,
            playerCollapsedFolderIDs: $playerCollapsedFolderIDs,
            hiddenFolderIDs: hiddenFolderIDs,
            hideAllFolders: hideAllFolders,
            fileTagsMap: fileTagsMap,
            subtitleFiles: queueSubtitleFiles,
            isScanning: scannerState.isCheckRunning,
            isAutoplayEnabled: playerEngine.isAutoplayEnabled,
            drawsWaveforms: playerEngine.drawsWaveforms,
            queueVersion: queueVersion,
            tagsVersion: tagsVersion,
            slotAURL: playerEngine.activeURL ?? playerEngine.slotA.url,
            slotAResolution: playerEngine.slotA.resolution,
            slotAFps: playerEngine.slotA.mediaKind == .video ? playerEngine.slotA.fps : 0,
            slotACodec: playerEngine.slotA.codec,
            slotBURL: playerEngine.slotBURL ?? playerEngine.slotB.url,
            slotBResolution: playerEngine.slotB.resolution,
            slotBFps: playerEngine.slotB.mediaKind == .video ? playerEngine.slotB.fps : 0,
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
            onClearQueue: {
                clearQueue()
            },
            onToggleHideFolders: {
                toggleHideFolders()
            },
            onToggleAutoplay: {
                playerEngine.isAutoplayEnabled.toggle()
            },
            onToggleWaveforms: {
                playerEngine.drawsWaveforms.toggle()
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
                withAnimation(Motion.sleeve) {
                    showNotesDrawer = true
                }
            },
            onOpenNotes: { url in
                openNotesDrawer(for: url)
            },
            onSetReadAsSequence: { url, asSequence in
                setReadAsSequence(asSequence, for: url)
            },
            onSetSequenceFPS: { url, fps in
                setSequenceFPS(fps, for: url)
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
        PanelResizeHandle(width: $playerQueueWidth, range: 240...maxWidth, defaultWidth: 360, isLightMode: isLightMode,
                          help: "Drag to resize the Assets & Queue panel. Double-click to reset (360 pt).")
            .zIndex(200)
    }
    
    // MARK: - Right Panel: Program Monitor & Timeline
    private var playerProgramMonitorPanel: some View {
        VStack(spacing: 0) {
                // Monitor Header Bar
                playerMonitorHeader
                    .headerBand(palette)
                
                // Program Monitor Viewport Canvas
                GeometryReader { vpGeo in
                    ZStack(alignment: .topLeading) {
                        if playerEngine.slotA.url != nil || playerEngine.slotB.url != nil {
                            VideoViewportView(engine: playerEngine, isLightMode: isLightMode, isSuspended: fullscreenMode != .none)
                                .frame(maxWidth: .infinity, maxHeight: .infinity)
                        } else {
                            VStack(spacing: 12) {
                                Image(systemName: "play.rectangle.fill")
                                    .font(.system(size: StudioTheme.scaleFont(40)))
                                    .foregroundColor(textMuted)
                                Text("No Video Selected")
                                    .font(.ui(size: 13, weight: .semibold))
                                    .foregroundColor(textMain)
                                Text("Click a file from the queue on the left to begin inspecting.")
                                    .font(.ui(size: 11))
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
                .studioBox(background: isLightMode ? Color(white: 0.88) : Color(white: 0.16), border: borderLine)
                
                // Timeline Scrubber & Transport Controls (Rigidly locked height to prevent any layout jitter)
                VStack(spacing: 8) {
                    // Timecode, Play Info & Zoom (centered above timeline)
                    playerTimecodeBar
                        .frame(height: StudioTheme.scale(24))
                    
                    // Timeline Scrubber
                    TimelineScrubberView(engine: playerEngine, isLightMode: isLightMode)
                        .disabled(playerEngine.activeURL == nil || !playerEngine.hasTimeline)
                    
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
        // Only an asset for the loaded clip: another file's asset would make the drawer show that file instead.
        let matchedAsset = specsState.deliverableAssets.first { $0.fileURL.standardizedFileURL == standardizedActiveURL }
            ?? propertiesAsset.flatMap { $0.fileURL.standardizedFileURL == standardizedActiveURL ? $0 : nil }
        
        NotesDrawerPanelView(
            isPresented: $showNotesDrawer,
            selectedDrawerTab: $playerDrawerTab,
            notes: playerEngine.activeNotes,
            mediaName: activeName.isEmpty ? (activeURL?.lastPathComponent ?? "Deliverable") : activeName,
            mediaURL: activeURL,
            mediaAsset: matchedAsset,
            clock: playerEngine.clock,
            isLightMode: isLightMode,
            subtitleEngine: playerEngine,
            hasSubtitles: !playerEngine.subtitleCues.isEmpty,
            subtitlesDirty: playerEngine.hasUnsavedSubtitleEdits,
            newSyncedNotesCount: unseenSyncedNoteIDs.count,
            onAssignSyncProject: { projectID in
                guard let url = notesTargetURL else { return }
                Task { await NotesSync.shared.assign(url, to: projectID) }
            },
            onSeekToFrame: { frame in
                seekToNoteFrame(frame)
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
            onDeleteNotes: { ids in
                deleteNotes(ids: ids)
            },
            onUpdateNote: { note in
                updateNote(note)
            },
            onExportNotes: {
                exportQCNotes()
            },
            onImportNotes: {
                importQCNotes()
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
            SleeveToggle(side: .leading, isOpen: showPlayerQueue, isLightMode: isLightMode,
                         help: showPlayerQueue ? "Hide Assets & Queue panel (⌘⇧←)." : "Reveal Assets & Queue panel (⌘⇧←).") {
                showPlayerQueue.toggle()
            }

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
                    Text(playerEngine.activeFileName.isEmpty ? "No Active Asset" : playerEngine.activeFileName)
                        .font(.ui(size: 12, weight: .semibold))
                        .foregroundColor(textMain)
                        .lineLimit(1)
                    
                    if !playerEngine.activeResolution.isEmpty {
                        Text(playerEngine.slotA.infoLine)
                            .font(.ui(size: 10, weight: .semibold))
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
                SleeveToggle(side: .trailing, isOpen: showNotesDrawer, isLightMode: isLightMode, isEnabled: playerEngine.activeURL != nil,
                             help: showNotesDrawer ? "Collapse review sleeve (⌘⇧→)." : "Bring out review sleeve (Media Info & Notes) (⌘⇧→).") {
                    if !showNotesDrawer {
                        playerDrawerTab = currentFileHasNotes ? .notes : .mediaInfo
                    }
                    showNotesDrawer.toggle()
                }
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
    /// `compact`: icons only (labels move to the tooltip) when the timecode bar is too narrow for them.
    private func playerNotesGroup(compact: Bool) -> some View {
        HStack(spacing: StudioTheme.scale(2)) {
            Button(action: { openAddNoteModal() }) {
                HStack(spacing: StudioTheme.scale(3)) {
                    Image(systemName: "plus")
                        .font(.system(size: StudioTheme.scaleFont(9), weight: .bold))
                    if !compact {
                        Text("Note")
                            .font(.ui(size: 10, weight: .semibold))
                    }
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
                    withAnimation(Motion.fade) {
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
                        if hasNotes || !compact {
                        SlotText(
                            hasNotes ? "\(notesCount)" : "Notes",
                            mode: hasNotes ? .character : .word,
                            direction: .up,
                            font: .ui(size: 10, weight: .semibold),
                            foregroundColor: isNotesActive ? accentBlue : (hasNotes ? textMain : textMuted)
                        )
                        }
                    }
                    .frame(height: StudioTheme.scale(24))
                    .padding(.horizontal, 4)
                    .foregroundColor(isNotesActive ? accentBlue : (hasNotes ? textMain : textMuted))
                    .contentShape(Rectangle())
                }
                .buttonStyle(TransportIconButtonStyle())
                .disabled(playerEngine.activeURL == nil)
                .explain(hasNotes ? "Toggle Review Notes drawer (\(notesCount) note\(notesCount == 1 ? "" : "s"))." : "Toggle Review Notes drawer.")
                
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
                    .font(.system(size: StudioTheme.scaleFont(10), weight: .bold))
                Text(text)
                    .font(.ui(size: 11, weight: .semibold))
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
            
            Text("Line")
                .font(.ui(size: 10, weight: .semibold))
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
    /// Sends the frame on screen to the developer when Line Check missed a line.
    private func missedLineButton(compact: Bool) -> some View {
        let hasPicture = playerEngine.activeURL != nil
        return Button(action: {
            playerEngine.pause()
            showMissedLineConfirm = true
        }) {
            HStack(spacing: 4) {
                if isSendingMissedLine {
                    ProgressView().controlSize(.mini)
                } else {
                    Image(systemName: "paperplane.fill")
                        .font(.system(size: StudioTheme.scaleFont(9), weight: .bold))
                }
                if !compact {
                    Text("Missed Line")
                        .font(.ui(size: 10, weight: .semibold))
                }
            }
            .frame(height: StudioTheme.scale(24))
            .padding(.horizontal, 5)
            .foregroundColor(hasPicture ? textMain.opacity(0.85) : textMuted)
            .contentShape(Rectangle())
        }
        .buttonStyle(TransportIconButtonStyle())
        .disabled(!hasPicture || isSendingMissedLine)
        .explain("Spotted a line Line Check didn't flag? Sends this frame (original pixels) and its details to the developer to improve the detector. Asks before sending.")
        .popover(isPresented: $showMissedLineConfirm, arrowEdge: .top) {
            missedLineConfirmView
        }
    }
    
    /// Confirmation before a missed-line report leaves the Mac: what is sent, about which frame, and to whom.
    private var missedLineConfirmView: some View {
        let slotState = notesTargetIsSlotB ? playerEngine.slotB : playerEngine.slotA
        let fileName = slotState.sequence?.displayName ?? notesTargetURL?.lastPathComponent ?? "This clip"
        return VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 8) {
                Image(systemName: "paperplane.fill")
                    .font(.system(size: StudioTheme.scaleFont(13), weight: .bold))
                    .foregroundColor(accentBlue)
                Text("Report a Missed Line")
                    .font(.ui(size: 13, weight: .semibold))
                    .foregroundColor(textMain)
            }
            if let frame = slotState.lastDecodedFrame {
                Image(decorative: frame, scale: 1)
                    .resizable()
                    .aspectRatio(contentMode: .fit)
                    .frame(maxWidth: .infinity, maxHeight: 150)
                    .clipShape(RoundedRectangle(cornerRadius: Radius.control))
                    .overlay(RoundedRectangle(cornerRadius: Radius.control).stroke(borderLine, lineWidth: 1))
            }
            VStack(alignment: .leading, spacing: 6) {
                missedLineInfoRow("Clip", fileName)
                missedLineInfoRow("Frame", "\(playerEngine.currentTimecode)  ·  #\(playerEngine.currentFrame)\(notesTargetIsSlotB ? "  ·  slot B" : "")")
                missedLineInfoRow("Sends", "This frame (original pixels, no EV), clip details, Line Check settings and results, your name")
                missedLineInfoRow("To", "The QCpie developer, to improve line detection")
            }
            TextField("Add a comment (optional): where the line is, what it looks like…", text: $missedLineComment, axis: .vertical)
                .textFieldStyle(.roundedBorder)
                .font(.ui(size: 11))
                .lineLimit(2...5)
                .explain("Sent with the report, above the automatic details.")
            HStack(spacing: 8) {
                Spacer()
                Button("Cancel") { showMissedLineConfirm = false }
                    .keyboardShortcut(.cancelAction)
                Button("Send Report") {
                    showMissedLineConfirm = false
                    // The popover closes first, so the alert isn't drawn over it.
                    DispatchQueue.main.async { confirmMissedLineReport() }
                }
            }
        }
        .padding(16)
        .frame(width: 340)
    }
    
    /// Last check before the frame leaves the Mac. Return and Esc cancel; only a click on Send sends.
    private func confirmMissedLineReport() {
        let alert = NSAlert()
        alert.messageText = "Send this frame to the QCpie developer?"
        alert.informativeText = "\(playerEngine.activeURL?.lastPathComponent ?? "This clip") at \(playerEngine.currentTimecode), with its details, your Line Check settings and your name."
        alert.addButton(withTitle: "Cancel").keyEquivalent = "\r"
        alert.addButton(withTitle: "Send Report").keyEquivalent = ""
        guard alert.runModal() == .alertSecondButtonReturn else { return }
        reportMissedLine()
    }

    private func missedLineInfoRow(_ label: String, _ value: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            Text(label)
                .font(.ui(size: 10, weight: .semibold))
                .foregroundColor(textMuted)
                .frame(width: 44, alignment: .leading)
            Text(value)
                .font(.system(size: StudioTheme.scaleFont(11)))
                .foregroundColor(textMain)
                .fixedSize(horizontal: false, vertical: true)
        }
    }
    
    private func playerTagsButton(compact: Bool) -> some View {
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
                if !compact {
                    Text("Tags")
                        .font(.ui(size: 10, weight: .semibold))
                }
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
    
    /// The In–Out range (I / O): its length, with Export and Clear.
    private var inOutChip: some View {
        let fps = max(1, playerEngine.activeFps)
        let start = playerEngine.inFrame ?? 0
        let end = playerEngine.outFrame ?? max(0, playerEngine.totalFrames - 1)
        let frames = max(0, end - start + 1)
        return Menu {
            Button("Export In–Out…") { exportInOutRange() }
            Button("Go to In (⇧I)") { playerEngine.goToIn() }
            Button("Go to Out (⇧O)") { playerEngine.goToOut() }
            Divider()
            Button("Clear In and Out (⌥X)") { playerEngine.clearInOut() }
        } label: {
            HStack(spacing: 4) {
                Image(systemName: "rectangle.dashed")
                    .font(.system(size: StudioTheme.scaleFont(9), weight: .semibold))
                Text(TimecodeFormatter.format(frameIndex: frames, fps: fps))
                    .font(.system(size: StudioTheme.scaleFont(11), weight: .medium, design: .monospaced))
            }
            .foregroundColor(accentBlue)
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
        .explain("In–Out range (I / O). With loop on (⌘L), playback loops inside it. Click to export it or clear it (⌥X).")
    }

    /// Saves slot A's In–Out range as its own file: the original samples copied (no re-encode) when the format allows,
    /// else the highest-quality encode.
    func exportInOutRange() {
        guard let url = playerEngine.slotA.url, let range = playerEngine.inOutTimeRange,
              playerEngine.slotA.sequence == nil else {
            showToast("Export works on video and audio files")
            return
        }
        playerEngine.pause()
        let panel = NSSavePanel()
        let isAudio = playerEngine.slotA.mediaKind == .audio
        let ext = isAudio ? "m4a" : url.pathExtension.lowercased() == "mp4" ? "mp4" : "mov"
        panel.nameFieldStringValue = url.deletingPathExtension().lastPathComponent + "_\(playerEngine.inFrame ?? 0)-\(playerEngine.outFrame ?? playerEngine.totalFrames - 1).\(ext)"
        panel.directoryURL = url.deletingLastPathComponent()
        panel.allowedContentTypes = [UTType(filenameExtension: ext) ?? .movie]
        guard panel.runModal() == .OK, let target = panel.url else { return }
        // The save panel allows replacing any file: never the clip being cut.
        // Same file by identity, not path text: on a case-insensitive volume "clip.mov" typed for "Clip.mov" is the source.
        func identity(_ u: URL) -> NSObject? { (try? u.resourceValues(forKeys: [.fileResourceIdentifierKey]))?.fileResourceIdentifier as? NSObject }
        let sameFile = target.standardizedFileURL.resolvingSymlinksInPath() == url.standardizedFileURL.resolvingSymlinksInPath()
            || (identity(target).map { $0.isEqual(identity(url)) } ?? false)
        guard !sameFile else {
            showToast("Choose another name: that's the clip itself")
            return
        }
        showToast("Exporting \(target.lastPathComponent)…")
        Task {
            do {
                try await InOutExporter.export(source: url, range: range, to: target)
                showToast("Exported \(target.lastPathComponent)")
                NSWorkspace.shared.activateFileViewerSelecting([target])
            } catch {
                showToast("Export failed: \(error.localizedDescription)")
            }
        }
    }

    // 7. Duration / Total Frames Label
    private var playerDurationLabel: some View {
        Text(playerEngine.displayTimeAsFrames ? "\(playerEngine.totalFrames) frames" : playerEngine.durationTimecode)
            .font(.system(size: StudioTheme.scaleFont(11), weight: .medium, design: .monospaced))
            .foregroundColor(textMuted)
            .lineLimit(1)
    }
    
    private func playerReviewTools(compact: Bool) -> some View {
        HStack(spacing: StudioTheme.scale(10)) {
            playerLineGlitchGroup
            Rectangle()
                .fill(borderLine.opacity(0.45))
                .frame(width: 1, height: 14)
            playerTagsButton(compact: compact)
            Rectangle()
                .fill(borderLine.opacity(0.45))
                .frame(width: 1, height: 14)
            missedLineButton(compact: compact)
        }
    }
    
    // MARK: - Timecode Bar (above timeline)
    
    private var playerTimecodeBar: some View {
        ZStack(alignment: .center) {
            // Absolute Center: Shuttle Speed Indicator (hidden on 1x play and pause)
            playerCenterShuttleBadge
            
            // Four equal columns: the review controls mirror each other around the exact centre (shuttle badge),
            // timecode + zoom sit left, duration right, at any window width.
            HStack(spacing: 0) {
                HStack(spacing: 12) {
                    playerTimecodeMenu
                    Rectangle()
                        .fill(borderLine.opacity(0.45))
                        .frame(width: 1, height: 14)
                    playerZoomMenu
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                
                ViewThatFits(in: .horizontal) {
                    playerNotesGroup(compact: false).fixedSize()
                    playerNotesGroup(compact: true).fixedSize()
                }
                .frame(maxWidth: .infinity, alignment: .trailing)
                
                // Clearance for the centred shuttle badge.
                Color.clear
                    .frame(width: 72, height: 24)
                    .allowsHitTesting(false)
                
                ViewThatFits(in: .horizontal) {
                    playerReviewTools(compact: false).fixedSize()
                    playerReviewTools(compact: true).fixedSize()
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                
                HStack(spacing: 8) {
                    if playerEngine.inFrame != nil || playerEngine.outFrame != nil { inOutChip }
                    playerDurationLabel
                }
                .frame(maxWidth: .infinity, alignment: .trailing)
            }
        }
        .frame(height: StudioTheme.scale(24))
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
    
    var filteredPlayerFiles: [URL] {
        let treeOrder = FileSystemTreeBuilder.orderedVideoURLs(from: playerTreeNodes)
        let baseFiles = treeOrder.isEmpty ? videoFiles : treeOrder
        let mask = MediaKindFilter.effectiveMask(mediaKindFilter, present: MediaKindFilter.presentMask(of: videoFiles))
        let query = playerFilterText.trimmingCharacters(in: .whitespacesAndNewlines)
        if query.isEmpty && mask == MediaKindFilter.all {
            return baseFiles
        }
        return baseFiles.filter {
            MediaKindFilter.allows($0, mask: mask) && (query.isEmpty || $0.lastPathComponent.localizedCaseInsensitiveContains(query))
        }
    }
    
    func revealPlayerFolderContaining(url: URL) {
        withAnimation(Motion.list) {
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
        // The frame is captured once the save panel closes: playing on meanwhile saved a later frame under this one's name.
        playerEngine.pause()
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
                // Times sit at frame centres ((n + 0.5) / fps): floor, as the Player numbers frames (round gave n + 1).
                frameNum = secsB.isFinite ? max(0, Int(floor(secsB * max(1.0, playerEngine.slotB.fps) + 1e-4))) : 0
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
                    showToast("Couldn't save the screenshot: \(error.localizedDescription)")
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
                                .font(.system(size: StudioTheme.scaleFont(9), weight: .black))
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
                    .font(.system(size: StudioTheme.scaleFont(16)))
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
