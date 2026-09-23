import SwiftUI
import AppKit
import AVFoundation
import CoreMedia
import VideoQCLib

// MARK: - Player Drawer Tabs

public enum PlayerDrawerTab: String, CaseIterable, Identifiable, Sendable {
    case mediaInfo = "Media Info"
    case notes = "Notes"
    
    public var id: String { rawValue }
}

// MARK: - Notes & Media Info Drawer Panel View

struct NotesDrawerPanelView: View {
    @Binding var isPresented: Bool
    @Binding var selectedDrawerTab: PlayerDrawerTab
    var notes: [QCFileNote]
    var mediaName: String
    var mediaURL: URL?
    var mediaAsset: DeliverableAsset?
    /// Read at action time; only the timecode badge observes it (the drawer must not re-render per frame).
    let clock: PlaybackClock
    var isLightMode: Bool
    
    var onSeekToFrame: (Int) -> Void
    var onAddNote: () -> Void
    var onSaveNote: (QCFileNote) -> Void
    var onToggleResolved: (UUID) -> Void
    var onDeleteNote: (UUID) -> Void
    var onClearAllNotes: () -> Void
    var onToast: (String) -> Void
    var onCopySpecs: ((String) -> Void)? = nil
    var onRevealInFinder: ((URL) -> Void)? = nil
    var onLoadSlotA: ((URL) -> Void)? = nil
    var onLoadSlotB: ((URL) -> Void)? = nil
    
    // Notes tab state
    @AppStorage("reviewerName") private var storedReviewerName: String = ""
    @State private var inlineNoteText: String = ""
    @State private var inlineSelectedColor: String = "cyan"
    @State private var showClearConfirmation: Bool = false
    @FocusState private var isInlineInputFocused: Bool
    
    // Media Info tab state
    @State private var extendedInfo: ExtendedMediaInfo? = nil
    @State private var isExtractingExtended: Bool = false
    @State private var internalAsset: DeliverableAsset? = nil
    
    private var palette: StudioPalette { StudioPalette(isLightMode) }
    
    private var effectiveURL: URL? {
        mediaAsset?.fileURL ?? mediaURL
    }
    
    private var effectiveAsset: DeliverableAsset? {
        mediaAsset ?? internalAsset
    }
    
