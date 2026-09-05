import SwiftUI
import VideoQCLib

extension ContentView {
    
    // MARK: ==================== TAB 3: DELIVERABLES SPECS ====================
    
    var deliverablesTabView: some View {
        HSplitView {
            // Left Control Panel
            VStack(alignment: .leading, spacing: 18) {
                // Unified Asset Picker
                deliveryAssetsSection(forTab: .deliverables)
                
                // Actions
                VStack(alignment: .leading, spacing: 10) {
                    sectionHeader(num: "02", title: "SPECS ACTIONS")
                    
                    Button(action: rescanDeliverables) {
                        HStack {
                            Text("[ RESCAN FOLDER / ASSETS ]")
                                .font(.system(size: 11, weight: .bold, design: .monospaced))
                            Spacer()
                            Image(systemName: "arrow.clockwise")
                                .font(.system(size: 10, weight: .bold))
                        }
                        .frame(maxWidth: .infinity)
                        .padding(.horizontal, 12)
                        .padding(.vertical, 9)
                        .foregroundColor((videoFiles.isEmpty && folderURL == nil) ? textMuted : textMain)
                        .studioBox(background: bgSubtle, border: borderLine)
                    }
                    .buttonStyle(.plain)
                    .disabled((videoFiles.isEmpty && folderURL == nil) || isInspectingDeliverables)
                    .explain("Re-inspects all video files and refreshes stream metadata.", binding: $hoverExplanation)
                    
                    Button(action: {
                        if !deliverableAssets.isEmpty {
                            exportDeliverablesManifest()
                        }
                    }) {
                        Text("[ EXPORT GOOGLE SHEETS / CSV ]")
                            .font(.system(size: 11, weight: .black, design: .monospaced))
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 10)
                            .foregroundColor(deliverableAssets.isEmpty ? textMuted : primaryBtnFg)
                            .studioBox(background: deliverableAssets.isEmpty ? bgSubtle : primaryBtnBg, border: borderLine)
                    }
                    .buttonStyle(.plain)
                    .disabled(deliverableAssets.isEmpty)
                    .explain("Exports the deliverables metadata table to a CSV file.", binding: $hoverExplanation)
                    
                    Button(action: {
                        if !deliverableAssets.isEmpty {
                            openManifestHTML()
                        }
                    }) {
                        Text("[ OPEN HTML SPECS ]")
                            .font(.system(size: 11, weight: .bold, design: .monospaced))
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 9)
                            .foregroundColor(deliverableAssets.isEmpty ? textMuted : textMain)
                            .studioBox(background: bgSubtle, border: borderLine)
                    }
                    .buttonStyle(.plain)
                    .disabled(deliverableAssets.isEmpty)
                    .explain("Generates and opens a formatted HTML delivery specs sheet in browser.", binding: $hoverExplanation)
                    
                    if let firstURL = deliverableAssets.first?.fileURL {
                        Button(action: {
                            NSWorkspace.shared.activateFileViewerSelecting([firstURL])
                        }) {
                            Text("[ REVEAL IN FINDER ]")
                                .font(.system(size: 11, weight: .bold, design: .monospaced))
                                .frame(maxWidth: .infinity)
                                .padding(.vertical, 9)
                                .foregroundColor(textMain)
                                .studioBox(background: bgSubtle, border: borderLine)
                        }
                        .buttonStyle(.plain)
                        .explain("Locates and highlights the first asset in macOS Finder.", binding: $hoverExplanation)
                    }
                    
                    if !deliverableAssets.isEmpty {
                        Button(action: {
                            deliverableAssets = []
                        }) {
                            Text("[ CLEAR LIST ]")
                                .font(.system(size: 10, weight: .bold, design: .monospaced))
                                .foregroundColor(textMuted)
                                .frame(maxWidth: .infinity, alignment: .center)
                                .padding(.top, 6)
                        }
                        .buttonStyle(.plain)
                        .explain("Removes all video assets from the inspection table.", binding: $hoverExplanation)
                    }
                }
                
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
                
                HStack(spacing: 8) {
                    Button(action: rescanDeliverables) {
                        HStack(spacing: 5) {
                            Image(systemName: "arrow.clockwise")
                                .font(.system(size: 9, weight: .bold))
                            Text("[ RESCAN ]")
                                .font(.system(size: 11, weight: .bold, design: .monospaced))
                        }
                        .padding(.horizontal, 12)
                        .padding(.vertical, 8)
                        .foregroundColor(textMain)
                        .studioBox(background: bgSubtle, border: borderLine)
                    }
                    .buttonStyle(.plain)
                    .disabled(isInspectingDeliverables)
                    .explain("Re-inspects all video files and refreshes stream metadata.", binding: $hoverExplanation)
                    
                    Button(action: exportDeliverablesManifest) {
                        Text("[ EXPORT GOOGLE SHEETS / CSV ]")
                            .font(.system(size: 11, weight: .bold, design: .monospaced))
                            .padding(.horizontal, 12)
                            .padding(.vertical, 8)
                            .foregroundColor(primaryBtnFg)
                            .studioBox(background: primaryBtnBg, border: primaryBtnBg)
                    }
                    .buttonStyle(.plain)
                    .explain("Exports the deliverables metadata table to a CSV file.", binding: $hoverExplanation)
                    
                    Button(action: openManifestHTML) {
                        Text("[ OPEN HTML SPECS ]")
                            .font(.system(size: 11, weight: .bold, design: .monospaced))
                            .padding(.horizontal, 12)
                            .padding(.vertical, 8)
                            .foregroundColor(textMain)
                            .studioBox(background: bgSubtle, border: borderLine)
                    }
                    .buttonStyle(.plain)
                    .explain("Generates and opens a formatted HTML delivery specs sheet in browser.", binding: $hoverExplanation)
                                   if let firstURL = deliverableAssets.first?.fileURL {
                        Button(action: { NSWorkspace.shared.activateFileViewerSelecting([firstURL]) }) {
                            Text("[ FINDER ]")
                                .font(.system(size: 11, weight: .bold, design: .monospaced))
                                .padding(.horizontal, 14)
                                .padding(.vertical, 8)
                                .foregroundColor(textMain)
                                .studioBox(background: bgSubtle, border: borderLine)
                        }
                        .buttonStyle(.plain)
                        .explain("Locates and highlights the first asset in macOS Finder.", binding: $hoverExplanation)
                    }
                    
                    if hasDeliverablesSubfolders {
                        Button(action: toggleHideFolders) {
                            Text(hideAllFolders || !hiddenFolderIDs.isEmpty ? "[ SHOW FOLDERS ]" : "[ HIDE FOLDERS ]")
                                .font(.system(size: 11, weight: .bold, design: .monospaced))
                                .padding(.horizontal, 12)
                                .padding(.vertical, 8)
                                .foregroundColor(textMain)
                                .studioBox(background: bgSubtle, border: borderLine)
                        }
                        .buttonStyle(.plain)
                        .explain(hideAllFolders || !hiddenFolderIDs.isEmpty ? "Show all folder banners in the deliverables audit table." : "Hide folder banners and display assets in a flat list.", binding: $hoverExplanation)
                        
                        if !hideAllFolders {
                            Button(action: toggleAllDeliverablesFolders) {
                                Text(deliverablesCollapsedFolderIDs.isEmpty ? "[ COLLAPSE ALL ]" : "[ EXPAND ALL ]")
                                    .font(.system(size: 11, weight: .bold, design: .monospaced))
                                    .padding(.horizontal, 12)
                                    .padding(.vertical, 8)
                                    .foregroundColor(textMain)
                                    .studioBox(background: bgSubtle, border: borderLine)
                            }
                            .buttonStyle(.plain)
                            .explain(deliverablesCollapsedFolderIDs.isEmpty ? "Collapse all subfolders in the deliverables audit table." : "Expand all subfolders in the deliverables audit table.", binding: $hoverExplanation)
                        }
                    }
                }
            }
            
