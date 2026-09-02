import Foundation

public struct RenamerEngine: Sendable {
    
    public static let availableTokens: [(token: String, label: String, example: String)] = [
        ("{NAME}", "Custom Name Field", "NIKE_AIR"),
        ("{ORIGINAL}", "Original Filename", "SPOT_MASTER"),
        ("{DUR}sec", "Duration sec", "15sec"),
        ("{DUR_S}", "Duration s", "15s"),
        ("{RATIO}", "Aspect Ratio", "16x9"),
        ("{TAG}", "Custom Tag", "CLEAN"),
        ("{RES}", "Standard Res", "1080p"),
        ("{DIMS}", "Dimensions", "1920x1080"),
        ("{FPS}", "Framerate", "25fps"),
        ("{CODEC}", "Video Codec", "ProRes422HQ"),
        ("{AUDIO}", "Audio Spec", "Stereo"),
        ("{TC}", "SMPTE Timecode", "00-00-15-00"),
        ("{INDEX}", "Sequence Index", "01"),
        ("{DATE}", "Date Stamp", "20260902")
    ]
    
    // MARK: - Generate Proposed Items
    
    public static func generateProposedItems(
        assets: [DeliverableAsset],
        mode: RenameMode,
        customName: String,
        templateString: String,
        findString: String,
        replaceString: String,
        prefixString: String,
        suffixString: String,
        customTag: String,
        caseOption: TextCaseOption,
        indexStart: Int = 1,
        indexPadding: Int = 2,
        selectedAssetIDs: Set<UUID> = []
    ) -> [RenameItem] {
        guard !assets.isEmpty else { return [] }
        
        let dateFormatted = Self.currentDateString()
        var items: [RenameItem] = []
        var proposedNamesCount: [String: Int] = [:]
        
        for (idx, asset) in assets.enumerated() {
            let isSelected = selectedAssetIDs.isEmpty || selectedAssetIDs.contains(asset.id)
            let originalFullName = asset.fileName
            let ext = (originalFullName as NSString).pathExtension
            let baseName = (originalFullName as NSString).deletingPathExtension
            let currentIndex = indexStart + idx
            let paddedIndex = String(format: "%0\(indexPadding)d", currentIndex)
            
            var proposedBase = ""
            
            if isSelected {
                switch mode {
                case .template:
                    proposedBase = evaluateTemplate(
                        template: templateString,
                        asset: asset,
                        baseName: baseName,
                        customName: customName,
                        customTag: customTag,
                        indexString: paddedIndex,
                        dateString: dateFormatted
                    )
                case .findReplace:
                    if findString.isEmpty {
                        proposedBase = baseName
                    } else {
                        proposedBase = baseName.replacingOccurrences(of: findString, with: replaceString)
                    }
                case .addText:
                    proposedBase = "\(prefixString)\(baseName)\(suffixString)"
                }
                
                // Apply Case Transformation
                proposedBase = applyCase(text: proposedBase, option: caseOption)
                
                // Sanitize illegal filesystem characters
                proposedBase = sanitizeFilename(proposedBase)
                
                if proposedBase.isEmpty {
                    proposedBase = baseName
                }
                
                let proposedFull = ext.isEmpty ? proposedBase : "\(proposedBase).\(ext)"
                proposedNamesCount[proposedFull.lowercased(), default: 0] += 1
            } else {
                // If excluded, keep original base name
                proposedBase = baseName
            }
            
            let item = RenameItem(
                asset: asset,
                originalURL: asset.fileURL,
                originalName: baseName,
                originalExtension: ext,
                proposedName: proposedBase,
                status: isSelected ? .pending : .excluded
            )
            items.append(item)
        }
        
        // Evaluate Collisions and Statuses
        return items.map { item in
            var updated = item
            
            // If item is excluded by user, keep it excluded
            if updated.status == .excluded {
                return updated
            }
            
            let proposedFull = item.proposedFullName
            let originalFull = item.asset.fileName
            
            if proposedFull == originalFull {
                updated.status = .unchanged
                return updated
            }
            
            // Check in-batch collision (only among selected active items)
            if let count = proposedNamesCount[proposedFull.lowercased()], count > 1 {
                updated.status = .collision("Duplicate Name in Batch")
                updated.collisionDetail = "Multiple files resolve to: \(proposedFull)"
                return updated
            }
            
            // Check filesystem collision (if file exists and is not the current file)
            let destinationURL = item.targetURL
            if destinationURL.path != item.originalURL.path && FileManager.default.fileExists(atPath: destinationURL.path) {
                updated.status = .collision("File Exists on Disk")
                updated.collisionDetail = "A file already exists with name: \(proposedFull)"
                return updated
            }
            
            updated.status = .pending
            return updated
        }
    }
    
