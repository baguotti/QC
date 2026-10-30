import Foundation
import Testing
@testable import QCpie

@Suite("Frame.io link store: versions and sent notes")
struct FrameIOLinksStateTests {
    private func stack(_ id: String, head: String) throws -> FrameIO.Item {
        let json: [String: Any] = ["id": id, "type": "version_stack", "name": id, "head_version": ["id": head, "name": "\(head).mov"]]
        return try JSONDecoder().decode(FrameIO.Item.self, from: JSONSerialization.data(withJSONObject: json))
    }

    @Test("First sighting is recorded only; a new head is news; a head seen before or a linked file isn't")
    func heads() async throws {
        let links = FrameIOLinks(directory: nil)
        #expect(await links.updateHeads([try stack("S", head: "V1")]).isEmpty)
        #expect(await links.updateHeads([try stack("S", head: "V1")]).isEmpty)
        #expect(await links.updateHeads([try stack("S", head: "V2")]).map(\.head.id) == ["V2"])
        // V2 removed from the top: V1 is the head again, which isn't a new version.
        #expect(await links.updateHeads([try stack("S", head: "V1")]).isEmpty)
        #expect(await links.updateHeads([try stack("S", head: "V2")]).isEmpty)
        // A version this Mac uploaded (linked to a local clip) isn't news either.
        let clip = FileManager.default.temporaryDirectory.appendingPathComponent("heads-\(UUID().uuidString).mov")
        try Data(count: 10).write(to: clip)
        defer { try? FileManager.default.removeItem(at: clip) }
        await links.link(clip, account: "A", fileID: "V3")
        #expect(await links.updateHeads([try stack("S", head: "V3")]).isEmpty)
        #expect(await links.updateHeads([try stack("S", head: "V4")]).map(\.head.id) == ["V4"])
    }

    @Test("A sent note is on disk at once (a quit right after can't lose it and send it again)")
    func sentWrittenAtOnce() async throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("links-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: folder) }
        let note = UUID()
        await FrameIOLinks(directory: folder).markSent(note: note, comment: "C1", fileID: "F1")
        // A fresh store reads the file: no waiting for the coalesced save.
        #expect(await FrameIOLinks(directory: folder).sent("F1") == ["C1": note])
    }
}
