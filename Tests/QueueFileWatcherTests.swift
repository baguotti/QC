import Foundation
import Testing
@testable import QCpie

@Suite("Queue file watcher")
struct QueueFileWatcherTests {
    @Test func topFoldersDropNestedOnes() {
        let top = QueueFileWatcher.topFolders(of: ["/r/a", "/r/a/b", "/r/a b", "/c/d/e", "/c/d/e"])
        #expect(top == ["/c/d/e", "/r/a", "/r/a b"])
    }

    @Test func filesOnAnEjectedVolumeAreKept() {
        #expect(QueueFileWatcher.volumeIsMounted("/Users/me/clip.mov"))
        #expect(!QueueFileWatcher.volumeIsMounted("/Volumes/QCpieNoSuchDrive-\(UUID().uuidString)/clip.mov"))
    }

    @Test @MainActor func deletedAndMovedFilesAreReported() async throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("QueueWatch-\(UUID().uuidString)")
        let sub = dir.appendingPathComponent("sub")
        try FileManager.default.createDirectory(at: sub, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let kept = dir.appendingPathComponent("kept.mov"), deleted = dir.appendingPathComponent("deleted.mov")
        let moved = sub.appendingPathComponent("moved.mov")
        for url in [kept, deleted, moved] { try Data([0]).write(to: url) }

        let watcher = QueueFileWatcher(grace: 0.2)
        var reported = Set<String>()
        watcher.watch([kept, deleted, moved]) { gone in reported.formUnion(gone.map(\.lastPathComponent)) }
        try await Task.sleep(for: .milliseconds(300))   // the stream starts on its own queue

        try FileManager.default.removeItem(at: deleted)
        try FileManager.default.moveItem(at: moved, to: dir.appendingPathComponent("renamed.mov"))

        let deadline = Date().addingTimeInterval(5)
        while reported.count < 2, Date() < deadline { try await Task.sleep(for: .milliseconds(100)) }
        #expect(reported == ["deleted.mov", "moved.mov"])
    }

    @Test @MainActor func aFileRewrittenAtTheSamePathStays() async throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("QueueWatch-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let clip = dir.appendingPathComponent("export.mov")
        try Data([0]).write(to: clip)
        let watcher = QueueFileWatcher(grace: 1)
        var reported: [URL] = []
        watcher.watch([clip]) { reported += $0 }
        try await Task.sleep(for: .milliseconds(300))
        try FileManager.default.removeItem(at: clip)
        try await Task.sleep(for: .milliseconds(200))
        try Data([1]).write(to: clip)
        try await Task.sleep(for: .seconds(2.5))
        #expect(reported.isEmpty)
    }

    @Test @MainActor func aRenamedFolderIsFoundWhenQCpieComesBack() async throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("QueueWatch-\(UUID().uuidString)")
        let sub = dir.appendingPathComponent("shots")
        try FileManager.default.createDirectory(at: sub, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let clip = sub.appendingPathComponent("a.mov")
        try Data([0]).write(to: clip)
        let watcher = QueueFileWatcher(grace: 0.1)
        var reported: [String] = []
        watcher.watch([clip]) { reported += $0.map(\.lastPathComponent) }
        try FileManager.default.moveItem(at: sub, to: dir.appendingPathComponent("shots renamed"))
        watcher.verifyFolders()
        let deadline = Date().addingTimeInterval(3)
        while reported.isEmpty, Date() < deadline { try await Task.sleep(for: .milliseconds(100)) }
        #expect(reported == ["a.mov"])
    }
}
