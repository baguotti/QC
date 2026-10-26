import SwiftUI
import UniformTypeIdentifiers
import VideoQCLib

extension ContentView {
    
    // MARK: ==================== TAB 2: SPECS ====================
    
    var deliverablesTabView: some View {
        HStack(spacing: 0) {
            // Left Control Panel
            if showSpecsControlPanel {
                VStack(alignment: .leading, spacing: 18) {
                    // Unified Asset Picker
                    deliveryAssetsSection(forTab: .specs)
                    
                    // Search Filter (like in Tab 1)
                    if !specsState.deliverableAssets.isEmpty {
                        specsSearchFilterBar
                    }
                    
                    // 02 SPECS ACTIONS: View controls, Audit & Exports
                    specsActionsSection
                    
                    Spacer(minLength: 0)
                }
                .padding(22)
                .frame(width: ContentView.specsPanelWidth)
                .background(bgPanel)
                .overlay(
                    Rectangle()
                        .fill(borderLine)
                        .frame(width: 1),
                    alignment: .trailing
                )
                .transition(.move(edge: .leading).combined(with: .opacity))
            }
            
            // Right Panel: Specs Table / Stats
            VStack(alignment: .leading, spacing: 0) {
                // Specs Header Bar with Sleeve Toggle
                HStack(spacing: 12) {
                    Button(action: {
                        withAnimation(.spring(response: 0.32, dampingFraction: 0.78)) {
                            showSpecsControlPanel.toggle()
                        }
                    }) {
                        Image(systemName: showSpecsControlPanel ? "chevron.left" : "chevron.right")
                            .font(.system(size: StudioTheme.scaleFont(11), weight: .bold))
                            .frame(width: StudioTheme.scale(24), height: StudioTheme.scale(26))
                            .foregroundColor(textMain)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(TransportIconButtonStyle())
                    .explain(showSpecsControlPanel ? "Hide Specs Control Panel (⌘⇧←)." : "Reveal Specs Control Panel (⌘⇧←).")
                    
                    Text("Specs Audit")
                        .font(.ui(size: 11, weight: .semibold))
                        .foregroundColor(textMuted)
                    
                    Spacer()
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 10)
                .panelHeaderBar(background: bgCardHeader, divider: borderLine)
                
                if specsState.isInspectingDeliverables {
                    VStack(alignment: .center, spacing: 12) {
                        Spacer()
                        Text("Inspecting deliverables specs...")
                            .font(.ui(size: 18, weight: .semibold))
                        ProgressView()
                            .scaleEffect(1.2)
                        Spacer()
                    }
                    .frame(maxWidth: .infinity)
                    .padding(28)
                } else if specsState.deliverableAssets.isEmpty {
                    emptyDeliverablesStateView
                } else {
                    deliverablesResultsView
                }
            }
            .frame(minWidth: 540, maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            .background(bgMain)
            .sheet(isPresented: $specsState.showSubtitleCrossCheck) {
                if let report = specsState.subtitleCrossCheck {
                    SubtitleCrossCheckSheet(
                        report: report,
                        isLightMode: isLightMode,
                        onChange: { specsState.subtitleCrossCheck = $0 },
                        onOpen: { video, seconds in
                            specsState.showSubtitleCrossCheck = false
                            openSubtitleDifference(video: video, seconds: seconds)
                        },
                        onClose: { specsState.showSubtitleCrossCheck = false }
                    )
                }
            }
        }
    }
    
    /// Opens a cross-check result: load the file in the player at that line with the Subtitles panel open.
    func openSubtitleDifference(video: URL, seconds: Double) {
        let fps = specsState.deliverableAssets.first { $0.fileURL.standardizedFileURL == video.standardizedFileURL }.flatMap { $0.fps > 0 ? $0.fps : nil } ?? 25
        withAnimation(.spring(response: 0.22, dampingFraction: 0.85)) {
            selectedTab = .player
        }
        playerEngine.loadVideo(url: video, into: .slotA, initialSeekFrame: max(0, Int(ceil(seconds * max(1, fps) - 0.5))))
        playerDrawerTab = .subtitles
        showNotesDrawer = true
    }
    
    // MARK: - Left Panel: Search Filter Bar (like in Tab 1)
    
    private var specsSearchFilterBar: some View {
        HStack(spacing: 6) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: StudioTheme.scaleFont(10)))
                .foregroundColor(textMuted)
            
            ZStack(alignment: .leading) {
                if specsState.specsFilterText.isEmpty {
                    Text("Filter assets...")
                        .font(.ui(size: 11, weight: .semibold))
                        .foregroundColor(textMuted)
                        .allowsHitTesting(false)
                }
                TextField("", text: $specsState.specsFilterText)
                    .font(.ui(size: 11, weight: .medium))
                    .textFieldStyle(.plain)
                    .foregroundColor(textMain)
                    .padding(.horizontal, 4)
            }
            
            if !specsState.specsFilterText.isEmpty {
                Button(action: { specsState.specsFilterText = "" }) {
                    Image(systemName: "xmark.circle.fill")
                        .font(.system(size: StudioTheme.scaleFont(10)))
                        .foregroundColor(textMuted)
                }
                .buttonStyle(.plain)
            }
            
            let present = specsPresentKinds
            if present.nonzeroBitCount > 1 {
                MediaKindFilterChips(mask: $mediaKindFilter, present: present, isLightMode: isLightMode)
            }
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 6)
        .studioBox(background: bgSubtle, border: borderLine)
    }
    
    // MARK: - Left Panel: 02 SPECS ACTIONS
    
    private var specsActionsSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            sectionHeader("Specs Actions")
            
            // Actions & Export Controls
            VStack(spacing: 6) {
                // Loudness Check (BS.1770 loudness, true peak, LRA, channel checks) against the chosen target
                VStack(spacing: 4) {
                    Button(action: {
                        if specsState.isAnalyzingAudioLevels {
                            specsState.cancelAudioAnalysis()
                        } else {
                            specsState.analyzeAudioLevels()
                        }
                    }) {
                        HStack(spacing: 6) {
                            if specsState.isAnalyzingAudioLevels {
                                ProgressView()
                                    .controlSize(.mini)
                                    .scaleEffect(0.65)
                                    .frame(width: 10, height: 10)
                                Text("Measuring Loudness (\(specsState.analyzedAudioCount)/\(specsState.totalAudioCount))")
                                    .font(.ui(size: 9.5, weight: .semibold))
                                    .foregroundColor(accentBlue)
                                Spacer()
                                Image(systemName: "xmark.circle.fill")
                                    .font(.system(size: StudioTheme.scaleFont(9), weight: .bold))
                                    .foregroundColor(textMuted)
                            } else {
                                Image(systemName: "waveform")
                                    .font(.system(size: StudioTheme.scaleFont(8.5), weight: .bold))
                                Text(hasPendingAudioAnalysis ? "Check Loudness" : "Recheck Loudness")
                                    .font(.ui(size: 9.5, weight: .semibold))
                                Spacer()
                            }
                        }
                        .frame(maxWidth: .infinity, alignment: .center)
                        .frame(height: 28)
                        .padding(.horizontal, 8)
                        .foregroundColor(specsState.deliverableAssets.isEmpty ? textMuted : (hasPendingAudioAnalysis ? textMain : textSubtle))
                        .studioBox(
                            background: hasPendingAudioAnalysis ? accentBlue.opacity(0.12) : bgSubtle,
                            border: hasPendingAudioAnalysis ? accentBlue.opacity(0.5) : borderLine
                        )
                    }
                    .buttonStyle(.plain)
                    .disabled(specsState.deliverableAssets.isEmpty)
                    .explain("Measures loudness (LUFS), true peak, loudness range and channel problems (silent channel, out of phase, dual mono) per ITU-R BS.1770-4, and checks them against the target.")

                    loudnessTargetMenu
                }

                // End Frame Check (on demand: one decoded frame per file)
                Button(action: {
                    if specsState.isCheckingEndFrames { specsState.cancelEndFrameCheck() } else { specsState.checkEndFrames() }
                }) {
                    HStack(spacing: 6) {
                        if specsState.isCheckingEndFrames {
                            ProgressView().controlSize(.mini).scaleEffect(0.65).frame(width: 10, height: 10)
                            Text("Checking End Frames (\(specsState.checkedEndFrameCount)/\(specsState.totalEndFrameCount))")
                                .font(.ui(size: 9.5, weight: .semibold))
                                .foregroundColor(accentBlue)
                            Spacer()
                            Image(systemName: "xmark.circle.fill").font(.system(size: StudioTheme.scaleFont(9), weight: .bold)).foregroundColor(textMuted)
                        } else {
                            Image(systemName: "rectangle.lefthalf.inset.filled.arrow.left")
                                .font(.system(size: StudioTheme.scaleFont(8.5), weight: .bold))
                            Text(hasPendingEndFrameCheck ? "Check End Frames" : "Recheck End Frames")
                                .font(.ui(size: 9.5, weight: .semibold))
                            Spacer()
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .center)
                    .frame(height: 28)
                    .padding(.horizontal, 8)
                    .foregroundColor(specsState.deliverableAssets.isEmpty ? textMuted : (hasPendingEndFrameCheck ? textMain : textSubtle))
                    .studioBox(background: hasPendingEndFrameCheck ? accentBlue.opacity(0.12) : bgSubtle,
                               border: hasPendingEndFrameCheck ? accentBlue.opacity(0.5) : borderLine)
                }
                .buttonStyle(.plain)
                .disabled(specsState.deliverableAssets.isEmpty)
                .explain("Checks whether each video ends on a pure black frame (decodes only the last frame of each file).")
                
                // Subtitle Cross-Check (selection with 2+ files, otherwise the whole list)
                let crossCheckTargets = subtitleCrossCheckTargets
                Button(action: { crossCheckSubtitles(crossCheckTargets) }) {
                    HStack(spacing: 6) {
                        if specsState.isCrossCheckingSubtitles {
                            ProgressView()
                                .controlSize(.mini)
                                .scaleEffect(0.65)
                                .frame(width: 10, height: 10)
                        } else {
                            CCBadge(size: 8.5)
                        }
                        Text("Cross-Check Subtitles")
                            .font(.ui(size: 9.5, weight: .semibold))
                        Spacer()
                        Text(crossCheckTargets.count >= 2 ? "\(crossCheckTargets.count) files" : "Need 2+ SRT")
                            .font(.ui(size: 7.5, weight: .semibold))
                            .foregroundColor(crossCheckTargets.count >= 2 ? accentBlue : textMuted)
                            .padding(.horizontal, 4)
                            .padding(.vertical, 1.5)
                            .background(borderLine)
                            .cornerRadius(2)
                    }
                    .frame(maxWidth: .infinity, alignment: .center)
                    .frame(height: 28)
                    .padding(.horizontal, 8)
                    .foregroundColor(crossCheckTargets.count >= 2 ? textMain : textMuted)
                    .studioBox(background: bgSubtle, border: borderLine)
                }
                .buttonStyle(.plain)
                .disabled(crossCheckTargets.count < 2 || specsState.isCrossCheckingSubtitles)
                .explain("Compares the .srt of the selected files (⌘/⇧-click to select; all files if none selected) and lists any differences.")
                
                // Export Row: SHEETS | SAVE CSV | OPEN HTML (All on one line)
                HStack(spacing: 6) {
                    // Google Sheets
                    Button(action: {
                        if !specsState.deliverableAssets.isEmpty {
                            openDeliverablesInGoogleSheets()
                        }
                    }) {
                        HStack(spacing: 4) {
                            Image(systemName: "arrow.up.right.square")
                                .font(.system(size: StudioTheme.scaleFont(8.5), weight: .bold))
                            Text("Sheets")
                                .font(.ui(size: 9.5, weight: .semibold))
                                .lineLimit(1)
                                .minimumScaleFactor(0.8)
                        }
                        .frame(maxWidth: .infinity, alignment: .center)
                        .frame(height: 28)
                        .foregroundColor(specsState.deliverableAssets.isEmpty ? textMuted : textMain)
                    }
                    .buttonStyle(TransportIconButtonStyle())
                    .disabled(specsState.deliverableAssets.isEmpty)
                    .explain("Copies specs as spreadsheet data and opens Google Sheets ready to paste (⌘V).")
                    
                    // Save CSV
                    Button(action: {
                        if !specsState.deliverableAssets.isEmpty {
                            exportDeliverablesManifest()
                        }
                    }) {
                        HStack(spacing: 4) {
                            Image(systemName: "doc.text")
                                .font(.system(size: StudioTheme.scaleFont(8.5), weight: .bold))
                            Text("Save CSV")
                                .font(.ui(size: 9.5, weight: .semibold))
                                .lineLimit(1)
                                .minimumScaleFactor(0.8)
                        }
                        .frame(maxWidth: .infinity, alignment: .center)
                        .frame(height: 28)
                        .foregroundColor(specsState.deliverableAssets.isEmpty ? textMuted : textMain)
                    }
                    .buttonStyle(TransportIconButtonStyle())
                    .disabled(specsState.deliverableAssets.isEmpty)
                    .explain("Saves the deliverables metadata table to a local CSV file.")
                    
                    // Open HTML
                    Button(action: {
                        if !specsState.deliverableAssets.isEmpty {
                            openManifestHTML()
                        }
                    }) {
                        HStack(spacing: 4) {
                            Image(systemName: "safari")
                                .font(.system(size: StudioTheme.scaleFont(8.5), weight: .bold))
                            Text("Open HTML")
                                .font(.ui(size: 9.5, weight: .semibold))
                                .lineLimit(1)
                                .minimumScaleFactor(0.8)
                        }
                        .frame(maxWidth: .infinity, alignment: .center)
                        .frame(height: 28)
                        .foregroundColor(specsState.deliverableAssets.isEmpty ? textMuted : textMain)
                    }
                    .buttonStyle(TransportIconButtonStyle())
                    .disabled(specsState.deliverableAssets.isEmpty)
                    .explain("Generates and opens a formatted HTML delivery specs sheet in browser.")
                }
                
                // Reveal in Finder
                if let firstURL = specsState.deliverableAssets.first?.fileURL {
                    Button(action: {
                        NSWorkspace.shared.activateFileViewerSelecting([specsState.selectedDeliverableURL ?? firstURL])
                    }) {
                        HStack(spacing: 5) {
                            Image(systemName: "folder")
                                .font(.system(size: StudioTheme.scaleFont(9), weight: .bold))
                            Text("Reveal in Finder")
                                .font(.ui(size: 10, weight: .semibold))
                        }
                        .frame(maxWidth: .infinity, alignment: .center)
                        .frame(height: 28)
                        .foregroundColor(textMain)
                    }
                    .buttonStyle(TransportIconButtonStyle())
                    .explain("Locates and highlights the selected or first asset in macOS Finder.")
                }
            }
            
            // Clear Button
            if !specsState.deliverableAssets.isEmpty {
                Button(action: {
                    specsState.cancelAudioAnalysis()
                    specsState.deliverableAssets = []
                    specsState.selectedDeliverableURL = nil
                }) {
                    HStack(spacing: 4) {
                        Image(systemName: "xmark")
                            .font(.system(size: StudioTheme.scaleFont(8), weight: .bold))
                        Text("Clear List")
                            .font(.ui(size: 9, weight: .semibold))
                    }
                    .foregroundColor(textMuted)
                    .frame(maxWidth: .infinity, alignment: .center)
                    .padding(.top, 4)
                }
                .buttonStyle(.plain)
                .explain("Removes all video assets from the inspection table.")
            }
        }
    }
    
    var emptyDeliverablesStateView: some View {
        VStack(alignment: .leading, spacing: 18) {
            Spacer()
            
            Text("Ready to Inspect Deliverables")
                .font(.system(size: StudioTheme.scaleFont(26), weight: .semibold))
                .foregroundColor(textMain)
            
            Text("Choose a delivery folder or video files on the left to generate a specs audit.\nShows exact timecode lengths, aspect ratios, resolutions, frame rates and sizes.")
                .font(.ui(size: 13))
                .foregroundColor(textMuted)
                .lineSpacing(4)
            
            Spacer()
        }
        .padding(40)
    }
    
    var deliverablesResultsView: some View {
        let displayAssets = filteredDeliverableAssets
        let totalBytes = displayAssets.reduce(Int64(0)) { $0 + $1.fileSizeBytes }
        let totalSeconds = displayAssets.reduce(0.0) { $0 + $1.durationSeconds }
        let mismatchCount = displayAssets.filter { $0.validation.hasAnyMismatch && !specsState.isMismatchDismissed(for: $0.fileURL) }.count
        let target = loudnessTarget
        let measured = displayAssets.compactMap(\.loudness)
        let loudnessFails = measured.filter { target.evaluate($0).verdict == .fail }.count
        
        return VStack(alignment: .leading, spacing: 20) {
            // Header: Clean audit status
            VStack(alignment: .leading, spacing: 2) {
                Text("Audit Complete")
                    .font(.system(size: StudioTheme.scaleFont(22), weight: .semibold))
                    .foregroundColor(textMain)
                if specsState.specsFilterText.isEmpty {
                    Text("\(specsState.deliverableAssets.count) assets analyzed")
                        .font(.ui(size: 11, weight: .semibold))
                        .foregroundColor(textMuted)
                } else {
                    Text("\(displayAssets.count) of \(specsState.deliverableAssets.count) assets (filtered)")
                        .font(.ui(size: 11, weight: .semibold))
                        .foregroundColor(accentBlue)
                }
            }
            
            // Quick stats on their own row (never squeezed by the table controls), table controls under them.
            VStack(alignment: .leading, spacing: 14) {
                HStack(spacing: 12) {
                    statBox(title: specsState.specsFilterText.isEmpty ? "Total Assets" : "Filtered Assets", val: String(format: "%02d", displayAssets.count))
                    statBox(title: "Name Mismatches", val: String(format: "%02d", mismatchCount), isRed: mismatchCount > 0, isPositive: mismatchCount == 0 && !displayAssets.isEmpty)
                    if !measured.isEmpty {
                        statBox(title: "Loudness Fails (\(target.name))", val: String(format: "%02d", loudnessFails), isRed: loudnessFails > 0, isPositive: loudnessFails == 0)
                    }
                    statBox(title: "Total Runtime", val: TimecodeFormatter.format(frameIndex: Int(round(totalSeconds * 25.0)), fps: 25.0))
                    statBox(title: "Total Batch Size", val: DeliverablesInspector.formatFileSize(bytes: totalBytes))
                }
                
                // Table controls
                HStack(spacing: 6) {
                    // Button 1: Fit / Reset Name
                    Button(action: { autoFitFileNameColumnWidth() }) {
                        HStack(spacing: 4) {
                            Image(systemName: isFileNameExpanded ? "arrow.right.and.line.vertical.and.arrow.left" : "arrow.left.and.line.vertical.and.arrow.right")
                                .font(.system(size: StudioTheme.scaleFont(8.5), weight: .bold))
                            Text(isFileNameExpanded ? "Reset Name" : "Fit Name")
                                .font(.ui(size: 9.5, weight: .semibold))
                        }
                        .padding(.horizontal, 8)
                        .frame(height: 24)
                        .contentShape(Rectangle())
                        .foregroundColor(isFileNameExpanded ? textMain : (specsState.deliverableAssets.isEmpty ? textMuted : textSubtle))
                    }
                    .buttonStyle(TransportIconButtonStyle())
                    .disabled(specsState.deliverableAssets.isEmpty)
                    .fixedSize()
                    .explain(isFileNameExpanded ? "Reset File Name column width back to default (220px)." : "Auto-fit File Name column to fit longest filename without truncation.")
                    
                    // Button 2: Folders (Hide/Show like Tab 1)
                    let isFoldersHidden = hideAllFolders || !hiddenFolderIDs.isEmpty
                    let canToggleFolders = hasDeliverablesSubfolders
                    Button(action: toggleHideFolders) {
                        HStack(spacing: 4) {
                            Image(systemName: isFoldersHidden ? "folder" : "folder.badge.minus")
                                .font(.system(size: StudioTheme.scaleFont(8.5), weight: .bold))
                            SlotText(
                                isFoldersHidden ? "Show" : "Hide",
                                mode: .word,
                                direction: .up,
                                font: .ui(size: 9.5, weight: .semibold),
                                foregroundColor: canToggleFolders ? (isFoldersHidden ? accentBlue : textMain) : textSubtle,
                                tracking: 0.3,
                                stagger: 0.018,
                                rollDistance: 9,
                                trigger: isFoldersHidden
                            )
                        }
                        .padding(.horizontal, 8)
                        .frame(height: 24)
                        .contentShape(Rectangle())
                        .foregroundColor(canToggleFolders ? (isFoldersHidden ? accentBlue : textMain) : textSubtle)
                    }
                    .buttonStyle(.plain)
                    .disabled(!canToggleFolders)
                    .fixedSize()
                    .contextMenu {
                        Button(action: toggleHideFolders) {
                            Label(isFoldersHidden ? "Show Folder Groups" : "Hide Folder Groups (Flat List)",
                                  systemImage: isFoldersHidden ? "folder.badge.plus" : "list.bullet")
                        }
                        if !isFoldersHidden && hasDeliverablesSubfolders {
                            Divider()
                            Button(action: toggleAllDeliverablesFolders) {
                                Label(specsState.deliverablesCollapsedFolderIDs.isEmpty ? "Collapse All Folders" : "Expand All Folders",
                                      systemImage: specsState.deliverablesCollapsedFolderIDs.isEmpty ? "chevron.down.square" : "chevron.right.square")
                            }
                        }
                    }
                    .explain(isFoldersHidden ? "Show all folder headers in asset lists." : "Hide folder headers and display assets in a flat list.")
                    
                    // Button 3: List / Thumbs (Direct Toggle + Chevron Popover)
                    HStack(spacing: 0) {
                        Button(action: {
                            withAnimation(.easeInOut(duration: 0.15)) {
                                specsDisplayMode = (specsDisplayMode == "thumbnail" ? "inline" : "thumbnail")
                            }
                        }) {
                            HStack(spacing: 4) {
                                Image(systemName: specsDisplayMode == "thumbnail" ? "square.grid.2x2" : "list.bullet")
                                    .font(.system(size: StudioTheme.scaleFont(8.5), weight: .bold))
                                Text(specsDisplayMode == "thumbnail" ? "Thumbs" : "List")
                                    .font(.ui(size: 9.5, weight: .semibold))
                            }
                            .padding(.horizontal, 9)
                            .frame(height: 24)
                            .contentShape(Rectangle())
                            .foregroundColor(textMain)
                        }
                        .buttonStyle(.plain)
                        .explain("Click to toggle between List and Thumbnail view.")
                        
                        Rectangle()
                            .fill(borderLine)
                            .frame(width: 1, height: 14)
                        
                        Button(action: { showSpecsViewOptionsPopover.toggle() }) {
                            Image(systemName: "chevron.down")
                                .font(.system(size: StudioTheme.scaleFont(7.5), weight: .bold))
                                .frame(width: 22, height: 24)
                                .contentShape(Rectangle())
                                .foregroundColor(textMuted)
                        }
                        .buttonStyle(.plain)
                        .explain("Open view options and adjust thumbnail size.")
                        .popover(isPresented: $showSpecsViewOptionsPopover, arrowEdge: .bottom) {
                            specsViewOptionsPopoverContent
                        }
                    }
                    .fixedSize()
                }
                .padding(.bottom, 4)
            }
            
            // Table
            GeometryReader { tableGeo in
                let geoWidth = floor(tableGeo.size.width)
                let availableWidth = max(specsTableMinWidth, geoWidth)
                let extraWidth = max(0, geoWidth - specsTableMinWidth)
                let pathColWidth = CGFloat(specsState.columnWidth(for: .path)) + extraWidth
                
                ScrollView(.horizontal, showsIndicators: availableWidth > geoWidth) {
                    VStack(alignment: .leading, spacing: 0) {
                        // Table Header
                        HStack(spacing: 8) {
                            Text("#").frame(width: 25, alignment: .center)
                            if specsDisplayMode == "thumbnail" {
                                Text("Preview").frame(width: CGFloat(specsThumbnailWidth), alignment: .center)
                            }
                            
                            sortableHeaderCell("File Name", column: .name, alignment: .leading)
                            sortableHeaderCell("Timecode (TC)", column: .timecode)
                            sortableHeaderCell("End Frame", column: .endFrame)
                            sortableHeaderCell("Ratio & Size", column: .ratio)
                            sortableHeaderCell("FPS", column: .fps)
                            sortableHeaderCell("File Size", column: .size)
                            sortableHeaderCell("Created", column: .date)
                            sortableHeaderCell("Video", column: .videoCodec)
                            sortableHeaderCell("Audio Spec", column: .audioCodec)
                            sortableHeaderCell("Path", column: .path, customWidth: pathColWidth, alignment: .leading, isResizable: false)
                        }
                        .font(.ui(size: 9, weight: .semibold))
                        .foregroundColor(textMuted)
                        .padding(.horizontal, 14)
                        .padding(.vertical, specsDisplayMode == "large" ? 10 : (specsDisplayMode == "thumbnail" ? 8 : 6))
                        .frame(width: availableWidth, alignment: .leading)
                        .background(bgCardHeader)
                        .contextMenu {
                            Menu("Sort By") {
                                ForEach(SpecsSortColumn.allCases, id: \.self) { col in
                                    Button(action: {
                                        toggleSpecsSort(col)
                                    }) {
                                        HStack {
                                            Text(col.displayName)
                                            if specsState.specsSortColumn == col {
                                                Image(systemName: specsState.specsSortAscending ? "chevron.up" : "chevron.down")
                                            }
                                        }
                                    }
                                }
                            }
                            Divider()
                            Button(action: { specsState.specsSortAscending.toggle() }) {
                                Label(specsState.specsSortAscending ? "Ascending" : "Descending", systemImage: specsState.specsSortAscending ? "arrow.up" : "arrow.down")
                            }
                        }
                        
                        Rectangle().fill(borderLine).frame(width: availableWidth, height: 1)
                        
                        // Table Rows
                        ScrollView(.vertical) {
                            LazyVStack(spacing: 0) {
                                let assetMap = deliverableAssetsMap
                                
                                if filteredDeliverableAssets.isEmpty && !specsState.specsFilterText.isEmpty {
                                    VStack(spacing: 10) {
                                        Spacer().frame(height: 40)
                                        Image(systemName: "line.3.horizontal.decrease.circle")
                                            .font(.system(size: StudioTheme.scaleFont(26)))
                                            .foregroundColor(textMuted)
                                        Text("No Assets Matching \"\(specsState.specsFilterText)\"")
                                            .font(.ui(size: 11, weight: .semibold))
                                            .foregroundColor(textMuted)
                                        Button(action: { specsState.specsFilterText = "" }) {
                                            Text("Clear Filter")
                                                .font(.ui(size: 10, weight: .semibold))
                                                .foregroundColor(accentBlue)
                                        }
                                        .buttonStyle(.plain)
                                        Spacer().frame(height: 40)
                                    }
                                    .frame(width: availableWidth)
                                } else {
                                    // One ForEach keyed by path for tree and flat layouts (separate branches with
                                    // shared ids left stale rows in the lazy stack — see AGENTS.md §5.6).
                                    let rows = deliverableRows
                                    let rowCount = rows.count
                                    // Computed once per render and handed to every row (each row used to rebuild the
                                    // sorted list + folder tree for its menus and indent, on every selection change).
                                    let displayOrder = rows.filter { !$0.isDirectory }.map(\.url)
                                    let isTreeLayout = hasDeliverablesSubfolders && !hideAllFolders
                                    let assetIndexMap = Dictionary(uniqueKeysWithValues: displayOrder.enumerated().map { ($0.element, $0.offset) })
                                    let _ = { specsState.currentDisplayOrder = displayOrder }()
                                    // Rows re-render only when something they show changes (like the Player queue):
                                    // a click then updates the 1–2 rows whose selection flipped, not the whole table.
                                    let columnWidths = SpecsSortColumn.allCases.map { specsState.columnWidth(for: $0) }
                                    let themeKey = "\(isLightMode)_\(themeManager.currentTheme.id)_\(themeManager.currentTheme.playHex)_\(themeManager.buttonZoom)"
                                    let multiSelectionKey = specsState.selectedDeliverableURLs.count > 1
                                        ? specsState.selectedDeliverableURLs.hashValue &+ tagsVersion &* 31 &+ specsState.subtitleURLs.count : 0
                                    
                                    ForEach(Array(rows.enumerated()), id: \.element.id) { idx, node in
                                        if node.isDirectory {
                                            deliverablesFolderBannerRow(node: node, assetMap: assetMap, rowWidth: availableWidth)
                                        } else if let asset = assetMap[node.url] {
                                            let isSelected = specsState.isSelected(asset.fileURL)
                                            EquatableRow(key: SpecsRowKey(
                                                asset: asset,
                                                idx: assetIndexMap[node.url] ?? idx,
                                                depth: node.depth,
                                                pathWidth: pathColWidth,
                                                rowWidth: availableWidth,
                                                isTreeLayout: isTreeLayout,
                                                isSelected: isSelected,
                                                isDismissed: specsState.isMismatchDismissed(for: asset.fileURL),
                                                hasSubtitleMismatch: specsState.hasSubtitleMismatch(asset.fileURL),
                                                srtURL: specsState.subtitleURL(for: asset.fileURL),
                                                hasManualSrt: specsState.manuallyAttachedSubtitleVideos.contains(asset.fileURL),
                                                tag: fileTagsMap[asset.fileURL],
                                                columnWidths: columnWidths,
                                                displayMode: specsDisplayMode,
                                                thumbnailWidth: specsThumbnailWidth,
                                                themeKey: themeKey,
                                                menuContext: isSelected ? multiSelectionKey : 0
                                            )) {
                                                deliverablesAssetRow(idx: assetIndexMap[node.url] ?? idx, asset: asset, depth: node.depth, pathWidth: pathColWidth, rowWidth: availableWidth, displayOrder: displayOrder, isTreeLayout: isTreeLayout)
                                            }
                                            .equatable()
                                        }
                                        
                                        if idx < rowCount - 1 {
                                            Rectangle().fill(borderLine.opacity(0.4)).frame(width: availableWidth, height: 1)
                                        }
                                    }
                                }
                            }
                            // Rebuild rows when the display mode / thumbnail size changes.
                            .id("\(specsDisplayMode)_\(Int(specsThumbnailWidth))")
                        }
                    }
                    .frame(width: availableWidth, alignment: .leading)
                }
            }
            .studioBox(background: bgPanel, border: borderLine)
            .clipShape(RoundedRectangle(cornerRadius: StudioTheme.cornerRadius))
        }
        .padding(28)
    }
    
    // MARK: - Column Resizing & Width Helpers
    
    /// Rows as shown: the folder tree when there are subfolders, otherwise the flat list as depth-0 nodes.
    private var deliverableRows: [FileSystemTreeNode] {
        if hasDeliverablesSubfolders { return flattenedDeliverableNodes }
        return filteredDeliverableAssets.map {
            FileSystemTreeNode(id: $0.fileURL.path, name: $0.fileName, url: $0.fileURL, isDirectory: false, relativePath: $0.fileName, depth: 0)
        }
    }
    
    /// Visible files in display order (for ⇧-click ranges and multi-file actions).
    var displayedDeliverableURLs: [URL] {
        deliverableRows.filter { !$0.isDirectory }.map(\.url)
    }
    
    var effectiveFileNameColumnWidth: Double {
        specsState.effectiveFileNameColumnWidth
    }
    
    var isFileNameExpanded: Bool {
        specsState.isFileNameExpanded
    }
    
    func autoFitFileNameColumnWidth() {
        withAnimation(.easeInOut(duration: 0.15)) {
            specsState.autoFitFileNameColumnWidth(filteredAssets: filteredDeliverableAssets)
        }
    }
    
    var specsThumbnailWidth: Double {
        specsDisplayMode == "thumbnail" ? max(36.0, min(110.0, specsThumbnailSize)) : 0.0
    }
    
    var specsTableMinWidth: CGFloat {
        let previewWidth: CGFloat = CGFloat(specsThumbnailWidth)
        let otherColumnsWidth: CGFloat = 25 + previewWidth +
            CGFloat(specsState.columnWidth(for: .timecode)) +
            CGFloat(specsState.columnWidth(for: .ratio)) +
            CGFloat(specsState.columnWidth(for: .fps)) +
            CGFloat(specsState.columnWidth(for: .size)) +
            CGFloat(specsState.columnWidth(for: .date)) +
            CGFloat(specsState.columnWidth(for: .videoCodec)) +
            CGFloat(specsState.columnWidth(for: .audioCodec)) +
            CGFloat(specsState.columnWidth(for: .endFrame)) +
            CGFloat(specsState.columnWidth(for: .path)) +
            (8 * 12) + 28
        return CGFloat(effectiveFileNameColumnWidth) + otherColumnsWidth
    }
    
    // MARK: - Finder-Style Column Sorting & Resizing Helpers
    
    func toggleSpecsSort(_ column: SpecsSortColumn) {
        withAnimation(.easeInOut(duration: 0.15)) {
            specsState.toggleSpecsSort(column)
        }
    }
    
    private func sortableHeaderCell(
        _ title: String,
        column: SpecsSortColumn,
        customWidth: CGFloat? = nil,
        alignment: Alignment = .center,
        isResizable: Bool = true
    ) -> some View {
        let isCurrent = specsState.specsSortColumn == column
        let colWidth = customWidth ?? CGFloat(specsState.columnWidth(for: column))
        let isDraggingThis = specsState.isDragging(column: column)
        
        return HStack(spacing: 0) {
            Button(action: { toggleSpecsSort(column) }) {
                HStack(spacing: 3) {
                    Text(title)
                        .lineLimit(1)
                        .foregroundColor(isCurrent ? textMain : textMuted)
                    
                    if isCurrent {
                        Image(systemName: specsState.specsSortAscending ? "chevron.up" : "chevron.down")
                            .font(.system(size: StudioTheme.scaleFont(7), weight: .black))
                            .foregroundColor(accentBlue)
                    }
                }
                .frame(maxWidth: .infinity, alignment: alignment)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            
            if isResizable {
                // Drag Resize Handle Divider (14px hit target zone)
                ZStack {
                    ResizeCursorArea()
                        .frame(width: 14, height: 24)
                    Rectangle()
                        .fill(isDraggingThis ? accentBlue : (hoveredResizeColumn == column ? PanelResizeHandle.hoverLine(isLightMode) : borderLine.opacity(0.85)))
                        .frame(width: isDraggingThis ? 2 : 1, height: hoveredResizeColumn == column || isDraggingThis ? 16 : 12)
                        .allowsHitTesting(false)
                }
                .frame(width: 14)
                .contentShape(Rectangle())
                .onTapGesture(count: 2) {
                    if column == .name {
                        autoFitFileNameColumnWidth()
                    } else {
                        specsState.resetColumnWidth(for: column)
                    }
                }
                .onHover { isHovered in
                    if isHovered { hoveredResizeColumn = column } else if hoveredResizeColumn == column { hoveredResizeColumn = nil }
                }
                .gesture(
                    DragGesture(minimumDistance: 1, coordinateSpace: .global)
                        .onChanged { value in
                            specsState.onColumnDragChanged(column: column, translationWidth: Double(value.translation.width))
                        }
                        .onEnded { value in
                            specsState.onColumnDragEnded(column: column, translationWidth: Double(value.translation.width))
                        }
                )
            }
        }
        .frame(
            minWidth: column == .path ? colWidth : nil,
            idealWidth: colWidth,
            maxWidth: column == .path ? (customWidth != nil ? colWidth : .infinity) : colWidth,
            alignment: alignment
        )
        .explain("Sort by \(title.lowercased()) (\(isCurrent ? (specsState.specsSortAscending ? "ascending" : "descending") : "click to sort"))." + (isResizable ? " Drag divider to resize." : ""))
    }
    
    func sortDeliverableAssets(_ assets: [DeliverableAsset]) -> [DeliverableAsset] {
        specsState.sortDeliverableAssets(assets)
    }
    
    // MARK: - Deliverables Filtering & Hierarchy Helpers
    
    var specsPresentKinds: Int { MediaKindFilter.presentMask(of: specsState.deliverableAssets.map(\.fileURL)) }
    var specsKindMask: Int { MediaKindFilter.effectiveMask(mediaKindFilter, present: specsPresentKinds) }
    
    var filteredDeliverableAssets: [DeliverableAsset] {
        let q = specsState.specsFilterText.trimmingCharacters(in: .whitespacesAndNewlines)
        let mask = specsKindMask
        let base: [DeliverableAsset]
        if q.isEmpty && mask == MediaKindFilter.all {
            base = specsState.deliverableAssets
        } else {
            base = specsState.deliverableAssets.filter {
                MediaKindFilter.allows($0.fileURL, mask: mask) &&
                (q.isEmpty || $0.fileName.localizedCaseInsensitiveContains(q) || $0.fileURL.path.localizedCaseInsensitiveContains(q))
            }
        }
        return sortDeliverableAssets(base)
    }
    
    var deliverablesTree: [FileSystemTreeNode] {
        FileSystemTreeBuilder.buildTree(
            rootURL: folderURL,
            files: filteredDeliverableAssets.map { $0.fileURL },
            preserveFileOrder: true
        )
    }
    
    var hasDeliverablesSubfolders: Bool {
        FileSystemTreeBuilder.hasSubfolders(in: deliverablesTree)
    }
    
    private var loudnessTargetMenu: some View {
        Menu {
            Picker("Loudness Target", selection: $loudnessTargetID) {
                ForEach(LoudnessTarget.presets) { preset in
                    Text("\(preset.name)  (\(preset.spec))").tag(preset.id)
                }
                Text("Custom  (\(LoudnessTarget.custom(integrated: loudnessCustomLUFS, tolerance: loudnessCustomTolerance, maxTruePeak: loudnessCustomTruePeak).spec))").tag("custom")
            }
            .pickerStyle(.inline)
            Divider()
            Button("Edit Custom Target…") {
                UserDefaults.standard.set("Loudness", forKey: UserSettingsModalView.paneKey)
                loudnessTargetID = "custom"
                showUserSettingsModal = true
            }
        } label: {
            HStack(spacing: 4) {
                Text("Target")
                    .foregroundColor(textMuted)
                Text("\(loudnessTarget.name) · \(loudnessTarget.spec)")
                    .foregroundColor(textSubtle)
                    .lineLimit(1)
                    .truncationMode(.tail)
                Spacer(minLength: 0)
                Image(systemName: "chevron.up.chevron.down")
                    .font(.system(size: StudioTheme.scaleFont(7), weight: .semibold))
                    .foregroundColor(textMuted)
            }
            .font(.ui(size: 10, weight: .medium))
            .padding(.horizontal, 8)
            .contentShape(Rectangle())
        }
        .menuStyle(.button)
        .buttonStyle(.plain)
        .menuIndicator(.hidden)
        .help("Loudness target used to pass or fail each file")
    }

    func loudnessColor(_ verdict: LoudnessTarget.Verdict) -> Color {
        switch verdict {
        case .pass: return accentPositive
        case .warn: return .orange
        case .fail: return alertRed
        }
    }

    private func loudnessHelp(for asset: DeliverableAsset) -> String {
        guard let loudness = asset.loudness else { return asset.audioConfig }
        let result = loudnessTarget.evaluate(loudness)
        var lines = [asset.audioConfig, "", "\(result.verdict.rawValue) · \(loudnessTarget.name) (\(loudnessTarget.spec))"]
        lines += result.issues.filter { !loudness.channelNotes.contains($0) }
        lines += ["", loudness.detail]
        return lines.joined(separator: "\n")
    }

    var hasPendingAudioAnalysis: Bool {
        specsState.deliverableAssets.contains { $0.hasAudio && $0.loudness == nil && !$0.isAudioMute }
    }
    
    var flattenedDeliverableNodes: [FileSystemTreeNode] {
        FileSystemTreeBuilder.flatten(
            nodes: deliverablesTree,
            collapsedIDs: specsState.deliverablesCollapsedFolderIDs,
            hiddenIDs: hiddenFolderIDs,
            hideAllFolders: hideAllFolders
        )
    }
    
    var deliverableAssetsMap: [URL: DeliverableAsset] {
        Dictionary(uniqueKeysWithValues: filteredDeliverableAssets.map { ($0.fileURL, $0) })
    }
    
    private func toggleAllDeliverablesFolders() {
        if specsState.deliverablesCollapsedFolderIDs.isEmpty {
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
            specsState.deliverablesCollapsedFolderIDs = Set(deliverablesTree.flatMap { collectFolderIDs($0) })
        } else {
            specsState.deliverablesCollapsedFolderIDs.removeAll()
        }
    }
    
    var isDeliverablesFolderRowCollapsed: (FileSystemTreeNode) -> Bool {
        { node in
            specsState.deliverablesCollapsedFolderIDs.contains(node.id)
        }
    }
    
    private func deliverablesFolderBannerRow(node: FileSystemTreeNode, assetMap: [URL: DeliverableAsset], rowWidth: CGFloat = 0) -> some View {
        let isCollapsed = isDeliverablesFolderRowCollapsed(node)
        let folderAssets = node.videoURLs.compactMap { assetMap[$0] }
        let folderMismatches = folderAssets.filter { $0.validation.hasAnyMismatch && !specsState.isMismatchDismissed(for: $0.fileURL) }.count
        let totalBytes = folderAssets.reduce(Int64(0)) { $0 + $1.fileSizeBytes }
        let totalSeconds = folderAssets.reduce(0.0) { $0 + $1.durationSeconds }
        let formattedSize = DeliverablesInspector.formatFileSize(bytes: totalBytes)
        let formattedDur = TimecodeFormatter.format(frameIndex: Int(round(totalSeconds * 25.0)), fps: 25.0)
        
        return HStack(spacing: 8) {
            Image(systemName: isCollapsed ? "chevron.right" : "chevron.down")
                .font(.system(size: StudioTheme.scaleFont(9), weight: .bold))
                .foregroundColor(textMuted)
                .frame(width: 25, alignment: .center)
            
            HStack(spacing: 6) {
                Image(systemName: "folder")
                    .font(.system(size: StudioTheme.scaleFont(11), weight: .medium))
                    .foregroundColor(textSubtle)
                    .frame(width: 14, height: 14)
                
                Text(node.relativePath.isEmpty ? node.name : "\(node.relativePath)/")
                    .font(.ui(size: 11, weight: .semibold))
                    .foregroundColor(textMain)
                    .lineLimit(1)
                
                Text("(\(node.videoCount) \(node.videoCount == 1 ? "asset" : "assets"))")
                    .font(.ui(size: 9, weight: .semibold))
                    .foregroundColor(textMuted)
            }
            .padding(.leading, CGFloat(node.depth * 14))
            
            Spacer()
            
            HStack(spacing: 12) {
                Text(formattedDur)
                    .font(.ui(size: 9, weight: .semibold))
                    .foregroundColor(textSubtle)
                
                Text(formattedSize)
                    .font(.ui(size: 9, weight: .semibold))
                    .foregroundColor(textSubtle)
                
                if folderMismatches > 0 {
                    Text("\(folderMismatches) mismatch\(folderMismatches == 1 ? "" : "es")")
                        .font(.ui(size: 8, weight: .semibold))
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(RoundedRectangle(cornerRadius: 4).fill(alertRed))
                        .foregroundColor(.white)
                }
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
        .frame(width: rowWidth > 0 ? rowWidth : nil, alignment: .leading)
        .background(bgCardHeader)
        .contentShape(Rectangle())
        .onTapGesture {
            if isCollapsed {
                specsState.deliverablesCollapsedFolderIDs.remove(node.id)
            } else {
                specsState.deliverablesCollapsedFolderIDs.insert(node.id)
            }
        }
        .explain(node.url.path)
        .contextMenu {
            Button("Hide Folder") {
                hideSpecificFolder(id: node.id)
            }
            Button("Clear Folder") {
                clearFolder(node: node)
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
    
    private func deliverablesAssetRow(
        idx: Int,
        asset: DeliverableAsset,
        depth: Int = 0,
        pathWidth: CGFloat = 0,
        rowWidth: CGFloat = 0,
        displayOrder: [URL],
        isTreeLayout: Bool
    ) -> some View {
        let isDismissed = specsState.isMismatchDismissed(for: asset.fileURL)
        let hasSubtitleMismatch = specsState.hasSubtitleMismatch(asset.fileURL)
        let hasMismatch = (asset.validation.hasAnyMismatch || hasSubtitleMismatch) && !isDismissed
        let isSelected = specsState.isSelected(asset.fileURL)
        let srtURL = specsState.subtitleURL(for: asset.fileURL)
        
        return HStack(spacing: 8) {
            Text(String(format: "%02d", idx + 1))
                .frame(width: 25, alignment: .center)
                .foregroundColor(isSelected ? accentBlue : textMuted)
                .fontWeight(isSelected ? .bold : .regular)
            
            if specsDisplayMode == "thumbnail" {
                let thumbW = CGFloat(specsThumbnailWidth)
                let thumbH = round(thumbW * 9.0 / 16.0)
                AssetThumbnailView(fileURL: asset.fileURL, width: thumbW, height: thumbH, cornerRadius: 2.5)
                    .frame(width: thumbW, alignment: .center)
            }
            
            HStack(spacing: 5) {
                if isTreeLayout && depth > 0 {
                    Spacer().frame(width: CGFloat((depth - 1) * 12 + 4))
                    Image(systemName: "arrow.turn.down.right")
                        .font(.system(size: StudioTheme.scaleFont(8), weight: .bold))
                        .foregroundColor(textMuted.opacity(0.55))
                }
                
                if let tag = fileTagsMap[asset.fileURL] {
                    Circle()
                        .fill(tag.color)
                        .frame(width: 6, height: 6)
                }
                
                if specsDisplayMode != "thumbnail", let kind = QCUtilities.mediaKind(of: asset.fileURL) {
                    Image(systemName: asset.container == "SEQ" ? "photo.stack" : kind.symbolName)
                        .font(.system(size: StudioTheme.scaleFont(9), weight: .semibold))
                        .foregroundColor(textMuted)
                        .frame(width: 12)
                }
                
                if let srtURL = srtURL {
                    CCBadge(color: hasSubtitleMismatch && !isDismissed ? alertRed : textMuted, size: 9)
                        .help(hasSubtitleMismatch ? "Subtitles differ from the reference (\(srtURL.lastPathComponent))" : "Subtitles: \(srtURL.lastPathComponent)")
                }
                
                Text(asset.fileName)
                    .fontWeight(.bold)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .foregroundColor(isSelected ? textMain : (hasMismatch ? alertRed : textMain))
                    .help(asset.fileName)
                
                Button(action: {
                    specsState.selectedDeliverableURL = asset.fileURL
                    openProperties(for: asset.fileURL)
                }) {
                    Image(systemName: "info.circle")
                        .font(.system(size: StudioTheme.scaleFont(10), weight: .semibold))
                        .foregroundColor(isSelected ? accentBlue : textMuted.opacity(0.65))
                }
                .buttonStyle(.plain)
                .help("Media Info (⌘I)")
            }
            .frame(width: CGFloat(effectiveFileNameColumnWidth), alignment: .leading)
            
            // Timecode Cell with Warning
            VStack(alignment: .center, spacing: 3) {
                Text(asset.timecode)
                    .foregroundColor((asset.validation.isDurationMismatch && !isDismissed) ? alertRed : textSubtle)
                    .fontWeight((asset.validation.isDurationMismatch && !isDismissed) ? .bold : .regular)
                
                if let detail = asset.validation.durationMismatchDetail {
                    HStack(spacing: 3) {
                        Image(systemName: isDismissed ? "checkmark.circle" : "exclamationmark.triangle.fill")
                            .font(.system(size: StudioTheme.scaleFont(7), weight: .bold))
                        Text(isDismissed ? "\(detail) (dismissed)" : detail)
                            .font(.ui(size: 8, weight: isDismissed ? .medium : .semibold))
                        
                        Button(action: {
                            specsState.toggleDismissMismatch(for: asset.fileURL)
                        }) {
                            Image(systemName: isDismissed ? "arrow.uturn.backward" : "xmark")
                                .font(.system(size: StudioTheme.scaleFont(7), weight: .heavy))
                                .foregroundColor(isDismissed ? textMuted : alertRed)
                                .padding(1)
                        }
                        .buttonStyle(.plain)
                        .help(isDismissed ? "Restore Mismatch Flag" : "Dismiss Mismatch Flag")
                    }
                    .padding(.horizontal, 5)
                    .padding(.vertical, 1.5)
                    .foregroundColor(isDismissed ? textMuted : alertRed)
                    .background(isDismissed ? bgSubtle : alertRed.opacity(0.12))
                    .overlay(
                        RoundedRectangle(cornerRadius: 3)
                            .stroke(isDismissed ? borderLine : alertRed.opacity(0.35), lineWidth: 0.8)
                    )
                    .cornerRadius(3)
                    .lineLimit(1)
                    .minimumScaleFactor(0.8)
                    .help("Duration Mismatch: \(detail) (Actual Timecode: \(asset.timecode))\(isDismissed ? " [Dismissed]" : "")")
                }
            }
            .frame(width: CGFloat(specsState.columnWidth(for: .timecode)), alignment: .center)
            
            endFrameCell(asset.endFrame)
                .frame(width: CGFloat(specsState.columnWidth(for: .endFrame)), alignment: .center)
            
            // Ratio Cell with Warning
            VStack(alignment: .center, spacing: 3) {
                HStack(spacing: 4) {
                    Text(asset.aspectRatioString)
                        .font(.ui(size: 9, weight: .semibold))
                        .padding(.horizontal, 4)
                        .padding(.vertical, 2)
                        .foregroundColor((asset.validation.isRatioMismatch && !isDismissed) ? .white : textMain)
                        .studioBox(
                            background: (asset.validation.isRatioMismatch && !isDismissed) ? alertRed : bgSubtle,
                            border: (asset.validation.isRatioMismatch && !isDismissed) ? alertRed : borderLine
                        )
                    
                    Text(asset.resolutionString)
                        .foregroundColor(textSubtle)
                }
                
                if let detail = asset.validation.ratioMismatchDetail {
                    HStack(spacing: 3) {
                        Image(systemName: isDismissed ? "checkmark.circle" : "exclamationmark.triangle.fill")
                            .font(.system(size: StudioTheme.scaleFont(7), weight: .bold))
                        Text(isDismissed ? "\(detail) (dismissed)" : detail)
                            .font(.ui(size: 8, weight: isDismissed ? .medium : .semibold))
                        
                        Button(action: {
                            specsState.toggleDismissMismatch(for: asset.fileURL)
                        }) {
                            Image(systemName: isDismissed ? "arrow.uturn.backward" : "xmark")
                                .font(.system(size: StudioTheme.scaleFont(7), weight: .heavy))
                                .foregroundColor(isDismissed ? textMuted : alertRed)
                                .padding(1)
                        }
                        .buttonStyle(.plain)
                        .help(isDismissed ? "Restore Mismatch Flag" : "Dismiss Mismatch Flag")
                    }
                    .padding(.horizontal, 5)
                    .padding(.vertical, 1.5)
                    .foregroundColor(isDismissed ? textMuted : alertRed)
                    .background(isDismissed ? bgSubtle : alertRed.opacity(0.12))
                    .overlay(
                        RoundedRectangle(cornerRadius: 3)
                            .stroke(isDismissed ? borderLine : alertRed.opacity(0.35), lineWidth: 0.8)
                    )
                    .cornerRadius(3)
                    .lineLimit(1)
                    .minimumScaleFactor(0.8)
                    .help("Aspect Ratio Mismatch: \(detail) (Actual Resolution: \(asset.resolutionString))\(isDismissed ? " [Dismissed]" : "")")
                }
            }
            .frame(width: CGFloat(specsState.columnWidth(for: .ratio)), alignment: .center)
            
            Text(asset.fps > 0 ? String(format: "%.2f", asset.fps) : "--")
                .frame(width: CGFloat(specsState.columnWidth(for: .fps)), alignment: .center)
                .foregroundColor(textSubtle)
            
            Text(asset.formattedFileSize)
                .frame(width: CGFloat(specsState.columnWidth(for: .size)), alignment: .center)
                .fontWeight(.semibold)
            
            // Creation Date Column
            Text(asset.formattedCreationDate)
                .font(.ui(size: 9))
                .foregroundColor(textSubtle)
                .frame(width: CGFloat(specsState.columnWidth(for: .date)), alignment: .center)
            
            Text(asset.videoCodec)
                .frame(width: CGFloat(specsState.columnWidth(for: .videoCodec)), alignment: .center)
                .foregroundColor(textMuted)
                .lineLimit(1)
                .minimumScaleFactor(0.8)
                .help(asset.videoCodec)
            
            // Audio Column
            if !asset.hasAudio {
                Text("None")
                    .font(.ui(size: 9, weight: .semibold))
                    .foregroundColor(textMuted)
                    .frame(width: CGFloat(specsState.columnWidth(for: .audioCodec)), alignment: .center)
            } else {
                VStack(alignment: .center, spacing: 3) {
                    HStack(spacing: 4) {
                        Text(asset.audioCodec)
                            .font(.ui(size: 10, weight: .semibold))
                            .foregroundColor(textMain)
                        if asset.audioBitrate != "--" {
                            Text(asset.audioBitrate)
                                .font(.ui(size: 8, weight: .semibold))
                                .padding(.horizontal, 4)
                                .padding(.vertical, 1)
                                .foregroundColor(textSubtle)
                                .studioBox(background: bgSubtle, border: borderLine)
                        }
                    }
                    
                    if asset.validation.isAudioMute {
                        HStack(spacing: 3) {
                            Image(systemName: "speaker.slash.fill")
                                .font(.system(size: StudioTheme.scaleFont(7), weight: .bold))
                            Text(asset.validation.audioMuteDetail ?? "Mute")
                                .font(.ui(size: 8, weight: .semibold))
                        }
                        .padding(.horizontal, 5)
                        .padding(.vertical, 1.5)
                        .foregroundColor(alertRed)
                        .background(alertRed.opacity(0.12))
                        .overlay(
                            RoundedRectangle(cornerRadius: 3)
                                .stroke(alertRed.opacity(0.35), lineWidth: 0.8)
                        )
                        .cornerRadius(3)
                        .lineLimit(1)
                        .minimumScaleFactor(0.8)
                        .help("Audio Track is Mute: \(asset.audioLevelString) (Codec: \(asset.audioCodec))")
                    } else if let loudness = asset.loudness {
                        let result = loudnessTarget.evaluate(loudness)
                        HStack(spacing: 3) {
                            if result.verdict != .pass {
                                Image(systemName: result.verdict == .fail ? "exclamationmark.triangle.fill" : "exclamationmark.circle")
                                    .font(.system(size: StudioTheme.scaleFont(7), weight: .bold))
                            }
                            Text(loudness.summary)
                                .font(.ui(size: 8, weight: .semibold))
                                .lineLimit(1)
                                .minimumScaleFactor(0.8)
                        }
                        .foregroundColor(loudnessColor(result.verdict))
                    } else {
                        HStack(spacing: 4) {
                            if !asset.audioFormatDetail.isEmpty {
                                Text(asset.audioFormatDetail)
                                    .font(.ui(size: 8, weight: .medium))
                                    .foregroundColor(textMuted)
                                    .lineLimit(1)
                            }
                        }
                    }
                }
                .frame(width: CGFloat(specsState.columnWidth(for: .audioCodec)), alignment: .center)
                .help(loudnessHelp(for: asset))
            }
            
            let effectivePathWidth = pathWidth > 0 ? pathWidth : CGFloat(specsState.columnWidth(for: .path))
            // Start of the path only (less clutter); click reveals the file in Finder, full path on hover.
            Button(action: { NSWorkspace.shared.activateFileViewerSelecting([asset.fileURL]) }) {
                HStack(spacing: 4) {
                    Image(systemName: "folder")
                        .font(.system(size: StudioTheme.scaleFont(9)))
                    Text(asset.fileURL.deletingLastPathComponent().path)
                        .font(.ui(size: 10))
                        .lineLimit(1)
                        .truncationMode(.tail)
                }
                .foregroundColor(textSubtle)
                .contentShape(Rectangle())
            }
            .buttonStyle(TransportIconButtonStyle())
            .frame(width: effectivePathWidth, alignment: .leading)
            .help("Reveal in Finder: \(asset.fileURL.path)")
        }
        .font(.ui(size: 11))
        .padding(.horizontal, 14)
        .padding(.vertical, specsDisplayMode == "large" ? 10 : (specsDisplayMode == "thumbnail" ? 7 : 4))
        .frame(width: rowWidth > 0 ? rowWidth : nil, alignment: .leading)
        .background(
            isSelected ? accentBlue.opacity(0.14) : (hasMismatch ? alertRed.opacity(0.12) : (idx % 2 == 0 ? bgPanel : bgCardSubtle))
        )
        .overlay(
            isSelected ? Rectangle().fill(accentBlue).frame(width: 3) : (hasMismatch ? Rectangle().fill(alertRed).frame(width: 3) : nil),
            alignment: .leading
        )
        .contentShape(Rectangle())
        // Finder-style: click selects, ⌘-click adds/removes, ⇧-click extends a range. Simultaneous with the double-click
        // (play) so a single click selects immediately instead of waiting out the double-click interval.
        .simultaneousGesture(TapGesture().onEnded {
            specsState.handleClick(on: asset.fileURL, modifiers: NSEvent.modifierFlags, displayOrder: specsState.currentDisplayOrder)
        })
        .simultaneousGesture(
            TapGesture(count: 2).onEnded {
                specsState.selectedDeliverableURL = asset.fileURL
                playDeliverableInPlayer(url: asset.fileURL)
            }
        )
        .explain(asset.fileURL.path)
        .contextMenu {
            Button(action: {
                specsState.selectedDeliverableURL = asset.fileURL
                playDeliverableInPlayer(url: asset.fileURL)
            }) {
                Label("Play in Player (Tab 1)", systemImage: "play.fill")
            }
            Divider()
            Button(action: {
                specsState.selectedDeliverableURL = asset.fileURL
                openProperties(for: asset.fileURL)
            }) {
                Label("Media Info (⌘I)", systemImage: "info.circle")
            }
            .keyboardShortcut("i", modifiers: .command)
            Divider()
            Button("Copy Path") {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(asset.fileURL.path, forType: .string)
            }
            Button("Reveal in Finder") {
                NSWorkspace.shared.activateFileViewerSelecting([asset.fileURL])
            }
            Divider()
            let subtitleTargets = specsState.actionTargets(for: asset.fileURL, displayOrder: displayOrder)
            if subtitleTargets.count > 1 {
                Button(action: { crossCheckSubtitles(subtitleTargets) }) {
                    Label("Cross-Check Subtitles (\(subtitleTargets.count) files)", systemImage: "text.badge.checkmark")
                }
                .disabled(subtitleTargets.filter { specsState.subtitleURL(for: $0) != nil }.count < 2)
            }
            Button(action: { attachSubtitles(to: asset.fileURL) }) {
                Label(srtURL == nil ? "Attach Subtitles (.srt)…" : "Change Subtitles (.srt)…", systemImage: "captions.bubble")
            }
            if specsState.manuallyAttachedSubtitleVideos.contains(asset.fileURL) {
                Button("Detach Subtitles") { specsState.attachSubtitles(nil, to: asset.fileURL) }
            }
            if let srtURL = srtURL {
                Button("Reveal Subtitles in Finder") { NSWorkspace.shared.activateFileViewerSelecting([srtURL]) }
            }
            if asset.validation.hasAnyMismatch || hasSubtitleMismatch {
                Divider()
                Button(action: {
                    specsState.toggleDismissMismatch(for: asset.fileURL)
                }) {
                    if isDismissed {
                        Label("Restore Mismatch Flag", systemImage: "arrow.uturn.backward.circle")
                    } else {
                        Label("Dismiss Mismatch Flag", systemImage: "xmark.circle")
                    }
                }
            }
            Divider()
            let tagTargets = specsState.actionTargets(for: asset.fileURL, displayOrder: displayOrder)
            Menu(tagTargets.count > 1 ? "Tags (\(tagTargets.count) files)" : "Tags") {
                ForEach(FinderTagColor.allCases) { tag in
                    let allTagged = tagTargets.allSatisfy { fileTagsMap[$0] == tag }
                    Button(action: {
                        // Like Finder: if every file already has the tag, remove it; otherwise apply it to all.
                        for url in tagTargets { setFinderTag(allTagged ? nil : tag, for: url) }
                    }) {
                        HStack {
                            Text(tag.rawValue)
                            if allTagged {
                                Image(systemName: "checkmark")
                            }
                        }
                    }
                }
                Divider()
                Button(action: {
                    for url in tagTargets { setFinderTag(nil, for: url) }
                }) {
                    Text(tagTargets.count > 1 ? "Remove Tags" : "Remove Tag")
                }
            }
        }
    }
    
    // MARK: - Subtitle Attach & Cross-Check
    
    func attachSubtitles(to video: URL) {
        let panel = NSOpenPanel()
        panel.title = "Attach Subtitles to \(video.lastPathComponent)"
        panel.prompt = "Attach"
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        panel.allowedContentTypes = [UTType(filenameExtension: "srt") ?? .plainText]
        panel.directoryURL = video.deletingLastPathComponent()
        guard panel.runModal() == .OK, let srt = panel.url else { return }
        specsState.attachSubtitles(srt, to: video)
        showToast("Attached \(srt.lastPathComponent) to \(video.lastPathComponent)")
    }
    
    /// Cross-checks the given videos' subtitles; the first one in list order is the reference.
    func crossCheckSubtitles(_ videos: [URL]) {
        let withSubs = videos.filter { specsState.subtitleURL(for: $0) != nil }
        guard withSubs.count >= 2 else {
            showToast("Need at least 2 files with subtitles to cross-check")
            return
        }
        let fps = Dictionary(uniqueKeysWithValues: specsState.deliverableAssets.map { ($0.fileURL, $0.fps) })
        specsState.runSubtitleCrossCheck(videos: withSubs, fpsByVideo: fps)
    }
    
    /// Files the sidebar action checks: the selection if it has 2+ files, otherwise the whole visible list.
    var subtitleCrossCheckTargets: [URL] {
        let shown = displayedDeliverableURLs
        let selected = shown.filter { specsState.isSelected($0) }
        return (selected.count >= 2 ? selected : shown).filter { specsState.subtitleURL(for: $0) != nil }
    }
    
    // MARK: - Specs View Options Popover (Thumbnail View / List View / Size Slider)
    private var specsViewOptionsPopoverContent: some View {
        VStack(alignment: .leading, spacing: 2) {
            // Thumbnail View
            Button(action: {
                withAnimation(.easeInOut(duration: 0.15)) {
                    specsDisplayMode = "thumbnail"
                }
            }) {
                HStack(spacing: 7) {
                    if specsDisplayMode == "thumbnail" {
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
                withAnimation(.easeInOut(duration: 0.15)) {
                    specsDisplayMode = "inline"
                }
            }) {
                HStack(spacing: 7) {
                    if specsDisplayMode == "inline" {
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
                    get: { specsThumbnailSize },
                    set: { newValue in
                        specsThumbnailSize = newValue
                        if specsDisplayMode != "thumbnail" {
                            specsDisplayMode = "thumbnail"
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
}


// MARK: - Row Skipping

/// Everything a Specs table row shows. Rows whose key is unchanged are not re-evaluated or re-diffed on a render.
struct SpecsRowKey: Equatable {
    let asset: DeliverableAsset
    let idx: Int
    let depth: Int
    let pathWidth: CGFloat
    let rowWidth: CGFloat
    let isTreeLayout: Bool
    let isSelected: Bool
    let isDismissed: Bool
    let hasSubtitleMismatch: Bool
    let srtURL: URL?
    let hasManualSrt: Bool
    let tag: FinderTagColor?
    let columnWidths: [Double]
    let displayMode: String
    let thumbnailWidth: Double
    let themeKey: String
    /// Selection / tag / subtitle state used by a multi-file right-click menu (0 when the row is not part of one).
    let menuContext: Int
}

/// Renders `content` only when `key` changes (use with `.equatable()`).
struct EquatableRow<Key: Equatable, Content: View>: View, Equatable {
    let key: Key
    @ViewBuilder let content: () -> Content
    
    nonisolated static func == (lhs: EquatableRow, rhs: EquatableRow) -> Bool {
        MainActor.assumeIsolated { lhs.key == rhs.key }
    }
    
    var body: some View { content() }
}

// MARK: - End Frame Column

extension ContentView {
    var hasPendingEndFrameCheck: Bool {
        specsState.deliverableAssets.contains { $0.endFrame == nil }
    }
    
    @ViewBuilder
    func endFrameCell(_ check: EndFrameCheck?) -> some View {
        if let check {
            // Neutral on purpose: ending on black is a fact, not a pass or fail. A black swatch for BLACK, an empty one otherwise.
            HStack(spacing: 5) {
                if check.verdict != .unavailable {
                    RoundedRectangle(cornerRadius: 1.5)
                        .fill(check.verdict == .black ? Color.black : Color.clear)
                        .frame(width: 8, height: 8)
                        .overlay(RoundedRectangle(cornerRadius: 1.5).stroke(textMuted, lineWidth: 1))
                }
                Text(check.verdict.rawValue)
                    .font(.ui(size: 9.5, weight: .semibold))
                    .foregroundColor(check.verdict == .unavailable ? textMuted : textMain)
                    .lineLimit(1)
            }
            .help(check.verdict == .unavailable
                  ? "No last frame to check (still image, audio, or the frame couldn't be decoded)"
                  : "Last frame \(check.timecode): \(String(format: "%.2f", 100 - check.litPercent))% black, \(String(format: "%.2f", check.litPercent))% picture/content (mean luma \(String(format: "%.1f", check.meanLuma)) / 255)")
        } else {
            Text("—")
                .font(.ui(size: 9.5, weight: .semibold))
                .foregroundColor(textMuted)
                .help("Not checked yet: use CHECK END FRAMES")
        }
    }
    
}
