import Foundation
import Testing
import VideoQCLib
@testable import QCpie

@Suite("Frame.io comments → QC notes")
struct FrameIOCommentsTests {
    private func comment(_ id: String, frame: Int?, text: String = "Extra shot", completed: Bool = false, edited: String? = nil,
                         replies: [FrameIO.Comment] = [], annotation: String? = nil, duration: Int? = nil) -> FrameIO.Comment {
        FrameIO.Comment(id: id, text: text, annotation: annotation, timestamp: frame, duration: duration,
                        completedAt: completed ? "2026-10-28T10:00:00.000Z" : nil, createdAt: "2026-10-01T09:30:00.000Z",
                        textEditedAt: edited, owner: .init(name: "Maria A.", email: "maria@example.com"), replies: replies)
    }

    @Test("A comment becomes a note on the frame before its 1-based timestamp, marked as from Frame.io")
    func conversion() {
        let reply = FrameIO.Comment(id: "r1", text: "Agreed", timestamp: nil, createdAt: "2026-10-02T09:30:00Z", owner: .init(name: "Ric", email: nil))
        let notes = FrameIOCommentImport.notes(from: [comment("c1", frame: 355, completed: true, replies: [reply], annotation: "{}")], fps: 24)
        #expect(notes.count == 1)
        let note = notes[0]
        #expect(note.frameIndex == 354)
        #expect(note.timecode == TimecodeFormatter.format(frameIndex: 354, fps: 24))
        #expect(note.author == "Maria A. (Frame.io)")
        #expect(note.colorTag == "purple")
        #expect(note.isResolved)
        #expect(note.text.hasPrefix("Extra shot"))
        #expect(note.text.contains("drawing"))
        #expect(note.replies.map(\.author) == ["Ric (Frame.io)"])
        #expect(note.id == FrameIOCommentImport.noteID("c1"))
    }

    @Test("Notes land where Frame.io's player shows the comment: its timecode, not the rounded frame number")
    func shownTimecode() {
        // Measured on a real 25 fps clip: 261 ↔ 00:00:10:11 (frame 261), 450 ↔ 00:00:17:24 (frame 449).
        let comments = [FrameIO.Comment(id: "a", text: "add a note here!", timestamp: 261, timecode: "00:00:10:11"),
                        FrameIO.Comment(id: "b", text: "Second note test", timestamp: 450, timecode: "00:00:17:24")]
        let notes = FrameIOCommentImport.notes(from: comments, fps: 25)
        #expect(notes.map(\.frameIndex) == [261, 449])
        #expect(notes.map(\.timecode) == ["00:00:10:11", "00:00:17:24"])
    }

    @Test("An embedded start timecode is taken off (Frame.io's timecodes include it)")
    func startTimecode() {
        let start = 10 * 3600 * 25   // 10:00:00:00
        let comments = [FrameIO.Comment(id: "a", text: "x", timestamp: 261, timecode: "10:00:10:11"),
                        FrameIO.Comment(id: "b", text: "y", timestamp: 450, timecode: "10:00:17:24")]
        #expect(FrameIOCommentImport.startFrames(comments, fps: 25) == start)
        #expect(FrameIOCommentImport.notes(from: comments, fps: 25).map(\.frameIndex) == [261, 449])
    }

    @Test("Drop-frame timecode converts to frames")
    func dropFrame() {
        #expect(FrameIOCommentImport.frames("00:01:00;02", fps: 29.97) == 1800)
        #expect(FrameIOCommentImport.frames("00:10:00;00", fps: 29.97) == 17982)
    }

    @Test("An imported note moves when Frame.io's position differs (fixes notes imported one frame off)")
    func moves() {
        let old = FrameIOCommentImport.notes(from: [FrameIO.Comment(id: "a", text: "x", timestamp: 261)], fps: 25)
        #expect(old.first?.frameIndex == 260)
        let fixed = FrameIOCommentImport.notes(from: [FrameIO.Comment(id: "a", text: "x", timestamp: 261, timecode: "00:00:10:11")], fps: 25)
        let result = FrameIOCommentImport.merge(local: old, incoming: fixed, previouslyImported: [FrameIOCommentImport.noteID("a")])
        #expect(result.notes.first?.frameIndex == 261)
        #expect(result.updated == 1)
    }

    @Test("Frame 1 is the first frame; document page comments are skipped")
    func edges() {
        let page = FrameIO.Comment(id: "b", text: "x", timestamp: nil, page: 3)
        let notes = FrameIOCommentImport.notes(from: [comment("a", frame: 1), page], fps: 25)
        #expect(notes.map(\.frameIndex) == [0])
    }

