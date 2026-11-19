import CoreGraphics
import Foundation
import Testing
@testable import QCpie
@testable import VideoQCLib

@Suite("Note drawings")
struct NoteDrawingTests {
    /// A notes file from before drawings still reads, and a note without one writes no `drawing` key.
    @Test func olderNotesReadAndPlainNotesStayPlain() throws {
        let old = #"{"id":"6F1C2C0A-3E5B-4C55-9C2F-3C2B1E4A5D6E","frameIndex":3,"timecode":"00:00:00:03","author":"A","text":"t","createdAt":0}"#
        let note = try JSONDecoder().decode(QCFileNote.self, from: Data(old.utf8))
        #expect(note.drawing == nil)
        let written = String(decoding: try JSONEncoder().encode(note), as: UTF8.self)
        #expect(!written.contains("drawing"))
    }

    @Test func drawingRoundTrips() throws {
        let note = QCFileNote(frameIndex: 1, timecode: "", author: "", text: "x", drawing: [[0.1, 0.2, 0.3, 0.4], [0.5, 0.5]])
        let back = try JSONDecoder().decode(QCFileNote.self, from: JSONEncoder().encode(note))
        #expect(back.drawing == [[0.1, 0.2, 0.3, 0.4], [0.5, 0.5]])
    }

    /// Stored top-left, drawn in a bottom-left layer: (0.25, 0.1) on a 200×100 picture is x 50, y 90.
    @Test func strokesMapToThePicture() {
        let path = PlayerContainerNSView.strokePath([[0.25, 0.1, 1, 1]], in: CGRect(x: 0, y: 0, width: 200, height: 100))
        var points: [CGPoint] = []
        path.applyWithBlock { element in points.append(element.pointee.points[0]) }
        #expect(points == [CGPoint(x: 50, y: 90), CGPoint(x: 200, y: 0)])
    }

    /// Three samples: a curve to the midpoint of the last two (the middle sample its control point), then the end.
    @Test func strokesAreSmoothed() {
        let path = PlayerContainerNSView.strokePath([[0, 1, 0.5, 0, 1, 1]], in: CGRect(x: 0, y: 0, width: 100, height: 100))
        var kinds: [CGPathElementType] = []
        path.applyWithBlock { kinds.append($0.pointee.type) }
        #expect(kinds == [.moveToPoint, .addQuadCurveToPoint, .addLineToPoint])
    }

    /// No picture to draw on (nothing loaded): draw mode doesn't start.
    @MainActor @Test func drawModeNeedsAPicture() {
        let engine = PlayerEngine()
        #expect(engine.toggleDrawMode() == false)
        #expect(engine.isDrawingNote == false)
    }

    /// Changed on both sides (sync) or imported: the drawing comes across and a side without one never clears it.
    @Test func mergeKeepsDrawings() {
        let id = UUID()
        let old = Date(timeIntervalSince1970: 0), new = Date(timeIntervalSince1970: 100)
        let plain = QCFileNote(id: id, frameIndex: 1, timecode: "", author: "", text: "a", createdAt: old)
        var drawn = plain
        drawn.drawing = [[0.1, 0.1, 0.2, 0.2]]
        #expect(QCNotesManager.merge(existing: [plain], incoming: [drawn]).notes.first?.drawing == drawn.drawing)
        var newerText = plain
        newerText.text = "b"
        newerText.editedAt = new
        let kept = QCNotesManager.merge(existing: [drawn], incoming: [newerText]).notes.first
        #expect(kept?.text == "b" && kept?.drawing == drawn.drawing)
    }
}
