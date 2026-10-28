import SwiftUI
import AppKit

/// Frame.io's service status from its public status page (status.frame.io, Atlassian Statuspage `api/v2/status.json`).
/// Checked while the badge is on screen, every 5 minutes; observed only by `FrameIOStatusBadge`.
@MainActor
final class FrameIOServiceStatus: ObservableObject {
    static let shared = FrameIOServiceStatus()

    enum Level: Equatable {
        case unknown, operational, minor, major, critical, maintenance
    }

    @Published private(set) var level: Level = .unknown
    /// Statuspage's own wording, e.g. "All Systems Operational" or "Partial System Outage".
    @Published private(set) var detail = "Checking Frame.io status…"
    @Published private(set) var checked: Date?

    static let page = URL(string: "https://status.frame.io")!
    private static let api = URL(string: "https://status.frame.io/api/v2/status.json")!
    private var watchers = 0
    private var poll: Task<Void, Never>?

    private init() {}

    /// The badge appeared: check now, then every 5 minutes while any badge is visible.
    func startWatching() {
        watchers += 1
        guard poll == nil else { return }
        poll = Task {
            while !Task.isCancelled {
                await refresh()
                try? await Task.sleep(for: .seconds(300))
            }
        }
    }

    func stopWatching() {
        watchers = max(0, watchers - 1)
        guard watchers == 0 else { return }
        poll?.cancel()
        poll = nil
    }

    /// status.frame.io sits behind a CDN that now and then doesn't answer a request at all (measured: one in four
    /// hung for 15 s, the next answered in 20 ms), so each check tries three times with a short timeout, and a failed
    /// check keeps the last answer until it's 15 minutes old.
    func refresh() async {
        let url = Self.api
        let result = await Task.detached(priority: .utility) { () -> (String, String)? in
            for attempt in 0..<3 {
                if attempt > 0 { try? await Task.sleep(for: .seconds(2)) }
                var request = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 6)
                request.setValue("application/json", forHTTPHeaderField: "Accept")
                guard let (data, response) = try? await URLSession.shared.data(for: request),
                      (response as? HTTPURLResponse)?.statusCode == 200,
                      let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                      let status = json["status"] as? [String: Any],
                      let indicator = status["indicator"] as? String else { continue }
                return (indicator, status["description"] as? String ?? "")
            }
            return nil
        }.value
        guard let (indicator, description) = result else {
            if checked.map({ -$0.timeIntervalSinceNow > 900 }) ?? true {
                level = .unknown
                detail = "Couldn't reach status.frame.io"
            }
            return
        }
        checked = Date()
        switch indicator {
        case "none": level = .operational
        case "minor": level = .minor
        case "major": level = .major
        case "critical": level = .critical
        case "maintenance": level = .maintenance
        default: level = .unknown
        }
        detail = description.isEmpty ? "Frame.io status: \(indicator)" : description
    }
}

/// A dot and a short word for Frame.io's status; hover for the details, click to open status.frame.io.
struct FrameIOStatusBadge: View {
    let isLightMode: Bool
    @ObservedObject private var status = FrameIOServiceStatus.shared
    @State private var isHovered = false

    private var palette: StudioPalette { StudioPalette(isLightMode) }

    private var color: Color {
        switch status.level {
        case .operational: return palette.positive
        case .minor: return Color(red: 0.95, green: 0.72, blue: 0.20)
        case .major: return Color(red: 0.96, green: 0.50, blue: 0.20)
        case .critical: return palette.negative
        case .maintenance: return palette.accentBlue
        case .unknown: return palette.textMuted
        }
    }

    private var label: String {
        switch status.level {
        case .operational: return "Operational"
        case .minor: return "Minor Issues"
        case .major: return "Major Outage"
        case .critical: return "Outage"
        case .maintenance: return "Maintenance"
        case .unknown: return "Status"
        }
    }

    private var help: String {
        let time = status.checked.map { " · checked \($0.formatted(date: .omitted, time: .shortened))" } ?? ""
        return "Frame.io: \(status.detail)\(time). Click to open status.frame.io."
    }

    var body: some View {
        Button(action: { NSWorkspace.shared.open(FrameIOServiceStatus.page) }) {
            HStack(spacing: 5) {
                Circle()
                    .fill(color)
                    .frame(width: StudioTheme.scale(7), height: StudioTheme.scale(7))
                    .shadow(color: status.level == .operational || status.level == .unknown ? .clear : color.opacity(0.6), radius: 3)
                Text(label)
                    .font(.ui(size: 11))
                    .foregroundColor(status.level == .operational || status.level == .unknown ? palette.textMuted : palette.textMain)
            }
            .padding(.horizontal, 7)
            .frame(height: StudioTheme.scale(24))
            .background(RoundedRectangle(cornerRadius: StudioTheme.cornerRadius).fill(isHovered ? palette.bgSubtle : .clear))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { isHovered = $0 }
        .help(help)
        .onAppear { status.startWatching() }
        .onDisappear { status.stopWatching() }
    }
}
