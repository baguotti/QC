import SwiftUI
import AppKit
import AuthenticationServices
import UniformTypeIdentifiers
import ImageIO

// The browser's sheets: Move to, New Project, Stack, Create Share Link.
/// "Move to…": browse the project's folders and pick where the items go.
struct FrameIOMoveSheet: View {
    let items: [FrameIO.Item]
    /// Copy to (any folder, including this one) instead of Move to.
    let isCopy: Bool
    let isLightMode: Bool
    let onMove: (_ folder: String, _ title: String) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var path: [FrameIOBrowser.Crumb] = []
    @State private var folders: [FrameIO.Item] = []
    @State private var isLoading = true
    @State private var error: String?

    private var palette: StudioPalette { StudioPalette(isLightMode) }
    private var movingIDs: Set<String> { Set(items.map(\.id)) }
    private var current: FrameIOBrowser.Crumb? { path.last }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text((isCopy ? "Copy " : "Move ") + (items.count == 1 ? "“\(items[0].title)”" : "\(items.count) items") + " to")
                .font(.ui(size: 13, weight: .semibold))
                .lineLimit(1)
                .truncationMode(.middle)
                .padding(16)
            HStack(spacing: 4) {
                ForEach(Array(path.enumerated()), id: \.offset) { index, crumb in
                    if index > 0 {
                        Image(systemName: "chevron.right")
                            .font(.system(size: StudioTheme.scaleFont(9), weight: .semibold))
                            .foregroundColor(palette.textMuted.opacity(0.6))
                    }
                    Button(crumb.title) { path.removeSubrange((index + 1)...); load() }
                        .buttonStyle(.plain)
                        .font(.ui(size: 12, weight: index == path.count - 1 ? .semibold : .regular))
                        .foregroundColor(index == path.count - 1 ? palette.textMain : palette.textMuted)
                        .disabled(index == path.count - 1)
                }
            }
            .lineLimit(1)
            .padding(.horizontal, 16)
            .padding(.bottom, 8)
            Rectangle().fill(palette.borderLine).frame(height: 1)
            Group {
                if isLoading {
                    ProgressView().controlSize(.small).frame(maxWidth: .infinity, maxHeight: .infinity)
                } else if let error {
                    Text(error).font(.ui(size: 11)).foregroundColor(palette.negative).padding(16)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else if folders.isEmpty {
                    Text("No subfolders").font(.ui(size: 11)).foregroundColor(palette.textMuted)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else {
                    ScrollView {
                        LazyVStack(spacing: 0) {
                            ForEach(folders) { folder in
                                let blocked = movingIDs.contains(folder.id)
                                Button(action: {
                                    path.append(.init(level: .folder, id: folder.id, title: folder.title, folderID: folder.id))
                                    load()
                                }) {
                                    HStack(spacing: 10) {
                                        Image(systemName: "folder.fill").foregroundColor(palette.accentBlue)
                                        Text(folder.title).font(.ui(size: 12)).lineLimit(1)
                                        Spacer()
                                        Image(systemName: "chevron.right")
                                            .font(.system(size: StudioTheme.scaleFont(10), weight: .semibold))
                                            .foregroundColor(palette.textMuted.opacity(0.5))
                                    }
                                    .padding(.horizontal, 16)
                                    .padding(.vertical, 6)
                                    .contentShape(Rectangle())
                                }
                                .buttonStyle(.plain)
                                .disabled(blocked)
                                .opacity(blocked ? 0.4 : 1)
                            }
                        }
                        .padding(.vertical, 4)
                    }
                }
            }
            .frame(height: 280)
            Rectangle().fill(palette.borderLine).frame(height: 1)
            HStack {
                Spacer()
                Button("Cancel") { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button(isCopy ? "Copy Here" : "Move Here") {
                    guard let current, let folder = current.listedFolder else { return }
                    onMove(folder, current.title)
                    dismiss()
                }
                .keyboardShortcut(.defaultAction)
                .disabled(current?.listedFolder == nil || (!isCopy && current?.listedFolder == FrameIOBrowser.shared.currentFolderID))
            }
            .padding(16)
        }
        .frame(width: 440)
        .background(palette.bgPanel)
        .onAppear {
            // Start at the open project's root, then the open folder's path.
            path = FrameIOBrowser.shared.path.filter { $0.level == .project || $0.level == .folder }
            load()
        }
    }

    private func load() {
        guard let account = FrameIOBrowser.shared.accountID, let folder = current?.listedFolder else { return }
        isLoading = true
        error = nil
        Task {
            do {
                let children = try await FrameIO.shared.children(account: account, folder: folder, thumbnails: false)
                guard current?.listedFolder == folder else { return }
                folders = children.filter(\.isFolder)
                    .sorted { $0.title.localizedStandardCompare($1.title) == .orderedAscending }
            } catch {
                guard current?.listedFolder == folder else { return }
                self.error = error.localizedDescription
            }
            isLoading = false
        }
    }
}

extension View {
    /// Accepts drops (Finder files, queue files or Frame.io items) only where `enabled`, so non-targets don't swallow them.
    @ViewBuilder
    func dropIf(_ enabled: Bool, isTargeted: Binding<Bool>, perform: @escaping ([NSItemProvider]) -> Bool) -> some View {
        if enabled {
            onDrop(of: [.fileURL, .utf8PlainText], isTargeted: isTargeted, perform: perform)
        } else {
            self
        }
    }
}

/// Frame.io's New Project dialog: a name, then Create (Return) or Cancel (Esc). The shortcut router leaves sheets'
/// keys alone, so Return and Esc reach these buttons.
struct FrameIONewProjectSheet: View {
    @ObservedObject private var themeManager = ThemeManager.shared   // accent changes redraw
    let isLightMode: Bool
    let onCreate: (String) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var name = ""
    @FocusState private var focused: Bool

