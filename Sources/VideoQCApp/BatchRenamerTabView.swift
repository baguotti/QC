import SwiftUI
import VideoQCLib

extension ContentView {
    
    // MARK: ==================== TAB 4: BATCH RENAMER ====================
    
    var batchRenamerTabView: some View {
        let items = renameItems
        return HSplitView {
            // Left Control Panel
            VStack(alignment: .leading, spacing: 16) {
                // 01 // Load Assets
                deliveryAssetsSection(forTab: .batchRenamer)
                
                // 02 // Rename Mode
                VStack(alignment: .leading, spacing: 10) {
                    sectionHeader(num: "02", title: "RENAME MODE")
                    
                    HStack(spacing: 6) {
                        ForEach(RenameMode.allCases) { mode in
                            Button(action: { renameMode = mode }) {
                                Text(mode.rawValue)
                                    .font(.system(size: 9, weight: .bold, design: .monospaced))
                                    .frame(maxWidth: .infinity)
                                    .padding(.vertical, 6)
                                    .foregroundColor(renameMode == mode ? primaryBtnFg : textMain)
                                    .studioBox(background: renameMode == mode ? primaryBtnBg : bgSubtle, border: borderLine)
                            }
                            .buttonStyle(.plain)
                            .explain("Sets rename mode to \(mode.rawValue).", binding: $hoverExplanation)
                        }
                    }
                }
                
                // 03 // Pattern & Rules Builder
                VStack(alignment: .leading, spacing: 10) {
                    sectionHeader(num: "03", title: "PATTERN & RULES")
                    
                    if renameMode == .template {
                        VStack(alignment: .leading, spacing: 8) {
                            // 1. Custom Name Field for {NAME}
                            VStack(alignment: .leading, spacing: 4) {
                                Text("PROJECT / ASSET NAME {NAME}:")
                                    .font(.system(size: 9, weight: .bold, design: .monospaced))
                                    .foregroundColor(textMuted)
                                TextField("e.g. NIKE_AIR (leave blank for original)", text: $customNameText)
                                    .textFieldStyle(.plain)
                                    .font(.system(size: 11, weight: .bold, design: .monospaced))
                                    .foregroundColor(textMain)
                                    .padding(7)
                                    .studioBox(background: bgSubtle, border: borderStrong)
                                    .explain("Custom text to replace the {NAME} token.", binding: $hoverExplanation)
                            }
                            
                            // 2. Template Structure
                            VStack(alignment: .leading, spacing: 4) {
                                Text("TEMPLATE STRUCTURE:")
                                    .font(.system(size: 9, weight: .bold, design: .monospaced))
                                    .foregroundColor(textMuted)
                                
                                TextField("e.g. {NAME}_{DUR}sec_{RATIO}_{TAG}", text: $templateText)
                                    .textFieldStyle(.plain)
                                    .font(.system(size: 11, weight: .bold, design: .monospaced))
                                    .foregroundColor(textMain)
                                    .padding(7)
                                    .studioBox(background: bgSubtle, border: borderStrong)
                                    .explain("Naming pattern string using bracketed tokens.", binding: $hoverExplanation)
                            }
                            
                            Text("CLICK TO INSERT TOKEN:")
                                .font(.system(size: 8, weight: .bold, design: .monospaced))
                                .foregroundColor(textMuted)
                            
                            // Token Chips ScrollView
                            ScrollView(.horizontal, showsIndicators: false) {
                                HStack(spacing: 5) {
                                    ForEach(RenamerEngine.availableTokens, id: \.token) { item in
                                        Button(action: {
                                            insertToken(item.token)
                                        }) {
                                            Text(item.token)
                                                .font(.system(size: 9, weight: .bold, design: .monospaced))
                                                .padding(.horizontal, 6)
                                                .padding(.vertical, 3)
                                                .foregroundColor(textMain)
                                                .studioBox(background: bgSubtle, border: borderLine)
                                        }
                                        .buttonStyle(.plain)
                                        .explain("Inserts \(item.token) (\(item.label), e.g. \(item.example)).", binding: $hoverExplanation)
                                    }
                                }
                            }
                            
                            HStack(spacing: 8) {
                                VStack(alignment: .leading, spacing: 4) {
                                    Text("TAG 1 {TAG1}:")
                                        .font(.system(size: 9, weight: .bold, design: .monospaced))
                                        .foregroundColor(textMuted)
                                    TextField("e.g. CLEAN", text: $customTag1)
                                        .textFieldStyle(.plain)
                                        .font(.system(size: 11, weight: .bold, design: .monospaced))
                                        .foregroundColor(textMain)
                                        .padding(6)
                                        .studioBox(background: bgSubtle, border: borderLine)
                                        .explain("Tag 1 token {TAG1} / {TAG}. Added to filename when typed.", binding: $hoverExplanation)
                                }
                                
                                VStack(alignment: .leading, spacing: 4) {
                                    Text("TAG 2 {TAG2}:")
                                        .font(.system(size: 9, weight: .bold, design: .monospaced))
                                        .foregroundColor(textMuted)
                                    TextField("e.g. SUBS", text: $customTag2)
                                        .textFieldStyle(.plain)
                                        .font(.system(size: 11, weight: .bold, design: .monospaced))
                                        .foregroundColor(textMain)
                                        .padding(6)
                                        .studioBox(background: bgSubtle, border: borderLine)
                                        .explain("Tag 2 token {TAG2}. Added to filename when typed.", binding: $hoverExplanation)
                                }
                                
                                VStack(alignment: .leading, spacing: 4) {
                                    Text("TAG 3 {TAG3}:")
                                        .font(.system(size: 9, weight: .bold, design: .monospaced))
                                        .foregroundColor(textMuted)
                                    TextField("e.g. V01", text: $customTag3)
                                        .textFieldStyle(.plain)
                                        .font(.system(size: 11, weight: .bold, design: .monospaced))
                                        .foregroundColor(textMain)
                                        .padding(6)
                                        .studioBox(background: bgSubtle, border: borderLine)
                                        .explain("Tag 3 token {TAG3}. Added to filename when typed.", binding: $hoverExplanation)
                                }
                                
                                VStack(alignment: .leading, spacing: 4) {
                                    Text("INDEX START:")
                                        .font(.system(size: 9, weight: .bold, design: .monospaced))
                                        .foregroundColor(textMuted)
                                    Stepper("\(indexStart) (PAD: \(indexPadding))", value: $indexStart, in: 1...999)
                                        .font(.system(size: 10, weight: .bold, design: .monospaced))
                                        .explain("Starting number and digit padding for {INDEX} token.", binding: $hoverExplanation)
                                }
                            }
                        }
                    } else if renameMode == .findReplace {
                        VStack(alignment: .leading, spacing: 8) {
                            Text("FIND TEXT:")
                                .font(.system(size: 9, weight: .bold, design: .monospaced))
                                .foregroundColor(textMuted)
                            TextField("Find text in filename...", text: $findText)
                                .textFieldStyle(.plain)
                                .font(.system(size: 11, weight: .bold, design: .monospaced))
                                .foregroundColor(textMain)
                                .padding(8)
                                .studioBox(background: bgSubtle, border: borderLine)
                                .explain("Text characters to find in filenames.", binding: $hoverExplanation)
                            
                            Text("REPLACE WITH:")
                                .font(.system(size: 9, weight: .bold, design: .monospaced))
                                .foregroundColor(textMuted)
                            TextField("Replace with...", text: $replaceText)
                                .textFieldStyle(.plain)
                                .font(.system(size: 11, weight: .bold, design: .monospaced))
                                .foregroundColor(textMain)
                                .padding(8)
                                .studioBox(background: bgSubtle, border: borderLine)
                                .explain("Replacement text for matched search strings.", binding: $hoverExplanation)
                        }
                    } else {
                        VStack(alignment: .leading, spacing: 8) {
                            Text("PREFIX (ADD TO START):")
                                .font(.system(size: 9, weight: .bold, design: .monospaced))
                                .foregroundColor(textMuted)
                            TextField("Prefix_", text: $prefixText)
                                .textFieldStyle(.plain)
                                .font(.system(size: 11, weight: .bold, design: .monospaced))
                                .foregroundColor(textMain)
                                .padding(8)
                                .studioBox(background: bgSubtle, border: borderLine)
                                .explain("Text prepended to start of filenames.", binding: $hoverExplanation)
                            
                            Text("SUFFIX (ADD TO END):")
                                .font(.system(size: 9, weight: .bold, design: .monospaced))
                                .foregroundColor(textMuted)
                            TextField("_Suffix", text: $suffixText)
                                .textFieldStyle(.plain)
                                .font(.system(size: 11, weight: .bold, design: .monospaced))
                                .foregroundColor(textMain)
                                .padding(8)
                                .studioBox(background: bgSubtle, border: borderLine)
                                .explain("Text appended to end of filenames.", binding: $hoverExplanation)
                        }
                    }
                    
                    // Case Formatting
                    VStack(alignment: .leading, spacing: 4) {
                        Text("TEXT CASING:")
                            .font(.system(size: 9, weight: .bold, design: .monospaced))
                            .foregroundColor(textMuted)
                        
                        HStack(spacing: 5) {
                            ForEach(TextCaseOption.allCases) { opt in
                                Button(action: { textCase = opt }) {
                                    Text(opt.rawValue)
                                        .font(.system(size: 8, weight: .bold, design: .monospaced))
                                        .frame(maxWidth: .infinity)
                                        .padding(.vertical, 5)
                                        .foregroundColor(textCase == opt ? primaryBtnFg : textSubtle)
                                        .studioBox(background: textCase == opt ? primaryBtnBg : bgSubtle, border: borderLine)
                                }
                                .buttonStyle(.plain)
                                .explain("Applies \(opt.rawValue) letter casing to filenames.", binding: $hoverExplanation)
                            }
                        }
                    }
                }
                
                // 04 // Execution
                VStack(alignment: .leading, spacing: 8) {
                    sectionHeader(num: "04", title: "EXECUTION")
                    
                    let activeSelectedCount = items.filter { selectedAssetIDs.contains($0.asset.id) && $0.status == .pending }.count
                    let hasCollisions = items.contains { selectedAssetIDs.contains($0.asset.id) && $0.status.isErrorOrCollision }
                    
                    Button(action: executeRename) {
                        Text(hasCollisions ? "[ RESOLVE COLLISIONS FIRST ]" : (activeSelectedCount > 0 ? "[ RENAME \(activeSelectedCount) SELECTED FILE(S) ]" : "[ NO CHANGES TO APPLY ]"))
                            .font(.system(size: 11, weight: .black, design: .monospaced))
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 11)
                            .foregroundColor(hasCollisions ? .white : (activeSelectedCount > 0 ? primaryBtnFg : textMuted))
                            .studioBox(background: hasCollisions ? alertRed : (activeSelectedCount > 0 ? primaryBtnBg : bgSubtle), border: borderLine)
                    }
                    .buttonStyle(.plain)
                    .disabled(activeSelectedCount == 0 || hasCollisions)
                    .explain(
                        hasCollisions ? "Cannot rename: resolve duplicate name collisions first." :
                        (activeSelectedCount > 0 ? "Renames \(activeSelectedCount) selected files on disk." : "No name changes to apply."),
                        binding: $hoverExplanation
                    )
                    
                    if let trans = lastTransaction {
                        Button(action: undoLastRename) {
                            HStack {
                                Image(systemName: "arrow.uturn.backward")
                                    .font(.system(size: 9, weight: .bold))
                                Text("[ UNDO / REVERT (\(trans.entries.count) FILES) ]")
                                    .font(.system(size: 10, weight: .bold, design: .monospaced))
                            }
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 8)
                            .foregroundColor(textMain)
                            .studioBox(background: bgSubtle, border: borderLine)
                        }
                        .buttonStyle(.plain)
                        .explain("Reverses the last rename operation and restores original filenames on disk.", binding: $hoverExplanation)
                    }
                }
                
                Spacer(minLength: 0)
            }
            .padding(22)
            .frame(minWidth: 360, idealWidth: 400, maxWidth: 440)
            .background(bgPanel)
            
