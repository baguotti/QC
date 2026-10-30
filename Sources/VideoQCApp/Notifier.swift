import AppKit
import AVFoundation
@preconcurrency import UserNotifications

/// What QCpie can notify about. Each has its own switch in User Settings → Notifications, under the master switch.
enum NotificationKind: String, CaseIterable, Sendable {
    case uploads, downloads, scans, comments, versions

    var label: String {
        switch self {
        case .uploads: return "Upload finished"
        case .downloads: return "Download finished"
        case .scans: return "Scan finished"
        case .comments: return "New comments, replies and mentions"
        case .versions: return "New versions in Frame.io favourites"
        }
    }

    var help: String {
        switch self {
        case .uploads: return "When an upload to Frame.io ends: how many files went, and any that failed."
        case .downloads: return "When the Frame.io downloads end: how many files arrived, and any that failed."
        case .scans: return "When a Line Check, Frame Check or Full Check ends: how many clips were flagged."
        case .comments: return "Frame.io comments and replies on the clip open in the Player (checked every minute), and when someone @mentions you."
        case .versions: return "A new version stacked on a file in your Frame.io favourites (checked every 30 minutes)."
        }
    }

    /// Where clicking the notification takes you.
    var tab: AppTab {
        switch self {
        case .uploads, .downloads, .versions: return .upload
        case .scans: return .lineFinder
        case .comments: return .player
        }
    }
}

/// Notification wording, apart so it's tested and stays in the app's voice: a plain title saying what happened, the
/// place as subtitle, the specifics in the body. Sentence case, no exclamation marks.
enum NotificationText {
    struct Message: Equatable, Sendable {
        let title: String
        let subtitle: String
        let body: String
    }

    static func upload(uploaded: Int, skipped: Int, failed: Int, destination: String) -> Message {
        var parts = ["\(count(uploaded, "file")) uploaded"]
        if skipped > 0 { parts.append("\(skipped) already there") }
        if failed > 0 { parts.append("\(failed) failed") }
        return Message(title: failed > 0 ? "Upload finished with errors" : "Upload finished", subtitle: destination,
                       body: parts.joined(separator: " · "))
    }

    static func download(downloaded: Int, failed: Int, destination: String) -> Message {
        var parts = ["\(count(downloaded, "file")) downloaded"]
        if failed > 0 { parts.append("\(failed) failed") }
        return Message(title: failed > 0 ? "Download finished with errors" : "Download finished", subtitle: destination,
                       body: parts.joined(separator: " · "))
    }

    /// `check`: "Line Check", "Frame Check" or "Full Check".
    static func scan(check: String, flagged: Int, total: Int) -> Message {
        Message(title: "\(check) finished", subtitle: count(total, "clip"),
                body: flagged == 0 ? "No issues found" : "\(flagged) of \(count(total, "clip")) flagged")
    }

    struct Remark: Equatable, Sendable {
        let author: String
        let text: String
    }

    /// New comments and replies on a clip. A remark that @mentions `me` leads, titled as a mention.
    static func comments(clip: String, comments: [Remark], replies: [Remark], me: String?) -> Message? {
        let all = comments + replies
        guard let first = all.first else { return nil }
        let mention = me.flatMap { name in
            all.first { $0.text.range(of: "@\(name)", options: .caseInsensitive) != nil }
        }
        let lead = mention ?? first
        let title: String
        if let mention {
            title = "\(mention.author) mentioned you"
        } else if replies.isEmpty {
            title = comments.count == 1 ? "New comment from \(first.author)" : "\(comments.count) new comments"
        } else if comments.isEmpty {
            title = replies.count == 1 ? "\(first.author) replied" : "\(replies.count) new replies"
        } else {
            title = "\(comments.count + replies.count) new comments and replies"
        }
        let quote = lead.text.trimmingCharacters(in: .whitespacesAndNewlines).replacingOccurrences(of: "\n", with: " ")
        return Message(title: title, subtitle: clip, body: all.count > 1 || mention != nil ? "\(lead.author): \(quote)" : quote)
    }

    /// New versions found in one pass of the favourites: one names it, several are counted.
    static func versions(_ found: [(stack: String, file: String)]) -> Message? {
        guard let first = found.first else { return nil }
        if found.count == 1 { return Message(title: "New version on Frame.io", subtitle: first.stack, body: first.file) }
        return Message(title: "\(found.count) new versions on Frame.io", subtitle: "In your favourites",
                       body: found.prefix(3).map(\.stack).joined(separator: ", ") + (found.count > 3 ? " and more" : ""))
    }

    private static func count(_ value: Int, _ noun: String) -> String { "\(value) \(noun)\(value == 1 ? "" : "s")" }
}

/// Posts macOS notifications (User Settings → Notifications). Quiet by design: no sound, grouped by kind, shown only
/// while QCpie isn't the front app (it shows its own status when it is) unless the user asks for them anyway. macOS
/// asks permission the first time one is posted (or when the master switch is turned on). Clicking one brings QCpie
/// forward on the tab it's about. Needs the app bundle: a bare debug binary posts nothing.
@MainActor
final class Notifier: NSObject, ObservableObject, UNUserNotificationCenterDelegate {
    static let shared = Notifier()

    static let enabledKey = "notificationsEnabled"
    static let whileActiveKey = "notificationsWhileActive"
    static func key(_ kind: NotificationKind) -> String { "notify.\(kind.rawValue)" }
    /// Posted with an `AppTab` when a notification is clicked.
    static let openTab = Notification.Name("QCpieNotificationOpenTab")

