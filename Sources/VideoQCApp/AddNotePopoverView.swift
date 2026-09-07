import SwiftUI
import AppKit
import VideoQCLib

struct AddNotePopoverView: View {
    @Binding var isPresented: Bool
    var timecode: String
    var frameIndex: Int
    var isLightMode: Bool
    var onSave: (QCFileNote) -> Void
    
    @AppStorage("reviewerName") private var storedReviewerName: String = ""
    @State private var author: String = ""
    @State private var noteText: String = ""
    @State private var selectedColor: String = "cyan"
    @FocusState private var isNoteFocused: Bool
    
    private var palette: StudioPalette { StudioPalette(isLightMode) }
    
    private let availableColors: [(id: String, name: String, color: Color)] = [
        ("cyan", "Cyan", Color(red: 0.20, green: 0.75, blue: 1.0)),
        ("yellow", "Yellow", Color(red: 1.0, green: 0.85, blue: 0.20)),
        ("green", "Green", Color(red: 0.30, green: 0.85, blue: 0.40)),
        ("red", "Red", Color(red: 1.0, green: 0.30, blue: 0.35)),
        ("purple", "Purple", Color(red: 0.75, green: 0.40, blue: 1.0))
    ]
    
    var body: some View {
        ZStack {
            // Backdrop Scrim
            Color.black.opacity(isPresented ? 0.65 : 0.0)
                .edgesIgnoringSafeArea(.all)
                .allowsHitTesting(isPresented)
                .onTapGesture {
                    dismiss()
                }
            
            // Modal Card
            VStack(spacing: 0) {
                // Header Bar
                HStack(spacing: 8) {
                    Image(systemName: "text.bubble.fill")
                        .font(.system(size: 13, weight: .bold))
                        .foregroundColor(palette.textMain)
                    
                    Text("ADD REVIEW NOTE")
                        .font(.system(size: 11, weight: .black, design: .monospaced))
                        .foregroundColor(palette.textMain)
                    
                    Spacer()
                    
                    // Timecode Badge
                    Text(timecode)
                        .font(.system(size: 11, weight: .black, design: .monospaced))
                        .padding(.horizontal, 7)
                        .padding(.vertical, 3)
                        .foregroundColor(palette.accentPositive)
                        .studioBox(background: palette.accentPositive.opacity(0.15), border: palette.accentPositive.opacity(0.6))
                    
                    Button(action: { dismiss() }) {
                        Image(systemName: "xmark")
                            .font(.system(size: 10, weight: .bold))
                            .foregroundColor(palette.textMuted)
                            .frame(width: 20, height: 20)
                    }
                    .buttonStyle(.plain)
                    .keyboardShortcut(.escape, modifiers: [])
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 12)
                .background(palette.bgPanel)
                
                Rectangle().fill(palette.borderLine).frame(height: 1)
                
                // Content Body
                VStack(alignment: .leading, spacing: 14) {
                    // Author / Reviewer Name Row
                    VStack(alignment: .leading, spacing: 5) {
                        Text("REVIEWER NAME")
                            .font(.system(size: 9, weight: .bold, design: .monospaced))
                            .foregroundColor(palette.textMuted)
                        
                        HStack {
                            Image(systemName: "person.fill")
                                .font(.system(size: 10))
                                .foregroundColor(palette.textMuted)
                            
                            TextField("Enter your name...", text: $author)
                                .font(.system(size: 11, weight: .semibold, design: .monospaced))
                                .textFieldStyle(.plain)
                                .foregroundColor(palette.textMain)
                                .onChange(of: author) { _, newName in
                                    storedReviewerName = newName.trimmingCharacters(in: .whitespacesAndNewlines)
                                }
                        }
                        .padding(.horizontal, 10)
                        .padding(.vertical, 7)
                        .studioBox(background: palette.bgSubtle, border: palette.borderLine)
                    }
                    
                    // Color Tag Row
                    VStack(alignment: .leading, spacing: 5) {
                        Text("CATEGORY / COLOR")
                            .font(.system(size: 9, weight: .bold, design: .monospaced))
                            .foregroundColor(palette.textMuted)
                        
                        HStack(spacing: 8) {
                            ForEach(availableColors, id: \.id) { item in
                                Button(action: { selectedColor = item.id }) {
                                    HStack(spacing: 4) {
                                        Circle()
                                            .fill(item.color)
                                            .frame(width: 8, height: 8)
                                        Text(item.name.uppercased())
                                            .font(.system(size: 9, weight: .bold, design: .monospaced))
                                    }
                                    .padding(.horizontal, 8)
                                    .padding(.vertical, 5)
                                    .foregroundColor(selectedColor == item.id ? palette.textMain : palette.textMuted)
                                    .studioBox(
                                        background: selectedColor == item.id ? item.color.opacity(0.18) : palette.bgSubtle,
                                        border: selectedColor == item.id ? item.color : palette.borderLine
                                    )
                                }
                                .buttonStyle(.plain)
                            }
                        }
                    }
                    
                    // Note Text
                    VStack(alignment: .leading, spacing: 5) {
                        Text("FEEDBACK / QC COMMENT")
                            .font(.system(size: 9, weight: .bold, design: .monospaced))
                            .foregroundColor(palette.textMuted)
                        
                        TextField("Type your review note here...", text: $noteText, axis: .vertical)
                            .font(.system(size: 11, design: .monospaced))
                            .textFieldStyle(.plain)
                            .lineLimit(3...5)
                            .focused($isNoteFocused)
                            .padding(8)
                            .frame(minHeight: 70)
                            .background(palette.bgSubtle)
                            .cornerRadius(4)
                            .overlay(RoundedRectangle(cornerRadius: 4).stroke(palette.borderLine, lineWidth: 1))
                            .onSubmit {
                                saveNote()
                            }
                    }
                }
                .padding(16)
                .background(palette.bgMain)
                
                Rectangle().fill(palette.borderLine).frame(height: 1)
                
                // Bottom Actions
                HStack {
                    Text("Frame \(frameIndex)")
                        .font(.system(size: 10, design: .monospaced))
                        .foregroundColor(palette.textSubtle)
                    
                    Spacer()
                    
                    Button(action: { dismiss() }) {
                        Text("CANCEL (ESC)")
                            .font(.system(size: 10, weight: .bold, design: .monospaced))
                            .padding(.horizontal, 10)
                            .padding(.vertical, 6)
                            .foregroundColor(palette.textMuted)
                            .studioBox(background: palette.bgSubtle, border: palette.borderLine)
                    }
                    .buttonStyle(.plain)
                    
                    Button(action: saveNote) {
                        HStack(spacing: 5) {
                            Image(systemName: "checkmark")
                                .font(.system(size: 9, weight: .bold))
                            Text("SAVE NOTE (⏎)")
                                .font(.system(size: 10, weight: .black, design: .monospaced))
                        }
                        .padding(.horizontal, 12)
                        .padding(.vertical, 6)
                        .foregroundColor(palette.accentPositive)
                        .studioBox(background: palette.accentPositive.opacity(0.18), border: palette.accentPositive)
                    }
                    .buttonStyle(.plain)
                    .keyboardShortcut(.defaultAction)
                    .disabled(noteText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 10)
                .background(palette.bgPanel)
            }
            .frame(width: 460)
            .studioBox(background: palette.bgPanel, border: palette.borderStrong)
            .shadow(color: Color.black.opacity(0.45), radius: 24, x: 0, y: 12)
        }
        .allowsHitTesting(isPresented)
        .onAppear {
            if storedReviewerName.isEmpty {
                let systemName = NSFullUserName()
                storedReviewerName = systemName.isEmpty ? NSUserName() : systemName
            }
            author = storedReviewerName
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) {
                isNoteFocused = true
            }
        }
    }
    
    private func saveNote() {
        let cleanText = noteText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !cleanText.isEmpty else { return }
        
        let finalAuthor = author.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? "Reviewer" : author.trimmingCharacters(in: .whitespacesAndNewlines)
        storedReviewerName = finalAuthor
        
        let newNote = QCFileNote(
            frameIndex: frameIndex,
            timecode: timecode,
            author: finalAuthor,
            text: cleanText,
            colorTag: selectedColor,
            createdAt: Date(),
            isResolved: false
        )
        onSave(newNote)
        dismiss()
    }
    
    private func dismiss() {
        withAnimation(.easeInOut(duration: 0.15)) {
            isPresented = false
        }
    }
}
