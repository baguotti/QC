import SwiftUI
import AppKit

/// Checking, downloading and installing QCpie updates (GitHub releases): one rounded card in the style of the Upload tab
/// and macOS's own update prompts — the app icon, a title and one line of detail, then the actions at the bottom right.
struct UpdateModalView: View {
    @ObservedObject var updateManager: UpdateManager
    @Binding var isPresented: Bool
    @AppStorage("isLightMode") private var isLightMode: Bool = false

    private var palette: StudioPalette { StudioPalette(isLightMode) }

    var body: some View {
        ZStack {
            Color.black.opacity(isPresented ? 0.45 : 0.0)
                .edgesIgnoringSafeArea(.all)
                .allowsHitTesting(isPresented)
                .onTapGesture { if !isBusy { dismissModal() } }

            VStack(alignment: .leading, spacing: 0) {
                content
            }
            .padding(22)
            .frame(width: 440, alignment: .leading)
            .background(RoundedRectangle(cornerRadius: 14, style: .continuous).fill(palette.bgPanel))
            .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).stroke(palette.borderLine.opacity(0.8), lineWidth: 0.5))
            .overlay(alignment: .topTrailing) {
                if !isBusy { closeButton.padding(10) }
            }
            .shadow(color: Color.black.opacity(0.35), radius: 30, x: 0, y: 14)
        }
        .allowsHitTesting(isPresented)
    }

    @ViewBuilder
    private var content: some View {
        switch updateManager.state {
        case .idle, .checking:
            header(title: "Checking for Updates…", detail: "Looking for a newer QCpie on GitHub.") {
                ProgressView().controlSize(.small)
            }
        case .upToDate:
            header(title: "QCpie is up to date", detail: "Version \(AppVersionInfo.version) is the latest.", badge: .upToDate)
            actions { primaryButton("OK") { dismissModal() } }
        case .updateAvailable(let version, let dmgURL, _):
            header(title: "QCpie \(version) is available", detail: "You have \(AppVersionInfo.version).", badge: .available)
            Text(dmgURL != nil
                 ? "Update and Restart downloads it, replaces QCpie in Applications and opens the new version."
                 : "This release has no disk image attached. Open it on GitHub to download it.")
                .font(.ui(size: 11))
                .foregroundColor(palette.textMuted)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.top, 14)
            actions(leading: {
                if dmgURL != nil {
                    linkButton("Download Disk Image") { updateManager.downloadDMGManually() }
                }
            }) {
                secondaryButton("Later") { dismissModal() }
                if dmgURL != nil {
                    primaryButton("Update and Restart") { updateManager.startOneClickUpdate() }
                } else {
                    primaryButton("View on GitHub") { if let url = updateManager.remoteWebURL { NSWorkspace.shared.open(url) } }
                }
            }
        case .downloading(let progress, let written, let total):
            header(title: "Downloading QCpie \(updateManager.latestVersion)",
                   detail: total > 0 ? "\(formatBytes(written)) of \(formatBytes(total))" : formatBytes(written))
            progressBar(progress)
                .padding(.top, 16)
            actions(leading: {
                Text("\(Int(progress * 100))%")
                    .font(.ui(size: 11, weight: .semibold))
                    .foregroundColor(palette.textMuted)
                    .monospacedDigit()
            }) {
                secondaryButton("Cancel") { updateManager.cancelDownload() }
            }
        case .installing(let status):
            header(title: "Installing QCpie \(updateManager.latestVersion)",
                   detail: status.isEmpty ? "Preparing the new version…" : status) {
                ProgressView().controlSize(.small)
            }
            Text("QCpie closes and opens again in a moment.")
                .font(.ui(size: 11))
                .foregroundColor(palette.textMuted)
                .padding(.top, 14)
        case .readyToInstall(let fileURL):
            header(title: "Almost done", detail: "The disk image is open in Finder.", badge: .available)
            VStack(alignment: .leading, spacing: 8) {
                step(1, "Quit QCpie so it can be replaced.")
                step(2, "In the Finder window, drag QCpie into Applications and choose Replace.")
            }
            .padding(.top, 14)
            actions(leading: {
                linkButton("Open Disk Image Again") { NSWorkspace.shared.open(fileURL) }
            }) {
                secondaryButton("Close") { dismissModal() }
                primaryButton("Quit QCpie") { updateManager.quitAppToReplace() }
            }
        case .failed(let message):
            header(title: "Couldn't check for updates", detail: message, badge: .failed)
            actions(leading: {
                if let url = updateManager.remoteWebURL {
                    linkButton("View on GitHub") { NSWorkspace.shared.open(url) }
                }
            }) {
                secondaryButton("Close") { dismissModal() }
                primaryButton("Try Again") { updateManager.checkForUpdates(userInitiated: true) }
            }
        }
    }

    // MARK: - Pieces

    private enum Badge { case upToDate, available, failed }

    /// The app icon (with a small status badge or a spinner), the title and one line of detail.
    private func header<Accessory: View>(title: String, detail: String, badge: Badge? = nil,
                                         @ViewBuilder accessory: () -> Accessory = { EmptyView() }) -> some View {
        HStack(alignment: .center, spacing: 14) {
            Image(nsImage: NSApp.applicationIconImage)
                .resizable()
                .frame(width: 52, height: 52)
                .overlay(alignment: .bottomTrailing) {
                    if let badge { badgeView(badge).offset(x: 3, y: 3) }
                }
            VStack(alignment: .leading, spacing: 3) {
                Text(title)
                    .font(.ui(size: 15, weight: .semibold))
                    .foregroundColor(palette.textMain)
                Text(detail)
                    .font(.ui(size: 11))
                    .foregroundColor(palette.textMuted)
                    .lineLimit(3)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 0)
            accessory()
        }
        .padding(.trailing, 18)   // clear of the close button
    }

    private func badgeView(_ badge: Badge) -> some View {
        let (symbol, color): (String, Color) = switch badge {
        case .upToDate: ("checkmark.circle.fill", palette.positive)
        case .available: ("arrow.down.circle.fill", palette.accentBlue)
        case .failed: ("exclamationmark.circle.fill", palette.negative)
        }
        return Image(systemName: symbol)
            .font(.system(size: StudioTheme.scaleFont(17), weight: .semibold))
            .foregroundStyle(.white, color)
            .background(Circle().fill(palette.bgPanel).padding(-1.5))
    }

    private func step(_ number: Int, _ text: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Text("\(number)")
                .font(.ui(size: 10, weight: .semibold))
                .foregroundColor(palette.textMuted)
                .frame(width: 16, height: 16)
                .background(Circle().fill(palette.bgSubtle))
            Text(text)
                .font(.ui(size: 11))
                .foregroundColor(palette.textMain)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private func progressBar(_ progress: Double) -> some View {
        GeometryReader { geo in
            ZStack(alignment: .leading) {
                Capsule().fill(palette.bgSubtle)
                Capsule()
                    .fill(palette.accentBlue)
                    .frame(width: max(6, geo.size.width * CGFloat(min(1, max(0, progress)))))
            }
        }
        .frame(height: 6)
        .animation(.easeOut(duration: 0.2), value: progress)
    }

    /// The bottom row: an optional link on the left, buttons on the right.
    private func actions<Leading: View, Trailing: View>(@ViewBuilder leading: () -> Leading = { EmptyView() },
                                                         @ViewBuilder _ trailing: () -> Trailing) -> some View {
        HStack(spacing: 8) {
            leading()
            Spacer(minLength: 12)
            trailing()
        }
        .padding(.top, 20)
    }

    private func primaryButton(_ title: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(title)
                .font(.ui(size: 12, weight: .semibold))
                .foregroundColor(palette.primaryBtnFg)
                .padding(.horizontal, 14)
                .frame(height: StudioTheme.scale(28))
                .background(RoundedRectangle(cornerRadius: 7, style: .continuous).fill(palette.primaryBtnBg))
                .contentShape(Rectangle())
        }
        .buttonStyle(UpdateButtonStyle())
        .keyboardShortcut(.defaultAction)
    }

    private func secondaryButton(_ title: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(title)
                .font(.ui(size: 12))
                .foregroundColor(palette.textMain)
                .padding(.horizontal, 12)
                .frame(height: StudioTheme.scale(28))
                .contentShape(Rectangle())
        }
        .buttonStyle(UpdateButtonStyle(hoverFill: palette.bgSubtle))
    }

    private func linkButton(_ title: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(title)
                .font(.ui(size: 11))
                .foregroundColor(palette.accentBlue)
                .padding(.horizontal, 4)
                .frame(height: StudioTheme.scale(24))
                .contentShape(Rectangle())
        }
        .buttonStyle(UpdateButtonStyle(underlineOnHover: true))
    }

    private var closeButton: some View {
        Button(action: dismissModal) {
            Image(systemName: "xmark")
                .font(.system(size: StudioTheme.scaleFont(9), weight: .bold))
                .foregroundColor(palette.textMuted)
                .frame(width: 22, height: 22)
                .contentShape(Circle())
        }
        .buttonStyle(UpdateButtonStyle(hoverFill: palette.bgSubtle, circle: true))
        .keyboardShortcut(.escape, modifiers: [])
        .help("Close (Esc)")
    }

    // MARK: - Helpers

    private var isBusy: Bool {
        if case .installing = updateManager.state { return true }
        return false
    }

    private func dismissModal() {
        if isBusy { return }
        withAnimation(.easeInOut(duration: 0.15)) {
            isPresented = false
        }
        DispatchQueue.main.async {
            if let window = NSApp.windows.first(where: { $0.canBecomeKey }) {
                window.makeKeyAndOrderFront(nil)
                window.makeFirstResponder(nil)
            }
        }
    }

    private func formatBytes(_ bytes: Int64) -> String {
        ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file)
    }
}

