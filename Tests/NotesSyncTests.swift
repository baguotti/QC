import Foundation
import Testing
@testable import QCpie
@testable import VideoQCLib

@Suite("Notes sync merge and key derivation")
struct NotesSyncTests {
    private func note(_ text: String, frame: Int = 10) -> QCFileNote {
        QCFileNote(frameIndex: frame, timecode: "00:00:00:10", author: "A", text: text, createdAt: Date(timeIntervalSince1970: 1_000))
    }

    @Test func newNotesFromBothSidesAreKept() {
        let a = note("local"), b = note("remote", frame: 5)
        let merged = QCNotesManager.threeWayMerge(local: [a], remote: [b], base: [])
        #expect(merged.map(\.id) == [b.id, a.id])
    }

    @Test func deletionOnEitherSideWins() {
        let a = note("a"), b = note("b")
        let merged = QCNotesManager.threeWayMerge(local: [a], remote: [b], base: [a, b])
        #expect(merged.isEmpty)
    }

    @Test func oneSidedChangeIsTakenIncludingUnresolve() {
        var resolved = note("x")
        resolved.isResolved = true
        var reopened = resolved
        reopened.isResolved = false
        #expect(QCNotesManager.threeWayMerge(local: [reopened], remote: [resolved], base: [resolved]) == [reopened])
        #expect(QCNotesManager.threeWayMerge(local: [resolved], remote: [reopened], base: [resolved]) == [reopened])
    }

    @Test func bothChangedUnionsReplies() {
        let original = note("x")
        var local = original
        local.replies = [QCNoteReply(author: "A", text: "mine")]
        var remote = original
        remote.replies = [QCNoteReply(author: "B", text: "theirs")]
        let merged = QCNotesManager.threeWayMerge(local: [local], remote: [remote], base: [original])
        #expect(merged.first?.replies.count == 2)
    }

    @Test func passwordDerivationIsStableAndCaseInsensitive() {
        let password = NotesSync.generatePassword()
        #expect(password.count == 23)
        let upper = NotesSync.deriveKeys(password: password)
        let lower = NotesSync.deriveKeys(password: " \(password.lowercased())\n")
        #expect(upper?.room == lower?.room)
        #expect(upper?.room.count == 32)
        #expect(upper?.room != NotesSync.deriveKeys(password: NotesSync.generatePassword())?.room)
        #expect(NotesSync.deriveKeys(password: "short") == nil)
    }
}
