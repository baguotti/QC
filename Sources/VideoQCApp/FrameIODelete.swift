import Foundation

/// What Delete asks of Frame.io: the network calls, apart so tests use a stub (and never delete anything real).
protocol FrameIODeleteAPI: Sendable {
    func delete(account: String, kind: String, id: String) async throws
    func stackVersions(account: String, stack: String, thumbnails: Bool) async throws -> [FrameIO.Item]
}

extension FrameIO: FrameIODeleteAPI {}

/// Delete in the Frame.io browser: files and folders (a folder with everything in it) by id. The V4 API can't delete a
/// version stack, so a stack's versions are deleted one by one instead. Goes on after a failed item and reports it;
/// stops when signed out.
enum FrameIODelete {
    struct Outcome: Sendable {
        /// Ids of the items deleted (stacks once all their versions are).
        var deleted: Set<String> = []
        var failures: [(title: String, message: String)] = []
    }

    /// Only files, folders and stacks inside a folder or stack: never projects, workspaces or accounts.
    static func canDelete(_ item: FrameIO.Item) -> Bool {
        item.type == "file" || item.isFolder || item.isVersionStack
    }

    static func run(_ items: [FrameIO.Item], account: String, api: FrameIODeleteAPI) async -> Outcome {
        var outcome = Outcome()
        for item in items where canDelete(item) {
            do {
                if item.isVersionStack {
                    for version in try await api.stackVersions(account: account, stack: item.id, thumbnails: false) {
                        try await api.delete(account: account, kind: "files", id: version.id)
                    }
                } else {
                    try await api.delete(account: account, kind: item.isFolder ? "folders" : "files", id: item.id)
                }
                outcome.deleted.insert(item.id)
            } catch {
                outcome.failures.append((item.title, error.localizedDescription))
                if case FrameIO.Failure.signedOut = error { break }
            }
        }
        return outcome
    }

    /// The confirmation's text: what goes, and that QCpie can't bring it back.
    static func summary(_ items: [FrameIO.Item]) -> (title: String, detail: String) {
        let title = items.count == 1 ? "Delete “\(items[0].title)” from Frame.io?" : "Delete \(items.count) items from Frame.io?"
        var notes: [String] = []
        let folders = items.filter(\.isFolder).count, stacks = items.filter(\.isVersionStack).count
        if folders > 0 { notes.append(folders == 1 && items.count == 1 ? "The folder is deleted with everything in it." : "Folders are deleted with everything in them.") }
        if stacks > 0 { notes.append(stacks == 1 && items.count == 1 ? "Every version in the stack is deleted." : "Version stacks are deleted with all their versions.") }
        notes.append("QCpie can't undo this. Frame.io on the web may still let you restore them from Recently Deleted for a while.")
        return (title, notes.joined(separator: " "))
    }
}
