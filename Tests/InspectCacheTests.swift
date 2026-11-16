import Foundation
import Testing
@testable import QCpie
@testable import VideoQCLib

// Clip details read in the background (prewarm, Media Info) are kept by path. A clip re-exported to the same path
// afterwards must be read again, not answered from the old export's details.
@Suite("Inspect details cache")
struct InspectCacheTests {
    @Test @MainActor
    func reExportAtTheSamePathIsReadAgain() async throws {
        let first = try await TestClips.ntscOn600TimeBase(SyntheticFrame(width: 64, height: 64), frames: 6)
        let folder = first.deletingLastPathComponent()
        defer { try? FileManager.default.removeItem(at: folder) }
        let state = SpecsState()
        let before = try #require(await state.details(for: first))
        // Unchanged: the same details come back without another read.
        #expect(await state.details(for: first)?.id == before.id)

        let second = try await TestClips.ntscOn600TimeBase(SyntheticFrame(width: 64, height: 64), frames: 30)
        defer { try? FileManager.default.removeItem(at: second.deletingLastPathComponent()) }
        _ = try FileManager.default.replaceItemAt(first, withItemAt: second)
        let after = try #require(await state.details(for: first))
        #expect(after.id != before.id)
        #expect(after.totalFrames > before.totalFrames)
    }
}
