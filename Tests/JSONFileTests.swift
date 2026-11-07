import Foundation
import Testing
@testable import VideoQCLib

@Suite("JSONFile")
struct JSONFileTests {
    private func folder() -> URL {
        FileManager.default.temporaryDirectory.appendingPathComponent("JSONFileTests-\(UUID().uuidString)", isDirectory: true)
    }

    @Test("Saves into a folder that doesn't exist yet and reads it back")
    func roundTrip() {
        let url = folder().appendingPathComponent("nested/state.json")
        #expect(JSONFile.save(["a": 1, "b": 2], to: url, log: .app))
        #expect(JSONFile.load([String: Int].self, from: url, log: .app) == ["a": 1, "b": 2])
        try? FileManager.default.removeItem(at: url.deletingLastPathComponent().deletingLastPathComponent())
    }

    @Test("A missing file is nil; a damaged one is nil too (and logged)")
    func missingAndDamaged() throws {
        let dir = folder()
        #expect(JSONFile.load([String].self, from: dir.appendingPathComponent("none.json"), log: .app) == nil)
        let bad = dir.appendingPathComponent("bad.json")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try Data("{not json".utf8).write(to: bad)
        #expect(JSONFile.load([String].self, from: bad, log: .app) == nil)
        JSONFile.remove(bad, log: .app)
        JSONFile.remove(bad, log: .app)   // already gone: fine
        #expect(!FileManager.default.fileExists(atPath: bad.path))
        try? FileManager.default.removeItem(at: dir)
    }

    @Test("attempt returns the value, or nil when the body throws")
    func attempt() {
        struct Boom: Error {}
        #expect(Log.app.attempt("ok") { 42 } == 42)
        #expect(Log.app.attempt("fails") { () throws -> Int in throw Boom() } == nil)
        #expect(Log.isCancellation(CancellationError()))
        #expect(Log.isCancellation(URLError(.cancelled)))
        #expect(!Log.isCancellation(Boom()))
    }
}
