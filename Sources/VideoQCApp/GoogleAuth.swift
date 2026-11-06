import AppKit
import AuthenticationServices
import CryptoKit
import Foundation

/// Google sign-in for the Delivery Plan (Sheets API). OAuth with PKCE and an iOS-type client (no secret; redirect to
/// the reversed client id), in the studio's Workspace project with an "Internal" consent screen: only studio accounts
/// can sign in, nothing to verify, refresh tokens don't expire after 7 days. Tokens live in
/// `Application Support/QCpie/Google/tokens.json` (0600), not the Keychain: the app is ad-hoc signed, so the Keychain
/// would ask after every update (as for Frame.io).
actor GoogleAuth {
    static let shared = GoogleAuth()

    static let scopes = "openid email https://www.googleapis.com/auth/spreadsheets"

    enum Failure: LocalizedError, Equatable {
        case notConfigured
        case signedOut
        case denied(String)

        var errorDescription: String? {
            switch self {
            case .notConfigured: return "Google sign-in isn't set up in this build of QCpie."
            case .signedOut: return "Sign in with Google (Delivery Plan ••• menu) to read and edit the sheet."
            case .denied(let reason): return reason.isEmpty ? "Google sign-in didn't finish." : "Google sign-in failed: \(reason)"
            }
        }
    }

    struct Tokens: Codable, Sendable {
        var access: String
        var refresh: String?
        var expires: Date
        var email: String?
    }

    nonisolated static var clientID: String { AppConfig.googleClientID }
    nonisolated static var isConfigured: Bool { !clientID.isEmpty }
    /// "1234-abc.apps.googleusercontent.com" → "com.googleusercontent.apps.1234-abc".
    nonisolated static var callbackScheme: String {
        clientID.split(separator: ".").reversed().joined(separator: ".")
    }
    nonisolated static var redirectURI: String { callbackScheme + ":/oauth2redirect" }

    private var tokens: Tokens?
    /// Bumped on sign-in and sign-out: a refresh that started before either is thrown away.
    private var generation = 0
    private var loaded = false
    private var refreshing: Task<Tokens, Error>?
    private let session: URLSession

    init(session: URLSession = .shared, tokens: Tokens? = nil) {
        self.session = session
        if let tokens { self.tokens = tokens; loaded = true }
    }

    private static var tokenFile: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("QCpie/Google/tokens.json")
    }

    var email: String? { load(); return tokens?.email }
    var isSignedIn: Bool { load(); return tokens != nil }

    // MARK: Sign-in

    nonisolated static func authorizeRequest() -> (url: URL, verifier: String) {
        let verifier = base64URL(Data((0..<32).map { _ in UInt8.random(in: .min ... .max) }))
        let challenge = base64URL(Data(SHA256.hash(data: Data(verifier.utf8))))
        var components = URLComponents(string: "https://accounts.google.com/o/oauth2/v2/auth")!
        components.queryItems = [
            .init(name: "client_id", value: clientID),
            .init(name: "redirect_uri", value: redirectURI),
            .init(name: "response_type", value: "code"),
            .init(name: "scope", value: scopes),
            .init(name: "code_challenge", value: challenge),
            .init(name: "code_challenge_method", value: "S256"),
            .init(name: "prompt", value: "select_account"),
        ]
        return (components.url!, verifier)
    }

    func completeSignIn(code: String, verifier: String) async throws {
        tokens = try await requestTokens([
            "grant_type": "authorization_code", "client_id": Self.clientID, "code": code,
            "code_verifier": verifier, "redirect_uri": Self.redirectURI,
        ], keeping: nil)
        loaded = true
        generation += 1
        save()
    }

    func signOut() {
        if let token = tokens?.refresh ?? tokens?.access {
            var request = URLRequest(url: URL(string: "https://oauth2.googleapis.com/revoke")!)
            request.httpMethod = "POST"
            request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
            request.httpBody = Data("token=\(Self.formEncode(token))".utf8)
            let session = session
            Task.detached { _ = try? await session.data(for: request) }
        }
        tokens = nil
        loaded = true
        generation += 1
        refreshing = nil
        try? FileManager.default.removeItem(at: Self.tokenFile)
    }

    // MARK: Tokens

    /// A valid access token, refreshed when it expires within a minute. Concurrent callers share one refresh.
    func accessToken(forceRefresh: Bool = false) async throws -> String {
        load()
        guard let current = tokens else { throw Self.isConfigured ? Failure.signedOut : Failure.notConfigured }
        if !forceRefresh, current.expires.timeIntervalSinceNow > 60 { return current.access }
        if let refreshing {
            do { return try await refreshing.value.access } catch Failure.denied { throw Failure.signedOut }
        }
        guard let refresh = current.refresh else {
            tokens = nil
            try? FileManager.default.removeItem(at: Self.tokenFile)
            throw Failure.signedOut
        }
        let started = generation
        let task = Task { try await self.requestTokens(["grant_type": "refresh_token", "client_id": Self.clientID, "refresh_token": refresh], keeping: current) }
        refreshing = task
        do {
            let fresh = try await task.value
            if refreshing == task { refreshing = nil }
            // Signed out or in again meanwhile: this refresh belongs to the old sign-in.
            guard generation == started else { throw Failure.signedOut }
            tokens = fresh
            save()
            return fresh.access
        } catch Failure.denied {
            if refreshing == task { refreshing = nil }
            // Revoked or expired refresh token: signed out (an offline Mac keeps its tokens: URL errors aren't `denied`).
            if generation == started {
                tokens = nil
                try? FileManager.default.removeItem(at: Self.tokenFile)
            }
            throw Failure.signedOut
        } catch {
            if refreshing == task { refreshing = nil }
            throw error
        }
    }

    private struct TokenResponse: Decodable {
        let access_token: String
        let expires_in: Double
        let refresh_token: String?
        let id_token: String?
    }

    private func requestTokens(_ form: [String: String], keeping old: Tokens?) async throws -> Tokens {
        var request = URLRequest(url: URL(string: "https://oauth2.googleapis.com/token")!)
        request.httpMethod = "POST"
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        request.httpBody = Data(form.map { "\($0.key)=\(Self.formEncode($0.value))" }.joined(separator: "&").utf8)
        let (data, response) = try await session.data(for: request)
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        // Google having a bad moment isn't a revoked sign-in: only 400/401 (invalid_grant…) signs out.
        if status != 200, status != 400, status != 401 { throw URLError(.badServerResponse) }
        guard status == 200, let decoded = try? JSONDecoder().decode(TokenResponse.self, from: data) else {
            let json = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
            throw Failure.denied((json?["error_description"] as? String) ?? (json?["error"] as? String) ?? "")
        }
        return Tokens(access: decoded.access_token, refresh: decoded.refresh_token ?? old?.refresh,
                      expires: Date().addingTimeInterval(decoded.expires_in),
                      email: decoded.id_token.flatMap(Self.email(fromIDToken:)) ?? old?.email)
    }

    /// The `email` claim of an id token (its signature needn't be checked: it came straight from Google over TLS).
    nonisolated static func email(fromIDToken token: String) -> String? {
        let parts = token.split(separator: ".")
        guard parts.count >= 2 else { return nil }
        var payload = parts[1].replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
        while payload.count % 4 != 0 { payload += "=" }
        guard let data = Data(base64Encoded: payload),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
        return json["email"] as? String
    }

    private func load() {
        guard !loaded else { return }
        loaded = true
        tokens = (try? Data(contentsOf: Self.tokenFile)).flatMap { try? JSONDecoder().decode(Tokens.self, from: $0) }
    }

    private func save() {
        guard let tokens, let data = try? JSONEncoder().encode(tokens) else { return }
        let file = Self.tokenFile
        try? FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? data.write(to: file, options: .atomic)
        try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: file.path)
    }

    private nonisolated static func formEncode(_ text: String) -> String {
        var allowed = CharacterSet.alphanumerics
        allowed.insert(charactersIn: "-._~")
        return text.addingPercentEncoding(withAllowedCharacters: allowed) ?? text
    }

    nonisolated static func base64URL(_ data: Data) -> String {
        data.base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }
}

