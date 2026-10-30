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
    @ObservedObject private var themeManager = ThemeManager.shared   // accent changes redraw
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
    var onDeleteNotes: (Set<UUID>) -> Void
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
    
    /// Media Info tab: read here, not in the tab's page, so switching tabs doesn't read the file again.
    @StateObject private var mediaInfo = MediaInfoLoader()
    
    private var palette: StudioPalette { StudioPalette(isLightMode) }
    
    private var effectiveURL: URL? {
        mediaAsset?.fileURL ?? mediaURL
    }
    
    /// The drawer's width: wider for the subtitle list. The Play tab sizes its other columns from this too.
    static func width(tab: PlayerDrawerTab, hasSubtitles: Bool) -> CGFloat {
        tab == .subtitles && hasSubtitles ? 420 : 340
    }

    var body: some View {
        VStack(spacing: 0) {
            // Frame.io Style Segmented Tab Header Bar
            topSegmentedHeader
            
            ZStack(alignment: .top) {
                if selectedDrawerTab == .mediaInfo {
                    MediaInfoPanel(url: effectiveURL, asset: mediaAsset, loader: mediaInfo, isLightMode: isLightMode,
                                   onToast: onToast, onCopySpecs: onCopySpecs, onRevealInFinder: onRevealInFinder)
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
        .frame(width: Self.width(tab: selectedDrawerTab, hasSubtitles: hasSubtitles))
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
            await mediaInfo.load(effectiveURL, asset: mediaAsset)
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
                        withAnimation(Motion.page) {
                            selectedDrawerTab = tab
                        }
                    }) {
                        HStack(spacing: 5) {
                            Text(tab.rawValue)
                                .font(.ui(size: 11, weight: isSelected ? .semibold : .medium))
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
                                        .font(.system(size: StudioTheme.scaleFont(8), weight: .bold))
                                    Text("+\(newSyncedNotesCount)")
                                        .font(.ui(size: 10, weight: .semibold))
                                }
                                .foregroundColor(palette.accentBlue)
                                .help("\(newSyncedNotesCount) new note\(newSyncedNotesCount == 1 ? "" : "s") from your collaborators")
                            } else if tab == .notes && !notes.isEmpty {
                                Text("\(notes.count)")
                                    .font(.ui(size: 10, weight: .semibold))
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
                                    RoundedRectangle(cornerRadius: Radius.segment)
                                        .fill(isLightMode ? palette.bgPanel : Color(white: 0.22))
                                        .overlay(
                                            RoundedRectangle(cornerRadius: Radius.segment)
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
                RoundedRectangle(cornerRadius: Radius.container)
                    .fill(palette.bgSubtle)
                    .overlay(
                        RoundedRectangle(cornerRadius: Radius.container)
                            .stroke(palette.borderLine, lineWidth: 1)
                    )
            )
            
            DrawerCloseButton(isLightMode: isLightMode) { isPresented = false }
        }
        .headerBand(palette, horizontalPadding: 12)
    }
    
    // MARK: - Tab 1: Notes Content View
    
    private var notesContentView: some View {
        VStack(spacing: 0) {
            // Notes Subheader (Clear All + Add Note)
            HStack(spacing: 6) {
                HStack(spacing: 0) {
                    Text("All Notes (")
                    SlotText(
                        "\(notes.count)",
                        mode: .character,
                        direction: .up,
                        font: .ui(size: 11, weight: .semibold),
                        foregroundColor: palette.textMain,
                        tracking: 0.5
                    )
                    Text(")")
                }
                .font(.ui(size: 11, weight: .semibold))
                .foregroundColor(palette.textMain)
                .lineLimit(1)
                
                Spacer(minLength: 4)
                
                if !notes.isEmpty {
                    Button(action: { showClearConfirmation = true }) {
                        HStack(spacing: 3) {
                            Image(systemName: "trash")
                                .font(.system(size: StudioTheme.scaleFont(7.5), weight: .bold))
                            Text(filteredNoteIDs == nil ? "Clear All" : "Clear Filtered")
                                .font(.ui(size: 10, weight: .semibold))
                                .lineLimit(1)
                        }
                        .padding(.horizontal, 6)
                        .padding(.vertical, 3.5)
                        .foregroundColor(palette.alertRed.opacity(0.85))
                        .studioBox(background: palette.alertRed.opacity(0.12), border: palette.alertRed.opacity(0.45))
                    }
                    .buttonStyle(.plain)
                    .help(filteredNoteIDs == nil ? "Clear all markers and review notes for this clip" : "Delete the notes shown by the filter (the others stay)")
                }
                
                Button(action: onAddNote) {
                    HStack(spacing: 3) {
                        Image(systemName: "plus")
                            .font(.system(size: StudioTheme.scaleFont(7.5), weight: .bold))
                        Text("Add (N)")
                            .font(.ui(size: 10, weight: .semibold))
                            .lineLimit(1)
                    }
                    .padding(.horizontal, 6)
                    .padding(.vertical, 3.5)
                    .foregroundColor(palette.accentBlue)
                    .studioBox(background: palette.accentBlue.opacity(0.14), border: palette.accentBlue.opacity(0.6))
                }
                .buttonStyle(.plain)
            }
            .padding(.horizontal, 10)
            .frame(height: 34)
            .background(palette.bgPanel)
            
            Rectangle().fill(palette.borderLine).frame(height: 1)
            
            NotesSyncProjectBar(isLightMode: isLightMode, onAssign: onAssignSyncProject)
            FrameIOCommentsBar(isLightMode: isLightMode, notes: notes)
            
            // Notes List or Empty State
            if notes.isEmpty {
                VStack(spacing: 12) {
                    Spacer()
                    Image(systemName: "note.text")
                        .font(.system(size: StudioTheme.scaleFont(28)))
                        .foregroundColor(palette.textMuted.opacity(0.5))
                    Text("No Review Notes")
                        .font(.ui(size: 11, weight: .semibold))
                        .foregroundColor(palette.textMain)
                    Text("Pause on any frame and type below or press N to log a timecoded note.")
                        .font(.system(size: StudioTheme.scaleFont(10), design: .monospaced))
                        .foregroundColor(palette.textSubtle)
                        .multilineTextAlignment(.center)
                        .padding(.horizontal, 20)
                    
                    Button(action: { isInlineInputFocused = true }) {
                        HStack(spacing: 5) {
                            Image(systemName: "plus.circle.fill")
                            Text("Add First Note")
                        }
                        .font(.ui(size: 11, weight: .semibold))
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
                let presentColors = Self.filterColors.filter { id in notes.contains { $0.colorTag == id } }
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
                        onToast("Notes copied for Slack/Email")
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
                        onToast("Resolve Marker EDL copied")
                    }
                } label: {
                    HStack(spacing: 4) {
                        Image(systemName: "square.and.arrow.up")
                            .font(.system(size: StudioTheme.scaleFont(9), weight: .bold))
                            .foregroundColor(palette.textMain)
                        Text("Export")
                            .font(.ui(size: 10, weight: .semibold))
                            .foregroundColor(palette.textMain)
                        Image(systemName: "chevron.down")
                            .font(.system(size: StudioTheme.scaleFont(7), weight: .bold))
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
                            .font(.system(size: StudioTheme.scaleFont(9), weight: .bold))
                        Text("Import")
                            .font(.ui(size: 10, weight: .semibold))
                    }
                    .padding(.horizontal, 8)
                    .padding(.vertical, 5)
                    .foregroundColor(palette.textMain)
                    .studioBox(background: palette.bgSubtle, border: palette.borderLine)
                }
                .buttonStyle(.plain)
                .help("Import a .qcnotes file into this clip (merged with existing notes)")
                
                Spacer()
                
                Text("\(notes.filter { $0.isResolved }.count)/\(notes.count) resolved")
                    .font(.ui(size: 10, weight: .semibold))
                    .foregroundColor(palette.textSubtle)
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 8)
            .background(palette.bgPanel)
        }
    }
    
    // MARK: - Inline Quick Note Input Box (Bottom)
    
    private var quickAddNoteSection: some View {
        VStack(spacing: 7) {
            // Header Row: Current Timecode badge & Quick Color picker
            HStack(spacing: 6) {
                HStack(spacing: 3.5) {
                    Image(systemName: "clock.fill")
                        .font(.system(size: StudioTheme.scaleFont(7.5)))
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
                
                // Colour dots: the user colours (red is Line Check's, purple Frame.io's)
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
                    .font(.ui(size: 11))
                    .foregroundColor(palette.textMain)
                    .focused($isInlineInputFocused)
                    .onSubmit {
                        submitInlineNote()
                    }
                
                let canSubmit = !inlineNoteText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                Button(action: submitInlineNote) {
                    Image(systemName: "arrow.up.circle.fill")
                        .font(.system(size: StudioTheme.scaleFont(16), weight: .semibold))
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
        .alert(filteredNoteIDs == nil ? "Clear All Markers for This Clip?" : "Delete the Filtered Notes?", isPresented: $showClearConfirmation) {
            Button(filteredNoteIDs == nil ? "Clear All" : "Delete", role: .destructive) {
                if let ids = filteredNoteIDs { onDeleteNotes(ids) } else { onClearAllNotes() }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            if let ids = filteredNoteIDs {
                Text("This will permanently remove the \(ids.count) filtered note\(ids.count == 1 ? "" : "s") for \(mediaName). The other notes stay. This cannot be undone.")
            } else {
                Text("This will permanently remove all \(notes.count) review notes and markers for \(mediaName). This cannot be undone.")
            }
        }
    }
    
    private func submitInlineNote() {
        let cleanText = inlineNoteText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !cleanText.isEmpty else { return }
        
        let authorName = storedReviewerName.trimmingCharacters(in: .whitespacesAndNewlines)
        let finalAuthor = authorName.isEmpty ? "Reviewer" : authorName
        storedReviewerName = finalAuthor
        
        // Red (Line Check) and purple (Frame.io) are reserved.
        let safeColorTag = QCNoteTheme.userTag(inlineSelectedColor)
        
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
                            .font(.system(size: StudioTheme.scaleFont(6)))
                        SlotText(
                            note.timecode,
                            mode: .character,
                            direction: .down,
                            font: .ui(size: 10, weight: .semibold),
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
                    .font(.ui(size: 10, weight: .semibold))
                    .foregroundColor(palette.textMain)
                    .lineLimit(1)
                
                Spacer()
                
                // Resolved Checkbox
                Button(action: { onToggleResolved(note.id) }) {
                    Image(systemName: note.isResolved ? "checkmark.circle.fill" : "circle")
                        .font(.system(size: StudioTheme.scaleFont(11)))
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
                        .font(.system(size: StudioTheme.scaleFont(9)))
                        .foregroundColor(palette.textMuted)
                }
                .buttonStyle(.plain)
                .help("Edit note")
                
                // Delete Button
                Button(action: { onDeleteNote(note.id) }) {
                    Image(systemName: "trash")
                        .font(.system(size: StudioTheme.scaleFont(9)))
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
                .font(.ui(size: 11))
                .strikethrough(note.isResolved, color: palette.textMuted)
                .textSelection(.enabled)
                .lineSpacing(2)
                .environment(\.openURL, OpenURLAction { url in
                    handleNoteURL(url)
                    return .handled
                })
            
            if let editedAt = note.editedAt {
                Text("edited \(editedAt.formatted(date: .abbreviated, time: .shortened))")
                    .font(.ui(size: 10))
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
                                    .font(.system(size: StudioTheme.scaleFont(8), weight: .bold))
                                Text(item.label)
                                    .font(.ui(size: 10, weight: .semibold))
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
    
    /// Filterable colours: red (Line Check glitches), the user note colours, and purple (from Frame.io).
    private static let filterColors = [QCNoteTheme.lineCheckTag] + QCNoteTheme.availableColors.map(\.id) + [QCNoteTheme.frameIOTag]
    
    /// IDs of the notes the colour filter shows, or nil when no filter is on.
    private var filteredNoteIDs: Set<UUID>? {
        let present = Set(notes.map(\.colorTag))
        let active = colorFilter.intersection(present)
        guard !active.isEmpty else { return nil }
        return Set(notes.filter { active.contains($0.colorTag) }.map(\.id))
    }
    
    private func noteColorFilterBar(presentColors: [String], active: Set<String>) -> some View {
        HStack(spacing: 4) {
            Text("Filter")
                .font(.ui(size: 10, weight: .semibold))
                .foregroundColor(palette.textMuted)
            ForEach(presentColors, id: \.self) { id in
                let isOn = active.contains(id)
                Button(action: {
                    if isOn { colorFilter.remove(id) } else { colorFilter.insert(id) }
                }) {
                    HStack(spacing: 4) {
                        Circle().fill(colorForTag(id)).frame(width: 8, height: 8)
                        Text("\(notes.filter { $0.colorTag == id }.count)")
                            .font(.ui(size: 10, weight: .semibold))
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
                Button("Show All") { colorFilter.removeAll() }
                    .buttonStyle(.plain)
                    .font(.ui(size: 10, weight: .semibold))
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
                .font(.ui(size: 11))
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
                // A Frame.io note stays purple: its colour says where it came from.
                ForEach(Self.isFromFrameIO(note) ? [] : QCNoteTheme.availableColors, id: \.id) { option in
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
                    .font(.ui(size: 10, weight: .semibold))
                    .foregroundColor(palette.textMuted)
                Button("Save") { commitEdit(note: note) }
                    .buttonStyle(.plain)
                    .font(.ui(size: 10, weight: .semibold))
                    .foregroundColor(palette.accentBlue)
            }
        }
    }
    
    /// A note imported from a Frame.io comment (`FrameIOCommentImport`): purple, author marked "(Frame.io)".
    private static func isFromFrameIO(_ note: QCFileNote) -> Bool {
        note.colorTag == QCNoteTheme.frameIOTag && note.author.hasSuffix("(Frame.io)")
    }

    private func commitEdit(note: QCFileNote) {
        let clean = editText.trimmingCharacters(in: .whitespacesAndNewlines)
        editingNoteID = nil
        guard !clean.isEmpty, clean != note.text || editColorTag != note.colorTag else { return }
        var updated = note
        // Only Frame.io's notes are purple (an older note made purple here takes a user colour when edited).
        updated.colorTag = Self.isFromFrameIO(note) ? note.colorTag : QCNoteTheme.userTag(editColorTag)
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
                                .font(.ui(size: 10, weight: .semibold))
                                .foregroundColor(palette.textMain)
                            Text(reply.createdAt.formatted(date: .abbreviated, time: .shortened))
                                .font(.ui(size: 10))
                                .foregroundColor(palette.textSubtle)
                        }
                        Text(reply.text)
                            .font(.ui(size: 10))
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
                    .font(.ui(size: 10))
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
                    .font(.ui(size: 10, weight: .semibold))
                    .foregroundColor(palette.accentBlue)
            }
        } else {
            Button(action: {
                replyText = ""
                replyingNoteID = note.id
            }) {
                HStack(spacing: 3) {
                    Image(systemName: "arrowshape.turn.up.left")
                        .font(.system(size: StudioTheme.scaleFont(8), weight: .bold))
                    Text(note.replies.isEmpty ? "Reply" : "Reply (\(note.replies.count))")
                        .font(.ui(size: 10, weight: .semibold))
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
            let (fps, size, seconds, audioChannels, audioSampleRate) = await Self.markerMediaInfo(url)
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

    /// Frame rate, displayed size, duration and audio format for the Premiere marker XML. Nonisolated: the tracks
    /// (not Sendable) never leave this function.
    private nonisolated static func markerMediaInfo(_ url: URL) async -> (fps: Double, size: CGSize, seconds: Double, audioChannels: Int, audioSampleRate: Int) {
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
        return (fps, size, seconds, audioChannels, audioSampleRate)
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
                        .font(.system(size: StudioTheme.scaleFont(9), weight: .bold))
                        .foregroundColor(palette.textMuted)
                    Text("Sync")
                        .font(.ui(size: 10, weight: .semibold))
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
                            .font(.ui(size: 10, weight: .semibold))
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

/// Shown when the clip is linked to a Frame.io file: its comments are imported as notes (checked when the clip opens
/// and every minute). Observes only `FrameIOCommentSync`.
private struct FrameIOCommentsBar: View {
    @ObservedObject private var sync = FrameIOCommentSync.shared
    @ObservedObject private var themeManager = ThemeManager.shared   // accent changes redraw
    var isLightMode: Bool
    /// The clip's notes: those written here and not sent yet can go to Frame.io.
    var notes: [QCFileNote]
    @State private var linkMessage: String?
    @State private var sendMessage: String?

    private var palette: StudioPalette { StudioPalette(isLightMode) }

    private var unsent: Int { FrameIOCommentPush.pending(notes, imported: sync.activeImported, sent: sync.activeSent).count }

    private var detail: String {
        if sync.isSending { return "Sending notes to Frame.io…" }
        if let sendMessage { return sendMessage }
        if let error = sync.lastError { return "Couldn't check: \(error)" }
        if sync.isChecking { return "Checking for comments…" }
        if let checked = sync.lastChecked { return "Comments imported · checked \(checked.formatted(date: .omitted, time: .shortened))" }
        return "Comments are imported as notes"
    }

    var body: some View {
        if !sync.activeLinked {
            if sync.signedIn {
                unlinked.onChange(of: sync.activeVersion) { _, _ in linkMessage = nil }
            }
        } else {
            VStack(spacing: 0) {
                HStack(spacing: 6) {
                    Image(systemName: "text.bubble")
                        .font(.system(size: StudioTheme.scaleFont(9), weight: .bold))
                        .foregroundColor(QCNoteTheme.color(for: FrameIOCommentImport.colorTag))
                    Text("Frame.io")
                        .font(.ui(size: 10, weight: .semibold))
                        .foregroundColor(palette.textMuted)
                    Text(detail)
                        .font(.ui(size: 10))
                        .foregroundColor(sync.lastError == nil ? palette.textMain : palette.negative)
                        .lineLimit(1)
                        .truncationMode(.tail)
                    Spacer(minLength: 4)
                    if unsent > 0 {
                        Button("Send \(unsent)") {
                            let count = unsent
                            FrameIOCommentPush.confirm(notes: count, clips: 1, onto: "this clip's Frame.io file") {
                                Task { sendMessage = await sync.sendActive(notes) }
                            }
                        }
                        .font(.ui(size: 10, weight: .semibold))
                        .buttonStyle(.borderless)
                        .disabled(sync.isSending)
                        .help("Send the \(unsent) note\(unsent == 1 ? "" : "s") written here to Frame.io as comments at their frames")
                    }
                    Button("Check Now", action: sync.checkActive)
                        .font(.ui(size: 10, weight: .semibold))
                        .buttonStyle(.borderless)
                        .disabled(sync.isChecking)
                        .help("Import new Frame.io comments on this clip now")
                }
                .padding(.horizontal, 10)
                .frame(height: 24)
                .background(palette.bgPanel)
                .help("This clip is linked to its Frame.io file: comments come in as purple notes marked (Frame.io), checked when the clip opens and every minute. Send puts your notes on Frame.io as comments.")
                .onChange(of: sync.activeVersion) { _, _ in sendMessage = nil }

                Rectangle().fill(palette.borderLine).frame(height: 1)
            }
        }
    }

    /// Not linked yet: copy the file's Frame.io link and link it here (or press ⌘V in the Player).
    private var unlinked: some View {
        VStack(spacing: 0) {
            HStack(spacing: 6) {
                Image(systemName: "text.bubble")
                    .font(.system(size: StudioTheme.scaleFont(9), weight: .bold))
                    .foregroundColor(palette.textMuted)
                Text("Frame.io")
                    .font(.ui(size: 10, weight: .semibold))
                    .foregroundColor(palette.textMuted)
                Text(linkMessage ?? "Not linked")
                    .font(.ui(size: 10))
                    .foregroundColor(palette.textMuted)
                    .lineLimit(1)
                    .truncationMode(.tail)
                Spacer(minLength: 4)
                Button("Link from Clipboard") {
                    if !sync.linkActiveFromClipboard({ linkMessage = $0 }) {
                        linkMessage = "Copy the file's Frame.io link first"
                    }
                }
                .font(.ui(size: 10, weight: .semibold))
                .buttonStyle(.borderless)
                .help("In Frame.io, right-click the file → Copy Asset URL, then click here or press ⌘V in the Player to import its comments (share links don't work for this)")
            }
            .padding(.horizontal, 10)
            .frame(height: 24)
            .background(palette.bgPanel)
            .help("Comments are imported automatically when QCpie finds this file on Frame.io (same name and size) in a folder you browsed or a favourite project or folder. Otherwise link it with its Frame.io asset URL.")

            Rectangle().fill(palette.borderLine).frame(height: 1)
        }
    }
}
