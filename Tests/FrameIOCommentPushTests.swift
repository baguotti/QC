import Foundation
import Testing
import VideoQCLib
@testable import QCpie

/// Records Send's comments instead of posting them: nothing reaches Frame.io.
private actor StubCommentAPI: FrameIOCommentAPI {
    var posted: [(text: String, timestamp: Int?, completed: Bool)] = []
    var failing: Set<Int> = []
    var signedOutAt: Int?
    /// Like an image on Frame.io: any timestamp is refused.
    var refusesTimestamps = false

    init(failing: Set<Int> = [], signedOutAt: Int? = nil, refusesTimestamps: Bool = false) {
        self.failing = failing
        self.signedOutAt = signedOutAt
        self.refusesTimestamps = refusesTimestamps
    }

    func createComment(account: String, file: String, text: String, timestamp: Int?, completed: Bool) async throws -> String {
        if refusesTimestamps, timestamp != nil {
            throw FrameIO.Failure.http(422, "The asset's filetype does not accept a timestamp parameter for asset: X.")
        }
        if let timestamp, signedOutAt == timestamp { throw FrameIO.Failure.signedOut }
        if let timestamp, failing.contains(timestamp) { throw FrameIO.Failure.http(422, "Invalid value") }
        posted.append((text, timestamp, completed))
        return "C\(timestamp ?? posted.count)"
    }
}

private func note(_ frame: Int, _ text: String, author: String = "Ric", resolved: Bool = false,
                  replies: [QCNoteReply] = [], id: UUID = UUID()) -> QCFileNote {
    QCFileNote(id: id, frameIndex: frame, timecode: "00:00:00:\(frame)", author: author, text: text,
               createdAt: Date(timeIntervalSince1970: 1000), isResolved: resolved, replies: replies)
}

@Suite("Frame.io Send QC Notes")
struct FrameIOCommentPushTests {
    @Test("Only notes written here, not sent yet, with text, are sent")
    func pending() {
        let imported = note(1, "From the client"), sent = note(2, "Sent before"), synced = note(3, "x", author: "Ana (Frame.io)")
        let empty = note(4, "  "), fresh = note(5, "Line at top"), lineCheck = note(6, "Left Edge (2px) — green line", author: "Line QC")
        let result = FrameIOCommentPush.pending([imported, sent, synced, empty, fresh, lineCheck], imported: [imported.id], sent: [sent.id])
        #expect(result.map(\.id) == [fresh.id])
    }