/// Hover and press feedback for the update card's buttons: a soft fill (or underline for links), a slight press dim.
private struct UpdateButtonStyle: ButtonStyle {
    var hoverFill: Color? = nil
    var circle = false
    var underlineOnHover = false

    func makeBody(configuration: Configuration) -> some View {
        UpdateButtonBody(configuration: configuration, hoverFill: hoverFill, circle: circle, underlineOnHover: underlineOnHover)
    }
}

private struct UpdateButtonBody: View {
    let configuration: ButtonStyle.Configuration
    let hoverFill: Color?
    let circle: Bool
    let underlineOnHover: Bool
    @State private var isHovered = false
    @Environment(\.isEnabled) private var isEnabled

    var body: some View {
        configuration.label
            .background {
                if let hoverFill, isHovered, isEnabled {
                    if circle { Circle().fill(hoverFill) } else { RoundedRectangle(cornerRadius: 7, style: .continuous).fill(hoverFill) }
                }
            }
            .underline(underlineOnHover && isHovered)
            .brightness(hoverFill == nil && !underlineOnHover && isHovered ? 0.04 : 0)
            .opacity(!isEnabled ? 0.4 : (configuration.isPressed ? 0.75 : 1))
            .onHover { isHovered = $0 }
            .animation(.easeInOut(duration: 0.12), value: isHovered)
    }
}
