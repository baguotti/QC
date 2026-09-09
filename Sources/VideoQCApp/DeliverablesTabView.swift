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
    
    // MARK: - Left Panel: 02 SPECS ACTIONS
    
    private var specsActionsSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            sectionHeader(num: "02", title: "SPECS ACTIONS")
            
            // View & Display Controls
            VStack(alignment: .leading, spacing: 6) {
                // 1. View Mode Segmented Switcher [ LIST | THUMBS | LARGE ]
                HStack(spacing: 0) {
                    ForEach([("inline", "LIST", "list.bullet"),
                             ("thumbnail", "THUMBS", "photo"),
                             ("large", "LARGE", "photo.fill")], id: \.0) { modeId, label, icon in
                        let isActive = specsDisplayMode == modeId
                        Button(action: { specsDisplayMode = modeId }) {
                            HStack(spacing: 4) {
                                Image(systemName: icon)
                                    .font(.system(size: 8, weight: .bold))
                                Text(label)
                                    .font(.system(size: 9, weight: .bold, design: .monospaced))
                            }
                            .frame(maxWidth: .infinity, alignment: .center)
                            .frame(height: 26)
                            .background(isActive ? (isLightMode ? Color.white : bgCardHeader) : Color.clear)
                            .foregroundColor(isActive ? textMain : textMuted)
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                    }
                }
                .padding(1)
                .studioBox(background: bgSubtle, border: borderLine, radius: StudioTheme.cornerRadius)
                .explain("Table view mode: Compact List, Thumbnails, or Large Previews.", binding: $hoverExplanation)
                
                // 2. Table Layout Options: Fit Name & Folders
                HStack(spacing: 6) {
                    Button(action: { autoFitFileNameColumnWidth() }) {
                        HStack(spacing: 4) {
                            Image(systemName: isFileNameExpanded ? "arrow.right.and.line.vertical.and.arrow.left" : "arrow.left.and.line.vertical.and.arrow.right")
                                .font(.system(size: 8, weight: .bold))
                            Text(isFileNameExpanded ? "RESET NAME" : "FIT NAME")
                                .font(.system(size: 10, weight: .bold, design: .monospaced))
                        }
                        .frame(maxWidth: .infinity, alignment: .center)
                        .frame(height: 28)
                        .foregroundColor(isFileNameExpanded ? textMain : (deliverableAssets.isEmpty ? textMuted : textSubtle))
                        .studioBox(background: isFileNameExpanded ? bgCardHeader : bgSubtle, border: isFileNameExpanded ? borderStrong : borderLine)
                    }
                    .buttonStyle(.plain)
                    .disabled(deliverableAssets.isEmpty)
                    .explain(isFileNameExpanded ? "Reset File Name column width back to default (220px)." : "Auto-fit File Name column to fit longest filename without truncation.", binding: $hoverExplanation)
                    
                    if hasDeliverablesSubfolders {
                        Menu {
                            Button(action: toggleHideFolders) {
                                Label(hideAllFolders || !hiddenFolderIDs.isEmpty ? "Show Folder Groups" : "Hide Folder Groups (Flat List)",
                                      systemImage: hideAllFolders || !hiddenFolderIDs.isEmpty ? "folder.badge.plus" : "list.bullet")
                            }
                            if !hideAllFolders {
                                Divider()
                                Button(action: toggleAllDeliverablesFolders) {
                                    Label(deliverablesCollapsedFolderIDs.isEmpty ? "Collapse All Folders" : "Expand All Folders",
                                          systemImage: deliverablesCollapsedFolderIDs.isEmpty ? "chevron.down.square" : "chevron.right.square")
                                }
                            }
                        } label: {
                            HStack(spacing: 4) {
                                Image(systemName: "folder")
                                    .font(.system(size: 9, weight: .bold))
                                Text("FOLDERS")
                                    .font(.system(size: 10, weight: .bold, design: .monospaced))
                                Image(systemName: "chevron.down")
                                    .font(.system(size: 7, weight: .bold))
                            }
                            .frame(maxWidth: .infinity, alignment: .center)
                            .frame(height: 28)
                            .foregroundColor(textMain)
                            .studioBox(background: bgSubtle, border: borderLine)
                        }
                        .menuStyle(.borderlessButton)
                        .menuIndicator(.hidden)
                        .explain("Folder hierarchy: Toggle grouping vs flat list, collapse or expand all subfolders.", binding: $hoverExplanation)
                    }
                }
            }
            
            Rectangle()
                .fill(borderLine.opacity(0.6))
                .frame(height: 1)
                .padding(.vertical, 2)
            
            // Actions & Export Controls
            VStack(spacing: 6) {
                // Rescan Button
                Button(action: rescanDeliverables) {
                    HStack(spacing: 5) {
                        Image(systemName: "arrow.clockwise")
                            .font(.system(size: 9, weight: .bold))
                        Text("RESCAN FOLDER / ASSETS")
                            .font(.system(size: 10, weight: .bold, design: .monospaced))
                    }
                    .frame(maxWidth: .infinity, alignment: .center)
                    .frame(height: 28)
                    .foregroundColor((videoFiles.isEmpty && folderURL == nil) ? textMuted : textMain)
                    .studioBox(background: bgSubtle, border: borderLine)
                }
                .buttonStyle(.plain)
                .disabled((videoFiles.isEmpty && folderURL == nil) || isInspectingDeliverables)
                .explain("Re-inspects all video files and refreshes stream metadata.", binding: $hoverExplanation)
                
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
        let totalBytes = deliverableAssets.reduce(Int64(0)) { $0 + $1.fileSizeBytes }
        let totalSeconds = deliverableAssets.reduce(0.0) { $0 + $1.durationSeconds }
        let mismatchCount = deliverableAssets.filter { $0.validation.hasAnyMismatch }.count
        
        return VStack(alignment: .leading, spacing: 20) {
            // Header: Clean audit status
            HStack(alignment: .center) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("AUDIT COMPLETE")
                        .font(.system(size: 28, weight: .black, design: .default))
                        .foregroundColor(textMain)
                        .tracking(1.0)
                    Text("\(deliverableAssets.count) ASSETS ANALYZED")
                        .font(.system(size: 11, weight: .bold, design: .monospaced))
                        .foregroundColor(textMuted)
                }
                Spacer()
            }
            
            // Quick Stats Strip
            HStack(spacing: 12) {
                statBox(title: "TOTAL ASSETS", val: String(format: "%02d", deliverableAssets.count))
                statBox(title: "NAME MISMATCHES", val: String(format: "%02d", mismatchCount), isRed: mismatchCount > 0, isPositive: mismatchCount == 0 && !deliverableAssets.isEmpty)
                statBox(title: "TOTAL RUNTIME", val: TimecodeFormatter.format(frameIndex: Int(round(totalSeconds * 25.0)), fps: 25.0))
                statBox(title: "TOTAL BATCH SIZE", val: DeliverablesInspector.formatFileSize(bytes: totalBytes))
            }
            
            // Table
            ScrollView(.horizontal, showsIndicators: true) {
                VStack(alignment: .leading, spacing: 0) {
                    // Table Header
                    HStack(spacing: 8) {
                        Text("#").frame(width: 25, alignment: .center)
                        if specsDisplayMode == "large" {
                            Text("PREVIEW").frame(width: 86, alignment: .center)
                        } else if specsDisplayMode == "thumbnail" {
                            Text("PREVIEW").frame(width: 54, alignment: .center)
                        }
                        
                        // Resizable File Name Column Header
                        HStack(spacing: 0) {
                            Text("FILE NAME")
                                .lineLimit(1)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .contentShape(Rectangle())
                                .onTapGesture(count: 2) {
                                    autoFitFileNameColumnWidth()
                                }
                            
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
                        .explain("Drag divider to resize File Name column. Double-click text to auto-fit full names.", binding: $hoverExplanation)
                        
                        Text("TIMECODE (TC)").frame(width: 130, alignment: .center)
                        Text("RATIO & SIZE").frame(width: 135, alignment: .center)
                        Text("FPS").frame(width: 60, alignment: .center)
                        Text("FILE SIZE").frame(width: 75, alignment: .center)
                        Text("CREATED").frame(width: 110, alignment: .center)
                        Text("VIDEO").frame(width: 85, alignment: .center)
                        Text("AUDIO SPEC").frame(width: 145, alignment: .center)
                        Text("PATH").frame(minWidth: 160, maxWidth: .infinity, alignment: .leading)
                    }
                    .font(.system(size: 9, weight: .bold, design: .monospaced))
                    .foregroundColor(textMuted)
                    .padding(.horizontal, 14)
                    .padding(.vertical, specsDisplayMode == "large" ? 10 : (specsDisplayMode == "thumbnail" ? 8 : 6))
                    .background(bgCardHeader)
                    
                    Rectangle().fill(borderLine).frame(height: 1)
                    
                    // Table Rows
                    ScrollView(.vertical) {
                        VStack(spacing: 0) {
                            let assetMap = deliverableAssetsMap
                            
                            if hasDeliverablesSubfolders {
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
                                    }
                                    
                                    if idx < nodeCount - 1 {
                                        Rectangle().fill(borderLine.opacity(0.4)).frame(height: 1)
                                    }
                                }
                            } else {
                                let assets = deliverableAssets
                                let assetCount = assets.count
                                ForEach(Array(assets.enumerated()), id: \.element.id) { idx, asset in
                                    deliverablesAssetRow(idx: idx, asset: asset, depth: 0)
                                    
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
            let longestName = deliverableAssets.map { $0.fileName }.max(by: { $0.count < $1.count }) ?? ""
            let estWidth = Double(longestName.count) * 7.5 + 40.0
            let targetWidth = max(260.0, min(1000.0, estWidth))
            withAnimation(.easeInOut(duration: 0.15)) {
                specsFileNameColumnWidth = targetWidth
                liveFileNameColumnWidth = targetWidth
            }
        }
    }
    
    var specsTableMinWidth: CGFloat {
        let previewWidth: CGFloat = (specsDisplayMode == "large" ? 86 : (specsDisplayMode == "thumbnail" ? 54 : 0))
        let otherColumnsWidth: CGFloat = 25 + previewWidth + 130 + 135 + 60 + 75 + 110 + 85 + 145 + 160 + (8 * 11) + 28
        return CGFloat(effectiveFileNameColumnWidth) + otherColumnsWidth
    }
    
    // MARK: - Deliverables Hierarchy Helpers
    
    var deliverablesTree: [FileSystemTreeNode] {
        FileSystemTreeBuilder.buildTree(rootURL: folderURL, files: deliverableAssets.map { $0.fileURL })
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
        Dictionary(uniqueKeysWithValues: deliverableAssets.map { ($0.fileURL, $0) })
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
            
            if specsDisplayMode == "large" {
                AssetThumbnailView(fileURL: asset.fileURL, width: 80, height: 46, cornerRadius: 3.5)
                    .frame(width: 86, alignment: .center)
            } else if specsDisplayMode == "thumbnail" {
                AssetThumbnailView(fileURL: asset.fileURL, width: 50, height: 29, cornerRadius: 2)
                    .frame(width: 54, alignment: .center)
            }
            
            HStack(spacing: 4) {
                if hasDeliverablesSubfolders && depth > 0 && !hideAllFolders {
                    Spacer().frame(width: CGFloat((depth - 1) * 12 + 4))
                    Image(systemName: "arrow.turn.down.right")
                        .font(.system(size: 8, weight: .bold))
                        .foregroundColor(textMuted.opacity(0.55))
                }
                
                Text(asset.fileName.uppercased())
                    .fontWeight(.bold)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .foregroundColor(isSelected ? textMain : (hasMismatch ? alertRed : textMain))
                    .help(asset.fileName)
                
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
            VStack(alignment: .center, spacing: 2) {
                Text(asset.timecode)
                    .foregroundColor(asset.validation.isDurationMismatch ? alertRed : textSubtle)
                    .fontWeight(asset.validation.isDurationMismatch ? .bold : .regular)
                
                if let detail = asset.validation.durationMismatchDetail {
                    Text(detail)
                        .font(.system(size: 8, weight: .heavy, design: .monospaced))
                        .foregroundColor(alertRed)
                        .lineLimit(1)
                }
            }
            .frame(width: 130, alignment: .center)
            
            // Ratio Cell with Warning
            VStack(alignment: .center, spacing: 2) {
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
                    Text(detail)
                        .font(.system(size: 8, weight: .heavy, design: .monospaced))
                        .foregroundColor(alertRed)
                        .lineLimit(1)
                }
            }
            .frame(width: 135, alignment: .center)
            
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
                VStack(alignment: .center, spacing: 2) {
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
                    if !asset.audioFormatDetail.isEmpty {
                        Text(asset.audioFormatDetail)
                            .font(.system(size: 8, weight: .medium, design: .monospaced))
                            .foregroundColor(textMuted)
                            .lineLimit(1)
                    }
                }
                .frame(width: 145, alignment: .center)
                .help(asset.audioConfig)
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
                openProperties(for: asset.fileURL)
            }
        )
        .explain(asset.fileURL.path, binding: $hoverExplanation)
        .contextMenu {
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
        }
    }
}
