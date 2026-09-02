import SwiftUI
import VideoQCLib

extension ContentView {
    
    // MARK: ==================== TAB 2: DELIVERABLES SPECS ====================
    
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
                        .background(bgSubtle)
                        .foregroundColor((videoFiles.isEmpty && folderURL == nil) ? textMuted : textMain)
                        .border(borderLine, width: 1)
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
                            .background(deliverableAssets.isEmpty ? bgSubtle : primaryBtnBg)
                            .foregroundColor(deliverableAssets.isEmpty ? textMuted : primaryBtnFg)
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
                            .background(bgSubtle)
                            .foregroundColor(deliverableAssets.isEmpty ? textMuted : textMain)
                            .border(borderLine, width: 1)
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
                                .background(bgSubtle)
                                .foregroundColor(textMain)
                                .border(borderLine, width: 1)
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
                        .background(bgSubtle)
                        .foregroundColor(textMain)
                        .border(borderLine, width: 1)
                    }
                    .buttonStyle(.plain)
                    .disabled(isInspectingDeliverables)
                    .explain("Re-inspects all video files and refreshes stream metadata.", binding: $hoverExplanation)
                    
                    Button(action: exportDeliverablesManifest) {
                        Text("[ EXPORT GOOGLE SHEETS / CSV ]")
                            .font(.system(size: 11, weight: .bold, design: .monospaced))
                            .padding(.horizontal, 12)
                            .padding(.vertical, 8)
                            .background(primaryBtnBg)
                            .foregroundColor(primaryBtnFg)
                    }
                    .buttonStyle(.plain)
                    .explain("Exports the deliverables metadata table to a CSV file.", binding: $hoverExplanation)
                    
                    Button(action: openManifestHTML) {
                        Text("[ OPEN HTML SPECS ]")
                            .font(.system(size: 11, weight: .bold, design: .monospaced))
                            .padding(.horizontal, 12)
                            .padding(.vertical, 8)
                            .background(bgSubtle)
                            .foregroundColor(textMain)
                            .border(borderLine, width: 1)
                    }
                    .buttonStyle(.plain)
                    .explain("Generates and opens a formatted HTML delivery specs sheet in browser.", binding: $hoverExplanation)
                    
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
                        .explain("Locates and highlights the first asset in macOS Finder.", binding: $hoverExplanation)
                    }
                }
            }
            
            // Quick Stats Strip
            HStack(spacing: 12) {
                statBox(title: "TOTAL ASSETS", val: String(format: "%02d", deliverableAssets.count))
                statBox(title: "NAME MISMATCHES", val: String(format: "%02d", mismatchCount), isRed: mismatchCount > 0)
                statBox(title: "TOTAL RUNTIME", val: TimecodeFormatter.format(frameIndex: Int(round(totalSeconds * 25.0)), fps: 25.0))
                statBox(title: "TOTAL BATCH SIZE", val: DeliverablesInspector.formatFileSize(bytes: totalBytes))
            }
            
            // Table
            VStack(alignment: .leading, spacing: 0) {
                // Table Header
                HStack(spacing: 8) {
                    Text("#").frame(width: 25, alignment: .leading)
                    Text("FILE NAME").frame(minWidth: 160, maxWidth: .infinity, alignment: .leading)
                    Text("STATUS").frame(width: 75, alignment: .leading)
                    Text("TIMECODE (TC)").frame(width: 140, alignment: .leading)
                    Text("RATIO & SIZE").frame(width: 140, alignment: .leading)
                    Text("FPS").frame(width: 65, alignment: .leading)
                    Text("FILE SIZE").frame(width: 75, alignment: .leading)
                    Text("VIDEO").frame(width: 85, alignment: .leading)
                    Text("AUDIO SPEC & BITRATE").frame(width: 150, alignment: .leading)
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
                        ForEach(Array(deliverableAssets.enumerated()), id: \.element.id) { idx, asset in
                            let hasMismatch = asset.validation.hasAnyMismatch
                            
                            HStack(spacing: 8) {
                                Text(String(format: "%02d", idx + 1))
                                    .frame(width: 25, alignment: .leading)
                                    .foregroundColor(textMuted)
                                
                                Text(asset.fileName.uppercased())
                                    .frame(minWidth: 160, maxWidth: .infinity, alignment: .leading)
                                    .fontWeight(.bold)
                                    .lineLimit(1)
                                    .truncationMode(.middle)
                                    .help(asset.fileName)
                                
                                // Validation Status Badge
                                if hasMismatch {
                                    Text("MISMATCH")
                                        .font(.system(size: 8, weight: .black, design: .monospaced))
                                        .padding(.horizontal, 5)
                                        .padding(.vertical, 2)
                                        .background(alertRed)
                                        .foregroundColor(.white)
                                        .frame(width: 75, alignment: .leading)
                                        .help(asset.validation.summaryString)
                                } else {
                                    Text("OK")
                                        .font(.system(size: 9, weight: .bold, design: .monospaced))
                                        .foregroundColor(textMuted)
                                        .frame(width: 75, alignment: .leading)
                                }
                                
                                // Timecode Cell with Warning
                                VStack(alignment: .leading, spacing: 2) {
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
                                .frame(width: 140, alignment: .leading)
                                
                                // Ratio Cell with Warning
                                VStack(alignment: .leading, spacing: 2) {
                                    HStack(spacing: 4) {
                                        Text(asset.aspectRatioString)
                                            .font(.system(size: 9, weight: .bold, design: .monospaced))
                                            .padding(.horizontal, 4)
                                            .padding(.vertical, 2)
                                            .background(asset.validation.isRatioMismatch ? alertRed : bgSubtle)
                                            .foregroundColor(asset.validation.isRatioMismatch ? .white : textMain)
                                            .border(asset.validation.isRatioMismatch ? alertRed : borderLine, width: 1)
                                        
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
                                .frame(width: 140, alignment: .leading)
                                
                                Text(String(format: "%.2f", asset.fps))
                                    .frame(width: 65, alignment: .leading)
                                    .foregroundColor(textSubtle)
                                
                                Text(asset.formattedFileSize)
                                    .frame(width: 75, alignment: .leading)
                                    .fontWeight(.semibold)
                                
                                Text(asset.videoCodec)
                                    .frame(width: 85, alignment: .leading)
                                    .foregroundColor(textMuted)
                                    .lineLimit(1)
                                
                                // Audio Column
                                if !asset.hasAudio {
                                    Text("NONE")
                                        .font(.system(size: 9, weight: .bold, design: .monospaced))
                                        .foregroundColor(textMuted)
                                        .frame(width: 150, alignment: .leading)
                                } else {
                                    VStack(alignment: .leading, spacing: 2) {
                                        HStack(spacing: 4) {
                                            Text(asset.audioCodec)
                                                .font(.system(size: 10, weight: .bold, design: .monospaced))
                                                .foregroundColor(textMain)
                                            if asset.audioBitrate != "--" {
                                                Text(asset.audioBitrate)
                                                    .font(.system(size: 8, weight: .bold, design: .monospaced))
                                                    .padding(.horizontal, 4)
                                                    .padding(.vertical, 1)
                                                    .background(bgSubtle)
                                                    .border(borderLine, width: 1)
                                                    .foregroundColor(textSubtle)
                                            }
                                        }
                                        if !asset.audioFormatDetail.isEmpty {
                                            Text(asset.audioFormatDetail)
                                                .font(.system(size: 8, weight: .medium, design: .monospaced))
                                                .foregroundColor(textMuted)
                                                .lineLimit(1)
                                        }
                                    }
                                    .frame(width: 150, alignment: .leading)
                                    .help(asset.audioConfig)
                                }
                            }
                            .font(.system(size: 11, design: .monospaced))
                            .padding(.horizontal, 14)
                            .padding(.vertical, 9)
                            .background(hasMismatch ? (isLightMode ? Color.red.opacity(0.08) : Color.red.opacity(0.12)) : (idx % 2 == 0 ? bgPanel : bgCardSubtle))
                            .overlay(
                                hasMismatch ? Rectangle().fill(alertRed).frame(width: 3) : nil,
                                alignment: .leading
                            )
                            
                            if idx < deliverableAssets.count - 1 {
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
}