    private var palette: StudioPalette { StudioPalette(isLightMode) }
    private var trimmed: String { name.trimmingCharacters(in: .whitespacesAndNewlines) }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("New Project")
                .font(.ui(size: 15, weight: .semibold))
                .foregroundColor(palette.textMain)
            TextField("Project name", text: $name)
                .textFieldStyle(.roundedBorder)
                .font(.ui(size: 12))
                .focused($focused)
            HStack {
                Spacer()
                Button("Cancel") { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button("Create", action: create)
                    .keyboardShortcut(.defaultAction)
                    .disabled(trimmed.isEmpty)
            }
        }
        .padding(20)
        .frame(width: 340)
        .background(palette.bgPanel)
        .onAppear { DispatchQueue.main.async { focused = true } }
    }

    private func create() {
        guard !trimmed.isEmpty else { return }
        onCreate(trimmed)
        dismiss()
    }
}

/// "Stack as Versions…": puts the files in version order (V1 oldest … last = current) before stacking.
struct FrameIOStackSheet: View {
    let isLightMode: Bool
    let onStack: ([FrameIO.Item]) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var ordered: [FrameIO.Item]

    init(files: [FrameIO.Item], isLightMode: Bool, onStack: @escaping ([FrameIO.Item]) -> Void) {
        self.isLightMode = isLightMode
        self.onStack = onStack
        _ordered = State(initialValue: files.sorted { $0.title.localizedStandardCompare($1.title) == .orderedAscending })
    }

