import Foundation
import Testing
@testable import QCpie

/// Records Delete's calls instead of making them: nothing reaches Frame.io.
private actor StubDeleteAPI: FrameIODeleteAPI {
    var calls: [String] = []
    var versions: [String: [FrameIO.Item]] = [:]
    var failing: Set<String> = []
    var signedOutAfter: Int?

    init(versions: [String: [FrameIO.Item]] = [:], failing: Set<String> = [], signedOutAfter: Int? = nil) {
        self.versions = versions
        self.failing = failing
        self.signedOutAfter = signedOutAfter
    }

    func delete(account: String, kind: String, id: String) async throws {
        if let limit = signedOutAfter, calls.count >= limit { throw FrameIO.Failure.signedOut }
        calls.append("DELETE \(account)/\(kind)/\(id)")
        if failing.contains(id) { throw FrameIO.Failure.http(403, "Not allowed") }
    }

    func stackVersions(account: String, stack: String, thumbnails: Bool) async throws -> [FrameIO.Item] {
        calls.append("GET \(account)/version_stacks/\(stack)/children")
        return versions[stack] ?? []
    }
}

private func item(_ id: String, _ type: String?, name: String? = nil) -> FrameIO.Item {
    let json: [String: Any?] = ["id": id, "type": type, "name": name ?? id]
    let data = try! JSONSerialization.data(withJSONObject: json.compactMapValues { $0 })
    return try! JSONDecoder().decode(FrameIO.Item.self, from: data)
}

@Suite("Frame.io Delete")
struct FrameIODeleteTests {
    @Test("Files and folders are deleted by id; a stack by deleting each of its versions")
    func calls() async {
        let api = StubDeleteAPI(versions: ["S1": [item("V2", "file"), item("V1", "file")]])
        let outcome = await FrameIODelete.run([item("F1", "file"), item("D1", "folder"), item("S1", "version_stack")],
                                              account: "A", api: api)
        #expect(await api.calls == [
            "DELETE A/files/F1",
            "DELETE A/folders/D1",
            "GET A/version_stacks/S1/children",
            "DELETE A/files/V2",
            "DELETE A/files/V1",
        ])
        #expect(outcome.deleted == ["F1", "D1", "S1"])
        #expect(outcome.failures.isEmpty)
    }

    @Test("Projects, workspaces and accounts are never deleted")
    func onlyAssets() async {
        let api = StubDeleteAPI()
        let outcome = await FrameIODelete.run([item("P1", nil), item("P2", "project"), item("F1", "file")], account: "A", api: api)
        #expect(await api.calls == ["DELETE A/files/F1"])
        #expect(outcome.deleted == ["F1"])
        #expect(!FrameIODelete.canDelete(item("P1", nil)))
    }

    @Test("A failed item is reported and the rest are still deleted")
    func partialFailure() async {
        let api = StubDeleteAPI(failing: ["F2"])
        let outcome = await FrameIODelete.run([item("F1", "file"), item("F2", "file", name: "Locked.mov"), item("F3", "file")],
                                              account: "A", api: api)
        #expect(outcome.deleted == ["F1", "F3"])
        #expect(outcome.failures.map(\.title) == ["Locked.mov"])
    }

    @Test("A stack whose version fails isn't counted as deleted")
    func stackFailure() async {
        let api = StubDeleteAPI(versions: ["S1": [item("V2", "file"), item("V1", "file")]], failing: ["V2"])
        let outcome = await FrameIODelete.run([item("S1", "version_stack")], account: "A", api: api)
        #expect(outcome.deleted.isEmpty)
        #expect(outcome.failures.count == 1)
    }

    @Test("Signing out stops the run")
    func signedOut() async {
        let api = StubDeleteAPI(signedOutAfter: 1)
        let outcome = await FrameIODelete.run([item("F1", "file"), item("F2", "file"), item("F3", "file")], account: "A", api: api)
        #expect(await api.calls == ["DELETE A/files/F1"])
        #expect(outcome.deleted == ["F1"])
        #expect(outcome.failures.count == 1)
    }

    @Test("A deleted Frame.io file is unlinked and leaves the name/size index")
    func forgetDeletedFile() async throws {
        let clip = FileManager.default.temporaryDirectory.appendingPathComponent("qcpie-forget-\(UUID().uuidString).mov")
        try Data(repeating: 1, count: 1234).write(to: clip)
        defer { try? FileManager.default.removeItem(at: clip) }
        let links = FrameIOLinks(directory: nil)
        await links.link(clip, account: "A", fileID: "F1")
        let listed = try JSONDecoder().decode(FrameIO.Item.self, from: JSONSerialization.data(withJSONObject: [
            "id": "F1", "type": "file", "name": clip.lastPathComponent, "file_size": 1234]))
        await links.remember([listed], account: "A")
        #expect(await links.link(for: clip)?.fileID == "F1")
        #expect(await links.indexed(clip)?.fileID == "F1")
        await links.forget(fileID: "F1")
        #expect(await links.link(for: clip) == nil)
        #expect(await links.indexed(clip) == nil)
    }

    @Test("The confirmation says what goes with folders and stacks")
    func summary() {
        let folder = FrameIODelete.summary([item("D1", "folder", name: "Selects")])
        #expect(folder.title == "Delete “Selects” from Frame.io?")
        #expect(folder.detail.contains("with everything in it"))
        let mixed = FrameIODelete.summary([item("F1", "file"), item("S1", "version_stack")])
        #expect(mixed.title == "Delete 2 items from Frame.io?")
        #expect(mixed.detail.contains("all their versions"))
        #expect(mixed.detail.contains("can't undo"))
    }
}
