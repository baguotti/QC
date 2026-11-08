import Foundation
import Testing
@testable import QCpie
@testable import VideoQCLib

/// The notes sidecar store: reviewers' work, so every path that writes or deletes it is covered here.
@Suite("QC notes store", .serialized)
struct QCNotesStoreTests {
    private func clip() throws -> (URL, URL) {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("NotesStore-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let url = dir.appendingPathComponent("SHOT_010 v2.mov")
        try Data("x".utf8).write(to: url)
        return (dir, url)
    }
    private func note(_ text: String, _ frame: Int = 10) -> QCFileNote {
        QCFileNote(frameIndex: frame, timecode: "00:00:00:10", author: "QA", text: text)
    }
    private func cleanup(_ dir: URL, _ url: URL) {
        try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: dir.path)
        try? FileManager.default.removeItem(at: dir)
        try? FileManager.default.removeItem(at: QCNotesManager.fallbackURL(for: url))
    }

    @Test("Imported notes keep their moment in time on a clip at another frame rate")
    func rescaledImport() {
        let notes = [note("a", 50), note("b", 0)]
        let moved = QCNotesManager.rescaled(notes, from: 25, to: 50)
        #expect(moved.map(\.frameIndex) == [100, 0])
        #expect(moved[0].timecode == "00:00:02:00")
        #expect(QCNotesManager.rescaled(notes, from: 25, to: 25).map(\.frameIndex) == [50, 0])
        #expect(QCNotesManager.rescaled(notes, from: 0, to: 50).map(\.frameIndex) == [50, 0])
        _ = QCNotesManager.rescaled([note("huge", .max)], from: 1, to: 1000)
    }

    @Test("Save and load round trip; clearing removes the sidecar")
    func roundTrip() async throws {
        let (dir, url) = try clip(); defer { cleanup(dir, url) }
        let store = QCNotesManager.shared
        #expect(await store.saveNotes([note("b", 20), note("a & <ç>", 5)], for: url, fps: 25))
        let loaded = await store.loadNotes(for: url)
        #expect(loaded.map(\.text) == ["a & <ç>", "b"])
        #expect(FileManager.default.fileExists(atPath: QCNotesManager.sidecarURL(for: url).path))
        #expect(await store.saveNotes([], for: url, fps: 25))
        #expect(await store.loadNotes(for: url).isEmpty)
        #expect(!FileManager.default.fileExists(atPath: QCNotesManager.sidecarURL(for: url).path))
    }

    @Test("A read-only folder keeps notes in the fallback copy; once writable they move back beside the clip")
    func readOnlyFolder() async throws {
        let (dir, url) = try clip(); defer { cleanup(dir, url) }
        let store = QCNotesManager.shared
        try FileManager.default.setAttributes([.posixPermissions: 0o555], ofItemAtPath: dir.path)
        #expect(await store.saveNotes([note("kept")], for: url, fps: 25))
        #expect(await store.loadNotes(for: url).map(\.text) == ["kept"])
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: dir.path)
        #expect(await store.saveNotes([note("kept"), note("more", 30)], for: url, fps: 25))
        #expect(await store.loadNotes(for: url).count == 2)
        #expect(!FileManager.default.fileExists(atPath: QCNotesManager.fallbackURL(for: url).path))
    }

    @Test("A damaged notes file is never overwritten")
    func damagedIsKept() async throws {
        let (dir, url) = try clip(); defer { cleanup(dir, url) }
        let store = QCNotesManager.shared
        let sidecar = QCNotesManager.sidecarURL(for: url)
        try Data("{ not json".utf8).write(to: sidecar)
        #expect(await store.loadNotes(for: url).isEmpty)
        #expect(await store.saveNotes([note("new")], for: url, fps: 25) == false)
        #expect(try String(contentsOf: sidecar, encoding: .utf8) == "{ not json")
    }

    @Test("An export is never the legacy sidecar the next save deletes")
    func exportNameDoesNotCollide() {
        let url = URL(fileURLWithPath: "/d/SHOT_010 v2.mov")
        let exportName = "\(url.deletingPathExtension().lastPathComponent) - QC Notes.qcnotes"
        #expect(url.deletingLastPathComponent().appendingPathComponent(exportName) != QCNotesManager.visibleSidecarURL(for: url))
    }
}