    private var palette: StudioPalette { StudioPalette(isLightMode) }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Stack \(ordered.count) Files as Versions")
                .font(.ui(size: 13, weight: .semibold))
            Text("The last one becomes the current version. Use the arrows to change the order.")
                .font(.ui(size: 11))
                .foregroundColor(palette.textMuted)
            VStack(spacing: 0) {
                ForEach(Array(ordered.enumerated()), id: \.element.id) { index, file in
                    HStack(spacing: 10) {
                        Text("V\(index + 1)")
                            .font(.ui(size: 11, weight: .bold))
                            .foregroundColor(.white)
                            .padding(.horizontal, 5)
                            .padding(.vertical, 1)
                            .background(Capsule().fill(palette.accentBlue))
                            .frame(width: 34, alignment: .leading)
                        Text(file.title).font(.ui(size: 12)).lineLimit(1).truncationMode(.middle)
                        if index == ordered.count - 1 {
                            Text("Current").font(.ui(size: 11, weight: .semibold)).foregroundColor(palette.positive)
                        }
                        Spacer()
                        Button(action: { ordered.swapAt(index, index - 1) }) { Image(systemName: "chevron.up") }
                            .buttonStyle(.borderless)
                            .disabled(index == 0)
                        Button(action: { ordered.swapAt(index, index + 1) }) { Image(systemName: "chevron.down") }
                            .buttonStyle(.borderless)
                            .disabled(index == ordered.count - 1)
                    }
                    .padding(.horizontal, 10)
                    .padding(.vertical, 6)
                    .background(index.isMultiple(of: 2) ? palette.bgCardSubtle : Color.clear)
                }
            }
            .studioBox(background: palette.bgMain, border: palette.borderLine)
            HStack {
                Spacer()
                Button("Cancel") { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button("Stack") {
                    onStack(ordered)
                    dismiss()
                }
                .keyboardShortcut(.defaultAction)
            }
        }
        .padding(16)
        .frame(width: 460)
        .background(palette.bgPanel)
    }
}

/// "Create Share Link…", modelled on Frame.io's share dialog: the link is created straight away with Frame.io's defaults,
/// then name, access, invites and settings are edited in place. Setting changes are batched into one update (the API
/// allows 10 per minute).
struct FrameIOShareSheet: View {
    let request: FrameIOBrowserView.ShareRequest
    let isLightMode: Bool
    @Environment(\.dismiss) private var dismiss
    @State private var share: FrameIO.Share?
    @State private var error: String?
    @State private var name = ""
    @FocusState private var nameFocused: Bool
    @State private var secure = false
    @State private var enabled = true
    @State private var comments = true
    @State private var downloads = true
    @State private var allVersions = false
    @State private var passphrase: String?
    /// The passphrase being typed (saved when the field loses focus).
    @State private var passphraseText = ""
    @FocusState private var passphraseFocused: Bool
    @State private var expiry: Date?
    @State private var invitees = ""
    @State private var message = ""
    @State private var notify = true
    @State private var inviteStatus: String?
    @State private var isInviting = false
    @State private var showSettings = false
    @State private var copied = false
    @State private var pending: [String: Any] = [:]
    @State private var saveTask: Task<Void, Never>?
    @State private var isSaving = false