            // Right Panel
            VStack(alignment: .leading, spacing: 0) {
                if deliverableAssets.isEmpty {
                    emptyRenamerStateView
                } else {
                    renamerResultsView(items: items)
                }
            }
            .frame(minWidth: 540)
            .background(bgMain)
        }
    }
    
    var emptyRenamerStateView: some View {
        VStack(alignment: .leading, spacing: 18) {
            Spacer()
            
            Text("STATUS // READY TO BATCH RENAME")
                .font(.system(size: 32, weight: .black, design: .default))
                .foregroundColor(textMain)
                .tracking(1.0)
            
            Text("CHOOSE A DELIVERY FOLDER OR VIDEO FILES ON THE LEFT TO AUTOMATICALLY RENAME ASSETS ACCORDING TO SPECS.\nSUPPORTS SMART DURATION TOKENS, ASPECT RATIOS, RESOLUTIONS, AUDIO, CODEC, AND CUSTOM TAGS.")
                .font(.system(size: 12, weight: .medium, design: .monospaced))
                .foregroundColor(textMuted)
                .lineSpacing(4)
            
            Rectangle()
                .fill(borderLine)
                .frame(height: 1)
            
            HStack(spacing: 16) {
                formatTag("{NAME}")
                formatTag("{XXsec}")
                formatTag("{RATIO}")
                formatTag("{TAG}")
                formatTag("{RES}")
                formatTag("{FPS}")
            }
            
            Spacer()
        }
        .padding(40)
    }
    
    func renamerResultsView(items: [RenameItem]) -> some View {
        let totalCount = items.count
        let selectedCount = selectedAssetIDs.count
        let readyCount = items.filter { selectedAssetIDs.contains($0.asset.id) && $0.status == .pending }.count
        let collisionCount = items.filter { selectedAssetIDs.contains($0.asset.id) && $0.status.isErrorOrCollision }.count
        let unchangedCount = items.filter { selectedAssetIDs.contains($0.asset.id) && $0.status == .unchanged }.count
        let excludedCount = items.filter { !selectedAssetIDs.contains($0.asset.id) }.count
        
        return VStack(alignment: .leading, spacing: 20) {
            HStack(alignment: .center) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("LIVE BATCH PREVIEW")
                        .font(.system(size: 28, weight: .black, design: .default))
                        .foregroundColor(textMain)
                        .tracking(1.0)
                    Text("\(selectedCount) OF \(totalCount) ASSETS SELECTED // SELECT INDIVIDUAL FILES BELOW")
                        .font(.system(size: 11, weight: .bold, design: .monospaced))
                        .foregroundColor(textMuted)
                }
                Spacer()
                
                HStack(spacing: 8) {
                    if hasRenamerSubfolders {
                        Button(action: toggleAllRenamerFolders) {
                            Text(renamerCollapsedFolderIDs.isEmpty ? "[ COLLAPSE ALL ]" : "[ EXPAND ALL ]")
                                .font(.system(size: 11, weight: .bold, design: .monospaced))
                                .padding(.horizontal, 12)
                                .padding(.vertical, 8)
                                .foregroundColor(textMain)
                                .studioBox(background: bgSubtle, border: borderLine)
                        }
                        .buttonStyle(.plain)
                        .explain(renamerCollapsedFolderIDs.isEmpty ? "Collapse all subfolders in the batch rename list." : "Expand all subfolders in the batch rename list.", binding: $hoverExplanation)
                    }
                    
                    Button(action: toggleSelectAll) {
                        Text(selectedAssetIDs.count == deliverableAssets.count ? "[ DESELECT ALL ]" : "[ SELECT ALL ]")
                            .font(.system(size: 11, weight: .bold, design: .monospaced))
                            .padding(.horizontal, 12)
                            .padding(.vertical, 8)
                            .foregroundColor(textMain)
                            .studioBox(background: bgSubtle, border: borderLine)
                    }
                    .buttonStyle(.plain)
                    .explain("Selects or deselects all files in the batch list.", binding: $hoverExplanation)
                    
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
                        .explain("Locates and highlights the first file in macOS Finder.", binding: $hoverExplanation)
                    }
                }
            }
            
            // Quick Stats Strip
            HStack(spacing: 12) {
                statBox(title: "TOTAL ASSETS", val: String(format: "%02d", totalCount))
                statBox(title: "TO BE RENAMED", val: String(format: "%02d", readyCount))
                statBox(title: "COLLISIONS", val: String(format: "%02d", collisionCount), isRed: collisionCount > 0)
                statBox(title: "EXCLUDED / UNCHANGED", val: String(format: "%02d", excludedCount + unchangedCount))
            }
            
            // Table
            VStack(alignment: .leading, spacing: 0) {
                // Table Header
                HStack(spacing: 8) {
                    // Select All Toggle Column
                    Button(action: toggleSelectAll) {
                        HStack(spacing: 6) {
                            Image(systemName: selectedAssetIDs.count == deliverableAssets.count && !deliverableAssets.isEmpty ? "checkmark.square.fill" : (selectedAssetIDs.isEmpty ? "square" : "minus.square.fill"))
                                .font(.system(size: 12, weight: .bold))
                                .foregroundColor(textMain)
                            Text("#")
                                .font(.system(size: 9, weight: .bold, design: .monospaced))
                                .foregroundColor(textMuted)
                        }
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .explain("Selects or deselects all files in the batch list.", binding: $hoverExplanation)
                    .frame(width: 55, alignment: .leading)
                    
                    Text("CURRENT FILE NAME").frame(minWidth: 150, maxWidth: .infinity, alignment: .leading)
                    Text("➔").frame(width: 20, alignment: .center)
                    Text("PROPOSED NEW NAME").frame(minWidth: 170, maxWidth: .infinity, alignment: .leading)
                    Text("SPECS APPLIED").frame(width: 140, alignment: .leading)
                    Text("STATUS").frame(width: 110, alignment: .trailing)
                }
                .font(.system(size: 9, weight: .bold, design: .monospaced))
                .foregroundColor(textMuted)
                .padding(.horizontal, 14)
                .padding(.vertical, 9)
                .background(bgCardHeader)
                
                Rectangle().fill(borderLine).frame(height: 1)
                
                // Table Rows
                ScrollView {
                    LazyVStack(spacing: 0) {
                        let itemMap = renameItemsMap
                        
                        if hasRenamerSubfolders {
                            let nodes = flattenedRenamerNodes
                            let nodeCount = nodes.count
                            ForEach(Array(nodes.enumerated()), id: \.element.id) { idx, node in
                                if node.isDirectory {
                                    renamerFolderBannerRow(node: node, itemsMap: itemMap)
                                } else if let item = itemMap[node.url] {
                                    renamerItemRow(idx: idx, item: item, depth: node.depth)
                                }
                                
                                if idx < nodeCount - 1 {
                                    Rectangle().fill(borderLine.opacity(0.4)).frame(height: 1)
                                }
                            }
                        } else {
                            let itemCount = items.count
                            ForEach(Array(items.enumerated()), id: \.element.id) { idx, item in
                                renamerItemRow(idx: idx, item: item, depth: 0)
                                
                                if idx < itemCount - 1 {
                                    Rectangle().fill(borderLine.opacity(0.4)).frame(height: 1)
                                }
                            }
                        }
                    }
                }
                .explain("Batch Items Table: Click any row or checkbox to include or exclude assets from renaming.", binding: $hoverExplanation)
            }
            .studioBox(background: bgPanel, border: borderLine)
        }
        .padding(28)
    }
    
    // MARK: - Batch Renamer Hierarchy Helpers
    
    var renamerTree: [FileSystemTreeNode] {
        FileSystemTreeBuilder.buildTree(rootURL: folderURL, files: deliverableAssets.map { $0.fileURL })
    }
    
    var hasRenamerSubfolders: Bool {
        FileSystemTreeBuilder.hasSubfolders(in: renamerTree)
    }
    
    var flattenedRenamerNodes: [FileSystemTreeNode] {
        FileSystemTreeBuilder.flatten(
            nodes: renamerTree,
            collapsedIDs: renamerCollapsedFolderIDs,
            hiddenIDs: hiddenFolderIDs,
            hideAllFolders: hideAllFolders
        )
    }
    
    var renameItemsMap: [URL: RenameItem] {
        Dictionary(uniqueKeysWithValues: renameItems.map { ($0.originalURL, $0) })
    }
    
    private func toggleAllRenamerFolders() {
        if renamerCollapsedFolderIDs.isEmpty {
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
            renamerCollapsedFolderIDs = Set(renamerTree.flatMap { collectFolderIDs($0) })
        } else {
            renamerCollapsedFolderIDs.removeAll()
        }
    }
    
    private func renamerFolderBannerRow(node: FileSystemTreeNode, itemsMap: [URL: RenameItem]) -> some View {
        let isCollapsed = renamerCollapsedFolderIDs.contains(node.id)
        let folderItems = node.videoURLs.compactMap { itemsMap[$0] }
        let folderSelectedCount = folderItems.filter { selectedAssetIDs.contains($0.asset.id) }.count
        let folderCollisionCount = folderItems.filter { selectedAssetIDs.contains($0.asset.id) && $0.status.isErrorOrCollision }.count
        let allSelected = !folderItems.isEmpty && folderSelectedCount == folderItems.count
        let noneSelected = folderSelectedCount == 0
        
        return HStack(spacing: 8) {
            // Folder Checkbox / Toggle
            Button(action: {
                if allSelected {
                    for item in folderItems {
                        selectedAssetIDs.remove(item.asset.id)
                    }
                } else {
                    for item in folderItems {
                        selectedAssetIDs.insert(item.asset.id)
                    }
                }
            }) {
                HStack(spacing: 6) {
                    Image(systemName: allSelected ? "checkmark.square.fill" : (noneSelected ? "square" : "minus.square.fill"))
                        .font(.system(size: 12, weight: .bold))
                        .foregroundColor(allSelected ? primaryBtnBg : (noneSelected ? textMuted : primaryBtnBg))
                    
                    Image(systemName: isCollapsed ? "chevron.right" : "chevron.down")
                        .font(.system(size: 9, weight: .bold))
                        .foregroundColor(textMuted)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .explain("Toggle selection for all assets in this folder.", binding: $hoverExplanation)
            .frame(width: 55, alignment: .leading)
            
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
                Text("\(folderSelectedCount) OF \(folderItems.count) SELECTED")
                    .font(.system(size: 9, weight: .bold, design: .monospaced))
                    .foregroundColor(textSubtle)
                
                if folderCollisionCount > 0 {
                    Text("\(folderCollisionCount) COLLISION\(folderCollisionCount == 1 ? "" : "S")")
                        .font(.system(size: 8, weight: .black, design: .monospaced))
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(RoundedRectangle(cornerRadius: 4).fill(alertRed))
                        .foregroundColor(.white)
                }
            }
            .frame(width: 250, alignment: .trailing)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
        .background(bgSubtle.opacity(0.85))
        .contentShape(Rectangle())
        .onTapGesture {
            if isCollapsed {
                renamerCollapsedFolderIDs.remove(node.id)
            } else {
                renamerCollapsedFolderIDs.insert(node.id)
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
            Divider()
            Button("Select All in Folder") {
                for item in folderItems {
                    selectedAssetIDs.insert(item.asset.id)
                }
            }
            Button("Deselect All in Folder") {
                for item in folderItems {
                    selectedAssetIDs.remove(item.asset.id)
                }
            }
        }
    }
    
    private func renamerItemRow(idx: Int, item: RenameItem, depth: Int = 0) -> some View {
        let isSelected = selectedAssetIDs.contains(item.asset.id)
        let isCollision = isSelected && item.status.isErrorOrCollision
        let isUnchanged = isSelected && item.status == .unchanged
        
        return HStack(spacing: 8) {
            // Large Checkbox + Index Number
            HStack(spacing: 6) {
                Image(systemName: isSelected ? "checkmark.square.fill" : "square")
                    .font(.system(size: 13, weight: .bold))
                    .foregroundColor(isSelected ? primaryBtnBg : textMuted)
                
                Text(String(format: "%02d", idx + 1))
                    .font(.system(size: 10, weight: .bold, design: .monospaced))
                    .foregroundColor(isSelected ? textMain : textMuted)
            }
            .frame(width: 55, alignment: .leading)
            
            HStack(spacing: 4) {
                if hasRenamerSubfolders && depth > 0 {
                    Spacer().frame(width: CGFloat((depth - 1) * 12 + 4))
                    Image(systemName: "arrow.turn.down.right")
                        .font(.system(size: 8, weight: .bold))
                        .foregroundColor(textMuted.opacity(0.55))
                }
                Text(item.originalName + (item.originalExtension.isEmpty ? "" : ".\(item.originalExtension)"))
                    .foregroundColor(isSelected ? textMuted : textMuted.opacity(0.35))
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            .frame(minWidth: 150, maxWidth: .infinity, alignment: .leading)
            
            Text("➔")
                .frame(width: 20, alignment: .center)
                .foregroundColor(isSelected ? textSubtle : textMuted.opacity(0.25))
                .font(.system(size: 10, weight: .bold))
            
            VStack(alignment: .leading, spacing: 2) {
                Text(isSelected ? item.proposedFullName : "\(item.originalName).\(item.originalExtension)")
                    .fontWeight(.bold)
                    .foregroundColor(!isSelected ? textMuted.opacity(0.35) : (isCollision ? alertRed : (isUnchanged ? textMuted : textMain)))
                    .lineLimit(1)
                    .truncationMode(.middle)
                
                if isSelected, let col = item.collisionDetail {
                    Text(col)
                        .font(.system(size: 8, weight: .heavy, design: .monospaced))
                        .foregroundColor(alertRed)
                        .lineLimit(1)
                }
            }
            .frame(minWidth: 170, maxWidth: .infinity, alignment: .leading)
            
            Text("\(item.asset.aspectRatioString) • \(Int(round(item.asset.durationSeconds)))s • \(item.asset.videoCodec)")
                .frame(width: 140, alignment: .leading)
                .foregroundColor(isSelected ? textSubtle : textMuted.opacity(0.35))
                .lineLimit(1)
            
            // Status Badge
            let badgeBg: Color = {
                if !isSelected { return bgSubtle.opacity(0.5) }
                if isCollision { return alertRed }
                if item.status == .renamed { return accentPositive }
                if isUnchanged { return bgSubtle }
                return primaryBtnBg
            }()
            let badgeFg: Color = {
                if !isSelected { return textMuted.opacity(0.6) }
                if isCollision || item.status == .renamed { return .white }
                if isUnchanged { return textMuted }
                return primaryBtnFg
            }()
            let badgeBorder: Color = {
                if isCollision { return alertRed }
                if item.status == .renamed { return accentPositive }
                return borderLine
            }()
            
            Text(isSelected ? item.status.badgeText : "EXCLUDED")
                .font(.system(size: 8, weight: .black, design: .monospaced))
                .padding(.horizontal, 6)
                .padding(.vertical, 2)
                .foregroundColor(badgeFg)
                .background(RoundedRectangle(cornerRadius: 4).fill(badgeBg))
                .overlay(RoundedRectangle(cornerRadius: 4).stroke(badgeBorder, lineWidth: 1))
                .frame(width: 110, alignment: .trailing)
        }
        .font(.system(size: 11, design: .monospaced))
        .padding(.horizontal, 14)
        .padding(.vertical, 9)
        .background(
            isCollision ? alertRed.opacity(0.12) :
            (isSelected ? (idx % 2 == 0 ? bgPanel : bgCardSubtle) : (isLightMode ? Color(white: 0.94) : Color(white: 0.04)))
        )
        .contentShape(Rectangle())
        .onTapGesture {
            if isSelected {
                selectedAssetIDs.remove(item.asset.id)
            } else {
                selectedAssetIDs.insert(item.asset.id)
            }
        }
        .explain(item.originalURL.path, binding: $hoverExplanation)
        .overlay(
            isCollision ? Rectangle().fill(alertRed).frame(width: 3) : nil,
            alignment: .leading
        )
        .contextMenu {
            Button("Copy Path") {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(item.originalURL.path, forType: .string)
            }
            Button("Reveal in Finder") {
                NSWorkspace.shared.activateFileViewerSelecting([item.originalURL])
            }
            Divider()
            Button(isSelected ? "Exclude from Renaming" : "Include in Renaming") {
                if isSelected {
                    selectedAssetIDs.remove(item.asset.id)
                } else {
                    selectedAssetIDs.insert(item.asset.id)
                }
            }
        }
    }
    
    func toggleSelectAll() {
        if selectedAssetIDs.count == deliverableAssets.count {
            selectedAssetIDs.removeAll()
        } else {
            selectedAssetIDs = Set(deliverableAssets.map { $0.id })
        }
    }
    
    func insertToken(_ token: String) {
        if templateText.isEmpty {
            templateText = token
        } else {
            templateText += "_\(token)"
        }
    }
    
    func executeRename() {
        let items = renameItems
        let result = RenamerEngine.executeBatchRename(items: items, selectedIDs: selectedAssetIDs)
        if let transaction = result.transaction {
            self.lastTransaction = transaction
        }
        
        // Refresh deliverable assets
        if let folder = folderURL {
            let updatedFiles = VideoScanner.findVideoFiles(in: folder)
            self.videoFiles = updatedFiles
            inspectDeliverablesBatch(urls: updatedFiles)
        } else if !videoFiles.isEmpty {
            if let transaction = result.transaction {
                let urlMap = Dictionary(uniqueKeysWithValues: transaction.entries.map { ($0.oldURL, $0.newURL) })
                let updated = self.videoFiles.map { urlMap[$0] ?? $0 }
                self.videoFiles = updated
                inspectDeliverablesBatch(urls: updated)
            }
        }
    }
    
    func undoLastRename() {
        guard let trans = lastTransaction else { return }
        _ = RenamerEngine.undoRenameTransaction(trans)
        self.lastTransaction = nil
        
        // Refresh deliverable assets
        if let folder = folderURL {
            let updatedFiles = VideoScanner.findVideoFiles(in: folder)
            self.videoFiles = updatedFiles
            inspectDeliverablesBatch(urls: updatedFiles)
        } else if !videoFiles.isEmpty {
            let urlMap = Dictionary(uniqueKeysWithValues: trans.entries.map { ($0.newURL, $0.oldURL) })
            let updated = self.videoFiles.map { urlMap[$0] ?? $0 }
            self.videoFiles = updated
            inspectDeliverablesBatch(urls: updated)
        }
    }
}