    @Test("Importing again adds nothing; an edit on Frame.io updates the note's text")
    func reimport() {
        let first = FrameIOCommentImport.merge(local: [], incoming: FrameIOCommentImport.notes(from: [comment("c1", frame: 10)], fps: 25),
                                               previouslyImported: [])
        #expect(first.added == 1)
        let again = FrameIOCommentImport.merge(local: first.notes, incoming: FrameIOCommentImport.notes(from: [comment("c1", frame: 10)], fps: 25),
                                               previouslyImported: [FrameIOCommentImport.noteID("c1")])
        #expect(again.added == 0 && again.updated == 0)
        let edited = comment("c1", frame: 10, text: "Swap this shot", edited: "2026-10-27T10:00:00Z")
        let update = FrameIOCommentImport.merge(local: again.notes, incoming: FrameIOCommentImport.notes(from: [edited], fps: 25),
                                                previouslyImported: [FrameIOCommentImport.noteID("c1")])
        #expect(update.updated == 1)
        #expect(update.notes.first?.text == "Swap this shot")
    }

    @Test("A note deleted here isn't brought back; new comments still come in")
    func deletedStaysDeleted() {
        let incoming = FrameIOCommentImport.notes(from: [comment("old", frame: 5), comment("new", frame: 9)], fps: 25)
        let result = FrameIOCommentImport.merge(local: [], incoming: incoming, previouslyImported: [FrameIOCommentImport.noteID("old")])
        #expect(result.notes.map(\.id) == [FrameIOCommentImport.noteID("new")])
    }

    @Test("Notes made in QCpie are kept alongside imported ones; resolving here survives a re-import")
    func keepsLocal() {
        let mine = QCFileNote(frameIndex: 3, timecode: "00:00:00:03", author: "Ric", text: "Mine")
        var imported = FrameIOCommentImport.merge(local: [mine], incoming: FrameIOCommentImport.notes(from: [comment("c1", frame: 10)], fps: 25),
                                                  previouslyImported: []).notes
        #expect(imported.count == 2)
        imported = imported.map { var n = $0; if n.id == FrameIOCommentImport.noteID("c1") { n.isResolved = true }; return n }
        let again = FrameIOCommentImport.merge(local: imported, incoming: FrameIOCommentImport.notes(from: [comment("c1", frame: 10)], fps: 25),
                                               previouslyImported: [FrameIOCommentImport.noteID("c1")])
        #expect(again.notes.first { $0.id == FrameIOCommentImport.noteID("c1") }?.isResolved == true)
        #expect(again.notes.contains { $0.id == mine.id })
    }

    @Test("The comments response decodes (timestamp as a number or a string)")
    func decoding() throws {
        let json = #"""
        {"data":[{"id":"c1","file_id":"f","text":"DJ","annotation":null,"timestamp":580,"duration":null,"page":null,
          "completed_at":null,"completer_id":null,"created_at":"2026-05-01T10:00:00.123Z","updated_at":"2026-05-01T10:00:00.123Z",
          "text_edited_at":null,"attachments":null,"links":[],"mentions":[],"text_review_annotation":null,
          "owner":{"id":"u","name":"Maria A.","email":"m@example.com","avatar_url":null,"active":true},"replies":[]},
         {"id":"c2","text":"x","timestamp":"12","created_at":"2026-05-01T10:00:00Z"}],
         "links":{"next":null}}
        """#
        struct Page: Decodable { let data: [FrameIO.Comment] }
        let page = try JSONDecoder().decode(Page.self, from: Data(json.utf8))
        #expect(page.data.map(\.timestamp) == [580, 12])
        #expect(page.data[0].owner?.name == "Maria A.")
    }

    @Test("Files seen on Frame.io are found again by exact name and size only")
    func index() async throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("idx-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let clip = folder.appendingPathComponent("HERO_E1.2.mp4")
        try Data(count: 500).write(to: clip)
        let other = folder.appendingPathComponent("HERO_E1.1.mp4")
        try Data(count: 500).write(to: other)
        let item = try JSONDecoder().decode(FrameIO.Item.self, from: Data(#"{"id":"f12","name":"HERO_E1.2.mp4","type":"file","file_size":500}"#.utf8))
        let links = FrameIOLinks(directory: nil)
        await links.remember([item], account: "acc")
        #expect(await links.indexed(clip) == .init(account: "acc", fileID: "f12"))
        #expect(await links.indexed(other) == nil)
        try Data(count: 501).write(to: clip)
        #expect(await links.indexed(clip) == nil)
    }

    @Test("A link is dropped when the local file changes size")
    func links() async throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("link-\(UUID().uuidString).mov")
        try Data(count: 100).write(to: url)
        let links = FrameIOLinks(directory: nil)
        await links.link(url, account: "a", fileID: "f1")
        #expect(await links.link(for: url)?.fileID == "f1")
        try Data(count: 120).write(to: url)
        #expect(await links.link(for: url) == nil)
        await links.markImported(["c1", "c2"], fileID: "f1")
        #expect(await links.imported("f1") == ["c1", "c2"])
    }
}
