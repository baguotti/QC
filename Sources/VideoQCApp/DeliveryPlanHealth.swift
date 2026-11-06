import SwiftUI

// The plan's connection at a glance: one dot and a word by the plan's title ("Synced", "2 waiting", "Signed out",
// "View only"…), and a popover with each part (Google account, reading, writing, QCpie tab, outbox) and the action
// that fixes it. Built from what the store already tracks; published only when something in it changes.

struct PlanHealth: Equatable, Sendable {
    /// Edits not yet sent, and sent ones waiting for a read to confirm them.
    var waiting = 0
    var confirming = 0
    /// The last read's error (nil: the last read worked).
    var readError: String? = nil
    /// The last send's error, and whether it's being retried (offline, Google busy) or was refused for good.
    var writeError: String? = nil
    var retrying = false
    /// Whether this account can edit the sheet: nil until a write tells.
    var canWrite: Bool? = nil

    enum Level: Equatable { case good, busy, warning, problem }

    /// What the badge says, from the account and tab state the store doesn't own.
    func status(signedIn: Bool, hasQCTab: Bool) -> (level: Level, text: String) {
        if !signedIn { return (.problem, "Signed out") }
        if readError != nil { return (.problem, "Can't read") }
        if canWrite == false { return (.warning, "View only") }
        if !hasQCTab { return (.warning, waiting > 0 ? "\(waiting) waiting" : "No QCpie tab") }
        if retrying { return (.warning, "\(waiting) waiting") }
        if writeError != nil { return (.problem, "Not saved") }
        if waiting > 0 { return (.busy, "Saving \(waiting)") }
        return (.good, "Synced")
    }
}

/// The badge by the plan's title. Click: the details and what to do.
struct PlanHealthBadge: View {
    let isLightMode: Bool
    let signIn: () -> Void
    let setUpQCTab: () -> Void
    let chooseFrameIOFolder: () -> Void

    @ObservedObject private var store = DeliveryPlanStore.shared
    @ObservedObject private var account = GoogleAccount.shared
    @State private var showing = false

    private var palette: StudioPalette { StudioPalette(isLightMode) }

    private func color(_ level: PlanHealth.Level) -> Color {
        switch level {
        case .good: return palette.positive
        case .busy: return palette.accentBlue
        case .warning: return TagTone.amber.color(palette.isLight)
        case .problem: return palette.negative
        }
    }

    var body: some View {
        let status = store.health.status(signedIn: account.signedIn, hasQCTab: store.hasQCTab)
        Button { showing.toggle() } label: {
            HStack(spacing: 4) {
                Circle().fill(color(status.level)).frame(width: 6, height: 6)
                Text(status.text)
                    .font(.ui(size: 10, weight: .medium))
                    .monospacedDigit()
                    .foregroundColor(status.level == .good ? palette.textSubtle : palette.textMuted)
                    .lineLimit(1)
            }
            .padding(.horizontal, 5)
            .frame(height: StudioTheme.scaleFont(16))
            .background(RoundedRectangle(cornerRadius: Radius.segment).fill(showing ? palette.bgSubtle : Color.clear))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .fixedSize()
        .tip("The plan's connection to Google Sheets. Click for details.")
        .popover(isPresented: $showing, arrowEdge: .bottom) { details }
    }

    private var details: some View {
        let health = store.health
        return VStack(alignment: .leading, spacing: 10) {
            Text("Connection").font(.ui(size: 13, weight: .semibold)).foregroundColor(palette.textMain)
            row("Google", account.signedIn ? (account.email ?? "Signed in") : "Signed out",
                ok: account.signedIn, action: account.signedIn ? nil : ("Sign In…", signIn))
            row("Reading", health.readError ?? (store.lastUpdated.map { "Read \($0.formatted(.relative(presentation: .named)))" } ?? "Not read yet"),
                ok: health.readError == nil && store.lastUpdated != nil,
                action: ("Read Now", { Task { await store.refresh(full: true) } }))
            row("Writing", writingText(health), ok: health.canWrite != false && health.writeError == nil && !health.retrying,
                action: health.retrying || health.writeError != nil ? ("Try Again", { store.retrySending() }) : nil)
            row("QCpie tab", store.hasQCTab ? "In the sheet" : "Not set up: statuses and links wait on this Mac",
                ok: store.hasQCTab, action: store.hasQCTab || !account.signedIn ? nil : ("Set Up…", { showing = false; setUpQCTab() }))
            row("Frame.io", store.config?.frameioRoot.map { "\($0.title) · \(PlanFrameIORootSheet.scanText(store.rootScan))" }
                    ?? "No folder set: links and extras come from whatever is browsed",
                ok: store.config?.frameioRoot != nil && !{ if case .failed = store.rootScan { return true }; return false }(),
                action: ("Choose…", { showing = false; chooseFrameIOFolder() }))
            row("Waiting", health.waiting == 0 && health.confirming == 0 ? "Nothing waiting"
                : [health.waiting > 0 ? "\(health.waiting) to send" : nil, health.confirming > 0 ? "\(health.confirming) sent, confirming" : nil]
                    .compactMap { $0 }.joined(separator: " · "),
                ok: health.waiting == 0, action: nil)
        }
        .padding(16)
        .frame(width: 340)
        .background(palette.bgPanel)
    }

    private func writingText(_ health: PlanHealth) -> String {
        if health.canWrite == false { return "This Google account can view the sheet but not edit it." }
        if let error = health.writeError { return health.retrying ? "Retrying: \(error)" : error }
        return health.canWrite == true ? "Working" : "Nothing sent yet"
    }

    private func row(_ title: String, _ value: String, ok: Bool, action: (String, () -> Void)?) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Circle().fill(ok ? palette.positive : TagTone.amber.color(palette.isLight)).frame(width: 6, height: 6)
            Text(title).font(.ui(size: 11, weight: .medium)).foregroundColor(palette.textMuted)
                .frame(width: StudioTheme.scaleFont(70), alignment: .leading)
            Text(value).font(.ui(size: 11)).foregroundColor(palette.textMain).fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 4)
            if let action {
                Button(action.0, action: action.1).font(.ui(size: 11)).controlSize(.small)
            }
        }
    }
}
