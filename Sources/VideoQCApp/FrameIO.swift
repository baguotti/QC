import AppKit
import AuthenticationServices
import CryptoKit
import Foundation

/// Frame.io V4 API: Adobe IMS sign-in (Native App credential, PKCE, no client secret) and the REST calls the Upload tab
/// needs. All network and token work runs on this actor. Tokens live in `Application Support/QCpie/FrameIO/tokens.json`
/// (0600) rather than the Keychain: the app is ad-hoc signed, so every update would trigger a Keychain access prompt.
actor FrameIO {
    static let shared = FrameIO()

    static let clientID = "169057d214734335a278bcd16616fc35"
    static let callbackScheme = "adobe+cae510fd8e34b733dba42bcd7de8f503fc26f32d"
    static let redirectURI = "\(callbackScheme)://adobeid/\(clientID)"
    private static let scopes = "openid email profile offline_access additional_info.roles"
    private static let ims = "https://ims-na1.adobelogin.com/ims"
    private static let api = "https://api.frame.io"

    struct Tokens: Codable {
        var access: String
        var refresh: String?
        var expires: Date
    }

    /// Accounts, workspaces, projects, folders and files share this shape; fields a kind doesn't have stay nil.
    struct Item: Decodable, Identifiable, Hashable, Sendable {
        let id: String
        let name: String?
        let displayName: String?
        let email: String?
        let type: String?
        let fileSize: Int64?
        let rootFolderID: String?
        /// Link to the item in the Frame.io web app (folders and files).
        let viewURL: String?
        /// Version stacks: the current (top) version.
        let headVersion: Head?

        /// Small thumbnail (listings ask for `media_links.thumbnail`); the URL is signed and expires.
        let mediaLinks: MediaLinks?
        /// Projects: the icon set in Frame.io (nil when none was uploaded).
        let image: String?
        /// Projects: "active" or "inactive", storage used in bytes, and ISO 8601 timestamps (shown in the project list).
        let status: String?
        let storage: Int64?
        let createdAt: String?
        let updatedAt: String?
        /// Where it lives (opening a pasted link walks these up to the project).
        var parentID: String? = nil
        var projectID: String? = nil
        var workspaceID: String? = nil

        struct Head: Decodable, Hashable, Sendable {
            let id: String
            let name: String?
            let fileSize: Int64?
            let mediaLinks: MediaLinks?

            enum CodingKeys: String, CodingKey {
                case id, name
                case fileSize = "file_size"
                case mediaLinks = "media_links"
            }
        }

        struct MediaLinks: Decodable, Hashable, Sendable {
            let thumbnail: Link?
            let thumbnailHighQuality: Link?
            /// The original file (`include=media_links.original`): a pre-signed, time-limited download link.
            let original: Original?
            struct Link: Decodable, Hashable, Sendable { let url: String? }
            struct Original: Decodable, Hashable, Sendable {
                let downloadURL: String?
                enum CodingKeys: String, CodingKey { case downloadURL = "download_url" }
            }

            enum CodingKeys: String, CodingKey {
                case thumbnail, original
                case thumbnailHighQuality = "thumbnail_high_quality"
            }
        }

        enum CodingKeys: String, CodingKey {
            case id, name, email, type
            case displayName = "display_name"
            case fileSize = "file_size"
            case rootFolderID = "root_folder_id"
            case viewURL = "view_url"
            case headVersion = "head_version"
            case mediaLinks = "media_links"
            case image, status, storage
            case createdAt = "created_at"
            case updatedAt = "updated_at"
            case parentID = "parent_id"
            case projectID = "project_id"
            case workspaceID = "workspace_id"
        }

        var title: String { name ?? displayName ?? email ?? "Untitled" }
        var isFolder: Bool { type == "folder" }
        var isVersionStack: Bool { type == "version_stack" }
        /// Files: their size; version stacks: the current version's.
        var displaySize: Int64? { fileSize ?? headVersion?.fileSize }
        /// Files: their thumbnail; stacks: the current version's. Nil for folders and files still processing.
        var thumbnailURL: URL? { (mediaLinks?.thumbnail?.url ?? headVersion?.mediaLinks?.thumbnail?.url).flatMap(URL.init(string:)) }
        /// Sharper thumbnail for large rows (falls back to the small one).
        var largeThumbnailURL: URL? {
            (mediaLinks?.thumbnailHighQuality?.url ?? headVersion?.mediaLinks?.thumbnailHighQuality?.url).flatMap(URL.init(string:))
                ?? thumbnailURL
        }
        var projectImageURL: URL? { image.flatMap(URL.init(string:)) }
        var isInactive: Bool { status == "inactive" }
        var createdDate: Date? { Self.date(createdAt) }
        var updatedDate: Date? { Self.date(updatedAt) }

        private static func date(_ text: String?) -> Date? {
            guard let text else { return nil }
            return (try? Date(text, strategy: Date.ISO8601FormatStyle(includingFractionalSeconds: true)))
                ?? (try? Date(text, strategy: Date.ISO8601FormatStyle()))
        }
        /// Changes when the picture does (a stack's new current version).
        var thumbnailKey: String { headVersion?.id ?? id }

        func renamed(_ newName: String) -> Item {
            Item(id: id, name: newName, displayName: displayName, email: email, type: type, fileSize: fileSize,
                 rootFolderID: rootFolderID, viewURL: viewURL, headVersion: headVersion, mediaLinks: mediaLinks, image: image,
                 status: status, storage: storage, createdAt: createdAt, updatedAt: updatedAt,
                 parentID: parentID, projectID: projectID, workspaceID: workspaceID)
        }
    }

    enum Failure: LocalizedError {
        case signedOut
        case http(Int, String)
        case unreadable

        var errorDescription: String? {
            switch self {
            case .signedOut: return "Signed out of Frame.io."
            case .http(let code, let message): return "Frame.io error \(code)\(message.isEmpty ? "" : ": \(message)")"
            case .unreadable: return "Unexpected response from Frame.io."
            }
        }
    }

    /// A file placeholder created for a local upload: PUT each part to its pre-signed URL, in order.
    struct LocalUpload: Decodable, Sendable {
        let id: String
        let mediaType: String?
        let uploadURLs: [Part]

        struct Part: Decodable, Sendable {
            let size: Int64
            let url: String
        }

        enum CodingKeys: String, CodingKey {
            case id
            case mediaType = "media_type"
            case uploadURLs = "upload_urls"
        }
    }

    /// Whether Frame.io has the whole file (`GET …/files/{id}/status`).
    struct UploadStatus: Decodable, Sendable {
        let uploadComplete: Bool?
        let uploadFailed: Bool?

        enum CodingKeys: String, CodingKey {
            case uploadComplete = "upload_complete"
            case uploadFailed = "upload_failed"
        }
    }

    private struct One: Decodable { let data: Item }
    private struct Status: Decodable { let data: UploadStatus }
    private struct Created: Decodable { let data: LocalUpload }
    private struct Page: Decodable {
        let data: [Item]
        let links: Links?
        struct Links: Decodable { let next: String? }
    }

    private var tokens: Tokens?
    private var tokensLoaded = false
    private var refreshing: Task<Tokens, Error>?

    private static var tokenFile: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("QCpie/FrameIO/tokens.json")
    }

    var isSignedIn: Bool {
        loadTokens()
        return tokens != nil
    }

    // MARK: Sign-in

    /// The authorize URL plus the PKCE verifier to send with the code.
    nonisolated static func authorizeRequest() -> (url: URL, verifier: String) {
        let verifier = base64URL(Data((0..<32).map { _ in UInt8.random(in: .min ... .max) }))
        let challenge = base64URL(Data(SHA256.hash(data: Data(verifier.utf8))))
        var components = URLComponents(string: "\(ims)/authorize/v2")!
        components.queryItems = [
            .init(name: "client_id", value: clientID),
            .init(name: "scope", value: scopes),
            .init(name: "response_type", value: "code"),
            .init(name: "redirect_uri", value: redirectURI),
            .init(name: "code_challenge", value: challenge),
            .init(name: "code_challenge_method", value: "S256"),
        ]
        return (components.url!, verifier)
    }

    func completeSignIn(code: String, verifier: String) async throws {
        try await requestTokens([
            "grant_type": "authorization_code", "client_id": Self.clientID, "code": code, "code_verifier": verifier,
        ])
    }

    func signOut() {
        tokens = nil
        tokensLoaded = true
        try? FileManager.default.removeItem(at: Self.tokenFile)
    }

    // MARK: Browsing

    func me() async throws -> Item {
        try JSONDecoder().decode(One.self, from: await request("GET", "/v4/me")).data
    }

    func accounts() async throws -> [Item] { try await list("/v4/accounts") }

    func workspaces(account: String) async throws -> [Item] { try await list("/v4/accounts/\(account)/workspaces") }

    func projects(account: String, workspace: String) async throws -> [Item] {
        try await list("/v4/accounts/\(account)/workspaces/\(workspace)/projects")
    }

    /// A folder's contents. `thumbnails: false` for name/size checks (uploads, Move to): smaller responses.
    func children(account: String, folder: String, thumbnails: Bool = true) async throws -> [Item] {
        try await list("/v4/accounts/\(account)/folders/\(folder)/children", query: thumbnails ? Self.thumbnailQuery : nil)
    }

    private static let thumbnailQuery = "include=media_links.thumbnail,media_links.thumbnail_high_quality"

    func createFolder(account: String, parent: String, name: String) async throws -> Item {
        let body = try JSONSerialization.data(withJSONObject: ["data": ["name": name]])
        return try JSONDecoder().decode(One.self, from: await request("POST", "/v4/accounts/\(account)/folders/\(parent)/folders", body: body)).data
    }

    /// One project, folder, file or version stack by id (`kind`: "projects", "folders", "files", "version_stacks").
    func item(account: String, kind: String, id: String) async throws -> Item {
        try JSONDecoder().decode(One.self, from: await request("GET", "/v4/accounts/\(account)/\(kind)/\(id)")).data
    }

    /// Creates a project in a workspace (Frame.io sets up its root folder).
    func createProject(account: String, workspace: String, name: String) async throws -> Item {
        let body = try JSONSerialization.data(withJSONObject: ["data": ["name": name]])
        return try JSONDecoder().decode(One.self, from: await request("POST", "/v4/accounts/\(account)/workspaces/\(workspace)/projects", body: body)).data
    }

    func createLocalUpload(account: String, folder: String, name: String, size: Int64) async throws -> LocalUpload {
        let body = try JSONSerialization.data(withJSONObject: ["data": ["name": name, "file_size": size]])
        return try JSONDecoder().decode(Created.self, from: await request("POST", "/v4/accounts/\(account)/folders/\(folder)/files/local_upload", body: body)).data
    }

    /// Renames a folder or file. A version stack is named after its current version, so that file is renamed.
    func rename(account: String, item: Item, to name: String) async throws {
        let body = try JSONSerialization.data(withJSONObject: ["data": ["name": name]])
        if item.isVersionStack {
            guard let head = item.headVersion?.id else { throw Failure.http(0, "This stack has no current version to rename.") }
            _ = try await request("PATCH", "/v4/accounts/\(account)/files/\(head)", body: body)
            return
        }
        _ = try await request("PATCH", "/v4/accounts/\(account)/\(item.isFolder ? "folders" : "files")/\(item.id)", body: body)
    }

    /// Moves items into `parent`: folders and files in bulk (100 per call), version stacks one by one.
    func move(account: String, items: [Item], to parent: String) async throws {
        func bulk(_ kind: String, _ key: String, _ ids: [String]) async throws {
            for start in stride(from: 0, to: ids.count, by: 100) {
                let chunk = Array(ids[start..<min(start + 100, ids.count)])
                let body = try JSONSerialization.data(withJSONObject: ["data": [key: chunk, "parent_id": parent]])
                _ = try await request("PATCH", "/v4/accounts/\(account)/\(kind)/move", body: body)
            }
        }
        try await bulk("folders", "folder_ids", items.filter(\.isFolder).map(\.id))
        try await bulk("files", "file_ids", items.filter { !$0.isFolder && !$0.isVersionStack }.map(\.id))
        for stack in items where stack.isVersionStack {
            let body = try JSONSerialization.data(withJSONObject: ["data": ["parent_id": parent]])
            _ = try await request("PATCH", "/v4/accounts/\(account)/version_stacks/\(stack.id)/move", body: body)
        }
    }

    /// A review link (Frame.io "share") and the settings shown in Create Share Link.
    struct Share: Decodable, Sendable, Equatable, Identifiable {
        let id: String
        let name: String?
        let access: String
        let shortURL: String?
        let passphrase: String?
        let expiration: String?
        let enabled: Bool
        let commentingEnabled: Bool
        let downloadingEnabled: Bool
        let showAllAssetVersions: Bool?

        enum CodingKeys: String, CodingKey {
            case id, name, access, passphrase, expiration, enabled
            case shortURL = "short_url"
            case commentingEnabled = "commenting_enabled"
            case downloadingEnabled = "downloading_enabled"
            case showAllAssetVersions = "show_all_asset_versions"
        }

        var expirationDate: Date? {
            guard let expiration else { return nil }
            let formatter = ISO8601DateFormatter()
            formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
            return formatter.date(from: expiration) ?? ISO8601DateFormatter().date(from: expiration)
        }
    }

    private struct ShareEnvelope: Decodable { let data: Share }
    private struct SharePage: Decodable {
        let data: [Share]
        let links: Page.Links?
    }

    /// The project's share links, newest first.
    func shares(account: String, project: String) async throws -> [Share] {
        var shares: [Share] = []
        var next: String? = "/v4/accounts/\(account)/projects/\(project)/shares"
        while let current = next {
            let url = current + (current.contains("?") ? "&" : "?") + "sort=created_at_desc"
            let page = try JSONDecoder().decode(SharePage.self, from: await request("GET", url))
            shares += page.data
            next = page.links?.next
        }
        return shares
    }

    /// Adds files, folders or stacks to an existing share link (one call each; 10 calls/min).
    func addToShare(account: String, share: String, assetIDs: [String]) async throws {
        for asset in assetIDs {
            let body = try JSONSerialization.data(withJSONObject: ["data": ["asset_id": asset]])
            _ = try await request("POST", "/v4/accounts/\(account)/shares/\(share)/assets", body: body)
        }
    }

    /// Creates a public review link with Frame.io's defaults (view, comment, download) for files, folders or stacks.
    func createShare(account: String, project: String, name: String, assetIDs: [String]) async throws -> Share {
        let body = try JSONSerialization.data(withJSONObject: ["data": [
            "type": "asset", "name": name, "access": "public", "asset_ids": assetIDs,
            "downloading_enabled": true,
        ]])
        return try JSONDecoder().decode(ShareEnvelope.self, from: await request("POST", "/v4/accounts/\(account)/projects/\(project)/shares", body: body)).data
    }

    /// The body for `updateShare` (`NSNull()` clears a value such as the passphrase or expiration).
    nonisolated static func shareUpdate(_ fields: [String: Any]) throws -> Data {
        try JSONSerialization.data(withJSONObject: ["data": fields])
    }

    /// Changes share settings (body from `shareUpdate`). 10 calls/min: batch them.
    func updateShare(account: String, share: String, body: Data) async throws -> Share {
        return try JSONDecoder().decode(ShareEnvelope.self, from: await request("PATCH", "/v4/accounts/\(account)/shares/\(share)", body: body)).data
    }

    /// Invites people by email: on a secure share they become reviewers; on a public one they get the link by email.
    func inviteToShare(account: String, share: String, emails: [String], message: String, notify: Bool) async throws {
        let body = try JSONSerialization.data(withJSONObject: ["data": [
            "message": message, "reviewers": ["emails": emails], "notify_by_email": notify,
        ]])
        _ = try await request("POST", "/v4/accounts/\(account)/shares/\(share)/reviewers", body: body)
    }

    /// Copies items into `parent`, or next to themselves when nil (Duplicate). Folder copies may finish in the background.
    func copy(account: String, items: [Item], to parent: String?) async throws {
        for item in items {
            let kind = item.isFolder ? "folders" : (item.isVersionStack ? "version_stacks" : "files")
            let body = try JSONSerialization.data(withJSONObject: ["data": parent.map { ["parent_id": $0] } ?? [String: String]()])
            _ = try await request("POST", "/v4/accounts/\(account)/\(kind)/\(item.id)/copy", body: body)
        }
    }

    /// A version stack's versions, newest (current) first.
    func stackVersions(account: String, stack: String, thumbnails: Bool = true) async throws -> [Item] {
        try await list("/v4/accounts/\(account)/version_stacks/\(stack)/children", query: thumbnails ? Self.thumbnailQuery : nil)
    }

    /// Stacks 2–10 files of `folder` as versions: the first is the oldest, the last becomes the current version.
    func createStack(account: String, folder: String, fileIDs: [String]) async throws -> Item {
        let body = try JSONSerialization.data(withJSONObject: ["data": ["file_ids": fileIDs]])
        return try JSONDecoder().decode(One.self, from: await request("POST", "/v4/accounts/\(account)/folders/\(folder)/version_stacks", body: body)).data
    }

    /// Adds files to a version stack (each becomes the newest version).
    func addToStack(account: String, files: [Item], stack: String) async throws {
        for file in files {
            let body = try JSONSerialization.data(withJSONObject: ["data": ["parent_id": stack]])
            _ = try await request("PATCH", "/v4/accounts/\(account)/files/\(file.id)/move", body: body)
        }
    }

    /// A file's original download link (pre-signed and time-limited: ask again for each download or retry after a 403).
    /// Nil when Frame.io gives none (no download rights, or the file isn't finished).
    func originalDownloadURL(account: String, file: String) async throws -> URL? {
        let item = try JSONDecoder().decode(One.self, from: await request("GET", "/v4/accounts/\(account)/files/\(file)?include=media_links.original")).data
        return item.mediaLinks?.original?.downloadURL.flatMap(URL.init(string:))
    }

    func uploadStatus(account: String, id: String) async throws -> UploadStatus {
        try JSONDecoder().decode(Status.self, from: await request("GET", "/v4/accounts/\(account)/files/\(id)/status")).data
    }

    /// Removes a placeholder whose upload was cancelled or failed.
    func deleteFile(account: String, id: String) async throws {
        _ = try await request("DELETE", "/v4/accounts/\(account)/files/\(id)")
    }

    /// Every comment on a file, with replies and authors, and the timecode Frame.io shows for each (`timecode`, a
    /// second listing with `timestamp_as_timecode`: see `Comment`). 100 per page; comments allow 100 calls/min.
    func comments(account: String, file: String) async throws -> [Comment] {
        func all(_ query: String) async throws -> [Comment] {
            var comments: [Comment] = []
            var next: String? = "/v4/accounts/\(account)/files/\(file)/comments"
            while let current = next {
                let url = current.contains(query) ? current : current + (current.contains("?") ? "&" : "?") + query
                let page = try JSONDecoder().decode(CommentPage.self, from: await request("GET", url))
                comments += page.data
                next = page.links?.next
            }
            return comments
        }
        var comments = try await all("include=replies,owner&page_size=100")
        let timecodes = Dictionary((try await all("timestamp_as_timecode=true&page_size=100")).compactMap { comment in
            comment.timestampText.map { (comment.id, $0) }
        }, uniquingKeysWith: { a, _ in a })
        for index in comments.indices { comments[index].timecode = timecodes[comments[index].id] }
        return comments
    }

    private struct CommentPage: Decodable {
        let data: [Comment]
        let links: Links?
        struct Links: Decodable { let next: String? }
    }

    /// A comment on a file (`GET …/files/{id}/comments`). Frame.io keeps the time the player was paused at, which falls
    /// between frames: `timestamp` is that time *rounded* to a frame, while the timecode Frame.io shows (and returns
    /// with `timestamp_as_timecode`) is it rounded *down*, so the two differ by one whenever the pause was in a frame's
    /// second half (measured on real comments, 25 fps: 261 ↔ 00:00:10:11 = frame 261, 450 ↔ 00:00:17:24 = frame 449).
    /// Notes use the timecode, so they land where Frame.io's player shows the comment. Replies have the same shape
    /// without `owner`/`replies`.
    struct Comment: Decodable, Sendable, Equatable {
        let id: String
        let text: String
        let annotation: String?
        let timestamp: Int?
        /// `timestamp` when it came as text (the `timestamp_as_timecode` listing).
        let timestampText: String?
        /// The timecode Frame.io shows for the comment (from the second listing), e.g. "00:00:10:11".
        var timecode: String?
        let duration: Int?
        let completedAt: String?
        let createdAt: String?
        let textEditedAt: String?
        let owner: Owner?
        let replies: [Comment]?

        struct Owner: Decodable, Sendable, Equatable {
            let name: String?
            let email: String?
        }

        enum CodingKeys: String, CodingKey {
            case id, text, annotation, timestamp, duration, owner, replies
            case completedAt = "completed_at"
            case createdAt = "created_at"
            case textEditedAt = "text_edited_at"
        }

        init(id: String, text: String, annotation: String? = nil, timestamp: Int?, timecode: String? = nil, duration: Int? = nil,
             completedAt: String? = nil, createdAt: String? = nil, textEditedAt: String? = nil, owner: Owner? = nil,
             replies: [Comment]? = nil) {
            self.id = id
            self.text = text
            self.annotation = annotation
            self.timestamp = timestamp
            self.timestampText = nil
            self.timecode = timecode
            self.duration = duration
            self.completedAt = completedAt
            self.createdAt = createdAt
            self.textEditedAt = textEditedAt
            self.owner = owner
            self.replies = replies
        }

        /// `timestamp` comes as a number, or a string (timecode or digits): only a frame number is used.
        init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            id = try c.decode(String.self, forKey: .id)
            text = try c.decodeIfPresent(String.self, forKey: .text) ?? ""
            annotation = try? c.decodeIfPresent(String.self, forKey: .annotation)
            if let number = try? c.decodeIfPresent(Int.self, forKey: .timestamp) {
                timestamp = number
                timestampText = nil
            } else {
                timestampText = (try? c.decodeIfPresent(String.self, forKey: .timestamp)) ?? nil
                timestamp = timestampText.flatMap(Int.init)
            }
            timecode = nil
            duration = try? c.decodeIfPresent(Int.self, forKey: .duration)
            completedAt = try? c.decodeIfPresent(String.self, forKey: .completedAt)
            createdAt = try? c.decodeIfPresent(String.self, forKey: .createdAt)
            textEditedAt = try? c.decodeIfPresent(String.self, forKey: .textEditedAt)
            owner = try? c.decodeIfPresent(Owner.self, forKey: .owner)
            replies = try? c.decodeIfPresent([Comment].self, forKey: .replies)
        }
    }

    /// Every page of a list endpoint (`links.next` is a relative path carrying the cursor).
    /// Every page of a list endpoint. `links.next` carries only the cursor, so `query` is re-added to each page.
    private func list(_ path: String, query: String? = nil) async throws -> [Item] {
        func withQuery(_ url: String) -> String {
            guard let query, !url.contains(query) else { return url }
            return url + (url.contains("?") ? "&" : "?") + query
        }
        var items: [Item] = []
        var next: String? = path
        while let current = next {
            let page = try JSONDecoder().decode(Page.self, from: await request("GET", withQuery(current)))
            items += page.data
            next = page.links?.next
        }
        return items
    }

    // MARK: HTTP

    private func request(_ method: String, _ path: String, body: Data? = nil, attempt: Int = 0) async throws -> Data {
        guard let url = URL(string: path.hasPrefix("http") ? path : Self.api + path) else { throw Failure.unreadable }
        var req = URLRequest(url: url)
        req.httpMethod = method
        req.setValue("Bearer \(try await accessToken())", forHTTPHeaderField: "Authorization")
        if let body {
            req.httpBody = body
            req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        }
        let (data, response) = try await URLSession.shared.data(for: req)
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        switch status {
        case 200..<300:
            return data
        case 401 where attempt == 0:
            tokens?.expires = .distantPast
            return try await request(method, path, body: body, attempt: 1)
        case 429 where attempt < 4:
            // Creating uploads is limited to 5 calls/s per user.
            let wait = (response as? HTTPURLResponse)?.value(forHTTPHeaderField: "Retry-After").flatMap(Double.init) ?? Double(attempt + 1)
            try await Task.sleep(for: .seconds(min(wait, 10)))
            return try await request(method, path, body: body, attempt: attempt + 1)
        default:
            throw Failure.http(status, Self.message(in: data))
        }
    }

    private func accessToken() async throws -> String {
        loadTokens()
        guard let current = tokens else { throw Failure.signedOut }
        if current.expires.timeIntervalSinceNow > 60 { return current.access }
        guard let refresh = current.refresh else { signOut(); throw Failure.signedOut }
        if let refreshing { return try await refreshing.value.access }
        let task = Task { try await self.refreshTokens(refresh) }
        refreshing = task
        defer { refreshing = nil }
        do {
            return try await task.value.access
        } catch Failure.http(let code, _) where (400..<500).contains(code) {
            signOut()
            throw Failure.signedOut
        }
    }

    private func refreshTokens(_ refresh: String) async throws -> Tokens {
        try await requestTokens(["grant_type": "refresh_token", "client_id": Self.clientID, "refresh_token": refresh])
    }

    @discardableResult
    private func requestTokens(_ form: [String: String]) async throws -> Tokens {
        var req = URLRequest(url: URL(string: "\(Self.ims)/token/v3")!)
        req.httpMethod = "POST"
        req.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        var body = URLComponents()
        body.queryItems = form.map { URLQueryItem(name: $0.key, value: $0.value) }
        req.httpBody = Data((body.percentEncodedQuery ?? "").replacingOccurrences(of: "+", with: "%2B").utf8)
        let (data, response) = try await URLSession.shared.data(for: req)
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard status == 200,
              let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let access = json["access_token"] as? String else {
            throw Failure.http(status, Self.message(in: data))
        }
        let lifetime = (json["expires_in"] as? NSNumber)?.doubleValue ?? 3600
        let new = Tokens(access: access, refresh: json["refresh_token"] as? String ?? tokens?.refresh,
                         expires: Date().addingTimeInterval(lifetime > 100_000 ? lifetime / 1000 : lifetime))
        tokens = new
        saveTokens()
        return new
    }

    private func loadTokens() {
        guard !tokensLoaded else { return }
        tokensLoaded = true
        tokens = (try? Data(contentsOf: Self.tokenFile)).flatMap { try? JSONDecoder().decode(Tokens.self, from: $0) }
    }

    private func saveTokens() {
        guard let tokens, let data = try? JSONEncoder().encode(tokens) else { return }
        let file = Self.tokenFile
        try? FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? data.write(to: file, options: .atomic)
        try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: file.path)
    }

    private static func message(in data: Data) -> String {
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return String(data: data.prefix(200), encoding: .utf8) ?? ""
        }
        if let errors = json["errors"] as? [[String: Any]], let first = errors.first {
            return (first["detail"] as? String) ?? (first["title"] as? String) ?? ""
        }
        return (json["error_description"] as? String) ?? (json["message"] as? String) ?? (json["error"] as? String) ?? ""
    }

    private nonisolated static func base64URL(_ data: Data) -> String {
        data.base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }
}