            // Quick Stats Strip
            HStack(spacing: 12) {
                statBox(title: "TOTAL ASSETS", val: String(format: "%02d", deliverableAssets.count))
                statBox(title: "NAME MISMATCHES", val: String(format: "%02d", mismatchCount), isRed: mismatchCount > 0, isPositive: mismatchCount == 0 && !deliverableAssets.isEmpty)
                statBox(title: "TOTAL RUNTIME", val: TimecodeFormatter.format(frameIndex: Int(round(totalSeconds * 25.0)), fps: 25.0))
                statBox(title: "TOTAL BATCH SIZE", val: DeliverablesInspector.formatFileSize(bytes: totalBytes))
            }
            
            // Table
            VStack(alignment: .leading, spacing: 0) {
                // Table Header
                HStack(spacing: 8) {
                    Text("#").frame(width: 25, alignment: .center)
                    Text("FILE NAME").frame(minWidth: 140, maxWidth: 220, alignment: .leading)
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
                .padding(.vertical, 9)
                .background(bgCardHeader)
                
                Rectangle().fill(borderLine).frame(height: 1)
                
                // Table Rows
                ScrollView {
                    VStack(spacing: 0) {
                        let assetMap = deliverableAssetsMap
                        
                        if hasDeliverablesSubfolders {
                            let nodes = flattenedDeliverableNodes
                            let nodeCount = nodes.count
                            ForEach(Array(nodes.enumerated()), id: \.element.id) { idx, node in
                                if node.isDirectory {
                                    deliverablesFolderBannerRow(node: node, assetMap: assetMap)
                                } else if let asset = assetMap[node.url] {
                                    deliverablesAssetRow(idx: idx, asset: asset, depth: node.depth)
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
            .studioBox(background: bgPanel, border: borderLine)
        }
        .padding(28)
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
                Image(systemName: "folder.fill")
                    .font(.system(size: 11))
                    .foregroundColor(textSubtle)
                
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
        
        return HStack(spacing: 8) {
            Text(String(format: "%02d", idx + 1))
                .frame(width: 25, alignment: .center)
                .foregroundColor(textMuted)
            
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
                    .help(asset.fileName)
            }
            .frame(minWidth: 140, maxWidth: 220, alignment: .leading)
            
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
        .padding(.vertical, 9)
        .background(hasMismatch ? alertRed.opacity(0.12) : (idx % 2 == 0 ? bgPanel : bgCardSubtle))
        .overlay(
            hasMismatch ? Rectangle().fill(alertRed).frame(width: 3) : nil,
            alignment: .leading
        )
        .contentShape(Rectangle())
        .explain(asset.fileURL.path, binding: $hoverExplanation)
        .contextMenu {
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
