import SwiftUI
import VideoQCLib

/// Drawing on notes (Frame.io style): there is no drawing apart from a note. The first stroke on a frame adds a note
/// there ("Drawing", with its marker); further strokes on that frame go into it; each is saved when drawn.
extension ContentView {

    /// Pencil or D. Says why when there is no picture to draw on.
    func toggleDrawing() {
        guard playerEngine.activeURL != nil else { return }
        if !playerEngine.toggleDrawMode() {
            showToast(playerEngine.compareMode == .difference || playerEngine.compareMode == .overlay
                      ? "Drawing isn't available in Difference or Overlay view"
                      : "Show the clip whose notes are open to draw on it")
        }
    }

    /// This draw session's note on the frame shown, if one was started here (and still exists).
    private var drawnNoteOnThisFrame: QCFileNote? {
        let frame = playerEngine.notesFrame(atMasterFrame: playerEngine.currentFrame)
        guard shownNotesAreTarget, let id = playerEngine.drawingNotes[frame],
              let note = playerEngine.activeNotes.first(where: { $0.id == id }), note.frameIndex == frame else { return nil }
        return note
    }

    func commitStroke(_ stroke: [Double]) {
        // Ended (Esc) or playing (Space) mid-stroke: the frame under it is gone, so the stroke is too.
        // The clip's notes not loaded yet (just switched): its strokes couldn't find their note, each would make another.
        guard stroke.count >= 2, playerEngine.isDrawingNote, !playerEngine.isPlaying, !playerEngine.isScrubbing,
              shownNotesAreTarget else { return }
        let rounded = stroke.map { ($0 * 10_000).rounded() / 10_000 }   // a tenth of a pixel at 8K
        if var note = drawnNoteOnThisFrame {
            note.drawing = (note.drawing ?? []) + [rounded]
            playerEngine.lastDrawnNoteID = note.id
            replaceDrawnNote(note)
            return
        }
        let author = UserDefaults.standard.string(forKey: "reviewerName")?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let note = QCFileNote(frameIndex: playerEngine.currentFrame, timecode: playerEngine.currentTimecode,
                              author: author.isEmpty ? "Reviewer" : author, text: QCFileNote.drawingPlaceholder,
                              colorTag: Self.noteColorTag, drawing: [rounded])
        addNote(note)   // on slot A's clock, mapped to slot B's frames there, like any note
        // Keyed by the frame the note landed on (slot B's frames for B's notes), as `drawnNoteOnThisFrame` looks it up.
        playerEngine.drawingNotes[playerEngine.notesFrame(atMasterFrame: playerEngine.currentFrame)] = note.id
        playerEngine.lastDrawnNoteID = note.id
    }

    /// ⌘Z or Undo in the drawing bar: the last stroke of this frame's note. false when there is none (the key goes on).
    @discardableResult
    func undoStroke() -> Bool {
        guard playerEngine.isDrawingNote, var note = drawnNoteOnThisFrame, let strokes = note.drawing, !strokes.isEmpty else { return false }
        note.drawing = Array(strokes.dropLast())
        saveDrawing(note)
        return true
    }

    /// Clear in the drawing bar: all of this frame's note drawing; draw mode stays.
    func clearDrawing() {
        guard var note = drawnNoteOnThisFrame else { return }
        note.drawing = []
        saveDrawing(note)
    }

    /// A note left without strokes and never given text was only its drawing: it goes, marker and all.
    private func saveDrawing(_ note: QCFileNote) {
        var note = note
        if note.drawing?.isEmpty ?? true {
            note.drawing = nil
            if note.text == QCFileNote.drawingPlaceholder && note.replies.isEmpty {
                playerEngine.drawingNotes = playerEngine.drawingNotes.filter { $0.value != note.id }
                if playerEngine.lastDrawnNoteID == note.id { playerEngine.lastDrawnNoteID = nil }
                deleteNote(id: note.id)
                return
            }
        }
        replaceDrawnNote(note)
    }

    /// Shown at once; saved once drawing pauses for half a second. A save per stroke queued a notes write and a sync
    /// push each, and saves started close together could land out of order (an older list written last loses strokes).
    private func replaceDrawnNote(_ note: QCFileNote) {
        guard let url = notesTargetURL, shownNotesAreTarget,
              let index = playerEngine.activeNotes.firstIndex(where: { $0.id == note.id }) else { return }
        playerEngine.activeNotes[index] = note
        let snapshot = playerEngine.activeNotes
        // Only a save of this clip's notes is replaced: drawing on the next clip within half a second cancelled the
        // last clip's save, and its last strokes were lost.
        if let pending = drawingSaveURL, isSameURL(pending, url) { drawingSaveTask?.cancel() }
        drawingSaveURL = url
        drawingSaveTask = Task {
            try? await Task.sleep(for: .milliseconds(500))
            guard !Task.isCancelled else { return }
            // Still shown: the notes as they are now (an edit or delete since the stroke stays); another clip shown:
            // this one's as left after the stroke (nothing else could change them).
            saveNotes(isSameURL(playerEngine.activeNotesURL, url) ? playerEngine.activeNotes : snapshot, for: url)
        }
    }

    /// The colour picked in the Notes drawer (red and purple are reserved).
    static var noteColorTag: String { QCNoteTheme.userTag(UserDefaults.standard.string(forKey: "noteColor") ?? "cyan") }

    /// A colour picked while drawing: this frame's drawn note takes it (one note, one colour); new ones follow it.
    func drawColorChanged(_ tag: String) {
        guard playerEngine.isDrawingNote, var note = drawnNoteOnThisFrame else { return }
        note.colorTag = QCNoteTheme.userTag(tag)
        replaceDrawnNote(note)
    }

    /// Draw mode ended: the Notes drawer, when showing notes, opens the note last drawn on for its text.
    func offerDrawnNoteText(_ id: UUID?) {
        guard let id, showNotesDrawer, playerDrawerTab == .notes,
              playerEngine.activeNotes.first(where: { $0.id == id })?.text == QCFileNote.drawingPlaceholder else { return }
        drawnNoteToEdit = id
    }
}