    @Test("The text has the author when it isn't the Frame.io account, and the replies")
    func text() {
        let reply = QCNoteReply(id: UUID(), author: "Ana", text: "Fixed in v2 ", createdAt: Date())
        #expect(FrameIOCommentPush.text(for: note(1, " Dead pixel ", author: "Ric"), signedInName: "ric") == "Dead pixel")
        #expect(FrameIOCommentPush.text(for: note(1, "Dead pixel", author: "Ana", replies: [reply]), signedInName: "Ric")
                == "Dead pixel\n— Ana\n↳ Ana: Fixed in v2")
    }

    @Test("Notes go at their frames, in order, resolved ones resolved; each is recorded as it lands")
    func run() async {
        let api = StubCommentAPI()
        let a = note(51, "B"), b = note(0, "A", resolved: true)
        let recorded = RecordedSends()
        let outcome = await FrameIOCommentPush.run([a, b], account: "A", file: "F", signedInName: "Ric", api: api) { note, comment in
            await recorded.add(note, comment)
        }
        let posted = await api.posted
        #expect(posted.map(\.timestamp) == [0, 51])
        #expect(posted.map(\.completed) == [true, false])
        #expect(outcome.sent.map(\.comment) == ["C0", "C51"])
        #expect(await recorded.all == [b.id: "C0", a.id: "C51"])
    }

    @Test("A failed note is reported and the rest still go; signing out stops")
    func failures() async {
        let api = StubCommentAPI(failing: [2], signedOutAt: 4)
        let outcome = await FrameIOCommentPush.run([note(1, "a"), note(2, "b"), note(3, "c"), note(4, "d"), note(5, "e")],
                                                   account: "A", file: "F", signedInName: nil, api: api) { _, _ in }
        #expect(await api.posted.map(\.timestamp) == [1, 3])
        #expect(outcome.failures.count == 2)
        #expect(outcome.failures.last == FrameIOCommentPush.signedOutMessage)
        #expect(FrameIOCommentPush.summary(sent: 2, clips: 1, failures: outcome.failures).hasPrefix("Sent 2 notes to Frame.io · 2 failed"))
    }

    @Test("A still's notes go without a timestamp; a file that refuses one gets the rest without")
    func untimed() async {
        let still = StubCommentAPI()
        _ = await FrameIOCommentPush.run([note(0, "Logo soft")], account: "A", file: "F", signedInName: nil, timed: false, api: still) { _, _ in }
        #expect(await still.posted.map(\.timestamp) == [nil])
        let image = StubCommentAPI(refusesTimestamps: true)
        let outcome = await FrameIOCommentPush.run([note(0, "a"), note(0, "b")], account: "A", file: "F", signedInName: nil, api: image) { _, _ in }
        #expect(outcome.failures.isEmpty)
        #expect(await image.posted.map(\.timestamp) == [nil, nil])
    }

    @Test("Comments on a still (no timestamp, no page) import at frame 0; PDF page comments don't")
    func stillComments() {
        let still = FrameIO.Comment(id: "S1", text: "Crop tighter", timestamp: nil)
        let page = FrameIO.Comment(id: "P1", text: "Typo", timestamp: nil, page: 2)
        let notes = FrameIOCommentImport.notes(from: [still, page], fps: 25)
        #expect(notes.map(\.text) == ["Crop tighter"])
        #expect(notes.first?.frameIndex == 0)
    }

    @Test("A sent comment's replies and resolving come back to its note, without touching its text or frame")
    func echo() {
        let local = note(51, "Dead pixel", author: "Ric")
        let comment = FrameIO.Comment(id: "C51", text: "Dead pixel\n— Ric", timestamp: 51, timecode: "01:00:02:01",
                                      completedAt: "2026-10-30T13:22:37Z", createdAt: "2026-10-30T13:20:00Z",
                                      replies: [FrameIO.Comment(id: "R1", text: "Fixed", timestamp: nil, createdAt: "2026-10-30T13:21:00Z",
                                                                owner: .init(name: "Ana", email: nil))])
        let incoming = FrameIOCommentImport.notes(from: [comment], fps: 25, sent: ["C51": local.id])
        let result = FrameIOCommentImport.merge(local: [local], incoming: incoming, previouslyImported: [], sent: [local.id])
        #expect(result.added == 0 && result.updated == 1)
        let merged = result.notes[0]
        #expect(merged.id == local.id && merged.text == "Dead pixel" && merged.frameIndex == 51 && merged.colorTag == local.colorTag)
        #expect(merged.isResolved)
        #expect(merged.replies.map(\.text) == ["Fixed"])
    }

    @Test("A sent note deleted here isn't brought back by its comment")
    func echoOfDeletedNote() {
        let gone = UUID()
        let comment = FrameIO.Comment(id: "C1", text: "Old", timestamp: 1, timecode: "00:00:00:01")
        let incoming = FrameIOCommentImport.notes(from: [comment], fps: 25, sent: ["C1": gone])
        let result = FrameIOCommentImport.merge(local: [], incoming: incoming, previouslyImported: [], sent: [gone])
        #expect(result.notes.isEmpty && result.added == 0)
    }
}

private actor RecordedSends {
    var all: [UUID: String] = [:]
    func add(_ note: UUID, _ comment: String) { all[note] = comment }
}
