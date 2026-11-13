import Foundation
import Testing
import VideoQCLib
@testable import QCpie

/// Settings → Orphaned notes: only hidden sidecars whose clip is gone are found, and removing them leaves the rest.
@Suite struct OrphanedNotesTests {
    private func write(_ mediaName: String, as fileName: String, in dir: URL) throws {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let doc = QCNotesDocument(version: 1, mediaFileName: mediaName, fps: 25, lastModified: Date(), notes: [])
        try encoder.encode(doc).write(to: dir.appendingPathComponent(fileName))
    }

    @Test func findsOnlySidecarsOfMissingClips() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let sub = root.appendingPathComponent("Sub")
        try FileManager.default.createDirectory(at: sub, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        try Data().write(to: root.appendingPathComponent("kept.mov"))
        try write("kept.mov", as: ".kept.mov.qcnotes", in: root)          // clip present
        try write("gone.mov", as: ".gone.mov.qcnotes", in: sub)           // orphan, in a subfolder
        try write("other.mov", as: ".renamed.mov.qcnotes", in: root)      // name mismatch: not ours to judge
        try write("old.mov", as: "old.mov.qcnotes", in: root)             // older visible sidecar, orphan
        try write("gone.mov", as: "gone - QC Notes.qcnotes", in: root)    // an export: kept
        try Data("junk".utf8).write(to: root.appendingPathComponent(".broken.mov.qcnotes"))  // unreadable
        try Data().write(to: sub.appendingPathComponent("._.gone.mov.qcnotes"))             // AppleDouble companion

        let orphans = QCNotesManager.orphanedSidecars(in: root)
        #expect(Set(orphans.map(\.lastPathComponent)) == [".gone.mov.qcnotes", "old.mov.qcnotes"])

        #expect(QCNotesManager.removeSidecars(orphans) == 2)
        let left = try FileManager.default.contentsOfDirectory(atPath: sub.path)
        #expect(left.isEmpty)
        #expect(FileManager.default.fileExists(atPath: root.appendingPathComponent(".kept.mov.qcnotes").path))
        #expect(FileManager.default.fileExists(atPath: root.appendingPathComponent("gone - QC Notes.qcnotes").path))
    }

    @Test func mediaNameOfSidecar() {
        #expect(QCNotesManager.mediaName(ofSidecar: ".A.mov.qcnotes") == "A.mov")
        #expect(QCNotesManager.mediaName(ofSidecar: "._.A.mov.qcnotes") == nil)
        #expect(QCNotesManager.mediaName(ofSidecar: "A.mov.qcnotes") == "A.mov")
        #expect(QCNotesManager.mediaName(ofSidecar: "..qcnotes") == nil)
        #expect(QCNotesManager.mediaName(ofSidecar: ".qcnotes") == nil)
    }
}
