import SwiftUI

/// Setting up a Delivery Plan in one place: sign in, link the sheet, add the QCpie tab, choose the Frame.io folder.
/// Each step shows done (✓ with what was chosen) or its one action; later steps wait for earlier ones. Shown in the
/// plan panel before a sheet is linked, and as a sheet afterwards (••• → Set Up Plan…, or right after linking while
/// steps remain).
struct PlanSetupGuide: View {
    let isLightMode: Bool
    /// Nil when shown inline (nothing to close).
    var onClose: (() -> Void)? = nil
    /// Relinking: step 2 is shown open even though a sheet is linked.
    var relinking = false
    /// A sheet was linked from step 2.
    var onLinked: (() -> Void)? = nil

    @ObservedObject private var store = DeliveryPlanStore.shared
    @ObservedObject private var account = GoogleAccount.shared
    @State private var linkText = ""
    @State private var folderText = ""
    @State private var busy: Int? = nil
    @State private var error: (step: Int, message: String)? = nil

    private var palette: StudioPalette { StudioPalette(isLightMode) }
    private var linked: Bool { store.config != nil && !relinking }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text(onClose == nil ? "Set Up a Delivery Plan" : "Delivery Plan Setup")
                .font(.ui(size: 15, weight: .semibold))
                .foregroundColor(palette.textMain)
            Text("Four steps, once per plan. QCpie reads the sheet as your Google account, keeps its statuses and links in a QCpie tab, and looks for the plan's files in one Frame.io folder.")
                .font(.ui(size: 11)).foregroundColor(palette.textMuted).fixedSize(horizontal: false, vertical: true)
            step(1, "Sign in with Google", done: account.signedIn ? (account.email ?? "Signed in") : nil) {
                Button(account.signingIn ? "Signing In…" : "Sign In with Google…") { run(1) { try await account.signIn() } }
                    .disabled(account.signingIn || !GoogleAuth.isConfigured)
            }
            step(2, "Link the sheet", done: linked ? store.config?.title : nil, enabled: account.signedIn) {
                HStack(spacing: 6) {
                    TextField("Paste the Google Sheets link", text: $linkText).textFieldStyle(.roundedBorder).onSubmit(linkSheet)
                    Button(busy == 2 ? "Linking…" : "Link", action: linkSheet).disabled(PlanSheetLink.parse(linkText) == nil || busy != nil)
                }
            }
            step(3, "Add the QCpie tab", done: linked && store.hasQCTab ? "In the sheet" : nil, enabled: linked && account.signedIn) {
                VStack(alignment: .leading, spacing: 6) {
                    Text("Adds a tab with one row per code for statuses, notes, batches and Frame.io links, filled from the QC columns the tabs have now; those columns become read-only lookups of it. Clients who see the sheet see the tab.")
                        .font(.ui(size: 10)).foregroundColor(palette.textMuted).fixedSize(horizontal: false, vertical: true)
                    Button(store.settingUpQCTab ? "Adding…" : "Add the QCpie Tab") {
                        run(3) { if let message = await store.setUpQCTab() { throw SetupError(message) } }
                    }
                    .disabled(store.settingUpQCTab)
                }
            }
            step(4, "Choose the Frame.io folder", done: linked ? store.config?.frameioRoot?.title : nil, enabled: linked && account.signedIn, optional: true) {
                VStack(alignment: .leading, spacing: 6) {
                    if let open = browserFolder {
                        Button("Use “\(open.title)” (open in the Upload tab)") { store.setFrameIORoot(open) }
                    }
                    HStack(spacing: 6) {
                        TextField(browserFolder == nil ? "Paste a Frame.io project or folder link" : "…or paste a Frame.io project or folder link", text: $folderText).textFieldStyle(.roundedBorder)
                        Button(busy == 4 ? "Finding…" : "Use") {
                            run(4) { store.setFrameIORoot(try await store.frameIORoot(fromLink: folderText)) }
                        }
                        .disabled(folderText.isEmpty || busy != nil)
                    }
                }
            }
            if let onClose {
                HStack {
                    Spacer()
                    Button("Done", action: onClose).keyboardShortcut(.defaultAction)
                }
                .font(.ui(size: 11))
            }
        }
        .font(.ui(size: 11))
        .padding(onClose == nil ? 16 : 20)
        .frame(width: onClose == nil ? nil : 500)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(onClose == nil ? Color.clear : palette.bgPanel)
        .onExitCommand { onClose?() }
    }

    private struct SetupError: LocalizedError { let message: String; init(_ m: String) { message = m }; var errorDescription: String? { message } }

    private var browserFolder: DeliveryPlanStore.FrameIORoot? {
        let browser = FrameIOBrowser.shared
        guard let accountID = browser.accountID, let folder = browser.currentFolderID else { return nil }
        let root = DeliveryPlanStore.FrameIORoot(account: accountID, folder: folder, title: DeliveryPlanStore.rootTitle(browser.path))
        return root == store.config?.frameioRoot ? nil : root
    }

    private func linkSheet() {
        guard PlanSheetLink.parse(linkText) != nil else { return }
        let text = linkText
        run(2) {
            await store.link(text)
            if case .failed(let message) = store.phase { throw SetupError(message) }
            linkText = ""
            onLinked?()
        }
    }

    private func run(_ n: Int, _ work: @escaping @MainActor () async throws -> Void) {
        busy = n
        error = nil
        Task {
            do { try await work() } catch {
                self.error = (n, (error as? LocalizedError)?.errorDescription ?? error.localizedDescription)
            }
            busy = nil
        }
    }

    /// One step: its number (✓ when done), title, then what was chosen or its action. Later steps are dimmed until
    /// they can be done.
    private func step<Action: View>(_ n: Int, _ title: String, done: String?, enabled: Bool = true, optional: Bool = false,
                                    @ViewBuilder action: () -> Action) -> some View {
        HStack(alignment: .top, spacing: 10) {
            ZStack {
                Circle().fill(done != nil ? palette.positive : palette.bgSubtle).frame(width: 18, height: 18)
                if done != nil {
                    Image(systemName: "checkmark").font(.system(size: StudioTheme.scaleFont(8), weight: .bold)).foregroundColor(palette.bgPanel)
                } else {
                    Text("\(n)").font(.ui(size: 10, weight: .semibold)).foregroundColor(palette.textMuted)
                }
            }
            VStack(alignment: .leading, spacing: 5) {
                HStack(spacing: 6) {
                    Text(title).font(.ui(size: 12, weight: .semibold)).foregroundColor(palette.textMain)
                    if optional, done == nil { Text("Optional").font(.ui(size: 10)).foregroundColor(palette.textSubtle) }
                }
                if let done {
                    Text(done).font(.ui(size: 11)).foregroundColor(palette.textMuted).lineLimit(1).truncationMode(.middle)
                } else if enabled {
                    action()
                }
                if let error, error.step == n {
                    Text(error.message).font(.ui(size: 10)).foregroundColor(palette.negative).fixedSize(horizontal: false, vertical: true)
                }
            }
            Spacer(minLength: 0)
        }
        .opacity(enabled || done != nil ? 1 : 0.45)
    }
}