    // MARK: - Template Token Evaluator
    
    private static func evaluateTemplate(
        template: String,
        asset: DeliverableAsset,
        baseName: String,
        customName: String,
        customTag: String,
        indexString: String,
        dateString: String
    ) -> String {
        var result = template
        if result.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return baseName
        }
        
        let roundedSeconds = Int(round(asset.durationSeconds))
        let paddedSeconds = String(format: "%02d", roundedSeconds)
        let ratioClean = asset.aspectRatioString.replacingOccurrences(of: ":", with: "x")
        let cleanFPS = String(format: asset.fps.truncatingRemainder(dividingBy: 1) == 0 ? "%.0ffps" : "%.2ffps", asset.fps)
        let safeTimecode = asset.timecode.replacingOccurrences(of: ":", with: "-").replacingOccurrences(of: ";", with: "-")
        
        // Standard Resolution Label
        let standardRes: String
        let maxDim = max(asset.width, asset.height)
        let minDim = min(asset.width, asset.height)
        if maxDim >= 3800 || minDim >= 2100 {
            standardRes = "4K"
        } else if maxDim >= 1900 || minDim >= 1080 {
            standardRes = "1080p"
        } else if maxDim >= 1200 || minDim >= 720 {
            standardRes = "720p"
        } else {
            standardRes = "\(asset.height)p"
        }
        
        // Codec Normalizer
        let cleanCodec = asset.videoCodec
            .replacingOccurrences(of: "Apple ", with: "")
            .replacingOccurrences(of: " ", with: "")
            .replacingOccurrences(of: ".", with: "")
        
        // Audio Normalizer
        let cleanAudio: String
        if !asset.hasAudio {
            cleanAudio = "MUTE"
        } else if asset.audioConfig.localizedCaseInsensitiveContains("Stereo") || asset.audioConfig.contains("2ch") {
            cleanAudio = "STEREO"
        } else if asset.audioConfig.localizedCaseInsensitiveContains("5.1") || asset.audioConfig.contains("6ch") {
            cleanAudio = "5.1"
        } else if asset.audioConfig.localizedCaseInsensitiveContains("Mono") || asset.audioConfig.contains("1ch") {
            cleanAudio = "MONO"
        } else {
            cleanAudio = asset.audioCodec
        }
        
        // Custom Name vs Original Name substitution
        let nameToUse = customName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? baseName : customName.trimmingCharacters(in: .whitespacesAndNewlines)
        
        // Replace Tokens
        result = result.replacingOccurrences(of: "{NAME}", with: nameToUse)
        result = result.replacingOccurrences(of: "{ORIGINAL}", with: baseName)
        result = result.replacingOccurrences(of: "{ORIGINAL_NAME}", with: baseName)
        
        result = result.replacingOccurrences(of: "{DUR_SEC}", with: "\(paddedSeconds)sec")
        result = result.replacingOccurrences(of: "{XXsec}", with: "\(paddedSeconds)sec")
        result = result.replacingOccurrences(of: "{DUR_S}", with: "\(paddedSeconds)s")
        result = result.replacingOccurrences(of: "{XXs}", with: "\(paddedSeconds)s")
        result = result.replacingOccurrences(of: "{DUR_PAD}", with: paddedSeconds)
        result = result.replacingOccurrences(of: "{XX}", with: paddedSeconds)
        result = result.replacingOccurrences(of: "{DUR}", with: "\(roundedSeconds)")
        result = result.replacingOccurrences(of: "{DURATION}", with: "\(roundedSeconds)")
        
