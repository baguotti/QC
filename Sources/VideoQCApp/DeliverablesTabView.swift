import SwiftUI
import VideoQCLib

extension ContentView {
    
    // MARK: ==================== TAB 2: SPECS ====================
    
    var deliverablesTabView: some View {
        HSplitView {
            // Left Control Panel
            VStack(alignment: .leading, spacing: 18) {
                // Unified Asset Picker
                deliveryAssetsSection(forTab: .specs)
                
                // Search Filter (like in Tab 1)
                if !deliverableAssets.isEmpty {
                    specsSearchFilterBar
                }
                
                // 02 SPECS ACTIONS: View controls, Audit & Exports
                specsActionsSection
                
                Spacer(minLength: 0)
            }
            .padding(22)
            .frame(minWidth: 360, idealWidth: 400, maxWidth: 440)
            .background(bgPanel)
            
            // Right Panel: Specs Table / Stats
            VStack(alignment: .leading, spacing: 0) {
                if isInspectingDeliverables {
                    VStack(alignment: .center, spacing: 12) {
                        Spacer()
                        Text("INSPECTING DELIVERABLES SPECS...")
                            .font(.system(size: 18, weight: .heavy, design: .monospaced))
                        ProgressView()
                            .scaleEffect(1.2)
                        Spacer()
                    }
                    .frame(maxWidth: .infinity)
                    .padding(28)
                } else if deliverableAssets.isEmpty {
                    emptyDeliverablesStateView
                } else {
                    deliverablesResultsView
                }
            }
            .frame(minWidth: 540)
            .background(bgMain)
        }
    }
    
    // MARK: - Left Panel: Search Filter Bar (like in Tab 1)
    
