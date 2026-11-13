import Foundation
import Testing
@testable import QCpie

/// The queue's folder tree: sibling folders stay siblings, also when a folder's row is hidden.
@MainActor @Suite struct QueueTreeTests {
    let root = URL(fileURLWithPath: "/Work/__PRESENTATION")
    var files: [URL] {
        ["KIKO_A_B/01_ENG/a.mov", "KL_MOCK_DELIVERY/BATCH 1/E01/KLP/b.mp4", "KL_MOCK_DELIVERY/BATCH 1/E01/c.mp4"]
            .map { root.appendingPathComponent($0) }
    }

    func rows(hidden: Set<String> = []) -> [(String, Int)] {
        FileSystemTreeBuilder.clearCache()
        let tree = FileSystemTreeBuilder.buildTree(rootURL: root, files: files)
        return FileSystemTreeBuilder.flatten(nodes: tree, collapsedIDs: [], hiddenIDs: hidden).map { ($0.name, $0.depth) }
    }

    @Test func siblingsAtTheTop() {
        let shown = rows()
        #expect(shown.first { $0.0 == "KIKO_A_B" }?.1 == 0)
        #expect(shown.first { $0.0 == "KL_MOCK_DELIVERY" }?.1 == 0)
        #expect(shown.first { $0.0 == "BATCH 1" }?.1 == 1)
    }

    @Test func hiddenFolderLiftsItsContents() {
        let hidden: Set<String> = [root.appendingPathComponent("KL_MOCK_DELIVERY").path,
                                   root.appendingPathComponent("KL_MOCK_DELIVERY/BATCH 1").path]
        let shown = rows(hidden: hidden)
        #expect(!shown.contains { $0.0 == "KL_MOCK_DELIVERY" || $0.0 == "BATCH 1" })
        #expect(shown.first { $0.0 == "E01" }?.1 == 0)
        #expect(shown.first { $0.0 == "KLP" }?.1 == 1)
        #expect(shown.first { $0.0 == "b.mp4" }?.1 == 2)
        #expect(shown.first { $0.0 == "c.mp4" }?.1 == 1)
    }
}