        result = result.replacingOccurrences(of: "{RATIO}", with: ratioClean)
        result = result.replacingOccurrences(of: "{AR}", with: ratioClean)
        result = result.replacingOccurrences(of: "{RATIO_COLON}", with: asset.aspectRatioString)
        
        result = result.replacingOccurrences(of: "{TAG}", with: customTag.isEmpty ? "CLEAN" : customTag)
        result = result.replacingOccurrences(of: "{RES}", with: standardRes)
        result = result.replacingOccurrences(of: "{DIMS}", with: "\(asset.width)x\(asset.height)")
        result = result.replacingOccurrences(of: "{RESOLUTION}", with: "\(asset.width)x\(asset.height)")
        
        result = result.replacingOccurrences(of: "{FPS}", with: cleanFPS)
        result = result.replacingOccurrences(of: "{CODEC}", with: cleanCodec)
        result = result.replacingOccurrences(of: "{AUDIO}", with: cleanAudio)
        result = result.replacingOccurrences(of: "{TC}", with: safeTimecode)
        result = result.replacingOccurrences(of: "{TIMECODE}", with: safeTimecode)
        result = result.replacingOccurrences(of: "{INDEX}", with: indexString)
        result = result.replacingOccurrences(of: "{COUNTER}", with: indexString)
        result = result.replacingOccurrences(of: "{DATE}", with: dateString)
        
        return result
    }
    
    // MARK: - Case Modifier
    
    private static func applyCase(text: String, option: TextCaseOption) -> String {
        switch option {
        case .uppercase:
            return text.uppercased()
        case .lowercase:
            return text.lowercased()
        case .capitalized:
            return text.capitalized
        case .original:
            return text
        }
    }
    
    // MARK: - Sanitization
    
    public static func sanitizeFilename(_ name: String) -> String {
        // Illegal macOS / Unix filename characters: / and : and Windows safety: \ ? * " < > |
        var clean = name
        let illegalChars = CharacterSet(charactersIn: "/:\\?*\"<>|")
        clean = clean.components(separatedBy: illegalChars).joined(separator: "_")
        
        // Collapse multiple underscores
        while clean.contains("__") {
            clean = clean.replacingOccurrences(of: "__", with: "_")
        }
        
        // Trim leading and trailing underscores and spaces
        clean = clean.trimmingCharacters(in: CharacterSet(charactersIn: " _.-"))
        return clean
    }
    
    private static func currentDateString() -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyyMMdd"
        return formatter.string(from: Date())
    }
    
    // MARK: - Batch Execution & Undo
    
    public static func executeBatchRename(
        items: [RenameItem],
        selectedIDs: Set<UUID>? = nil
    ) -> (successCount: Int, failedCount: Int, transaction: RenameTransaction?) {
        var successEntries: [(oldURL: URL, newURL: URL)] = []
        var failed = 0
        
        for item in items {
            // Check if specifically selected if selectedIDs is provided
            if let sel = selectedIDs, !sel.contains(item.asset.id) {
                continue
            }
            
            guard item.status == .pending else { continue }
            
            let sourceURL = item.originalURL
            let targetURL = item.targetURL
            
            do {
                try FileManager.default.moveItem(at: sourceURL, to: targetURL)
                successEntries.append((oldURL: sourceURL, newURL: targetURL))
            } catch {
                failed += 1
            }
        }
        
        let transaction = successEntries.isEmpty ? nil : RenameTransaction(entries: successEntries)
        return (successEntries.count, failed, transaction)
    }
    
    public static func undoRenameTransaction(_ transaction: RenameTransaction) -> (revertedCount: Int, failedCount: Int) {
        var reverted = 0
        var failed = 0
        
        for entry in transaction.entries.reversed() {
            let currentURL = entry.newURL
            let originalURL = entry.oldURL
            
            if FileManager.default.fileExists(atPath: currentURL.path) {
                do {
                    try FileManager.default.moveItem(at: currentURL, to: originalURL)
                    reverted += 1
                } catch {
                    failed += 1
                }
            } else {
                failed += 1
            }
        }
        
        return (reverted, failed)
    }
}