    /// Defaults: everything on (macOS still asks before the first one shows).
    static var registeredDefaults: [String: Any] {
        var defaults: [String: Any] = [enabledKey: true, whileActiveKey: false]
        for kind in NotificationKind.allCases { defaults[key(kind)] = true }
        return defaults
    }

    /// macOS's answer for QCpie (nil until read), for the settings pane.
    @Published private(set) var authorization: UNAuthorizationStatus?
    /// Why the last example couldn't be shown (macOS refused it), for the settings pane.
    @Published private(set) var problem: String?

    /// Frame.io files QCpie uploaded this session: a stack whose new head is one isn't news to this user.
    private(set) var ownUploads: Set<String> = []

    private var center: UNUserNotificationCenter? {
        Bundle.main.bundleURL.pathExtension == "app" && Bundle.main.bundleIdentifier != nil ? .current() : nil
    }

    func start() {
        center?.delegate = self
        refreshAuthorization()
    }

    func isOn(_ kind: NotificationKind) -> Bool {
        let defaults = UserDefaults.standard
        return defaults.bool(forKey: Self.enabledKey) && defaults.bool(forKey: Self.key(kind))
    }

    /// Whether a notification of this kind would show now (switched on, and QCpie not in front unless asked): checked
    /// before preparing anything costly for one (a still).
    func wouldShow(_ kind: NotificationKind) -> Bool {
        center != nil && isOn(kind) && (!NSApp.isActive || UserDefaults.standard.bool(forKey: Self.whileActiveKey))
    }

    func noteOwnUpload(_ fileID: String) { ownUploads.insert(fileID) }

    func refreshAuthorization() {
        guard let center else { return }
        Task {
            let status = await center.notificationSettings().authorizationStatus
            authorization = status
        }
    }

    /// Asks macOS for permission (once: later calls return its answer).
    func requestAuthorization() async {
        guard let center else { return }
        do {
            _ = try await center.requestAuthorization(options: [.alert])
        } catch {
            // e.g. a debug copy whose signature doesn't match the bundle: macOS won't register it.
            problem = "macOS refused: \(error.localizedDescription)"
        }
        authorization = await center.notificationSettings().authorizationStatus
    }

    /// Posts unless switched off, or QCpie is in front (and the user didn't ask for those too). `image`: a still shown
    /// with it (the file is moved into the notification).
    func post(_ kind: NotificationKind, _ message: NotificationText.Message, image: URL? = nil) {
        guard let center, wouldShow(kind) else {
            if let image { try? FileManager.default.removeItem(at: image) }
            return
        }
        let content = UNMutableNotificationContent()
        content.title = message.title
        content.subtitle = message.subtitle
        content.body = message.body
        content.threadIdentifier = kind.rawValue
        content.userInfo = ["tab": kind.tab.rawValue]
        content.interruptionLevel = .active
        if let image {
            // The attachment moves the file into Notification Center's store; if it can't, drop it.
            if let attachment = try? UNNotificationAttachment(identifier: "still", url: image) {
                content.attachments = [attachment]
            } else {
                try? FileManager.default.removeItem(at: image)
            }
        }
        Task {
            if await center.notificationSettings().authorizationStatus == .notDetermined { await requestAuthorization() }
            try? await center.add(UNNotificationRequest(identifier: UUID().uuidString, content: content, trigger: nil))
        }
    }

    /// Settings → Notifications → Show Example: posts one even with QCpie in front.
    func sendExample() {
        guard let center else {
            problem = "Notifications need QCpie running as an app (this is a bare binary)."
            return
        }
        problem = nil
        let message = NotificationText.upload(uploaded: 12, skipped: 0, failed: 0, destination: "Project › Selects")
        let content = UNMutableNotificationContent()
        content.title = message.title
        content.subtitle = message.subtitle
        content.body = message.body
        content.threadIdentifier = "example"
        Task {
            await requestAuthorization()
            if authorization == .denied { return }
            do {
                try await center.add(UNNotificationRequest(identifier: UUID().uuidString, content: content, trigger: nil))
            } catch {
                problem = "macOS didn't show it: \(error.localizedDescription)"
            }
        }
    }

    /// A small still of a clip at a frame, written where a notification can take it. Nil if the clip can't be read.
    nonisolated static func still(of url: URL, frame: Int, fps: Double) async -> URL? {
        let generator = AVAssetImageGenerator(asset: AVURLAsset(url: url))
        generator.appliesPreferredTrackTransform = true
        generator.maximumSize = CGSize(width: 480, height: 480)
        let time = CMTime(seconds: Double(frame) / max(fps, 1), preferredTimescale: 600)
        guard let image = try? await generator.image(at: time).image else { return nil }
        let rep = NSBitmapImageRep(cgImage: image)
        guard let data = rep.representation(using: .jpeg, properties: [.compressionFactor: 0.8]) else { return nil }
        let file = FileManager.default.temporaryDirectory.appendingPathComponent("qcpie-notification-\(UUID().uuidString).jpg")
        return (try? data.write(to: file)) == nil ? nil : file
    }

    // MARK: UNUserNotificationCenterDelegate

    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter, willPresent notification: UNNotification)
        async -> UNNotificationPresentationOptions {
        [.banner, .list]
    }

    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter, didReceive response: UNNotificationResponse) async {
        let tab = (response.notification.request.content.userInfo["tab"] as? Int).flatMap(AppTab.init(rawValue:))
        await MainActor.run {
            NSApp.activate()
            if let tab { NotificationCenter.default.post(name: Self.openTab, object: tab) }
        }
    }
}
