import SwiftUI

/// Choosing the plan's Frame.io folder: the folder open in the Upload tab's browser, or a pasted project / folder
/// link. Says what binding changes before anything does.
struct PlanFrameIORootSheet: View {
    let isLightMode: Bool
    let onClose: () -> Void

    @ObservedObject private var store = DeliveryPlanStore.shared
    @State private var linkText = ""
    @State private var resolving = false
    @State private var error: String?

    private var palette: StudioPalette { StudioPalette(isLightMode) }

    /// The folder (or project) open in the Upload tab's Frame.io browser, if any.
    private var browserFolder: DeliveryPlanStore.FrameIORoot? {
        let browser = FrameIOBrowser.shared
        guard let account = browser.accountID, let folder = browser.currentFolderID else { return nil }
        return .init(account: account, folder: folder, title: DeliveryPlanStore.rootTitle(browser.path))
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Frame.io Folder")
                .font(.ui(size: 15, weight: .semibold))
                .foregroundColor(palette.textMain)
            Text("The project or folder holding this plan's files. QCpie reads only it and its subfolders for the plan: links found there, “on Frame.io” and “on Frame.io, not in the plan” come from it alone. It's read when set, then every 15 minutes while the plan is open.")
                .font(.ui(size: 11))
                .foregroundColor(palette.textMuted)
                .fixedSize(horizontal: false, vertical: true)
            if let root = store.config?.frameioRoot {
                HStack(spacing: 8) {
                    Image(systemName: "folder").font(.system(size: StudioTheme.scaleFont(11))).foregroundColor(palette.textMuted)
                    VStack(alignment: .leading, spacing: 1) {
                        Text(root.title).font(.ui(size: 12, weight: .semibold)).foregroundColor(palette.textMain).lineLimit(2)
                        Text(PlanFrameIORootSheet.scanText(store.rootScan)).font(.ui(size: 10)).foregroundColor(palette.textMuted)
                    }
                    Spacer(minLength: 4)
                    Button("Remove") { store.setFrameIORoot(nil) }
                        .tip("Stop binding the plan to this folder: links and extras come from whatever is browsed again.")
                }
                .padding(10)
                .studioBox(background: palette.bgCardSubtle, border: palette.borderLine, radius: Radius.container)
            }
            if let open = browserFolder, open != store.config?.frameioRoot {
                HStack(spacing: 8) {
                    Text("Open in the Upload tab:").font(.ui(size: 11)).foregroundColor(palette.textMuted)
                    Text(open.title).font(.ui(size: 11, weight: .medium)).foregroundColor(palette.textMain).lineLimit(1).truncationMode(.middle)
                    Spacer(minLength: 4)
                    Button("Use This Folder") { store.setFrameIORoot(open); onClose() }
                }
            }
            HStack(spacing: 8) {
                TextField("Paste a Frame.io project or folder link", text: $linkText)
                    .textFieldStyle(.roundedBorder)
                    .font(.ui(size: 11))
                Button(resolving ? "Finding…" : "Use Link", action: useLink)
                    .disabled(linkText.isEmpty || resolving)
            }
            .font(.ui(size: 11))
            if let error {
                Text(error).font(.ui(size: 11)).foregroundColor(palette.negative).fixedSize(horizontal: false, vertical: true)
            }
            HStack {
                Spacer()
                Button("Done", action: onClose).keyboardShortcut(.defaultAction)
            }
            .font(.ui(size: 11))
        }
        .padding(20)
        .frame(width: 480)
        .background(palette.bgPanel)
        .onExitCommand(perform: onClose)   // Esc
        .onAppear {
            if let clip = NSPasteboard.general.string(forType: .string), FrameIOLink.looksLikeLink(clip) { linkText = clip }
        }
    }

    private func useLink() {
        resolving = true
        error = nil
        Task {
            do {
                store.setFrameIORoot(try await store.frameIORoot(fromLink: linkText))
                onClose()
            } catch {
                self.error = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
            }
            resolving = false
        }
    }

    nonisolated static func scanText(_ scan: DeliveryPlanStore.RootScan) -> String {
        switch scan {
        case .idle: return "Not read yet"
        case .scanning(let n): return n == 0 ? "Reading…" : "Reading… \(n) folders"
        case .done(let date): return "Read \(date.formatted(.relative(presentation: .named)))"
        case .failed(let message): return message
        }
    }
}
