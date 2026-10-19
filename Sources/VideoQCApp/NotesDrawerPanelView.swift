import SwiftUI
import AppKit
import AVFoundation
import CoreMedia
import VideoQCLib

// MARK: - Player Drawer Tabs

public enum PlayerDrawerTab: String, CaseIterable, Identifiable, Sendable {
    case mediaInfo = "Media Info"
    case notes = "Notes"
    case subtitles = "Subtitles"
    
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
    /// Subtitles tab: shown only when slot A's clip has subtitles loaded.
    let subtitleEngine: PlayerEngine
    var hasSubtitles: Bool
    var subtitlesDirty: Bool
    /// Notes another Mac added that haven't been seen yet (badge on the Notes tab).
    var newSyncedNotesCount: Int
    var onAssignSyncProject: (UUID) -> Void
    
    var onSeekToFrame: (Int) -> Void
    var onAddNote: () -> Void
    var onSaveNote: (QCFileNote) -> Void
    var onToggleResolved: (UUID) -> Void
    var onDeleteNote: (UUID) -> Void
    var onClearAllNotes: () -> Void
    var onUpdateNote: (QCFileNote) -> Void
    var onExportNotes: () -> Void
    var onImportNotes: () -> Void
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
    @State private var editingNoteID: UUID? = nil
    @State private var editColorTag: String = "cyan"
    /// Colours shown in the list; empty shows every note.
    @State private var colorFilter: Set<String> = []
    @State private var editText: String = ""
    @State private var replyingNoteID: UUID? = nil
    @State private var replyText: String = ""
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
                if selectedDrawerTab == .subtitles && hasSubtitles {
                    SubtitlesPanelView(engine: subtitleEngine, isLightMode: isLightMode, onToast: onToast)
                        .transition(.asymmetric(
                            insertion: .move(edge: .trailing).combined(with: .opacity),
                            removal: .move(edge: .trailing).combined(with: .opacity)
                        ))
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .clipped()
        }
        .frame(width: selectedDrawerTab == .subtitles && hasSubtitles ? 420 : 340)
        .onChange(of: hasSubtitles) { _, has in
            if !has && selectedDrawerTab == .subtitles { selectedDrawerTab = .notes }
        }
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
                ForEach(PlayerDrawerTab.allCases.filter { $0 != .subtitles || hasSubtitles }) { tab in
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
                            
                            if tab == .subtitles && subtitlesDirty {
                                Circle()
                                    .fill(palette.accentBlue)
                                    .frame(width: 5, height: 5)
                                    .help("Unsaved subtitle changes")
                            }
                            
                            if tab == .notes && newSyncedNotesCount > 0 && !isSelected {
                                HStack(spacing: 2) {
                                    Image(systemName: "icloud.and.arrow.down")
                                        .font(.system(size: 8, weight: .bold))
                                    Text("+\(newSyncedNotesCount)")
                                        .font(.system(size: 9, weight: .bold, design: .monospaced))
                                }
                                .foregroundColor(palette.accentBlue)
                                .help("\(newSyncedNotesCount) new note\(newSyncedNotesCount == 1 ? "" : "s") from your collaborators")
                            } else if tab == .notes && !notes.isEmpty {
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
            
            NotesSyncProjectBar(isLightMode: isLightMode, onAssign: onAssignSyncProject)
            
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
                let presentColors = QCNoteTheme.availableColors.map(\.id).filter { id in notes.contains { $0.colorTag == id } }
                let activeFilter = colorFilter.intersection(presentColors)
                if presentColors.count > 1 {
                    noteColorFilterBar(presentColors: presentColors, active: activeFilter)
                }
                ScrollView {
                    LazyVStack(spacing: 8) {
                        ForEach(notes.filter { activeFilter.isEmpty || activeFilter.contains($0.colorTag) }.sorted { $0.frameIndex < $1.frameIndex }) { note in
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
                    Button("Export QCpie Notes (.qcnotes)…") {
                        onExportNotes()
                    }
                    Divider()
                    Button("Export Premiere Pro Markers (XML)…") {
                        exportPremiereMarkers()
                    }
                    Button("Export DaVinci Resolve Markers (EDL)") {
                        let edl = QCNotesManager.generateResolveEDL(notes: notes, mediaName: mediaName)
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
                
                Button(action: onImportNotes) {
                    HStack(spacing: 4) {
                        Image(systemName: "square.and.arrow.down")
                            .font(.system(size: 9, weight: .bold))
                        Text("IMPORT")
                            .font(.system(size: 9, weight: .bold, design: .monospaced))
                    }
                    .padding(.horizontal, 8)
                    .padding(.vertical, 5)
                    .foregroundColor(palette.textMain)
                    .studioBox(background: palette.bgSubtle, border: palette.borderLine)
                }
                .buttonStyle(.plain)
                .help("Import a .qcnotes file into this clip (merged with existing notes)")
                
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
                TextField("Add note at playhead... (drop files to link them)", text: $inlineNoteText)
                    .onDrop(of: [.fileURL], isTargeted: nil) { providers in
                        handlePathDrop(providers) { token in
                            inlineNoteText = appendingPath(token, to: inlineNoteText)
                            isInlineInputFocused = true
                        }
                    }
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
                
                // Edit Button
                Button(action: {
                    editText = note.text
                    editColorTag = note.colorTag
                    editingNoteID = note.id
                }) {
                    Image(systemName: "pencil")
                        .font(.system(size: 9))
                        .foregroundColor(palette.textMuted)
                }
                .buttonStyle(.plain)
                .help("Edit note")
                
                // Delete Button
                Button(action: { onDeleteNote(note.id) }) {
                    Image(systemName: "trash")
                        .font(.system(size: 9))
                        .foregroundColor(palette.textMuted)
                }
                .buttonStyle(.plain)
                .help("Delete note")
            }
            
            if editingNoteID == note.id {
                noteEditor(note: note)
            } else {
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
            
            if let editedAt = note.editedAt {
                Text("edited \(editedAt.formatted(date: .abbreviated, time: .shortened))")
                    .font(.system(size: 8, design: .monospaced))
                    .foregroundColor(palette.textSubtle)
            }
            }
            
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

            noteThread(note: note)
        }
        .padding(9)
        .studioBox(background: palette.bgCardSubtle, border: palette.borderLine)
    }
    
    // MARK: - Colour Filter
    
    private func noteColorFilterBar(presentColors: [String], active: Set<String>) -> some View {
        HStack(spacing: 4) {
            Text("FILTER")
                .font(.system(size: 8.5, weight: .black, design: .monospaced))
                .foregroundColor(palette.textMuted)
            ForEach(presentColors, id: \.self) { id in
                let isOn = active.contains(id)
                Button(action: {
                    if isOn { colorFilter.remove(id) } else { colorFilter.insert(id) }
                }) {
                    HStack(spacing: 4) {
                        Circle().fill(colorForTag(id)).frame(width: 8, height: 8)
                        Text("\(notes.filter { $0.colorTag == id }.count)")
                            .font(.system(size: 8.5, weight: .bold, design: .monospaced))
                            .foregroundColor(isOn ? palette.textMain : palette.textMuted)
                    }
                    .padding(.horizontal, 6)
                    .frame(height: 18)
                    .studioBox(background: isOn ? colorForTag(id).opacity(0.2) : palette.bgSubtle,
                               border: isOn ? colorForTag(id) : palette.borderLine, radius: 3)
                }
                .buttonStyle(.plain)
                .help(isOn ? "Stop filtering by this colour" : "Show only notes of this colour (click more to combine)")
            }
            Spacer()
            if !active.isEmpty {
                Button("SHOW ALL") { colorFilter.removeAll() }
                    .buttonStyle(.plain)
                    .font(.system(size: 8.5, weight: .bold, design: .monospaced))
                    .foregroundColor(palette.accentBlue)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
        .background(palette.bgMain)
    }
    
    // MARK: - Note Editing & Replies
    
    private var currentAuthor: String {
        let name = storedReviewerName.trimmingCharacters(in: .whitespacesAndNewlines)
        return name.isEmpty ? "Reviewer" : name
    }
    
    private func noteEditor(note: QCFileNote) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            TextField("Note", text: $editText, axis: .vertical)
                .font(.system(size: 10, design: .monospaced))
                .textFieldStyle(.plain)
                .lineLimit(1...8)
                .padding(6)
                .studioBox(background: palette.bgMain, border: palette.accentBlue.opacity(0.6))
                .onSubmit { commitEdit(note: note) }
                .onDrop(of: [.fileURL], isTargeted: nil) { providers in
                    handlePathDrop(providers) { token in editText = appendingPath(token, to: editText) }
                }
                .onExitCommand { editingNoteID = nil }
            HStack(spacing: 6) {
                ForEach(QCNoteTheme.availableColors, id: \.id) { option in
                    Button(action: { editColorTag = option.id }) {
                        Circle()
                            .fill(option.color)
                            .frame(width: 10, height: 10)
                            .overlay(Circle().stroke(palette.textMain, lineWidth: editColorTag == option.id ? 1.5 : 0).padding(-2))
                            .frame(width: 16, height: 16)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .help(option.name)
                }
                Spacer()
                Button("Cancel") { editingNoteID = nil }
                    .buttonStyle(.plain)
                    .font(.system(size: 9, weight: .bold, design: .monospaced))
                    .foregroundColor(palette.textMuted)
                Button("Save") { commitEdit(note: note) }
                    .buttonStyle(.plain)
                    .font(.system(size: 9, weight: .bold, design: .monospaced))
                    .foregroundColor(palette.accentPositive)
            }
        }
    }
    
    private func commitEdit(note: QCFileNote) {
        let clean = editText.trimmingCharacters(in: .whitespacesAndNewlines)
        editingNoteID = nil
        guard !clean.isEmpty, clean != note.text || editColorTag != note.colorTag else { return }
        var updated = note
        updated.colorTag = editColorTag
        updated.text = clean
        // Also stamped for colour-only edits: .qcnotes imports keep the most recently edited version.
        updated.editedAt = Date()
        onUpdateNote(updated)
    }
    
    @ViewBuilder
    private func noteThread(note: QCFileNote) -> some View {
        if !note.replies.isEmpty {
            VStack(alignment: .leading, spacing: 5) {
                ForEach(note.replies) { reply in
                    VStack(alignment: .leading, spacing: 2) {
                        HStack(spacing: 5) {
                            Text(reply.author)
                                .font(.system(size: 8.5, weight: .bold, design: .monospaced))
                                .foregroundColor(palette.textMain)
                            Text(reply.createdAt.formatted(date: .abbreviated, time: .shortened))
                                .font(.system(size: 8, design: .monospaced))
                                .foregroundColor(palette.textSubtle)
                        }
                        Text(reply.text)
                            .font(.system(size: 9.5, design: .monospaced))
                            .foregroundColor(palette.textMuted)
                            .textSelection(.enabled)
                    }
                }
            }
            .padding(.leading, 8)
            .overlay(alignment: .leading) {
                Rectangle().fill(palette.borderLine).frame(width: 1)
            }
        }
        if replyingNoteID == note.id {
            HStack(spacing: 6) {
                TextField("Reply…", text: $replyText)
                    .font(.system(size: 9.5, design: .monospaced))
                    .textFieldStyle(.plain)
                    .padding(5)
                    .studioBox(background: palette.bgMain, border: palette.borderLine)
                    .onSubmit { commitReply(note: note) }
                    .onDrop(of: [.fileURL], isTargeted: nil) { providers in
                        handlePathDrop(providers) { token in replyText = appendingPath(token, to: replyText) }
                    }
                    .onExitCommand { replyingNoteID = nil }
                Button("Send") { commitReply(note: note) }
                    .buttonStyle(.plain)
                    .font(.system(size: 9, weight: .bold, design: .monospaced))
                    .foregroundColor(palette.accentBlue)
            }
        } else {
            Button(action: {
                replyText = ""
                replyingNoteID = note.id
            }) {
                HStack(spacing: 3) {
                    Image(systemName: "arrowshape.turn.up.left")
                        .font(.system(size: 8, weight: .bold))
                    Text(note.replies.isEmpty ? "REPLY" : "REPLY (\(note.replies.count))")
                        .font(.system(size: 8, weight: .bold, design: .monospaced))
                }
                .foregroundColor(palette.textMuted)
            }
            .buttonStyle(.plain)
            .help("Reply to this note")
        }
    }
    
    /// Dropped files become quoted paths, which notes render as clickable reveal-in-Finder links.
    private func handlePathDrop(_ providers: [NSItemProvider], insert: @escaping @MainActor @Sendable (String) -> Void) -> Bool {
        let fileProviders = providers.filter { $0.canLoadObject(ofClass: URL.self) }
        guard !fileProviders.isEmpty else { return false }
        for provider in fileProviders {
            _ = provider.loadObject(ofClass: URL.self) { url, _ in
                guard let url = url, url.isFileURL else { return }
                let token = "\"\(url.path)\""
                DispatchQueue.main.async {
                    MainActor.assumeIsolated { insert(token) }
                }
            }
        }
        return true
    }
    
    private func appendingPath(_ token: String, to text: String) -> String {
        let trimmed = text.trimmingCharacters(in: .whitespaces)
        return trimmed.isEmpty ? token : trimmed + " " + token
    }
    
    private func commitReply(note: QCFileNote) {
        let clean = replyText.trimmingCharacters(in: .whitespacesAndNewlines)
        replyingNoteID = nil
        replyText = ""
        guard !clean.isEmpty else { return }
        var updated = note
        updated.replies.append(QCNoteReply(author: currentAuthor, text: clean))
        onUpdateNote(updated)
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
    
    /// Saves an FCP7 XML that Premiere imports (File > Import) as a sequence with the clip and every note as a marker.
    private func exportPremiereMarkers() {
        guard let url = effectiveURL else {
            onToast("No media loaded to export markers for")
            return
        }
        let exportNotes = notes
        let name = mediaName.isEmpty ? url.lastPathComponent : mediaName
        Task { @MainActor in
            let asset = AVURLAsset(url: url)
            var fps = 25.0
            var size = CGSize(width: 1920, height: 1080)
            var seconds = 0.0
            if let track = try? await asset.loadTracks(withMediaType: .video).first {
                if let rate = try? await track.load(.nominalFrameRate), rate > 0 { fps = Double(rate) }
                if let natural = try? await track.load(.naturalSize), let transform = try? await track.load(.preferredTransform) {
                    let rect = CGRect(origin: .zero, size: natural).applying(transform)
                    size = CGSize(width: abs(rect.width), height: abs(rect.height))
                }
            }
            if let duration = try? await asset.load(.duration) { seconds = CMTimeGetSeconds(duration) }
            var audioChannels = 0
            var audioSampleRate = 48000
            if let track = try? await asset.loadTracks(withMediaType: .audio).first,
               let desc = try? await track.load(.formatDescriptions).first,
               let asbd = CMAudioFormatDescriptionGetStreamBasicDescription(desc)?.pointee {
                audioChannels = max(1, Int(asbd.mChannelsPerFrame))
                if asbd.mSampleRate > 0 { audioSampleRate = Int(asbd.mSampleRate) }
            }
            let totalFrames = max(1, Int((seconds * fps).rounded()))

            let xml = QCNotesManager.generatePremiereXML(
                notes: exportNotes, mediaName: name, mediaURL: url,
                fps: fps, width: Int(size.width), height: Int(size.height), totalFrames: totalFrames,
                audioChannels: audioChannels, audioSampleRate: audioSampleRate
            )
            let panel = NSSavePanel()
            panel.title = "Export Premiere Pro Markers"
            panel.prompt = "Export"
            panel.canCreateDirectories = true
            panel.allowedContentTypes = [.xml]
            panel.nameFieldStringValue = "\(url.deletingPathExtension().lastPathComponent)_QC_Markers.xml"
            panel.directoryURL = url.deletingLastPathComponent()
            guard panel.runModal() == .OK, let dest = panel.url else { return }
            do {
                try xml.write(to: dest, atomically: true, encoding: .utf8)
                onToast("Premiere markers saved — File > Import in Premiere")
            } catch {
                onToast("Couldn't save markers: \(error.localizedDescription)")
            }
        }
    }

    private func copyToClipboard(_ text: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }
}

/// Which sync project the shown clip's notes go to; hidden while no project is connected.
/// Observes only the sync status (changes rarely), so the drawer itself doesn't re-render on sync.
private struct NotesSyncProjectBar: View {
    @ObservedObject private var status = NotesSyncStatus.shared
    var isLightMode: Bool
    var onAssign: (UUID) -> Void
    
    private var palette: StudioPalette { StudioPalette(isLightMode) }
    
    private var label: String {
        if let id = status.activeProjectID, let project = status.projects.first(where: { $0.id == id }) {
            return project.name
        }
        let fallback = status.projects.first { $0.id == status.defaultProjectID }?.name ?? status.projects.first?.name ?? ""
        return "\(fallback) (when notes are added)"
    }
    
    var body: some View {
        if !status.projects.isEmpty && status.state != .unavailable {
            VStack(spacing: 0) {
                HStack(spacing: 6) {
                    Image(systemName: "icloud")
                        .font(.system(size: 9, weight: .bold))
                        .foregroundColor(palette.textMuted)
                    Text("SYNC")
                        .font(.system(size: 8, weight: .bold, design: .monospaced))
                        .foregroundColor(palette.textMuted)
                    Menu {
                        ForEach(status.projects) { project in
                            Button(action: { onAssign(project.id) }) {
                                if project.id == status.activeProjectID {
                                    Label(project.name, systemImage: "checkmark")
                                } else {
                                    Text(project.name)
                                }
                            }
                        }
                    } label: {
                        Text(label)
                            .font(.system(size: 9, weight: .bold, design: .monospaced))
                            .foregroundColor(palette.textMain)
                            .lineLimit(1)
                    }
                    .menuStyle(.button)
                    .buttonStyle(.plain)
                    .menuIndicator(.visible)
                    .fixedSize()
                    .help("Notes sync project for this clip. Pick another to move its notes there.")
                    Spacer(minLength: 0)
                }
                .padding(.horizontal, 10)
                .frame(height: 24)
                .background(palette.bgPanel)
                
                Rectangle().fill(palette.borderLine).frame(height: 1)
            }
        }
    }
}