    private var specsSearchFilterBar: some View {
        HStack(spacing: 6) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 10))
                .foregroundColor(textMuted)
            
            ZStack(alignment: .leading) {
                if specsFilterText.isEmpty {
                    Text("FILTER ASSETS...")
                        .font(.system(size: 11, weight: .bold, design: .monospaced))
                        .foregroundColor(textMuted)
                        .allowsHitTesting(false)
                }
                TextField("", text: $specsFilterText)
                    .font(.system(size: 11, weight: .medium, design: .monospaced))
                    .textFieldStyle(.plain)
                    .foregroundColor(textMain)
                    .onSubmit {
                        NSApp.keyWindow?.makeFirstResponder(nil)
                    }
            }
            
            if !specsFilterText.isEmpty {
                Button(action: { specsFilterText = "" }) {
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
    
    // MARK: - Left Panel: 02 SPECS ACTIONS
    
    private var specsActionsSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            sectionHeader(num: "02", title: "SPECS ACTIONS")
            
            // Actions & Export Controls
            VStack(spacing: 6) {
                
                // Export Row: SHEETS | SAVE CSV | OPEN HTML (All on one line)
                HStack(spacing: 6) {
                    // Google Sheets
                    Button(action: {
                        if !deliverableAssets.isEmpty {
                            openDeliverablesInGoogleSheets()
                        }
                    }) {
                        HStack(spacing: 4) {
                            Image(systemName: "arrow.up.right.square")
                                .font(.system(size: 8.5, weight: .bold))
                            Text("SHEETS")
                                .font(.system(size: 9.5, weight: .bold, design: .monospaced))
                                .lineLimit(1)
                                .minimumScaleFactor(0.8)
                        }
                        .frame(maxWidth: .infinity, alignment: .center)
                        .frame(height: 28)
                        .foregroundColor(deliverableAssets.isEmpty ? textMuted : textMain)
                        .studioBox(background: bgSubtle, border: borderLine)
                    }
                    .buttonStyle(.plain)
                    .disabled(deliverableAssets.isEmpty)
                    .explain("Copies specs as spreadsheet data and opens Google Sheets ready to paste (⌘V).", binding: $hoverExplanation)
                    
                    // Save CSV
                    Button(action: {
                        if !deliverableAssets.isEmpty {
                            exportDeliverablesManifest()
                        }
                    }) {
                        HStack(spacing: 4) {
                            Image(systemName: "doc.text")
                                .font(.system(size: 8.5, weight: .bold))
                            Text("SAVE CSV")
                                .font(.system(size: 9.5, weight: .bold, design: .monospaced))
                                .lineLimit(1)
                                .minimumScaleFactor(0.8)
                        }
                        .frame(maxWidth: .infinity, alignment: .center)
                        .frame(height: 28)
                        .foregroundColor(deliverableAssets.isEmpty ? textMuted : textMain)
                        .studioBox(background: bgSubtle, border: borderLine)
                    }
                    .buttonStyle(.plain)
                    .disabled(deliverableAssets.isEmpty)
                    .explain("Saves the deliverables metadata table to a local CSV file.", binding: $hoverExplanation)
                    
                    // Open HTML
                    Button(action: {
                        if !deliverableAssets.isEmpty {
                            openManifestHTML()
                        }
                    }) {
                        HStack(spacing: 4) {
                            Image(systemName: "safari")
                                .font(.system(size: 8.5, weight: .bold))
                            Text("OPEN HTML")
                                .font(.system(size: 9.5, weight: .bold, design: .monospaced))
                                .lineLimit(1)
                                .minimumScaleFactor(0.8)
                        }
                        .frame(maxWidth: .infinity, alignment: .center)
                        .frame(height: 28)
                        .foregroundColor(deliverableAssets.isEmpty ? textMuted : textMain)
                        .studioBox(background: bgSubtle, border: borderLine)
                    }
                    .buttonStyle(.plain)
                    .disabled(deliverableAssets.isEmpty)
                    .explain("Generates and opens a formatted HTML delivery specs sheet in browser.", binding: $hoverExplanation)
                }
                
                // Reveal in Finder
                if let firstURL = deliverableAssets.first?.fileURL {
                    Button(action: {
                        NSWorkspace.shared.activateFileViewerSelecting([selectedDeliverableURL ?? firstURL])
                    }) {
                        HStack(spacing: 5) {
                            Image(systemName: "folder")
                                .font(.system(size: 9, weight: .bold))
                            Text("REVEAL IN FINDER")
                                .font(.system(size: 10, weight: .bold, design: .monospaced))
                        }
                        .frame(maxWidth: .infinity, alignment: .center)
                        .frame(height: 28)
                        .foregroundColor(textMain)
                        .studioBox(background: bgSubtle, border: borderLine)
                    }
                    .buttonStyle(.plain)
                    .explain("Locates and highlights the selected or first asset in macOS Finder.", binding: $hoverExplanation)
                }
            }
            
            // Clear Button
            if !deliverableAssets.isEmpty {
                Button(action: {
                    deliverableAssets = []
                    selectedDeliverableURL = nil
                }) {
                    HStack(spacing: 4) {
                        Image(systemName: "xmark")
                            .font(.system(size: 8, weight: .bold))
                        Text("CLEAR LIST")
                            .font(.system(size: 9, weight: .bold, design: .monospaced))
                    }
                    .foregroundColor(textMuted)
                    .frame(maxWidth: .infinity, alignment: .center)
                    .padding(.top, 4)
                }
                .buttonStyle(.plain)
                .explain("Removes all video assets from the inspection table.", binding: $hoverExplanation)
            }
        }
    }
    
    var emptyDeliverablesStateView: some View {
        VStack(alignment: .leading, spacing: 18) {
            Spacer()
            
            Text("STATUS // READY TO INSPECT DELIVERABLES")
                .font(.system(size: 32, weight: .black, design: .default))
                .foregroundColor(textMain)
                .tracking(1.0)
            
            Text("CHOOSE A DELIVERY FOLDER OR VIDEO FILES ON THE LEFT TO INSTANTLY GENERATE A DELIVERABLE SPECS AUDIT.\nDISPLAYS EXACT TIMECODE LENGTHS, ASPECT RATIOS, RESOLUTIONS, FRAMERATES, AND SIZES.")
                .font(.system(size: 12, weight: .medium, design: .monospaced))
                .foregroundColor(textMuted)
                .lineSpacing(4)
            
            Rectangle()
                .fill(borderLine)
                .frame(height: 1)
            
            HStack(spacing: 16) {
                formatTag("16:9 • 9:16 • 4:5 • 1:1")
                formatTag("SMPTE TIMECODES")
                formatTag("FILE SIZES")
                formatTag("CODEC & BITRATES")
            }
            
            Spacer()
        }
        .padding(40)
    }
    
    var deliverablesResultsView: some View {
        let displayAssets = filteredDeliverableAssets
        let totalBytes = displayAssets.reduce(Int64(0)) { $0 + $1.fileSizeBytes }
        let totalSeconds = displayAssets.reduce(0.0) { $0 + $1.durationSeconds }
        let mismatchCount = displayAssets.filter { $0.validation.hasAnyMismatch }.count
        
        return VStack(alignment: .leading, spacing: 20) {
            // Header: Clean audit status
            VStack(alignment: .leading, spacing: 2) {
                Text("AUDIT COMPLETE")
                    .font(.system(size: 28, weight: .black, design: .default))
                    .foregroundColor(textMain)
                    .tracking(1.0)
                if specsFilterText.isEmpty {
                    Text("\(deliverableAssets.count) ASSETS ANALYZED")
                        .font(.system(size: 11, weight: .bold, design: .monospaced))
                        .foregroundColor(textMuted)
                } else {
                    Text("\(displayAssets.count) OF \(deliverableAssets.count) ASSETS (FILTERED)")
                        .font(.system(size: 11, weight: .bold, design: .monospaced))
                        .foregroundColor(accentBlue)
                }
            }
            
            // Quick Stats Strip & Table Controls (Right-aligned to stats baseline / cyan line)
            HStack(alignment: .bottom, spacing: 12) {
                // Left: Quick Stats
                HStack(spacing: 12) {
                    statBox(title: specsFilterText.isEmpty ? "TOTAL ASSETS" : "FILTERED ASSETS", val: String(format: "%02d", displayAssets.count))
                    statBox(title: "NAME MISMATCHES", val: String(format: "%02d", mismatchCount), isRed: mismatchCount > 0, isPositive: mismatchCount == 0 && !displayAssets.isEmpty)
                    statBox(title: "TOTAL RUNTIME", val: TimecodeFormatter.format(frameIndex: Int(round(totalSeconds * 25.0)), fps: 25.0))
                    statBox(title: "TOTAL BATCH SIZE", val: DeliverablesInspector.formatFileSize(bytes: totalBytes))
                }
                
                Spacer()
                
                // Right: 3 Visually Cohesive Studio Buttons
                HStack(spacing: 6) {
                    // Button 1: Fit / Reset Name
                    Button(action: { autoFitFileNameColumnWidth() }) {
                        HStack(spacing: 4) {
                            Image(systemName: isFileNameExpanded ? "arrow.right.and.line.vertical.and.arrow.left" : "arrow.left.and.line.vertical.and.arrow.right")
                                .font(.system(size: 8.5, weight: .bold))
                            Text(isFileNameExpanded ? "RESET NAME" : "FIT NAME")
                                .font(.system(size: 9.5, weight: .bold, design: .monospaced))
                        }
                        .padding(.horizontal, 8)
                        .frame(height: 24)
                        .contentShape(Rectangle())
                        .foregroundColor(isFileNameExpanded ? textMain : (deliverableAssets.isEmpty ? textMuted : textSubtle))
                    }
                    .buttonStyle(.plain)
                    .disabled(deliverableAssets.isEmpty)
                    .fixedSize()
                    .studioBox(
                        background: isFileNameExpanded ? (isLightMode ? Color.white : bgCardHeader) : bgSubtle,
                        border: isFileNameExpanded ? borderStrong : borderLine
                    )
                    .explain(isFileNameExpanded ? "Reset File Name column width back to default (220px)." : "Auto-fit File Name column to fit longest filename without truncation.", binding: $hoverExplanation)
                    
                    // Button 2: Folders (Hide/Show like Tab 1)
                    let isFoldersHidden = hideAllFolders || !hiddenFolderIDs.isEmpty
                    let canToggleFolders = hasDeliverablesSubfolders
                    Button(action: toggleHideFolders) {
                        HStack(spacing: 4) {
                            Image(systemName: isFoldersHidden ? "folder" : "folder.badge.minus")
                                .font(.system(size: 8.5, weight: .bold))
                            SlotText(
                                isFoldersHidden ? "SHOW" : "HIDE",
                                mode: .character,
                                direction: .up,
                                font: .system(size: 9.5, weight: .bold, design: .monospaced),
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
                    .studioBox(
                        background: isFoldersHidden ? accentBlue.opacity(0.18) : bgSubtle,
                        border: isFoldersHidden ? accentBlue : borderLine
                    )
                    .contextMenu {
                        Button(action: toggleHideFolders) {
                            Label(isFoldersHidden ? "Show Folder Groups" : "Hide Folder Groups (Flat List)",
                                  systemImage: isFoldersHidden ? "folder.badge.plus" : "list.bullet")
                        }
                        if !isFoldersHidden && hasDeliverablesSubfolders {
                            Divider()
                            Button(action: toggleAllDeliverablesFolders) {
                                Label(deliverablesCollapsedFolderIDs.isEmpty ? "Collapse All Folders" : "Expand All Folders",
                                      systemImage: deliverablesCollapsedFolderIDs.isEmpty ? "chevron.down.square" : "chevron.right.square")
                            }
                        }
                    }
                    .explain(isFoldersHidden ? "Show all folder headers in asset lists." : "Hide folder headers and display assets in a flat list.", binding: $hoverExplanation)
                    
                    // Button 3: List / Thumbs (Direct Toggle + Chevron Popover)
                    HStack(spacing: 0) {
                        Button(action: {
                            withAnimation(.easeInOut(duration: 0.15)) {
                                specsDisplayMode = (specsDisplayMode == "thumbnail" ? "inline" : "thumbnail")
                            }
                        }) {
                            HStack(spacing: 4) {
                                Image(systemName: specsDisplayMode == "thumbnail" ? "square.grid.2x2" : "list.bullet")
                                    .font(.system(size: 8.5, weight: .bold))
                                Text(specsDisplayMode == "thumbnail" ? "THUMBS" : "LIST")
                                    .font(.system(size: 9.5, weight: .bold, design: .monospaced))
                            }
                            .padding(.horizontal, 9)
                            .frame(height: 24)
                            .contentShape(Rectangle())
                            .foregroundColor(textMain)
                        }
                        .buttonStyle(.plain)
                        .explain("Click to toggle between List and Thumbnail view.", binding: $hoverExplanation)
                        
                        Rectangle()
                            .fill(borderLine)
                            .frame(width: 1, height: 14)
                        
                        Button(action: { showSpecsViewOptionsPopover.toggle() }) {
                            Image(systemName: "chevron.down")
                                .font(.system(size: 7.5, weight: .bold))
                                .frame(width: 22, height: 24)
                                .contentShape(Rectangle())
                                .foregroundColor(textMuted)
                        }
                        .buttonStyle(.plain)
                        .explain("Open view options and adjust thumbnail size.", binding: $hoverExplanation)
                        .popover(isPresented: $showSpecsViewOptionsPopover, arrowEdge: .bottom) {
                            specsViewOptionsPopoverContent
                        }
                    }
                    .fixedSize()
                    .studioBox(
                        background: showSpecsViewOptionsPopover ? (isLightMode ? Color.white : bgCardHeader) : bgSubtle,
                        border: showSpecsViewOptionsPopover ? borderStrong : borderLine
                    )
                }
                .padding(.bottom, 4)
            }
            
            // Table
            ScrollView(.horizontal, showsIndicators: true) {
                VStack(alignment: .leading, spacing: 0) {
                    // Table Header
                    HStack(spacing: 8) {
                        Text("#").frame(width: 25, alignment: .center)
                        if specsDisplayMode == "thumbnail" {
                            Text("PREVIEW").frame(width: CGFloat(specsThumbnailWidth), alignment: .center)
                        }
                        
                        // Resizable & Sortable File Name Column Header
                        HStack(spacing: 0) {
                            Button(action: { toggleSpecsSort(.name) }) {
                                HStack(spacing: 3) {
                                    Text("FILE NAME")
                                        .lineLimit(1)
                                        .foregroundColor(specsSortColumn == .name ? textMain : textMuted)
                                    
                                    if specsSortColumn == .name {
                                        Image(systemName: specsSortAscending ? "chevron.up" : "chevron.down")
                                            .font(.system(size: 7, weight: .black))
                                            .foregroundColor(accentBlue)
                                    }
                                }
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .contentShape(Rectangle())
                            }
                            .buttonStyle(.plain)
                            
                            // Drag Resize Handle Divider (16px hit target zone)
                            ZStack {
                                Rectangle()
                                    .fill(Color.clear)
                                    .frame(width: 16, height: 24)
                                    .contentShape(Rectangle())
                                
                                Rectangle()
                                    .fill(isDraggingFileNameColumn ? accentBlue : borderLine.opacity(0.85))
                                    .frame(width: isDraggingFileNameColumn ? 2 : 1, height: 12)
                            }
                            .frame(width: 16)
                            .onTapGesture(count: 2) {
                                autoFitFileNameColumnWidth()
                            }
                            .onHover { isHovered in
                                if isHovered {
                                    NSCursor.resizeLeftRight.push()
                                } else {
                                    NSCursor.pop()
                                }
                            }
                            .gesture(
                                DragGesture(minimumDistance: 1, coordinateSpace: .global)
                                    .onChanged { value in
                                        if dragStartFileNameWidth == nil {
                                            dragStartFileNameWidth = specsFileNameColumnWidth
                                            isDraggingFileNameColumn = true
                                        }
                                        let start = dragStartFileNameWidth ?? specsFileNameColumnWidth
                                        let newWidth = max(140.0, min(1200.0, start + Double(value.translation.width)))
                                        liveFileNameColumnWidth = newWidth
                                    }
                                    .onEnded { value in
                                        if let start = dragStartFileNameWidth {
                                            let finalWidth = max(140.0, min(1200.0, start + Double(value.translation.width)))
                                            specsFileNameColumnWidth = finalWidth
                                            liveFileNameColumnWidth = finalWidth
                                        }
                                        dragStartFileNameWidth = nil
                                        isDraggingFileNameColumn = false
                                    }
                            )
                        }
                        .frame(width: CGFloat(effectiveFileNameColumnWidth), alignment: .leading)
                        .explain("Click to sort by filename (\(specsSortColumn == .name ? (specsSortAscending ? "A-Z" : "Z-A") : "click to sort")). Drag divider to resize.", binding: $hoverExplanation)
                        
                        sortableHeaderCell("TIMECODE (TC)", column: .timecode, width: 142)
                        sortableHeaderCell("RATIO & SIZE", column: .ratio, width: 152)
                        sortableHeaderCell("FPS", column: .fps, width: 60)
                        sortableHeaderCell("FILE SIZE", column: .size, width: 75)
                        sortableHeaderCell("CREATED", column: .date, width: 110)
                        sortableHeaderCell("VIDEO", column: .videoCodec, width: 85)
                        sortableHeaderCell("AUDIO SPEC", column: .audioCodec, width: 145)
                        sortableHeaderCell("PATH", column: .path, minWidth: 160, maxWidth: .infinity, alignment: .leading)
                    }
                    .font(.system(size: 9, weight: .bold, design: .monospaced))
                    .foregroundColor(textMuted)
                    .padding(.horizontal, 14)
                    .padding(.vertical, specsDisplayMode == "large" ? 10 : (specsDisplayMode == "thumbnail" ? 8 : 6))
                    .background(bgCardHeader)
                    .contextMenu {
                        Menu("Sort By") {
                            ForEach(SpecsSortColumn.allCases, id: \.self) { col in
                                Button(action: {
                                    toggleSpecsSort(col)
                                }) {
                                    HStack {
                                        Text(col.displayName)
                                        if specsSortColumn == col {
                                            Image(systemName: specsSortAscending ? "chevron.up" : "chevron.down")
                                        }
                                    }
                                }
                            }
                        }
                        Divider()
                        Button(action: { specsSortAscending.toggle() }) {
                            Label(specsSortAscending ? "Ascending" : "Descending", systemImage: specsSortAscending ? "arrow.up" : "arrow.down")
                        }
                    }
                    
                    Rectangle().fill(borderLine).frame(height: 1)
                    
                    // Table Rows
                    ScrollView(.vertical) {
                        VStack(spacing: 0) {
                            let assetMap = deliverableAssetsMap
                            
                            if filteredDeliverableAssets.isEmpty && !specsFilterText.isEmpty {
                                VStack(spacing: 10) {
                                    Spacer().frame(height: 40)
                                    Image(systemName: "line.3.horizontal.decrease.circle")
                                        .font(.system(size: 26))
                                        .foregroundColor(textMuted)
                                    Text("NO ASSETS MATCHING \"\(specsFilterText)\"")
                                        .font(.system(size: 11, weight: .bold, design: .monospaced))
                                        .foregroundColor(textMuted)
                                    Button(action: { specsFilterText = "" }) {
                                        Text("CLEAR FILTER")
                                            .font(.system(size: 10, weight: .bold, design: .monospaced))
                                            .foregroundColor(accentBlue)
                                    }
                                    .buttonStyle(.plain)
                                    Spacer().frame(height: 40)
                                }
                                .frame(maxWidth: .infinity)
                            } else if hasDeliverablesSubfolders {
                                let nodes = flattenedDeliverableNodes
                                let nodeCount = nodes.count
                                let nonDirNodes = nodes.filter { !$0.isDirectory }
                                let assetIndexMap: [URL: Int] = Dictionary(uniqueKeysWithValues: nonDirNodes.enumerated().map { ($0.element.url, $0.offset) })
                                
                                ForEach(Array(nodes.enumerated()), id: \.element.id) { idx, node in
                                    if node.isDirectory {
                                        deliverablesFolderBannerRow(node: node, assetMap: assetMap)
                                    } else if let asset = assetMap[node.url] {
                                        let assetIdx = assetIndexMap[node.url] ?? idx
                                        deliverablesAssetRow(idx: assetIdx, asset: asset, depth: node.depth)
                                            .id("\(node.url.path)_\(specsDisplayMode)_\(Int(specsThumbnailWidth))")
                                    }
                                    
                                    if idx < nodeCount - 1 {
                                        Rectangle().fill(borderLine.opacity(0.4)).frame(height: 1)
                                    }
                                }
                            } else {
                                let assets = filteredDeliverableAssets
                                let assetCount = assets.count
                                ForEach(Array(assets.enumerated()), id: \.element.id) { idx, asset in
                                    deliverablesAssetRow(idx: idx, asset: asset, depth: 0)
                                        .id("\(asset.fileURL.path)_\(specsDisplayMode)_\(Int(specsThumbnailWidth))")
                                    
                                    if idx < assetCount - 1 {
                                        Rectangle().fill(borderLine.opacity(0.4)).frame(height: 1)
                                    }
                                }
                            }
                        }
                    }
                }
                .frame(minWidth: specsTableMinWidth, maxWidth: .infinity, alignment: .leading)
            }
            .studioBox(background: bgPanel, border: borderLine)
        }
        .padding(28)
    }
    
    // MARK: - Column Resizing & Width Helpers
    
    var effectiveFileNameColumnWidth: Double {
        isDraggingFileNameColumn ? liveFileNameColumnWidth : specsFileNameColumnWidth
    }
    
    var isFileNameExpanded: Bool {
        effectiveFileNameColumnWidth > 240.0
    }
    
    func autoFitFileNameColumnWidth() {
        if isFileNameExpanded {
            withAnimation(.easeInOut(duration: 0.15)) {
                specsFileNameColumnWidth = 220.0
                liveFileNameColumnWidth = 220.0
            }
        } else {
            let longestName = filteredDeliverableAssets.map { $0.fileName }.max(by: { $0.count < $1.count }) ?? ""
            let estWidth = Double(longestName.count) * 7.5 + 40.0
            let targetWidth = max(260.0, min(1000.0, estWidth))
            withAnimation(.easeInOut(duration: 0.15)) {
                specsFileNameColumnWidth = targetWidth
                liveFileNameColumnWidth = targetWidth
            }
        }
    }
    
    var specsThumbnailWidth: Double {
        specsDisplayMode == "thumbnail" ? max(36.0, min(110.0, specsThumbnailSize)) : 0.0
    }
    
    var specsTableMinWidth: CGFloat {
        let previewWidth: CGFloat = CGFloat(specsThumbnailWidth)
        let otherColumnsWidth: CGFloat = 25 + previewWidth + 142 + 152 + 60 + 75 + 110 + 85 + 145 + 160 + (8 * 11) + 28
        return CGFloat(effectiveFileNameColumnWidth) + otherColumnsWidth
    }
    
    // MARK: - Finder-Style Column Sorting Helpers
    
    func toggleSpecsSort(_ column: SpecsSortColumn) {
        withAnimation(.easeInOut(duration: 0.15)) {
            if specsSortColumn == column {
                specsSortAscending.toggle()
            } else {
                specsSortColumn = column
                if column == .date || column == .size {
                    specsSortAscending = false
                } else {
                    specsSortAscending = true
                }
            }
        }
    }
    
    private func sortableHeaderCell(
        _ title: String,
        column: SpecsSortColumn,
        width: CGFloat? = nil,
        minWidth: CGFloat? = nil,
        maxWidth: CGFloat? = nil,
        alignment: Alignment = .center
    ) -> some View {
        let isCurrent = specsSortColumn == column
        return Button(action: { toggleSpecsSort(column) }) {
            HStack(spacing: 3) {
                Text(title)
                    .lineLimit(1)
                    .foregroundColor(isCurrent ? textMain : textMuted)
                
                if isCurrent {
                    Image(systemName: specsSortAscending ? "chevron.up" : "chevron.down")
                        .font(.system(size: 7, weight: .black))
                        .foregroundColor(accentBlue)
                }
            }
            .frame(
                minWidth: minWidth,
                idealWidth: width,
                maxWidth: maxWidth ?? width,
                alignment: alignment
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .explain("Sort by \(title.lowercased()) (\(isCurrent ? (specsSortAscending ? "ascending" : "descending") : "click to sort")).", binding: $hoverExplanation)
    }
    
    func sortDeliverableAssets(_ assets: [DeliverableAsset]) -> [DeliverableAsset] {
        assets.sorted { a, b in
            let order: ComparisonResult
            switch specsSortColumn {
            case .name:
                order = a.fileName.localizedStandardCompare(b.fileName)
            case .timecode:
                if a.durationSeconds == b.durationSeconds {
                    order = a.fileName.localizedStandardCompare(b.fileName)
                } else {
                    order = a.durationSeconds < b.durationSeconds ? .orderedAscending : .orderedDescending
                }
            case .ratio:
                let aPixels = a.width * a.height
                let bPixels = b.width * b.height
                if aPixels == bPixels {
                    order = a.aspectRatioString.compare(b.aspectRatioString)
                } else {
                    order = aPixels < bPixels ? .orderedAscending : .orderedDescending
                }
            case .fps:
                if a.fps == b.fps {
                    order = a.fileName.localizedStandardCompare(b.fileName)
                } else {
                    order = a.fps < b.fps ? .orderedAscending : .orderedDescending
                }
            case .size:
                if a.fileSizeBytes == b.fileSizeBytes {
                    order = a.fileName.localizedStandardCompare(b.fileName)
                } else {
                    order = a.fileSizeBytes < b.fileSizeBytes ? .orderedAscending : .orderedDescending
                }
            case .date:
                let aDate = a.creationDate ?? .distantPast
                let bDate = b.creationDate ?? .distantPast
                if aDate == bDate {
                    order = a.fileName.localizedStandardCompare(b.fileName)
                } else {
                    order = aDate < bDate ? .orderedAscending : .orderedDescending
                }
            case .videoCodec:
                if a.videoCodec == b.videoCodec {
                    order = a.fileName.localizedStandardCompare(b.fileName)
                } else {
                    order = a.videoCodec.localizedStandardCompare(b.videoCodec)
                }
            case .audioCodec:
                let aAudio = "\(a.audioCodec) \(a.audioBitrate)"
                let bAudio = "\(b.audioCodec) \(b.audioBitrate)"
                if aAudio == bAudio {
                    order = a.fileName.localizedStandardCompare(b.fileName)
                } else {
                    order = aAudio.localizedStandardCompare(bAudio)
                }
            case .path:
                order = a.fileURL.path.localizedStandardCompare(b.fileURL.path)
            }
            
            return specsSortAscending ? (order == .orderedAscending) : (order == .orderedDescending)
        }
    }
    
    // MARK: - Deliverables Filtering & Hierarchy Helpers
    
    var filteredDeliverableAssets: [DeliverableAsset] {
        let q = specsFilterText.trimmingCharacters(in: .whitespacesAndNewlines)
        let base: [DeliverableAsset]
        if q.isEmpty {
            base = deliverableAssets
        } else {
            base = deliverableAssets.filter {
                $0.fileName.localizedCaseInsensitiveContains(q) ||
                $0.fileURL.path.localizedCaseInsensitiveContains(q)
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
    
    var flattenedDeliverableNodes: [FileSystemTreeNode] {
        FileSystemTreeBuilder.flatten(
            nodes: deliverablesTree,
            collapsedIDs: deliverablesCollapsedFolderIDs,
            hiddenIDs: hiddenFolderIDs,
            hideAllFolders: hideAllFolders
        )
    }
    
    var deliverableAssetsMap: [URL: DeliverableAsset] {
        Dictionary(uniqueKeysWithValues: filteredDeliverableAssets.map { ($0.fileURL, $0) })
    }
    
    private func toggleAllDeliverablesFolders() {
        if deliverablesCollapsedFolderIDs.isEmpty {
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
            deliverablesCollapsedFolderIDs = Set(deliverablesTree.flatMap { collectFolderIDs($0) })
        } else {
            deliverablesCollapsedFolderIDs.removeAll()
        }
    }
    
    private func deliverablesFolderBannerRow(node: FileSystemTreeNode, assetMap: [URL: DeliverableAsset]) -> some View {
        let isCollapsed = deliverablesCollapsedFolderIDs.contains(node.id)
        let folderAssets = node.videoURLs.compactMap { assetMap[$0] }
        let folderMismatches = folderAssets.filter { $0.validation.hasAnyMismatch }.count
        let totalBytes = folderAssets.reduce(Int64(0)) { $0 + $1.fileSizeBytes }
        let totalSeconds = folderAssets.reduce(0.0) { $0 + $1.durationSeconds }
        let formattedSize = DeliverablesInspector.formatFileSize(bytes: totalBytes)
        let formattedDur = TimecodeFormatter.format(frameIndex: Int(round(totalSeconds * 25.0)), fps: 25.0)
        
        return HStack(spacing: 8) {
            Image(systemName: isCollapsed ? "chevron.right" : "chevron.down")
                .font(.system(size: 9, weight: .bold))
                .foregroundColor(textMuted)
                .frame(width: 25, alignment: .center)
            
            HStack(spacing: 6) {
                Image(systemName: "folder")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundColor(textSubtle)
                    .frame(width: 14, height: 14)
                
                Text(node.relativePath.isEmpty ? node.name.uppercased() : "\(node.relativePath.uppercased())/")
                    .font(.system(size: 11, weight: .black, design: .monospaced))
                    .foregroundColor(textMain)
                    .lineLimit(1)
                
                Text("(\(node.videoCount) \(node.videoCount == 1 ? "ASSET" : "ASSETS"))")
                    .font(.system(size: 9, weight: .bold, design: .monospaced))
                    .foregroundColor(textMuted)
            }
            .padding(.leading, CGFloat(node.depth * 14))
            
            Spacer()
            
            HStack(spacing: 12) {
                Text(formattedDur)
                    .font(.system(size: 9, weight: .bold, design: .monospaced))
                    .foregroundColor(textSubtle)
                
                Text(formattedSize)
                    .font(.system(size: 9, weight: .bold, design: .monospaced))
                    .foregroundColor(textSubtle)
                
                if folderMismatches > 0 {
                    Text("\(folderMismatches) MISMATCH\(folderMismatches == 1 ? "" : "ES")")
                        .font(.system(size: 8, weight: .black, design: .monospaced))
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(RoundedRectangle(cornerRadius: 4).fill(alertRed))
                        .foregroundColor(.white)
                }
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
        .background(bgCardHeader)
        .contentShape(Rectangle())
        .onTapGesture {
            if isCollapsed {
                deliverablesCollapsedFolderIDs.remove(node.id)
            } else {
                deliverablesCollapsedFolderIDs.insert(node.id)
            }
        }
        .explain(node.url.path, binding: $hoverExplanation)
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
    
    private func deliverablesAssetRow(idx: Int, asset: DeliverableAsset, depth: Int = 0) -> some View {
        let hasMismatch = asset.validation.hasAnyMismatch
        let isSelected = selectedDeliverableURL?.standardizedFileURL == asset.fileURL.standardizedFileURL
        
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
                if hasDeliverablesSubfolders && depth > 0 && !hideAllFolders {
                    Spacer().frame(width: CGFloat((depth - 1) * 12 + 4))
                    Image(systemName: "arrow.turn.down.right")
                        .font(.system(size: 8, weight: .bold))
                        .foregroundColor(textMuted.opacity(0.55))
                }
                
                if let tag = fileTagsMap[asset.fileURL] {
                    Circle()
                        .fill(tag.color)
                        .frame(width: 6, height: 6)
                }
                
                Text(asset.fileName.uppercased())
                    .fontWeight(.bold)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .foregroundColor(isSelected ? textMain : (hasMismatch ? alertRed : textMain))
                    .help(asset.fileName)
                    .contentShape(Rectangle())
                    .onTapGesture(count: 2) {
                        playDeliverableInPlayer(url: asset.fileURL)
                    }
                
                Button(action: {
                    selectedDeliverableURL = asset.fileURL
                    openProperties(for: asset.fileURL)
                }) {
                    Image(systemName: "info.circle")
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundColor(isSelected ? accentBlue : textMuted.opacity(0.65))
                }
                .buttonStyle(.plain)
                .help("Media Info (⌘I)")
            }
            .frame(width: CGFloat(effectiveFileNameColumnWidth), alignment: .leading)
            
            // Timecode Cell with Warning
            VStack(alignment: .center, spacing: 3) {
                Text(asset.timecode)
                    .foregroundColor(asset.validation.isDurationMismatch ? alertRed : textSubtle)
                    .fontWeight(asset.validation.isDurationMismatch ? .bold : .regular)
                
                if let detail = asset.validation.durationMismatchDetail {
                    HStack(spacing: 3) {
                        Image(systemName: "exclamationmark.triangle.fill")
                            .font(.system(size: 7, weight: .bold))
                        Text(detail)
                            .font(.system(size: 8, weight: .black, design: .monospaced))
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
                    .help("Duration Mismatch: \(detail) (Actual Timecode: \(asset.timecode))")
                }
            }
            .frame(width: 142, alignment: .center)
            
            // Ratio Cell with Warning
            VStack(alignment: .center, spacing: 3) {
                HStack(spacing: 4) {
                    Text(asset.aspectRatioString)
                        .font(.system(size: 9, weight: .bold, design: .monospaced))
                        .padding(.horizontal, 4)
                        .padding(.vertical, 2)
                        .foregroundColor(asset.validation.isRatioMismatch ? .white : textMain)
                        .studioBox(background: asset.validation.isRatioMismatch ? alertRed : bgSubtle, border: asset.validation.isRatioMismatch ? alertRed : borderLine)
                    
                    Text(asset.resolutionString)
                        .foregroundColor(textSubtle)
                }
                
                if let detail = asset.validation.ratioMismatchDetail {
                    HStack(spacing: 3) {
                        Image(systemName: "exclamationmark.triangle.fill")
                            .font(.system(size: 7, weight: .bold))
                        Text(detail)
                            .font(.system(size: 8, weight: .black, design: .monospaced))
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
                    .help("Aspect Ratio Mismatch: \(detail) (Actual Resolution: \(asset.resolutionString))")
                }
            }
            .frame(width: 152, alignment: .center)
            
            Text(String(format: "%.2f", asset.fps))
                .frame(width: 60, alignment: .center)
                .foregroundColor(textSubtle)
            
            Text(asset.formattedFileSize)
                .frame(width: 75, alignment: .center)
                .fontWeight(.semibold)
            
            // Creation Date Column
            Text(asset.formattedCreationDate)
                .font(.system(size: 9, design: .monospaced))
                .foregroundColor(textSubtle)
                .frame(width: 110, alignment: .center)
            
            Text(asset.videoCodec)
                .frame(width: 85, alignment: .center)
                .foregroundColor(textMuted)
                .lineLimit(1)
            
            // Audio Column
            if !asset.hasAudio {
                Text("NONE")
                    .font(.system(size: 9, weight: .bold, design: .monospaced))
                    .foregroundColor(textMuted)
                    .frame(width: 145, alignment: .center)
            } else {
                VStack(alignment: .center, spacing: 3) {
                    HStack(spacing: 4) {
                        Text(asset.audioCodec)
                            .font(.system(size: 10, weight: .bold, design: .monospaced))
                            .foregroundColor(textMain)
                        if asset.audioBitrate != "--" {
                            Text(asset.audioBitrate)
                                .font(.system(size: 8, weight: .bold, design: .monospaced))
                                .padding(.horizontal, 4)
                                .padding(.vertical, 1)
                                .foregroundColor(textSubtle)
                                .studioBox(background: bgSubtle, border: borderLine)
                        }
                    }
                    
                    if asset.validation.isAudioMute {
                        HStack(spacing: 3) {
                            Image(systemName: "speaker.slash.fill")
                                .font(.system(size: 7, weight: .bold))
                            Text(asset.validation.audioMuteDetail ?? "MUTE")
                                .font(.system(size: 8, weight: .bold, design: .monospaced))
                        }
                        .padding(.horizontal, 5)
                        .padding(.vertical, 1.5)
                        .foregroundColor(accentPositive)
                        .background(accentPositive.opacity(0.12))
                        .overlay(
                            RoundedRectangle(cornerRadius: 3)
                                .stroke(accentPositive.opacity(0.35), lineWidth: 0.8)
                        )
                        .cornerRadius(3)
                        .lineLimit(1)
                        .minimumScaleFactor(0.8)
                        .help("Audio Track is Mute: \(asset.audioLevelString) (Codec: \(asset.audioCodec))")
                    } else {
                        HStack(spacing: 4) {
                            if !asset.audioLevelString.isEmpty && asset.audioLevelString != "--" {
                                Text(asset.audioLevelString)
                                    .font(.system(size: 8, weight: .bold, design: .monospaced))
                                    .foregroundColor(accentPositive)
                            }
                            if !asset.audioFormatDetail.isEmpty {
                                Text(asset.audioFormatDetail)
                                    .font(.system(size: 8, weight: .medium, design: .monospaced))
                                    .foregroundColor(textMuted)
                                    .lineLimit(1)
                            }
                        }
                    }
                }
                .frame(width: 145, alignment: .center)
                .help(asset.audioConfig + (asset.audioLevelString.isEmpty ? "" : "\nPeak Level: \(asset.audioLevelString)"))
            }
            
            Text(asset.fileURL.path)
                .font(.system(size: 10, design: .monospaced))
                .foregroundColor(textSubtle)
                .frame(minWidth: 160, maxWidth: .infinity, alignment: .leading)
                .lineLimit(1)
                .truncationMode(.middle)
        }
        .font(.system(size: 11, design: .monospaced))
        .padding(.horizontal, 14)
        .padding(.vertical, specsDisplayMode == "large" ? 10 : (specsDisplayMode == "thumbnail" ? 7 : 4))
        .background(
            isSelected ? accentBlue.opacity(0.14) : (hasMismatch ? alertRed.opacity(0.12) : (idx % 2 == 0 ? bgPanel : bgCardSubtle))
        )
        .overlay(
            isSelected ? Rectangle().fill(accentBlue).frame(width: 3) : (hasMismatch ? Rectangle().fill(alertRed).frame(width: 3) : nil),
            alignment: .leading
        )
        .contentShape(Rectangle())
        .onTapGesture {
            selectedDeliverableURL = asset.fileURL
        }
        .simultaneousGesture(
            TapGesture(count: 2).onEnded {
                selectedDeliverableURL = asset.fileURL
                playDeliverableInPlayer(url: asset.fileURL)
            }
        )
        .explain(asset.fileURL.path, binding: $hoverExplanation)
        .contextMenu {
            Button(action: {
                selectedDeliverableURL = asset.fileURL
                playDeliverableInPlayer(url: asset.fileURL)
            }) {
                Label("Play in Player (Tab 1)", systemImage: "play.fill")
            }
            Divider()
            Button(action: {
                selectedDeliverableURL = asset.fileURL
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
            Menu("Tags") {
                let currentTag = fileTagsMap[asset.fileURL]
                ForEach(FinderTagColor.allCases) { tag in
                    Button(action: {
                        toggleFinderTag(tag, for: asset.fileURL)
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
                    setFinderTag(nil, for: asset.fileURL)
                }) {
                    Text("Remove Tag")
                }
            }
        }
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
                withAnimation(.easeInOut(duration: 0.15)) {
                    specsDisplayMode = "inline"
                }
            }) {
                HStack(spacing: 7) {
                    if specsDisplayMode == "inline" {
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