    private var palette: StudioPalette { StudioPalette(isLightMode) }
    private var account: String? { FrameIOBrowser.shared.accountID }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            if let share {
                editor(share)
            } else {
                VStack(spacing: 12) {
                    if let error {
                        Text(error).font(.ui(size: 12)).foregroundColor(palette.negative).multilineTextAlignment(.center)
                        Button("Close") { dismiss() }
                    } else {
                        ProgressView().controlSize(.small)
                        Text("Creating share link…").font(.ui(size: 12)).foregroundColor(palette.textMuted)
                    }
                }
                .frame(maxWidth: .infinity, minHeight: 180)
                .padding(20)
            }
        }
        // Fixed size: macOS sheets don't resize with their content, so Settings is its own page (like Frame.io's).
        .frame(width: 440, height: 600)
        .background(palette.bgPanel)
        .task { await create() }
    }

    // MARK: Editor

    @ViewBuilder
    private func editor(_ share: FrameIO.Share) -> some View {
        if showSettings {
            settingsPage(share)
                .transition(.move(edge: .trailing))
        } else {
            mainPage(share)
                .transition(.move(edge: .leading))
        }
    }

    private func settingsPage(_ share: FrameIO.Share) -> some View {
        VStack(spacing: 0) {
            ZStack {
                Text("Settings").font(.ui(size: 13, weight: .semibold))
                HStack {
                    Button(action: { withAnimation(Motion.list) { showSettings = false } }) {
                        HStack(spacing: 3) {
                            Image(systemName: "chevron.left").font(.system(size: StudioTheme.scaleFont(11), weight: .semibold))
                            Text(name.isEmpty ? "Back" : name).font(.ui(size: 12)).lineLimit(1)
                        }
                        .frame(maxWidth: 150, alignment: .leading)
                    }
                    .buttonStyle(.borderless)
                    Spacer()
                    if isSaving { ProgressView().controlSize(.mini) }
                }
            }
            .padding(.horizontal, 18)
            .padding(.vertical, 14)
            Rectangle().fill(palette.borderLine).frame(height: 1)
            ScrollView {
                VStack(alignment: .leading, spacing: 10) {
                    Text(summary)
                        .font(.ui(size: 11))
                        .foregroundColor(palette.textMuted)
                        .fixedSize(horizontal: false, vertical: true)
                        .padding(.horizontal, 4)
                    settingsGroups
                }
                .padding(18)
            }
            Rectangle().fill(palette.borderLine).frame(height: 1)
            footer(share)
        }
    }

    private func footer(_ share: FrameIO.Share) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 10) {
                if let link = share.shortURL, let url = URL(string: link) {
                    Button(action: { NSWorkspace.shared.open(url) }) {
                        Label("Open in Frame.io", systemImage: "arrow.up.right").font(.ui(size: 12))
                    }
                    .buttonStyle(.borderless)
                }
                Spacer()
                Button("Copy Link", action: copyLink)
                Button("Done") { flushNow(); dismiss() }
                    .keyboardShortcut(.defaultAction)
            }
            .padding(.horizontal, 18)
            .padding(.vertical, 14)
            if let error {
                Text(error)
                    .font(.ui(size: 11))
                    .foregroundColor(palette.negative)
                    .padding(.horizontal, 18)
                    .padding(.bottom, 12)
            }
        }
    }

    private func mainPage(_ share: FrameIO.Share) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            VStack(alignment: .leading, spacing: 12) {
                HStack(spacing: 6) {
                    TextField("Share name", text: $name)
                        .textFieldStyle(.plain)
                        .font(.ui(size: 15, weight: .semibold))
                        .focused($nameFocused)
                        .onChange(of: nameFocused) { _, focused in
                            if !focused { commitName() }
                        }
                    Image(systemName: "pencil")
                        .font(.system(size: StudioTheme.scaleFont(11)))
                        .foregroundColor(palette.textMuted)
                    Spacer()
                    if isSaving { ProgressView().controlSize(.mini) }
                }

                HStack(spacing: 0) {
                    Text(share.shortURL ?? "—")
                        .font(.ui(size: 12))
                        .textSelection(.enabled)
                        .lineLimit(1)
                        .padding(.horizontal, 10)
                    Spacer(minLength: 6)
                    Button(action: copyLink) {
                        Image(systemName: copied ? "checkmark" : "link")
                            .font(.system(size: StudioTheme.scaleFont(12)))
                            .foregroundColor(copied ? palette.positive : palette.textMuted)
                    }
                    .buttonStyle(.borderless)
                    .tip("Copy link")
                    .padding(.trailing, 8)
                    Rectangle().fill(palette.borderLine).frame(width: 1)
                    Menu {
                        Button(action: { set(secure: false) }) {
                            Label("Public: anyone with the link", systemImage: "globe")
                        }
                        Button(action: { set(secure: true) }) {
                            Label(Self.secureUnavailable ? "Secure: not included in your Frame.io plan" : "Secure: only people you invite",
                                  systemImage: "lock")
                        }
                        .disabled(Self.secureUnavailable)
                    } label: {
                        Label(secure ? "Secure" : "Public", systemImage: secure ? "lock" : "globe")
                            .font(.ui(size: 12, weight: .semibold))
                    }
                    .menuStyle(.borderlessButton)
                    .fixedSize()
                    .padding(.horizontal, 10)
                }
                .frame(height: StudioTheme.scale(34))
                .studioBox(background: palette.bgMain, border: palette.borderLine)
                .opacity(enabled ? 1 : 0.5)

                invite
            }
            .padding(18)

            Rectangle().fill(palette.borderLine).frame(height: 1)

            VStack(alignment: .leading, spacing: 14) {
                preview
                settingsLink
            }
            .padding(18)
            .frame(maxHeight: .infinity, alignment: .top)

            Rectangle().fill(palette.borderLine).frame(height: 1)
            footer(share)
        }
    }

    private var invite: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                TextField("Add emails (separate with commas)", text: $invitees)
                    .textFieldStyle(.plain)
                    .font(.ui(size: 12))
                    .padding(.horizontal, 10)
                    .frame(height: StudioTheme.scale(30))
                    .studioBox(background: palette.bgMain, border: palette.borderLine)
                if !emails.isEmpty {
                    Button(isInviting ? "Inviting…" : "Invite", action: sendInvites)
                        .disabled(isInviting)
                }
            }
            if !emails.isEmpty {
                TextField("Message (optional)", text: $message)
                    .textFieldStyle(.plain)
                    .font(.ui(size: 12))
                    .padding(.horizontal, 10)
                    .frame(height: StudioTheme.scale(28))
                    .studioBox(background: palette.bgMain, border: palette.borderLine)
                Toggle("Send an email invitation", isOn: $notify)
                    .toggleStyle(.checkbox)
                    .font(.ui(size: 11))
            }
            if let inviteStatus {
                Text(inviteStatus).font(.ui(size: 11)).foregroundColor(palette.textMuted)
            }
        }
    }

    private var preview: some View {
        ZStack {
            RoundedRectangle(cornerRadius: Radius.segment).fill(palette.bgSubtle)
            if let first = request.items.first {
                FrameIOThumbnail(item: first, width: 200, isLightMode: isLightMode)
            } else {
                Image(systemName: "folder.fill")
                    .font(.system(size: StudioTheme.scaleFont(22)))
                    .foregroundColor(palette.textMuted)
            }
            if request.assetIDs.count > 1 {
                Text("\(request.assetIDs.count) items")
                    .font(.ui(size: 11, weight: .semibold))
                    .foregroundColor(.white)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background(Capsule().fill(Color.black.opacity(0.55)))
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomTrailing)
                    .padding(8)
            }
        }
        .frame(height: 140)
    }

    /// Opens the Settings page (Frame.io's "Settings ›" row).
    private var settingsLink: some View {
        Button(action: { withAnimation(Motion.list) { showSettings = true } }) {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Settings").font(.ui(size: 13, weight: .semibold)).foregroundColor(palette.textMain)
                    Text(summary).font(.ui(size: 11)).foregroundColor(palette.textMuted)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer()
                Image(systemName: "chevron.right").foregroundColor(palette.textMuted)
            }
            .padding(12)
            .background(RoundedRectangle(cornerRadius: Radius.container).fill(palette.bgCardSubtle))
            .overlay(RoundedRectangle(cornerRadius: Radius.container).stroke(palette.borderLine.opacity(0.7), lineWidth: 0.5))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private var settingsGroups: some View {
        VStack(alignment: .leading, spacing: 10) {
                VStack(alignment: .leading, spacing: 14) {
                    settingsGroup("Reviewers can") {
                        switchRow("Comment", value: $comments, key: "commenting_enabled")
                        rowDivider
                        switchRow("Download", value: $downloads, key: "downloading_enabled")
                        rowDivider
                        switchRow("See all versions", detail: "Every version in a stack, not just the current one",
                                  value: $allVersions, key: "show_all_asset_versions")
                    }
                    settingsGroup("Link") {
                        switchRow("Active", detail: "Off stops the link working without deleting it", value: $enabled, key: "enabled")
                        rowDivider
                        settingRow("Passphrase", detail: passphrase == nil ? nil : "Suggested, or type your own. Share it separately") {
                            Toggle("", isOn: Binding(get: { passphrase != nil }, set: { on in
                                passphrase = on ? Self.newPassphrase() : nil
                                passphraseText = passphrase ?? ""
                                queue("passphrase", passphrase ?? NSNull())
                            }))
                            .labelsHidden()
                            .toggleStyle(.switch)
                            .controlSize(.small)
                        }
                        if passphrase != nil {
                            HStack(spacing: 8) {
                                TextField("Passphrase", text: $passphraseText)
                                    .textFieldStyle(.plain)
                                    .font(.system(size: StudioTheme.scaleFont(12), design: .monospaced))
                                    .focused($passphraseFocused)
                                    .onChange(of: passphraseFocused) { _, focused in
                                        if !focused { commitPassphrase() }
                                    }
                                    .padding(.horizontal, 8)
                                    .frame(height: StudioTheme.scale(26))
                                    .background(RoundedRectangle(cornerRadius: 5).fill(palette.bgMain))
                                    .overlay(RoundedRectangle(cornerRadius: 5).stroke(palette.borderLine, lineWidth: 0.5))
                                Button(action: suggestPassphrase) {
                                    Image(systemName: "arrow.triangle.2.circlepath").font(.system(size: StudioTheme.scaleFont(11)))
                                }
                                .buttonStyle(.borderless)
                                .tip("Suggest a new strong passphrase")
                                Button(action: { Self.copy(passphraseText) }) {
                                    Image(systemName: "doc.on.doc").font(.system(size: StudioTheme.scaleFont(11)))
                                }
                                .buttonStyle(.borderless)
                                .tip("Copy passphrase")
                            }
                            .padding(.horizontal, 12)
                            .padding(.bottom, 10)
                            if passphraseText.trimmingCharacters(in: .whitespaces).count < 8 {
                                Text("Use at least 8 characters.")
                                    .font(.ui(size: 11))
                                    .foregroundColor(palette.negative)
                                    .padding(.horizontal, 12)
                                    .padding(.bottom, 8)
                                    .frame(maxWidth: .infinity, alignment: .leading)
                            }
                        }
                        rowDivider
                        settingRow("Expires") {
                            HStack(spacing: 8) {
                                if expiry != nil {
                                    DatePicker("", selection: Binding(get: { expiry ?? Date() }, set: { expiry = $0; queueExpiry() }),
                                               in: Date()..., displayedComponents: [.date, .hourAndMinute])
                                        .labelsHidden()
                                        .datePickerStyle(.compact)
                                        .controlSize(.small)
                                }
                                Toggle("", isOn: Binding(get: { expiry != nil }, set: { on in
                                    expiry = on ? Calendar.current.date(byAdding: .day, value: 7, to: Date()) : nil
                                    queueExpiry()
                                }))
                                .labelsHidden()
                                .toggleStyle(.switch)
                                .controlSize(.small)
                            }
                        }
                    }
                }
        }
    }

    /// A System Settings–style group: small header, rounded box, rows separated by hairlines.
    private func settingsGroup<Rows: View>(_ title: String, @ViewBuilder rows: () -> Rows) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title)
                .font(.ui(size: 11, weight: .semibold))
                .foregroundColor(palette.textMuted)
                .padding(.leading, 4)
            VStack(spacing: 0) { rows() }
                .background(RoundedRectangle(cornerRadius: Radius.container).fill(palette.bgCardSubtle))
                .overlay(RoundedRectangle(cornerRadius: Radius.container).stroke(palette.borderLine.opacity(0.7), lineWidth: 0.5))
        }
    }

    private var rowDivider: some View {
        Rectangle().fill(palette.borderLine.opacity(0.6)).frame(height: 0.5).padding(.leading, 12)
    }

    /// Title (and optional detail) on the left, the control right-aligned, fixed height like System Settings.
    private func settingRow<Control: View>(_ title: String, detail: String? = nil, @ViewBuilder control: () -> Control) -> some View {
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 1) {
                Text(title).font(.ui(size: 12)).foregroundColor(palette.textMain)
                if let detail {
                    Text(detail).font(.ui(size: 11)).foregroundColor(palette.textMuted).lineLimit(1)
                }
            }
            Spacer(minLength: 8)
            control()
        }
        .padding(.horizontal, 12)
        .frame(minHeight: StudioTheme.scale(detail == nil ? 34 : 42))
    }

    private func switchRow(_ title: String, detail: String? = nil, value: Binding<Bool>, key: String) -> some View {
        settingRow(title, detail: detail) {
            Toggle("", isOn: Binding(get: { value.wrappedValue }, set: { value.wrappedValue = $0; queue(key, $0) }))
                .labelsHidden()
                .toggleStyle(.switch)
                .controlSize(.small)
        }
    }

    private var summary: String {
        guard enabled else { return "The link is turned off." }
        var can = ["view"]
        if downloads { can.append("download") }
        if comments { can.append("comment") }
        let list = can.count > 1 ? can.dropLast().joined(separator: ", ") + " and " + can.last! : can[0]
        var text = (secure ? "Invited people can " : "Anyone with the link can ") + list + "."
        if passphrase != nil { text += " Passphrase required." }
        if let expiry { text += " Expires \(expiry.formatted(date: .abbreviated, time: .shortened))." }
        return text
    }

    private var emails: [String] {
        invitees.split(whereSeparator: { ",; \n".contains($0) }).map(String.init).filter { $0.contains("@") }
    }

    // MARK: Network

    private func create() async {
        guard share == nil, let account else { return }
        do {
            let made = try await FrameIO.shared.createShare(account: account, project: request.project, name: request.name,
                                                            assetIDs: request.assetIDs)
            apply(made)
            if let link = made.shortURL { Self.copy(link); flashCopied() }
        } catch {
            self.error = "Couldn't create the share link: \(error.localizedDescription)"
        }
    }

    private func apply(_ made: FrameIO.Share) {
        share = made
        name = made.name ?? request.name
        secure = made.access == "secure"
        enabled = made.enabled
        comments = made.commentingEnabled
        downloads = made.downloadingEnabled
        allVersions = made.showAllAssetVersions ?? false
        passphrase = made.passphrase
        passphraseText = made.passphrase ?? ""
        expiry = made.expirationDate
    }

    private func set(secure value: Bool) {
        secure = value
        queue("access", value ? "secure" : "public")
    }

    private func commitName() {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, trimmed != share?.name else {
            if trimmed.isEmpty { name = share?.name ?? request.name }
            return
        }
        queue("name", trimmed)
    }

    private func commitPassphrase() {
        let text = passphraseText.trimmingCharacters(in: .whitespaces)
        guard passphrase != nil, text != passphrase else { return }
        guard text.count >= 8 else { return }
        passphrase = text
        queue("passphrase", text)
    }

    private func suggestPassphrase() {
        let suggestion = Self.newPassphrase()
        passphraseText = suggestion
        passphrase = suggestion
        queue("passphrase", suggestion)
    }

    private func queueExpiry() {
        queue("expiration", expiry.map { ISO8601DateFormatter().string(from: $0) } ?? NSNull())
    }

    /// Collects changes and sends them together 0.8 s after the last one.
    private func queue(_ key: String, _ value: Any) {
        pending[key] = value
        saveTask?.cancel()
        saveTask = Task {
            try? await Task.sleep(for: .milliseconds(800))
            guard !Task.isCancelled else { return }
            await flush()
        }
    }

    private func flushNow() {
        commitName()
        commitPassphrase()
        guard !pending.isEmpty else { return }
        saveTask?.cancel()
        // Finish the save after the sheet closes.
        let fields = pending
        pending = [:]
        guard let account, let id = share?.id, let body = try? FrameIO.shareUpdate(fields) else { return }
        Task { _ = try? await FrameIO.shared.updateShare(account: account, share: id, body: body) }
    }

    private func flush() async {
        guard !pending.isEmpty, let account, let id = share?.id else { return }
        let fields = pending
        pending = [:]
        isSaving = true
        defer { isSaving = false }
        do {
            let updated = try await FrameIO.shared.updateShare(account: account, share: id, body: FrameIO.shareUpdate(fields))
            share = updated
            error = nil
        } catch {
            self.error = Self.explain(error, changing: fields)
            // Changes sent together with a refused one still get saved.
            var rest = fields
            rest["access"] = nil
            if error.localizedDescription.contains("not included in plan"), fields["access"] != nil, !rest.isEmpty,
               let updated = try? await FrameIO.shared.updateShare(account: account, share: id, body: FrameIO.shareUpdate(rest)) {
                share = updated
            }
            if let share { apply(share) }
        }
    }

    /// Remembered for the session once Frame.io says the plan has no secure links.
    @MainActor private static var secureUnavailable = false

    /// Frame.io answers 422 "feature(s) not included in plan: …" for settings the account's plan doesn't have.
    private static func explain(_ error: Error, changing fields: [String: Any]) -> String {
        let text = error.localizedDescription
        guard text.contains("not included in plan") else { return "Couldn't save: \(text)" }
        if fields["access"] != nil {
            secureUnavailable = true
            return "Secure (invite-only) links aren't included in your Frame.io plan. The link stays Public."
        }
        let feature = text.components(separatedBy: "plan:").last?.trimmingCharacters(in: .whitespaces) ?? "this setting"
        return "Your Frame.io plan doesn't include \(feature.replacingOccurrences(of: "_", with: " ")). The change wasn't saved."
    }

    private func sendInvites() {
        guard let account, let id = share?.id else { return }
        let list = emails
        let note = message.trimmingCharacters(in: .whitespacesAndNewlines)
        isInviting = true
        Task {
            do {
                try await FrameIO.shared.inviteToShare(account: account, share: id, emails: list,
                                                       message: note.isEmpty ? "Shared from QCpie: \(name)" : note, notify: notify)
                inviteStatus = "Invited \(list.joined(separator: ", "))"
                invitees = ""
                message = ""
            } catch {
                inviteStatus = "Couldn't invite: \(error.localizedDescription)"
            }
            isInviting = false
        }
    }

    private func copyLink() {
        guard let link = share?.shortURL else { return }
        Self.copy(link)
        flashCopied()
    }

    private func flashCopied() {
        copied = true
        Task {
            try? await Task.sleep(for: .seconds(1.5))
            copied = false
        }
    }

    private static func copy(_ text: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }

    /// Strong but easy to read out or type: four groups of four from 31 characters without look-alikes (0/O, 1/l/I),
    /// about 79 bits, e.g. "k7mq-x2pt-9hcz-r4wd". Uses the system's secure random generator.
    private static func newPassphrase() -> String {
        let alphabet = Array("abcdefghjkmnpqrstuvwxyz23456789")
        var generator = SystemRandomNumberGenerator()
        return (0..<4).map { _ in String((0..<4).map { _ in alphabet.randomElement(using: &generator)! }) }
            .joined(separator: "-")
    }
}