/// Who is signed in, for the plan panels (published only on sign-in / sign-out).
@MainActor
final class GoogleAccount: ObservableObject {
    static let shared = GoogleAccount()
    @Published private(set) var email: String?
    @Published private(set) var signedIn = false
    @Published private(set) var signingIn = false

    private init() { Task { await refresh() } }

    func refresh() async {
        let auth = GoogleAuth.shared
        let (inNow, mail) = (await auth.isSignedIn, await auth.email)
        if inNow != signedIn { signedIn = inNow }
        if mail != email { email = mail }
    }

    /// Runs Google's sign-in page in a system web sheet. Throws only real failures (cancelling is silent).
    func signIn() async throws {
        guard GoogleAuth.isConfigured else { throw GoogleAuth.Failure.notConfigured }
        signingIn = true
        defer { signingIn = false }
        do {
            try await GoogleSignIn.run()
        } catch let error as ASWebAuthenticationSessionError where error.code == .canceledLogin {
            return
        }
        await refresh()
        DeliveryPlanStore.shared.signedIn()
    }

    func signOut() async {
        await GoogleAuth.shared.signOut()
        await refresh()
    }

    /// The token was refused (revoked, or the refresh token expired): show signed out.
    func noteSignedOut() { if signedIn { signedIn = false; email = nil } }
}

@MainActor
final class GoogleSignIn: NSObject, ASWebAuthenticationPresentationContextProviding {
    private static var current: GoogleSignIn?
    private var session: ASWebAuthenticationSession?

    static func run() async throws {
        let (url, verifier) = GoogleAuth.authorizeRequest()
        let flow = GoogleSignIn()
        current = flow
        defer { current = nil }
        let callback: URL = try await withCheckedThrowingContinuation { continuation in
            let handler: ASWebAuthenticationSession.CompletionHandler = { url, error in
                if let url { continuation.resume(returning: url) } else { continuation.resume(throwing: error ?? GoogleAuth.Failure.denied("")) }
            }
            let session: ASWebAuthenticationSession
            if #available(macOS 14.4, *) {
                session = ASWebAuthenticationSession(url: url, callback: .customScheme(GoogleAuth.callbackScheme), completionHandler: handler)
            } else {
                session = ASWebAuthenticationSession(url: url, callbackURLScheme: GoogleAuth.callbackScheme, completionHandler: handler)
            }
            session.presentationContextProvider = flow
            flow.session = session
            session.start()
        }
        let items = URLComponents(url: callback, resolvingAgainstBaseURL: false)?.queryItems ?? []
        guard let code = items.first(where: { $0.name == "code" })?.value else {
            throw GoogleAuth.Failure.denied(items.first(where: { $0.name == "error" })?.value ?? "")
        }
        try await GoogleAuth.shared.completeSignIn(code: code, verifier: verifier)
    }

    func presentationAnchor(for session: ASWebAuthenticationSession) -> ASPresentationAnchor {
        NSApp.keyWindow ?? NSApp.windows.first ?? ASPresentationAnchor()
    }
}
