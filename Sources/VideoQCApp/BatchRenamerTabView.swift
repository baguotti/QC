import SwiftUI
import VideoQCLib

extension ContentView {
    
    // MARK: ==================== TAB 3: BATCH RENAMER ====================
    
    var batchRenamerTabView: some View {
        HSplitView {
            // Left Control Panel
            VStack(alignment: .leading, spacing: 16) {
                // 01 // Assets
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
                                    .background(renameMode == mode ? primaryBtnBg : bgSubtle)
                                    .foregroundColor(renameMode == mode ? primaryBtnFg : textMain)
                                    .border(borderLine, width: 1)
                            }
                            .buttonStyle(.plain)
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
                                    .background(bgSubtle)
                                    .border(borderStrong, width: 1)
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
                                    .background(bgSubtle)
                                    .border(borderStrong, width: 1)
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
                                                .background(bgSubtle)
                                                .foregroundColor(textMain)
                                                .border(borderLine, width: 1)
                                        }
                                        .buttonStyle(.plain)
                                        .help("\(item.label) (e.g. \(item.example))")
                                    }
                                }
                            }
                            
                            HStack(spacing: 10) {
                                VStack(alignment: .leading, spacing: 4) {
                                    Text("CUSTOM TAG {TAG}:")
                                        .font(.system(size: 9, weight: .bold, design: .monospaced))
                                        .foregroundColor(textMuted)
                                    TextField("TAG", text: $customTag)
                                        .textFieldStyle(.plain)
                                        .font(.system(size: 11, weight: .bold, design: .monospaced))
                                        .foregroundColor(textMain)
                                        .padding(6)
                                        .background(bgSubtle)
                                        .border(borderLine, width: 1)
                                }
                                
                                VStack(alignment: .leading, spacing: 4) {
                                    Text("INDEX START:")
                                        .font(.system(size: 9, weight: .bold, design: .monospaced))
                                        .foregroundColor(textMuted)
                                    Stepper("\(indexStart) (PAD: \(indexPadding))", value: $indexStart, in: 1...999)
                                        .font(.system(size: 10, weight: .bold, design: .monospaced))
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
                                .background(bgSubtle)
                                .border(borderLine, width: 1)
                            
                            Text("REPLACE WITH:")
                                .font(.system(size: 9, weight: .bold, design: .monospaced))
                                .foregroundColor(textMuted)
                            TextField("Replace with...", text: $replaceText)
                                .textFieldStyle(.plain)
                                .font(.system(size: 11, weight: .bold, design: .monospaced))
                                .foregroundColor(textMain)
                                .padding(8)
                                .background(bgSubtle)
                                .border(borderLine, width: 1)
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
                                .background(bgSubtle)
                                .border(borderLine, width: 1)
                            
                            Text("SUFFIX (ADD TO END):")
                                .font(.system(size: 9, weight: .bold, design: .monospaced))
                                .foregroundColor(textMuted)
                            TextField("_Suffix", text: $suffixText)
                                .textFieldStyle(.plain)
                                .font(.system(size: 11, weight: .bold, design: .monospaced))
                                .foregroundColor(textMain)
                                .padding(8)
                                .background(bgSubtle)
                                .border(borderLine, width: 1)
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
                                        .background(textCase == opt ? primaryBtnBg : bgSubtle)
                                        .foregroundColor(textCase == opt ? primaryBtnFg : textSubtle)
                                        .border(borderLine, width: 1)
                                }
                                .buttonStyle(.plain)
                            }
                        }
                    }
                }
                
                // 04 // Execution
                VStack(alignment: .leading, spacing: 8) {
                    sectionHeader(num: "04", title: "EXECUTION")
                    
                    let items = renameItems
                    let activeSelectedCount = items.filter { selectedAssetIDs.contains($0.asset.id) && $0.status == .pending }.count
                    let hasCollisions = items.contains { selectedAssetIDs.contains($0.asset.id) && $0.status.isErrorOrCollision }
                    
                    Button(action: executeRename) {
                        Text(hasCollisions ? "[ RESOLVE COLLISIONS FIRST ]" : (activeSelectedCount > 0 ? "[ RENAME \(activeSelectedCount) SELECTED FILE(S) ]" : "[ NO CHANGES TO APPLY ]"))
                            .font(.system(size: 11, weight: .black, design: .monospaced))
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 11)
                            .background(hasCollisions ? alertRed : (activeSelectedCount > 0 ? primaryBtnBg : bgSubtle))
                            .foregroundColor(hasCollisions ? .white : (activeSelectedCount > 0 ? primaryBtnFg : textMuted))
                    }
                    .buttonStyle(.plain)
                    .disabled(activeSelectedCount == 0 || hasCollisions)
                    
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
                            .background(bgSubtle)
                            .foregroundColor(textMain)
                            .border(borderLine, width: 1)
                        }
                        .buttonStyle(.plain)
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
                    renamerResultsView
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
    
    var renamerResultsView: some View {
        let items = renameItems
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
                    Button(action: toggleSelectAll) {
                        Text(selectedAssetIDs.count == deliverableAssets.count ? "[ DESELECT ALL ]" : "[ SELECT ALL ]")
                            .font(.system(size: 11, weight: .bold, design: .monospaced))
                            .padding(.horizontal, 12)
                            .padding(.vertical, 8)
                            .background(bgSubtle)
                            .foregroundColor(textMain)
                            .border(borderLine, width: 1)
                    }
                    .buttonStyle(.plain)
                    
                    if let firstURL = deliverableAssets.first?.fileURL {
                        Button(action: { NSWorkspace.shared.activateFileViewerSelecting([firstURL]) }) {
                            Text("[ FINDER ]")
                                .font(.system(size: 11, weight: .bold, design: .monospaced))
                                .padding(.horizontal, 14)
                                .padding(.vertical, 8)
                                .background(bgSubtle)
                                .foregroundColor(textMain)
                                .border(borderLine, width: 1)
                        }
                        .buttonStyle(.plain)
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
                    VStack(spacing: 0) {
                        ForEach(Array(items.enumerated()), id: \.element.id) { idx, item in
                            let isSelected = selectedAssetIDs.contains(item.asset.id)
                            let isCollision = isSelected && item.status.isErrorOrCollision
                            let isUnchanged = isSelected && item.status == .unchanged
                            
                            HStack(spacing: 8) {
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
                                
                                Text(item.originalName + (item.originalExtension.isEmpty ? "" : ".\(item.originalExtension)"))
                                    .frame(minWidth: 150, maxWidth: .infinity, alignment: .leading)
                                    .foregroundColor(isSelected ? textMuted : textMuted.opacity(0.35))
                                    .lineLimit(1)
                                    .truncationMode(.middle)
                                
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
                                Text(isSelected ? item.status.badgeText : "EXCLUDED")
                                    .font(.system(size: 8, weight: .black, design: .monospaced))
                                    .padding(.horizontal, 6)
                                    .padding(.vertical, 2)
                                    .background(!isSelected ? bgSubtle.opacity(0.5) : (isCollision ? alertRed : (isUnchanged ? bgSubtle : primaryBtnBg)))
                                    .foregroundColor(!isSelected ? textMuted.opacity(0.6) : (isCollision ? .white : (isUnchanged ? textMuted : primaryBtnFg)))
                                    .border(isCollision ? alertRed : borderLine, width: 1)
                                    .frame(width: 110, alignment: .trailing)
                            }
                            .font(.system(size: 11, design: .monospaced))
                            .padding(.horizontal, 14)
                            .padding(.vertical, 9)
                            .background(
                                isCollision ? (isLightMode ? Color.red.opacity(0.08) : Color.red.opacity(0.12)) :
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
                            .overlay(
                                isCollision ? Rectangle().fill(alertRed).frame(width: 3) : nil,
                                alignment: .leading
                            )
                            
                            if idx < items.count - 1 {
                                Rectangle().fill(borderLine.opacity(0.4)).frame(height: 1)
                            }
                        }
                    }
                }
            }
            .background(bgPanel)
            .border(borderLine, width: 1)
        }
        .padding(28)
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