    var body: some View {
        VStack(spacing: 0) {
            // Frame.io Style Segmented Tab Header Bar
            topSegmentedHeader
            
            Rectangle().fill(palette.borderLine).frame(height: 1)
            
            ZStack(alignment: .top) {
                if selectedDrawerTab == .mediaInfo {
                    mediaInfoContentView
                        .transition(.asymmetric(
                            insertion: .move(edge: .leading).combined(with: .opacity),
                            removal: .move(edge: .leading).combined(with: .opacity)
                        ))
                }
                if selectedDrawerTab == .notes {
                    notesContentView
                        .transition(.asymmetric(
                            insertion: .move(edge: .trailing).combined(with: .opacity),
                            removal: .move(edge: .trailing).combined(with: .opacity)
                        ))
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .clipped()
        }
        .frame(width: 340)
        .studioBox(background: palette.bgPanel, border: palette.borderLine)
        .onAppear {
            if storedReviewerName.isEmpty {
                let systemName = NSFullUserName()
                storedReviewerName = systemName.isEmpty ? NSUserName() : systemName
            }
        }
        .task(id: effectiveURL) {
            guard let url = effectiveURL else {
                extendedInfo = nil
                return
            }
            isExtractingExtended = true
            if effectiveAsset == nil {
                internalAsset = await DeliverablesInspector.inspectFile(url: url)
            }
            extendedInfo = await ExtendedMediaInfo.extract(url: url, baseAsset: effectiveAsset)
            isExtractingExtended = false
        }
    }
    
    // MARK: - Frame.io Segmented Header Bar
    
    private var topSegmentedHeader: some View {
        HStack(spacing: 8) {
            // Rounded Pill Switcher
            HStack(spacing: 4) {
                ForEach(PlayerDrawerTab.allCases) { tab in
                    let isSelected = (selectedDrawerTab == tab)
                    Button(action: {
                        withAnimation(.spring(response: 0.32, dampingFraction: 0.84)) {
                            selectedDrawerTab = tab
                        }
                    }) {
                        HStack(spacing: 5) {
                            Text(tab.rawValue)
                                .font(.system(size: 11, weight: isSelected ? .bold : .medium, design: .monospaced))
                                .lineLimit(1)
                            
                            if tab == .notes && !notes.isEmpty {
                                Text("\(notes.count)")
                                    .font(.system(size: 9, weight: .bold, design: .monospaced))
                                    .padding(.horizontal, 4)
                                    .padding(.vertical, 1)
                                    .background(
                                        Capsule()
                                            .fill(isSelected ? palette.accentBlue.opacity(0.25) : palette.bgSubtle)
                                    )
                                    .foregroundColor(isSelected ? palette.accentBlue : palette.textMuted)
                            }
                        }
                        .frame(maxWidth: .infinity)
                        .frame(height: 25)
                        .foregroundColor(isSelected ? (isLightMode ? Color.black : Color.white) : palette.textMuted)
                        .background(
                            Group {
                                if isSelected {
                                    RoundedRectangle(cornerRadius: 6)
                                        .fill(isLightMode ? Color.white : Color(white: 0.22))
                                        .overlay(
                                            RoundedRectangle(cornerRadius: 6)
                                                .stroke(isLightMode ? palette.borderStrong : Color.white.opacity(0.18), lineWidth: 1)
                                        )
                                        .shadow(color: Color.black.opacity(isLightMode ? 0.08 : 0.25), radius: 2, y: 1)
                                } else {
                                    Color.clear
                                }
                            }
                        )
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(3)
            .background(
                RoundedRectangle(cornerRadius: 8)
                    .fill(palette.bgSubtle)
                    .overlay(
                        RoundedRectangle(cornerRadius: 8)
                            .stroke(palette.borderLine, lineWidth: 1)
                    )
            )
            
            // Close 'X' Button
            Button(action: { withAnimation(.spring(response: 0.32, dampingFraction: 0.78)) { isPresented = false } }) {
                Image(systemName: "xmark")
                    .font(.system(size: 10, weight: .bold))
                    .foregroundColor(palette.textMuted)
                    .padding(6)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help("Close Side Panel")
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .background(palette.bgPanel)
    }
    
    // MARK: - Tab 1: Notes Content View
    
    private var notesContentView: some View {
        VStack(spacing: 0) {
            // Notes Subheader (Clear All + Add Note)
            HStack(spacing: 6) {
                HStack(spacing: 0) {
                    Text("ALL NOTES (")
                    SlotText(
                        "\(notes.count)",
                        mode: .character,
                        direction: .up,
                        font: .system(size: 10, weight: .bold, design: .monospaced),
                        foregroundColor: palette.textMain,
                        tracking: 0.5
                    )
                    Text(")")
                }
                .font(.system(size: 10, weight: .bold, design: .monospaced))
                .foregroundColor(palette.textMain)
                .lineLimit(1)
                
                Spacer(minLength: 4)
                
                if !notes.isEmpty {
                    Button(action: { showClearConfirmation = true }) {
                        HStack(spacing: 3) {
                            Image(systemName: "trash")
                                .font(.system(size: 7.5, weight: .bold))
                            Text("CLEAR ALL")
                                .font(.system(size: 8, weight: .bold, design: .monospaced))
                                .lineLimit(1)
                        }
                        .padding(.horizontal, 6)
                        .padding(.vertical, 3.5)
                        .foregroundColor(palette.alertRed.opacity(0.85))
                        .studioBox(background: palette.alertRed.opacity(0.12), border: palette.alertRed.opacity(0.45))
                    }
                    .buttonStyle(.plain)
                    .help("Clear all markers and review notes for this clip")
                }
                
                Button(action: onAddNote) {
                    HStack(spacing: 3) {
                        Image(systemName: "plus")
                            .font(.system(size: 7.5, weight: .bold))
                        Text("ADD (N)")
                            .font(.system(size: 8, weight: .bold, design: .monospaced))
                            .lineLimit(1)
                    }
                    .padding(.horizontal, 6)
                    .padding(.vertical, 3.5)
                    .foregroundColor(palette.accentPositive)
                    .studioBox(background: palette.accentPositive.opacity(0.14), border: palette.accentPositive.opacity(0.6))
                }
                .buttonStyle(.plain)
            }
            .padding(.horizontal, 10)
            .frame(height: 34)
            .background(palette.bgPanel)
            
            Rectangle().fill(palette.borderLine).frame(height: 1)
            
            // Notes List or Empty State
            if notes.isEmpty {
                VStack(spacing: 12) {
                    Spacer()
                    Image(systemName: "note.text")
                        .font(.system(size: 28))
                        .foregroundColor(palette.textMuted.opacity(0.5))
                    Text("NO REVIEW NOTES")
                        .font(.system(size: 11, weight: .bold, design: .monospaced))
                        .foregroundColor(palette.textMain)
                    Text("Pause on any frame and type below or press N to log a timecoded note.")
                        .font(.system(size: 10, design: .monospaced))
                        .foregroundColor(palette.textSubtle)
                        .multilineTextAlignment(.center)
                        .padding(.horizontal, 20)
                    
                    Button(action: { isInlineInputFocused = true }) {
                        HStack(spacing: 5) {
                            Image(systemName: "plus.circle.fill")
                            Text("ADD FIRST NOTE")
                        }
                        .font(.system(size: 10, weight: .bold, design: .monospaced))
                        .padding(.horizontal, 12)
                        .padding(.vertical, 6)
                        .foregroundColor(palette.textMain)
                        .studioBox(background: palette.bgSubtle, border: palette.borderLine)
                    }
                    .buttonStyle(.plain)
                    
                    Spacer()
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(palette.bgMain)
            } else {
                ScrollView {
                    LazyVStack(spacing: 8) {
                        ForEach(notes.sorted { $0.frameIndex < $1.frameIndex }) { note in
                            noteCard(note: note)
                                .transition(.asymmetric(
                                    insertion: .offset(y: 12).combined(with: .opacity),
                                    removal: .opacity
                                ))
                        }
                    }
                    .padding(12)
                }
                .background(palette.bgMain)
            }
            
            Rectangle().fill(palette.borderLine).frame(height: 1)
            
            // Inline Quick Note Input Box (Always ready at bottom)
            quickAddNoteSection
            
            Rectangle().fill(palette.borderLine).frame(height: 1)
            
            // Bottom Action Bar: NLE & Markdown Export
            HStack(spacing: 6) {
                Menu {
                    Button("Copy Checklist for Slack/Email") {
                        let text = QCNotesManager.generateMarkdown(notes: notes, mediaName: mediaName)
                        copyToClipboard(text)
                        onToast("Notes copied for Slack/Email!")
                    }
                    Button("Export Premiere Pro Markers (CSV)") {
                        let csv = QCNotesManager.generatePremiereCSV(notes: notes, mediaName: mediaName, fps: 25.0)
                        copyToClipboard(csv)
                        onToast("Premiere Markers CSV copied!")
                    }
                    Button("Export DaVinci Resolve Markers (EDL)") {
                        let edl = QCNotesManager.generateResolveEDL(notes: notes, mediaName: mediaName, fps: 25.0)
                        copyToClipboard(edl)
                        onToast("Resolve Marker EDL copied!")
                    }
                } label: {
                    HStack(spacing: 4) {
                        Image(systemName: "square.and.arrow.up")
                            .font(.system(size: 9, weight: .bold))
                            .foregroundColor(palette.textMain)
                        Text("EXPORT")
                            .font(.system(size: 9, weight: .bold, design: .monospaced))
                            .foregroundColor(palette.textMain)
                        Image(systemName: "chevron.down")
                            .font(.system(size: 7, weight: .bold))
                            .foregroundColor(palette.textMain)
                    }
                    .padding(.horizontal, 8)
                    .padding(.vertical, 5)
                    .foregroundColor(palette.textMain)
                    .studioBox(background: palette.bgSubtle, border: palette.borderLine)
                }
                .menuStyle(.borderlessButton)
                .foregroundColor(palette.textMain)
                .fixedSize()
                .disabled(notes.isEmpty)
                
                Spacer()
                
                Text("\(notes.filter { $0.isResolved }.count)/\(notes.count) RESOLVED")
                    .font(.system(size: 9, weight: .bold, design: .monospaced))
                    .foregroundColor(palette.textSubtle)
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 8)
            .background(palette.bgPanel)
        }
    }
    
    // MARK: - Tab 2: Media Info Content View
    
    private var mediaInfoContentView: some View {
        VStack(spacing: 0) {
            if isExtractingExtended && extendedInfo == nil {
                VStack(spacing: 12) {
                    Spacer()
                    ProgressView()
                        .scaleEffect(0.9)
                    Text("READING MEDIA INFO...")
                        .font(.system(size: 10, weight: .bold, design: .monospaced))
                        .foregroundColor(palette.textMuted)
                    Spacer()
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(palette.bgPanel)
            } else if let info = extendedInfo {
                ScrollView {
                    VStack(alignment: .leading, spacing: 14) {
                        drawerFileView(info: info)
                        drawerTracksView(info: info)
                    }
                    .padding(12)
                }
                .background(palette.bgMain)
                
                Rectangle().fill(palette.borderLine).frame(height: 1)
                
                drawerMediaInfoFooter(info: info)
            } else {
                VStack(spacing: 10) {
                    Spacer()
                    Image(systemName: "info.circle")
                        .font(.system(size: 26))
                        .foregroundColor(palette.textMuted.opacity(0.4))
                    Text("NO MEDIA LOADED")
                        .font(.system(size: 11, weight: .bold, design: .monospaced))
                        .foregroundColor(palette.textMain)
                    Text("Load a deliverable in Slot A or B to inspect container tracks and metadata.")
                        .font(.system(size: 10, design: .monospaced))
                        .foregroundColor(palette.textSubtle)
                        .multilineTextAlignment(.center)
                        .padding(.horizontal, 24)
                    Spacer()
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(palette.bgPanel)
            }
        }
    }
    
    // MARK: - Drawer Tracks View
    
    private func drawerTracksView(info: ExtendedMediaInfo) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("TRACK INVENTORY (\(info.tracks.count))")
                .font(.system(size: 10, weight: .bold, design: .monospaced))
                .foregroundColor(palette.textMain)
                .tracking(0.8)
            
            ForEach(info.tracks) { track in
                VStack(alignment: .leading, spacing: 6) {
                    HStack {
                        Text(track.typeName)
                            .font(.system(size: 9.5, weight: .bold, design: .monospaced))
                            .foregroundColor(track.typeName.contains("VIDEO") ? palette.accentPositive : (track.typeName.contains("AUDIO") ? palette.accentSlotB : palette.textMain))
                        Spacer()
                        Text(track.format.uppercased())
                            .font(.system(size: 8.5, weight: .bold, design: .monospaced))
                            .padding(.horizontal, 6)
                            .padding(.vertical, 2)
                            .foregroundColor(palette.textMain)
                            .studioBox(background: palette.bgSubtle, border: palette.borderLine)
                    }
                    
                    VStack(alignment: .leading, spacing: 4) {
                        if track.typeName.contains("VIDEO") {
                            drawerInfoRow(label: "Format:", value: info.videoFormat)
                            drawerInfoRow(label: "Codec:", value: track.codec)
                            if let asset = effectiveAsset {
                                drawerInfoRow(label: "Size:", value: "\(asset.width)×\(asset.height) (\(asset.aspectRatioString))")
                            }
                            drawerInfoRow(label: "FPS:", value: info.formattedFPS)
                            if info.videoBitrate != "--" {
                                drawerInfoRow(label: "Bit Rate:", value: info.videoBitrate)
                            }
                            drawerInfoRow(label: "Colorspace:", value: info.colorspace)
                            drawerInfoRow(label: "Primaries:", value: info.primaries)
                            drawerInfoRow(label: "Pixel Format:", value: info.pixelFormat)
                            drawerInfoRow(label: "Decoder:", value: info.hwDecoder)
                        } else if track.typeName.contains("AUDIO") {
                            drawerInfoRow(label: "Format:", value: info.audioFormat)
                            drawerInfoRow(label: "Codec:", value: track.codec)
                            drawerInfoRow(label: "Channels:", value: info.audioChannels)
                            drawerInfoRow(label: "Sample Rate:", value: info.audioSampleRate != "--" ? "\(info.audioSampleRate) Hz" : "--")
                            if info.audioBitrate != "--" {
                                drawerInfoRow(label: "Bit Rate:", value: info.audioBitrate)
                            }
                            
                            let levelStr = (effectiveAsset?.audioLevelString.isEmpty == false && effectiveAsset?.audioLevelString != "--") ? (effectiveAsset?.audioLevelString ?? info.audioLevelString) : info.audioLevelString
                            let isMute = effectiveAsset?.isAudioMute ?? info.isAudioMute
                            if !levelStr.isEmpty && levelStr != "--" {
                                drawerAudioLevelRow(levelString: levelStr, isMute: isMute)
                            }
                            
                            if track.language != "Undetermined" {
                                drawerInfoRow(label: "Language:", value: track.language)
                            }
                        } else {
                            drawerInfoRow(label: "Format:", value: track.format)
                            drawerInfoRow(label: "Codec:", value: track.codec)
                            drawerInfoRow(label: "Details:", value: track.details)
                            if track.language != "Undetermined" {
                                drawerInfoRow(label: "Language:", value: track.language)
                            }
                        }
                    }
                }
                .padding(10)
                .studioBox(background: palette.bgCardSubtle, border: palette.borderLine)
            }
        }
    }
    
    // MARK: - Drawer File View
    
    private func drawerFileView(info: ExtendedMediaInfo) -> some View {
        VStack(alignment: .leading, spacing: 14) {
            VStack(alignment: .leading, spacing: 6) {
                Text("FILE SYSTEM")
                    .font(.system(size: 10, weight: .bold, design: .monospaced))
                    .foregroundColor(palette.textMain)
                    .tracking(0.8)
                
                VStack(alignment: .leading, spacing: 5) {
                    // File Name Row
                    let fileName = effectiveAsset?.fileName ?? effectiveURL?.lastPathComponent ?? "UNKNOWN"
                    HStack(alignment: .top, spacing: 6) {
                        Text("File Name:")
                            .font(.system(size: 10, weight: .bold, design: .monospaced))
                            .foregroundColor(palette.textMuted)
                            .frame(width: 84, alignment: .leading)
                        
                        if let url = effectiveURL {
                            Button(action: { revealInFinder(url) }) {
                                Text(fileName)
                                    .font(.system(size: 10, weight: .bold, design: .monospaced))
                                    .foregroundColor(palette.textMain)
                                    .multilineTextAlignment(.leading)
                                    .fixedSize(horizontal: false, vertical: true)
                            }
                            .buttonStyle(.plain)
                            .onHover { hovering in
                                if hovering { NSCursor.pointingHand.push() } else { NSCursor.pop() }
                            }
                            .help("Left click to reveal in Finder")
                        } else {
                            Text(fileName)
                                .font(.system(size: 10, weight: .bold, design: .monospaced))
                                .foregroundColor(palette.textMain)
                                .multilineTextAlignment(.leading)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                        
                        Spacer(minLength: 2)
                        
                        Button(action: {
                            copyToClipboard(fileName)
                            onToast("Copied file name")
                        }) {
                            Image(systemName: "doc.on.doc")
                                .font(.system(size: 8.5, weight: .bold))
                                .foregroundColor(palette.textSubtle)
                        }
                        .buttonStyle(.plain)
                        .help("Copy file name")
                    }
                    .padding(.vertical, 1)
                    
                    // Path with left-click to reveal in Finder
                    VStack(alignment: .leading, spacing: 3) {
                        HStack {
                            Text("Path:")
                                .font(.system(size: 10, weight: .bold, design: .monospaced))
                                .foregroundColor(palette.textMuted)
                            
                            Spacer()
                            
                            if let path = effectiveURL?.path {
                                Button(action: {
                                    copyToClipboard(path)
                                    onToast("Copied path")
                                }) {
                                    HStack(spacing: 3) {
                                        Image(systemName: "doc.on.doc")
                                            .font(.system(size: 8))
                                        Text("COPY")
                                            .font(.system(size: 8, weight: .bold, design: .monospaced))
                                    }
                                    .foregroundColor(palette.textMuted)
                                    .padding(.horizontal, 4)
                                    .padding(.vertical, 2)
                                    .background(palette.bgSubtle)
                                    .cornerRadius(3)
                                }
                                .buttonStyle(.plain)
                                .help("Copy full path")
                            }
                        }
                        
                        if let url = effectiveURL {
                            Button(action: { revealInFinder(url) }) {
                                HStack(alignment: .center, spacing: 6) {
                                    Image(systemName: "folder.fill")
                                        .font(.system(size: 9.5))
                                        .foregroundColor(palette.accentBlue)
                                    
                                    Text(url.path)
                                        .font(.system(size: 9.5, weight: .medium, design: .monospaced))
                                        .foregroundColor(palette.textMain)
                                        .lineLimit(3)
                                        .truncationMode(.middle)
                                        .multilineTextAlignment(.leading)
                                        .fixedSize(horizontal: false, vertical: true)
                                    
                                    Spacer(minLength: 4)
                                    
                                    Image(systemName: "arrow.up.right")
                                        .font(.system(size: 8, weight: .bold))
                                        .foregroundColor(palette.textMuted)
                                }
                                .padding(.horizontal, 8)
                                .padding(.vertical, 5)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .background(
                                    RoundedRectangle(cornerRadius: 4)
                                        .fill(palette.bgSubtle.opacity(0.8))
                                        .overlay(
                                            RoundedRectangle(cornerRadius: 4)
                                                .stroke(palette.borderLine, lineWidth: 0.8)
                                        )
                                )
                            }
                            .buttonStyle(.plain)
                            .onHover { hovering in
                                if hovering { NSCursor.pointingHand.push() } else { NSCursor.pop() }
                            }
                            .help("Left click to reveal in Finder")
                        }
                    }
                    .padding(.vertical, 2)
                    
                    drawerInfoRow(label: "Container:", value: ExtendedMediaInfo.containerType(for: effectiveURL))
                    if let asset = effectiveAsset {
                        drawerInfoRow(label: "File Size:", value: "\(asset.formattedFileSize) (\(ExtendedMediaInfo.formattedByteString(asset.fileSizeBytes)))")
                        drawerInfoRow(label: "Created:", value: asset.formattedCreationDate)
                    }
                    drawerInfoRow(label: "Modified:", value: info.fileModifiedDate)
                }
                .padding(10)
                .studioBox(background: palette.bgCardSubtle, border: palette.borderLine)
            }
            
            if let asset = effectiveAsset {
                VStack(alignment: .leading, spacing: 6) {
                    Text("TIMING & RASTER")
                        .font(.system(size: 10, weight: .bold, design: .monospaced))
                        .foregroundColor(palette.textMain)
                        .tracking(0.8)
                    
                    VStack(alignment: .leading, spacing: 4) {
                        drawerInfoRow(label: "Duration:", value: "\(asset.timecode) (\(asset.formattedDuration))")
                        drawerInfoRow(label: "Frames:", value: "\(asset.totalFrames) frames")
                        drawerInfoRow(label: "Aspect:", value: asset.aspectRatioString)
                        drawerInfoRow(label: "Pixel Aspect:", value: "1.0 (Square)")
                        if asset.validation.hasAnyMismatch {
                            drawerInfoRow(label: "QC Alert:", value: asset.validation.summaryString)
                        } else {
                            drawerInfoRow(label: "Naming QC:", value: "All Tags Validated")
                        }
                    }
                    .padding(10)
                    .studioBox(background: palette.bgCardSubtle, border: palette.borderLine)
                }
            }
        }
    }
    
    // MARK: - Drawer Info Row
    
    private func drawerInfoRow(label: String, value: String, copyable: Bool = false) -> some View {
        HStack(alignment: .top, spacing: 6) {
            Text(label)
                .font(.system(size: 10, weight: .bold, design: .monospaced))
                .foregroundColor(palette.textMuted)
                .frame(width: 84, alignment: .leading)
            
            Text(value)
                .font(.system(size: 10, weight: .medium, design: .monospaced))
                .foregroundColor(palette.textMain)
                .multilineTextAlignment(.leading)
                .fixedSize(horizontal: false, vertical: true)
            
            Spacer(minLength: 2)
            
            if copyable {
                Button(action: {
                    copyToClipboard(value)
                    onToast("Copied \(label.replacingOccurrences(of: ":", with: ""))")
                }) {
                    Image(systemName: "doc.on.doc")
                        .font(.system(size: 8.5, weight: .bold))
                        .foregroundColor(palette.textSubtle)
                }
                .buttonStyle(.plain)
                .help("Copy \(label)")
            }
        }
        .padding(.vertical, 1.5)
    }
    
    private func drawerAudioLevelRow(levelString: String, isMute: Bool) -> some View {
        HStack(alignment: .center, spacing: 6) {
            Text("Levels:")
                .font(.system(size: 10, weight: .bold, design: .monospaced))
                .foregroundColor(palette.textMuted)
                .frame(width: 84, alignment: .leading)
            
            HStack(spacing: 5) {
                Text(levelString.isEmpty ? (isMute ? "MUTE" : "--") : levelString)
                    .font(.system(size: 9.5, weight: .bold, design: .monospaced))
                    .foregroundColor(isMute ? palette.alertRed : palette.accentPositive)
                    .padding(.horizontal, 5)
                    .padding(.vertical, 1.5)
                    .background(
                        (isMute ? palette.alertRed : palette.accentPositive).opacity(0.12)
                    )
                    .overlay(
                        RoundedRectangle(cornerRadius: 3)
                            .stroke((isMute ? palette.alertRed : palette.accentPositive).opacity(0.35), lineWidth: 0.8)
                    )
                    .cornerRadius(3)
                
                if isMute {
                    Text("SILENT")
                        .font(.system(size: 8.5, weight: .bold, design: .monospaced))
                        .foregroundColor(palette.alertRed)
                } else {
                    Text("Peak")
                        .font(.system(size: 8.5, weight: .medium, design: .monospaced))
                        .foregroundColor(palette.textMuted)
                }
            }
            
            Spacer()
        }
        .padding(.vertical, 1.5)
    }
    
    private func revealInFinder(_ url: URL) {
        if let onReveal = onRevealInFinder {
            onReveal(url)
        } else {
            NSWorkspace.shared.activateFileViewerSelecting([url])
        }
    }
    
    // MARK: - Drawer Media Info Footer
    
    private func drawerMediaInfoFooter(info: ExtendedMediaInfo) -> some View {
        HStack(spacing: 6) {
            if let asset = effectiveAsset {
                Button(action: {
                    let text = ExtendedMediaInfo.buildSpecsText(asset: asset, info: info)
                    copyToClipboard(text)
                    onCopySpecs?(text)
                    onToast("Copied specs to clipboard")
                }) {
                    HStack(spacing: 3) {
                        Image(systemName: "doc.on.doc")
                            .font(.system(size: 8.5, weight: .bold))
                        Text("SPECS")
                            .font(.system(size: 8.5, weight: .bold, design: .monospaced))
                    }
                    .padding(.horizontal, 7)
                    .padding(.vertical, 5)
                    .foregroundColor(palette.textMain)
                    .studioBox(background: palette.bgSubtle, border: palette.borderLine)
                }
                .buttonStyle(.plain)
                .help("Copy formatted technical specifications")
            }
            
            if let url = effectiveURL {
                Button(action: {
                    onRevealInFinder?(url) ?? NSWorkspace.shared.activateFileViewerSelecting([url])
                }) {
                    HStack(spacing: 3) {
                        Image(systemName: "folder")
                            .font(.system(size: 8.5, weight: .bold))
                        Text("REVEAL")
                            .font(.system(size: 8.5, weight: .bold, design: .monospaced))
                    }
                    .padding(.horizontal, 7)
                    .padding(.vertical, 5)
                    .foregroundColor(palette.textMain)
                    .studioBox(background: palette.bgSubtle, border: palette.borderLine)
                }
                .buttonStyle(.plain)
                .help("Reveal file in Finder")
            }
            
            Spacer()
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 7)
        .background(palette.bgPanel)
    }
    
    // MARK: - Inline Quick Note Input Box (Bottom)
    
    private var quickAddNoteSection: some View {
        VStack(spacing: 7) {
            // Header Row: Current Timecode badge & Quick Color picker
            HStack(spacing: 6) {
                HStack(spacing: 3.5) {
                    Image(systemName: "clock.fill")
                        .font(.system(size: 7.5))
                    PlaybackClockText(
                        clock: clock,
                        value: .timecode,
                        template: "00:00:00:00",
                        fontSize: 9,
                        color: colorForTag(inlineSelectedColor)
                    )
                }
                .padding(.horizontal, 6)
                .padding(.vertical, 2.5)
                .foregroundColor(colorForTag(inlineSelectedColor))
                .studioBox(
                    background: colorForTag(inlineSelectedColor).opacity(0.12),
                    border: colorForTag(inlineSelectedColor).opacity(0.45),
                    radius: 3
                )
                
                Spacer()
                
                // Color dots (cyan, yellow, green, purple) - red strictly excluded
                HStack(spacing: 5) {
                    ForEach(QCNoteTheme.availableColors, id: \.id) { item in
                        Button(action: { inlineSelectedColor = item.id }) {
                            Circle()
                                .fill(item.color)
                                .frame(width: 9, height: 9)
                                .overlay(
                                    Circle()
                                        .stroke(palette.textMain, lineWidth: inlineSelectedColor == item.id ? 1.5 : 0)
                                )
                                .scaleEffect(inlineSelectedColor == item.id ? 1.25 : 1.0)
                        }
                        .buttonStyle(.plain)
                        .help("Tag note as \(item.name)")
                    }
                }
            }
            
            // Text Input Field & Send Button
            HStack(spacing: 6) {
                TextField("Add note at playhead...", text: $inlineNoteText)
                    .textFieldStyle(.plain)
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundColor(palette.textMain)
                    .focused($isInlineInputFocused)
                    .onSubmit {
                        submitInlineNote()
                    }
                
                let canSubmit = !inlineNoteText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                Button(action: submitInlineNote) {
                    Image(systemName: "arrow.up.circle.fill")
                        .font(.system(size: 16, weight: .semibold))
                        .foregroundColor(canSubmit ? colorForTag(inlineSelectedColor) : palette.textMuted.opacity(0.35))
                }
                .buttonStyle(.plain)
                .keyboardShortcut(.return, modifiers: [])
                .disabled(!canSubmit)
                .help("Add note at current timecode (⏎)")
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 5)
            .studioBox(
                background: palette.bgSubtle,
                border: isInlineInputFocused ? colorForTag(inlineSelectedColor).opacity(0.6) : palette.borderLine,
                radius: StudioTheme.cornerRadius
            )
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(palette.bgPanel)
        .alert("Clear All Markers for This Clip?", isPresented: $showClearConfirmation) {
            Button("Clear All", role: .destructive) {
                onClearAllNotes()
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("This will permanently remove all \(notes.count) review notes and markers for \(mediaName). This cannot be undone.")
        }
    }
    
    private func submitInlineNote() {
        let cleanText = inlineNoteText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !cleanText.isEmpty else { return }
        
        let authorName = storedReviewerName.trimmingCharacters(in: .whitespacesAndNewlines)
        let finalAuthor = authorName.isEmpty ? "Reviewer" : authorName
        storedReviewerName = finalAuthor
        
        // Red is strictly reserved for automated Line QC findings
        let safeColorTag = inlineSelectedColor.lowercased() == "red" ? "cyan" : inlineSelectedColor
        
        let newNote = QCFileNote(
            frameIndex: clock.currentFrame,
            timecode: clock.currentTimecode,
            author: finalAuthor,
            text: cleanText,
            colorTag: safeColorTag,
            createdAt: Date(),
            isResolved: false
        )
        onSaveNote(newNote)
        inlineNoteText = ""
        DispatchQueue.main.async {
            isInlineInputFocused = true
        }
    }
    
    // MARK: - Note Card Row
    
    private func noteCard(note: QCFileNote) -> some View {
        let (attributedText, detectedLinks) = NoteLinkParser.buildAttributedString(
            text: note.text,
            isResolved: note.isResolved,
            accentColor: palette.accentBlue,
            textMuted: palette.textMuted,
            textMain: palette.textMain
        )
        
        return VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                // Clickable Timecode Seek Badge
                Button(action: { onSeekToFrame(note.frameIndex) }) {
                    HStack(spacing: 3) {
                        Image(systemName: "play.fill")
                            .font(.system(size: 6))
                        SlotText(
                            note.timecode,
                            mode: .character,
                            direction: .down,
                            font: .system(size: 9, weight: .bold, design: .monospaced),
                            foregroundColor: colorForTag(note.colorTag),
                            tracking: 0.5,
                            animateOnAppear: true
                        )
                    }
                    .padding(.horizontal, 6)
                    .padding(.vertical, 3)
                    .foregroundColor(colorForTag(note.colorTag))
                    .studioBox(background: colorForTag(note.colorTag).opacity(0.15), border: colorForTag(note.colorTag).opacity(0.6))
                }
                .buttonStyle(.plain)
                .help("Jump playhead to \(note.timecode)")
                
                // Author
                Text(note.author)
                    .font(.system(size: 9, weight: .bold, design: .monospaced))
                    .foregroundColor(palette.textMain)
                    .lineLimit(1)
                
                Spacer()
                
                // Resolved Checkbox
                Button(action: { onToggleResolved(note.id) }) {
                    Image(systemName: note.isResolved ? "checkmark.circle.fill" : "circle")
                        .font(.system(size: 11))
                        .foregroundColor(note.isResolved ? palette.accentPositive : palette.textMuted)
                }
                .buttonStyle(.plain)
                .help(note.isResolved ? "Mark as unresolved" : "Mark as resolved")
                
                // Delete Button
                Button(action: { onDeleteNote(note.id) }) {
                    Image(systemName: "trash")
                        .font(.system(size: 9))
                        .foregroundColor(palette.textMuted)
                }
                .buttonStyle(.plain)
                .help("Delete note")
            }
            
            // Note Text with Clickable Links and File Paths
            Text(attributedText)
                .font(.system(size: 10, design: .monospaced))
                .strikethrough(note.isResolved, color: palette.textMuted)
                .textSelection(.enabled)
                .lineSpacing(2)
                .environment(\.openURL, OpenURLAction { url in
                    handleNoteURL(url)
                    return .handled
                })
            
            // Clickable Quick Action Badges for Detected Links & File Paths
            if !detectedLinks.isEmpty && !note.isResolved {
                HStack(spacing: 5) {
                    ForEach(detectedLinks) { item in
                        Button(action: { item.open() }) {
                            HStack(spacing: 4) {
                                Image(systemName: item.iconName)
                                    .font(.system(size: 8, weight: .bold))
                                Text(item.label)
                                    .font(.system(size: 8.5, weight: .bold, design: .monospaced))
                                    .lineLimit(1)
                            }
                            .padding(.horizontal, 6)
                            .padding(.vertical, 3)
                            .foregroundColor(palette.accentBlue)
                            .studioBox(background: palette.accentBlue.opacity(0.12), border: palette.accentBlue.opacity(0.45), radius: 3)
                        }
                        .buttonStyle(.plain)
                        .help(item.displayString)
                    }
                }
            }
        }
        .padding(9)
        .studioBox(background: palette.bgCardSubtle, border: palette.borderLine)
    }
    
    private func handleNoteURL(_ url: URL) {
        if url.scheme == "qcpie-reveal" {
            if let components = URLComponents(url: url, resolvingAgainstBaseURL: false),
               let pathItem = components.queryItems?.first(where: { $0.name == "path" })?.value {
                DetectedNoteLink.revealInFinder(path: pathItem)
            }
        } else if url.isFileURL {
            DetectedNoteLink.revealInFinder(path: url.path)
        } else {
            NSWorkspace.shared.open(url)
        }
    }
    
    private func colorForTag(_ tag: String) -> Color {
        QCNoteTheme.color(for: tag)
    }
    
    private func copyToClipboard(_ text: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }
}
