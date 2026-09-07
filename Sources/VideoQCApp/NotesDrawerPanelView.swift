import SwiftUI
import AppKit
import VideoQCLib

struct NotesDrawerPanelView: View {
    @Binding var isPresented: Bool
    var notes: [QCFileNote]
    var mediaName: String
    var isLightMode: Bool
    
    var onSeekToFrame: (Int) -> Void
    var onAddNote: () -> Void
    var onToggleResolved: (UUID) -> Void
    var onDeleteNote: (UUID) -> Void
    var onToast: (String) -> Void
    
    @AppStorage("reviewerName") private var storedReviewerName: String = ""
    private var palette: StudioPalette { StudioPalette(isLightMode) }
    
    var body: some View {
        VStack(spacing: 0) {
            // Header Bar
            HStack(spacing: 8) {
                Image(systemName: "text.bubble.fill")
                    .font(.system(size: 11, weight: .bold))
                    .foregroundColor(palette.textMain)
                
                Text("NOTES (\(notes.count))")
                    .font(.system(size: 11, weight: .black, design: .monospaced))
                    .foregroundColor(palette.textMain)
                
                Spacer()
                
                Button(action: onAddNote) {
                    HStack(spacing: 4) {
                        Image(systemName: "plus")
                            .font(.system(size: 8, weight: .bold))
                        Text("ADD (M)")
                            .font(.system(size: 9, weight: .bold, design: .monospaced))
                    }
                    .padding(.horizontal, 7)
                    .padding(.vertical, 4)
                    .foregroundColor(palette.accentPositive)
                    .studioBox(background: palette.accentPositive.opacity(0.14), border: palette.accentPositive.opacity(0.6))
                }
                .buttonStyle(.plain)
                
                Button(action: { withAnimation(.easeInOut(duration: 0.15)) { isPresented = false } }) {
                    Image(systemName: "xmark")
                        .font(.system(size: 9, weight: .bold))
                        .foregroundColor(palette.textMuted)
                        .frame(width: 20, height: 20)
                }
                .buttonStyle(.plain)
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 10)
            .background(palette.bgPanel)
            
            Rectangle().fill(palette.borderLine).frame(height: 1)
            
            // Notes List or Empty State
            if notes.isEmpty {
                VStack(spacing: 12) {
                    Spacer()
                    Image(systemName: "square.and.pencil")
                        .font(.system(size: 26))
                        .foregroundColor(palette.textMuted)
                    Text("NO REVIEW NOTES")
                        .font(.system(size: 11, weight: .bold, design: .monospaced))
                        .foregroundColor(palette.textMain)
                    Text("Pause on any frame and press M to log a timecoded note for your team.")
                        .font(.system(size: 9.5, design: .monospaced))
                        .foregroundColor(palette.textSubtle)
                        .multilineTextAlignment(.center)
                        .padding(.horizontal, 20)
                    
                    Button(action: onAddNote) {
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
                        }
                    }
                    .padding(12)
                }
                .background(palette.bgMain)
            }
            
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
                        Text("EXPORT")
                            .font(.system(size: 9.5, weight: .bold, design: .monospaced))
                        Image(systemName: "chevron.down")
                            .font(.system(size: 7, weight: .bold))
                    }
                    .padding(.horizontal, 8)
                    .padding(.vertical, 5)
                    .foregroundColor(palette.textMain)
                    .studioBox(background: palette.bgSubtle, border: palette.borderLine)
                }
                .menuStyle(.borderlessButton)
                .fixedSize()
                .disabled(notes.isEmpty)
                
                Spacer()
                
                Text("\(notes.filter { $0.isResolved }.count)/\(notes.count) RESOLVED")
                    .font(.system(size: 8.5, weight: .bold, design: .monospaced))
                    .foregroundColor(palette.textSubtle)
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 8)
            .background(palette.bgPanel)
        }
        .frame(width: 320)
        .studioBox(background: palette.bgPanel, border: palette.borderStrong)
    }
    
    // MARK: - Note Card Row
    
    private func noteCard(note: QCFileNote) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                // Clickable Timecode Seek Badge
                Button(action: { onSeekToFrame(note.frameIndex) }) {
                    HStack(spacing: 3) {
                        Image(systemName: "play.fill")
                            .font(.system(size: 6))
                        Text(note.timecode)
                            .font(.system(size: 9.5, weight: .black, design: .monospaced))
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
                    .font(.system(size: 9.5, weight: .bold, design: .monospaced))
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
            
            // Note Text
            Text(note.text)
                .font(.system(size: 10, design: .monospaced))
                .foregroundColor(note.isResolved ? palette.textMuted : palette.textMain)
                .strikethrough(note.isResolved, color: palette.textMuted)
                .textSelection(.enabled)
                .lineSpacing(2)
        }
        .padding(9)
        .studioBox(background: palette.bgCardSubtle, border: palette.borderLine)
    }
    
    private func colorForTag(_ tag: String) -> Color {
        QCNoteTheme.color(for: tag)
    }
    
    private func copyToClipboard(_ text: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }
}