/// Runs the Adobe sign-in page in a system web sheet and hands the code to `FrameIO`.
@MainActor
final class FrameIOSignIn: NSObject, ASWebAuthenticationPresentationContextProviding {
    private static var current: FrameIOSignIn?
    private var session: ASWebAuthenticationSession?

    static func run() async throws {
        let (url, verifier) = FrameIO.authorizeRequest()
        let flow = FrameIOSignIn()
        current = flow
        defer { current = nil }
        let callback: URL = try await withCheckedThrowingContinuation { continuation in
            let handler: ASWebAuthenticationSession.CompletionHandler = { url, error in
                if let url { continuation.resume(returning: url) } else { continuation.resume(throwing: error ?? FrameIO.Failure.unreadable) }
            }
            let session: ASWebAuthenticationSession
            if #available(macOS 14.4, *) {
                session = ASWebAuthenticationSession(url: url, callback: .customScheme(FrameIO.callbackScheme), completionHandler: handler)
            } else {
                session = ASWebAuthenticationSession(url: url, callbackURLScheme: FrameIO.callbackScheme, completionHandler: handler)
            }
            session.presentationContextProvider = flow
            flow.session = session
            session.start()
        }
        let items = URLComponents(url: callback, resolvingAgainstBaseURL: false)?.queryItems ?? []
        guard let code = items.first(where: { $0.name == "code" })?.value else {
            let reason = items.first(where: { $0.name == "error_description" || $0.name == "error" })?.value ?? ""
            throw FrameIO.Failure.http(0, reason)
        }
        try await FrameIO.shared.completeSignIn(code: code, verifier: verifier)
    }

    func presentationAnchor(for session: ASWebAuthenticationSession) -> ASPresentationAnchor {
        NSApp.keyWindow ?? NSApp.windows.first ?? ASPresentationAnchor()
    }
}
