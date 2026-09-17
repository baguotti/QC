import SwiftUI
import AppKit
import VideoQCLib

struct NotesDrawerPanelView: View {
    @Binding var isPresented: Bool
    var notes: [QCFileNote]
    var mediaName: String
    var currentTimecode: String
    var currentFrame: Int
    var isLightMode: Bool
    
    var onSeekToFrame: (Int) -> Void
    var onAddNote: () -> Void
    var onSaveNote: (QCFileNote) -> Void
    var onToggleResolved: (UUID) -> Void
    var onDeleteNote: (UUID) -> Void
    var onClearAllNotes: () -> Void
    var onToast: (String) -> Void
    
    @AppStorage("reviewerName") private var storedReviewerName: String = ""
    @State private var inlineNoteText: String = ""
    @State private var inlineSelectedColor: String = "cyan"
    @State private var showClearConfirmation: Bool = false
    @FocusState private var isInlineInputFocused: Bool
    
    private var palette: StudioPalette { StudioPalette(isLightMode) }
    
    var body: some View {
        VStack(spacing: 0) {
            // Header Bar
            HStack(spacing: 6) {
                Image(systemName: "bubble.left.fill")
                    .font(.system(size: 11, weight: .bold))
                    .foregroundColor(palette.textMain)
                
                HStack(spacing: 0) {
                    Text("NOTES (")
                    SlotText(
                        "\(notes.count)",
                        mode: .character,
                        direction: .up,
                        font: .system(size: 11, weight: .black, design: .monospaced),
                        foregroundColor: palette.textMain,
                        tracking: 0.5
                    )
                    Text(")")
                }
                .font(.system(size: 11, weight: .black, design: .monospaced))
                .foregroundColor(palette.textMain)
                .lineLimit(1)
                .fixedSize(horizontal: true, vertical: false)
                
                Spacer(minLength: 4)
                
                if !notes.isEmpty {
                    Button(action: { showClearConfirmation = true }) {
                        HStack(spacing: 3) {
                            Image(systemName: "trash")
                                .font(.system(size: 7.5, weight: .bold))
                            Text("CLEAR ALL")
                                .font(.system(size: 8, weight: .bold, design: .monospaced))
                                .lineLimit(1)
                                .fixedSize(horizontal: true, vertical: false)
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
                            .fixedSize(horizontal: true, vertical: false)
                    }
                    .padding(.horizontal, 6)
                    .padding(.vertical, 3.5)
                    .foregroundColor(palette.accentPositive)
                    .studioBox(background: palette.accentPositive.opacity(0.14), border: palette.accentPositive.opacity(0.6))
                }
                .buttonStyle(.plain)
                
                Button(action: { withAnimation(.easeInOut(duration: 0.15)) { isPresented = false } }) {
                    Image(systemName: "xmark")
                        .font(.system(size: 10, weight: .bold))
                        .foregroundColor(palette.textMuted)
                }
                .buttonStyle(.plain)
            }
            .padding(.horizontal, 10)
            .frame(height: 40)
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
        .frame(width: 326)
        .studioBox(background: palette.bgPanel, border: palette.borderLine)
        .onAppear {
            if storedReviewerName.isEmpty {
                let systemName = NSFullUserName()
                storedReviewerName = systemName.isEmpty ? NSUserName() : systemName
            }
        }
    }
    
    // MARK: - Inline Quick Note Input Box (Bottom)
    
    private var quickAddNoteSection: some View {
        VStack(spacing: 7) {
            // Header Row: Current Timecode badge & Quick Color picker
            HStack(spacing: 6) {
                HStack(spacing: 3.5) {
                    Image(systemName: "clock.fill")
                        .font(.system(size: 7.5))
                    Text(currentTimecode)
                        .font(.system(size: 9, weight: .bold, design: .monospaced))
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
                TextField("Add note at \(currentTimecode)...", text: $inlineNoteText)
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
            frameIndex: currentFrame,
            timecode: currentTimecode,
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
                            .studioBox(
                                background: palette.accentBlue.opacity(0.12),
                                border: palette.accentBlue.opacity(0.4),
                                radius: 3
                            )
                        }
                        .buttonStyle(.plain)
                        .help(item.isWeb ? "Open \(item.displayString) in browser" : "Reveal \(item.displayString) in Finder")
                    }
                }
                .padding(.top, 2)
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
