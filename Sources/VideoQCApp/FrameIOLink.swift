import Foundation

/// A Frame.io web link pasted into the Upload tab (⌘V, the filter field or Open Link), resolved to a place in the
/// browser. Links look like (from the API's `view_url`s):
/// - project: `https://next.frame.io/project/{project}`
/// - folder: `https://next.frame.io/project/{project}/{folder}`
/// - file or version stack: `https://next.frame.io/project/{project}/view/{id}`
/// `f.io` short links are followed to where they redirect first.
struct FrameIOLink: Equatable, Sendable {
    let project: String
    var folder: String?
    /// A file or version stack to select.
    var asset: String?

    enum Failure: LocalizedError, Equatable {
        case notALink, shareLink, legacyLink, notFound

        var errorDescription: String? {
            switch self {
            case .notALink: return "That isn't a Frame.io link."
            case .shareLink: return "That's a share (review) link: it can't be opened as a place in your account. Ask for the project link instead."
            case .legacyLink: return "That's a link from the old Frame.io (app.frame.io), which QCpie can't open."
            case .notFound: return "Couldn't find that in your Frame.io accounts (no access, or it was deleted)."
            }
        }
    }

    /// Whether `text` looks like a Frame.io link (cheap: for deciding whether ⌘V or the filter field should act).
    static func looksLikeLink(_ text: String) -> Bool {
        guard let host = URL(string: text.trimmingCharacters(in: .whitespacesAndNewlines))?.host?.lowercased() else { return false }
        return host == "f.io" || host == "frame.io" || host.hasSuffix(".frame.io")
    }

    /// The project, folder and file a web link points to. Throws `shareLink` / `legacyLink` / `notALink` for others.
    static func parse(_ text: String) throws -> FrameIOLink {
        guard let url = URL(string: text.trimmingCharacters(in: .whitespacesAndNewlines)), let host = url.host?.lowercased(),
              host == "frame.io" || host.hasSuffix(".frame.io") else { throw Failure.notALink }
        let parts = url.pathComponents.filter { $0 != "/" }
        if parts.first == "share" || parts.first == "reviews" || parts.first == "presentations" { throw Failure.shareLink }
        if host == "app.frame.io" { throw Failure.legacyLink }
        guard let index = parts.firstIndex(of: "project"), parts.count > index + 1 else { throw Failure.notALink }
        var link = FrameIOLink(project: parts[index + 1])
        let rest = Array(parts.dropFirst(index + 2))
        if rest.first == "view", rest.count > 1 {
            link.asset = rest[1]
        } else if let folder = rest.first {
            link.folder = folder
        }
        return link
    }

    /// Follows an `f.io` short link to the page it redirects to.
    static func expand(_ text: String) async -> String {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let url = URL(string: trimmed), url.host?.lowercased() == "f.io" else { return trimmed }
        var request = URLRequest(url: url, timeoutInterval: 10)
        request.httpMethod = "HEAD"
        guard let (_, response) = try? await URLSession.shared.data(for: request), let final = response.url else { return trimmed }
        return final.absoluteString
    }

    /// The browser path to the link's place (account → workspace → project → folders [→ stack]) and the item to
    /// select there. Tries the open account first, then the others.
    static func resolve(_ link: FrameIOLink, preferredAccount: String?) async throws -> (path: [FrameIOBrowser.Crumb], select: String?) {
        let api = FrameIO.shared
        var accounts = try await api.accounts()
        if let preferred = accounts.firstIndex(where: { $0.id == preferredAccount }) { accounts.insert(accounts.remove(at: preferred), at: 0) }
        for account in accounts {
            guard let project = try? await api.item(account: account.id, kind: "projects", id: link.project),
                  let workspaceID = project.workspaceID, let root = project.rootFolderID else { continue }
            let workspaces = (try? await api.workspaces(account: account.id)) ?? []
            let workspaceTitle = workspaces.first { $0.id == workspaceID }?.title ?? "Workspace"
            var path: [FrameIOBrowser.Crumb] = [
                .init(level: .account, id: account.id, title: account.title, folderID: nil),
                .init(level: .workspace, id: workspaceID, title: workspaceTitle, folderID: nil),
                .init(level: .project, id: project.id, title: project.title, folderID: root),
            ]
            var select: String?
            var folder = link.folder
            if let asset = link.asset {
                // A file (inside a folder or a stack), or a stack.
                if let file = try? await api.item(account: account.id, kind: "files", id: asset), let parent = file.parentID {
                    select = file.id
                    if let stack = try? await api.item(account: account.id, kind: "version_stacks", id: parent) {
                        select = stack.id   // show the stack in its folder; its versions are one double-click away
                        folder = stack.parentID
                    } else {
                        folder = parent
                    }
                } else if let stack = try? await api.item(account: account.id, kind: "version_stacks", id: asset) {
                    select = stack.id
                    folder = stack.parentID
                } else {
                    throw Failure.notFound
                }
            }
            if let folder, folder != root {
                path += try await folderCrumbs(folder, root: root, account: account.id)
            }
            return (path, select)
        }
        throw Failure.notFound
    }

    /// The folders from the project's root down to `folder` (walking `parent_id` up; at most 64 levels).
    private static func folderCrumbs(_ folder: String, root: String, account: String) async throws -> [FrameIOBrowser.Crumb] {
        var crumbs: [FrameIOBrowser.Crumb] = []
        var current: String? = folder
        while let id = current, id != root, crumbs.count < 64 {
            let item = try await FrameIO.shared.item(account: account, kind: "folders", id: id)
            crumbs.insert(.init(level: .folder, id: item.id, title: item.title, folderID: nil), at: 0)
            current = item.parentID
        }
        return crumbs
    }
}
