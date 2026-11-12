import SwiftUI
import AppKit
import AuthenticationServices
import UniformTypeIdentifiers
import ImageIO

/// The browser's actions (rename, move, share, download…) and its toast.
extension FrameIOBrowserView {
    // MARK: Actions

    @ViewBuilder
    var undoMenuItem: some View {
        if let undo = browser.lastUndo {
            Button("Undo: \(undo.message)", action: browser.performUndo)
            Divider()
        }
    }

    /// Toolbar Share: the selection, else the open folder (or stack).
    func shareSelectionOrFolder() {
        guard let project = browser.projectID else { return }
        let selected = browser.items.filter { browser.selection.contains($0.id) }
        if !selected.isEmpty {
            shareRequest = ShareRequest(project: project, name: selected.count == 1 ? selected[0].title : "\(selected.count) items",
                                        assetIDs: selected.map(\.id), items: selected)
        } else if let current = browser.path.last, let id = current.listedFolder ?? (browser.inStack ? current.id : nil) {
            shareRequest = ShareRequest(project: project, name: current.title, assetIDs: [id])
        }
    }

    @ViewBuilder
    func shareButton(_ targets: [FrameIO.Item]) -> some View {
        if let project = browser.projectID, !targets.isEmpty {
            Button {
                shareRequest = ShareRequest(project: project, name: targets.count == 1 ? targets[0].title : "\(targets.count) items",
                                            assetIDs: targets.map(\.id), items: targets)
            } label: {
                Label("Create Share Link", systemImage: "square.and.arrow.up")
            }
            Menu {
                if browser.projectShares.isEmpty {
                    Text("No share links in this project yet")
                }
                ForEach(browser.projectShares.prefix(25)) { share in
                    Button(share.name ?? share.shortURL ?? "Untitled share") { browser.addToShare(targets, share: share) }
                }
            } label: {
                Label("Add to Share Links", systemImage: "rectangle.stack.badge.plus")
            }
        }
    }

    func renameField(_ item: FrameIO.Item) -> some View {
        TextField("", text: $renameText)
            .textFieldStyle(.plain)
            .font(.ui(size: 12))
            .padding(.horizontal, 4)
            .background(RoundedRectangle(cornerRadius: 3).fill(palette.bgMain))
            .focused($renameFocused)
            .onAppear {
                renameText = item.title
                DispatchQueue.main.async { renameFocused = true }
            }
            .onChange(of: renameFocused) { _, focused in
                if !focused { finishRename(item) }
            }
            .onSubmit { renameFocused = false }
    }

    func startRename(_ item: FrameIO.Item) {
        browser.selection = [item.id]
        browser.renamingID = item.id
    }

    /// Return or clicking away renames; Esc cancels (the shortcut router unfocuses the field for both).
    func finishRename(_ item: FrameIO.Item) {
        guard browser.renamingID == item.id else { return }
        browser.renamingID = nil
        let cancelled = NSApp.currentEvent?.type == .keyDown && NSApp.currentEvent?.keyCode == 53
        if !cancelled { browser.rename(item, to: renameText) }
    }

    func copy(_ text: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }

    func targetBinding(_ key: String) -> Binding<Bool> {
        Binding(
            get: { dropTarget == key },
            set: { inside in
                if inside { dropTarget = key } else if dropTarget == key { dropTarget = nil }
            }
        )
    }

    /// A drop on a folder: queue files start uploading there; Frame.io items dragged from this list move there.
    func accept(_ providers: [NSItemProvider], into folder: String, titles: [String]) -> Bool {
        guard browser.accountID != nil else { return false }
        if Self.acceptFinderFiles(providers, into: folder, titles: titles) { return true }
        guard let provider = providers.first(where: { $0.canLoadObject(ofClass: NSString.self) }) else { return false }
        _ = provider.loadObject(ofClass: NSString.self) { object, _ in
            guard let text = object as? String else { return }
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    if text.hasPrefix(UploadQueue.dragPrefix) {
                        Self.startUpload(text, into: folder, titles: titles)
                    } else if text.hasPrefix(FrameIOBrowser.dragPrefix) {
                        let ids = Set(text.dropFirst(FrameIOBrowser.dragPrefix.count).split(separator: "\n").map(String.init))
                        let moving = FrameIOBrowser.shared.items.filter { ids.contains($0.id) }
                        FrameIOBrowser.shared.move(moving, to: folder, titled: titles.last ?? "Frame.io")
                    }
                }
            }
        }
        return true
    }

    /// Files and folders dragged from Finder: they join the app's queue, then upload to `folder` (`uploadFromFinder`).
    /// Checked before the text drags, since Finder also offers file names as text.
    static func acceptFinderFiles(_ providers: [NSItemProvider], into folder: String, titles: [String]) -> Bool {
        let files = providers.filter { $0.hasItemConformingToTypeIdentifier(UTType.fileURL.identifier) }
        guard !files.isEmpty else { return false }
        final class Collector: @unchecked Sendable {
            let lock = NSLock()
            var urls: [URL] = []
        }
        let collector = Collector()
        let group = DispatchGroup()
        for provider in files {
            group.enter()
            _ = provider.loadObject(ofClass: URL.self) { url, _ in
                if let url { collector.lock.withLock { collector.urls.append(url) } }
                group.leave()
            }
        }
        group.notify(queue: .main) {
            MainActor.assumeIsolated {
                let urls = collector.lock.withLock { collector.urls }
                guard !urls.isEmpty, let account = FrameIOBrowser.shared.accountID else { return }
                guard !UploadQueue.shared.isRunning else {
                    FrameIOBrowser.shared.notify("An upload is already running: wait for it to finish or cancel it.", isError: true)
                    return
                }
                UploadQueue.shared.uploadFromFinder(urls, to: .init(account: account, folder: folder, path: titles.joined(separator: " › ")))
            }
        }
        return true
    }

    /// Starts uploading queue files dragged onto a Frame.io folder.
    static func startUpload(_ text: String, into folder: String, titles: [String]) {
        let lines = text.dropFirst(UploadQueue.dragPrefix.count).split(separator: "\n").map(String.init)
        let roots = lines.filter { $0.hasPrefix(UploadQueue.dragRootPrefix) }.map { String($0.dropFirst(UploadQueue.dragRootPrefix.count)) }
        let paths = lines.filter { !$0.hasPrefix(UploadQueue.dragRootPrefix) }
        guard !paths.isEmpty, let account = FrameIOBrowser.shared.accountID else { return }
        guard !UploadQueue.shared.isRunning else {
            FrameIOBrowser.shared.notify("An upload is already running: wait for it to finish or cancel it.", isError: true)
            return
        }
        UploadQueue.shared.start(to: .init(account: account, folder: folder, path: titles.joined(separator: " › ")), paths: Set(paths),
                                  roots: roots.isEmpty ? nil : roots)
    }

    // MARK: Toast

    @ViewBuilder
    var toastView: some View {
        if let toast = browser.toast {
            HStack(spacing: 12) {
                Image(systemName: toast.isError ? "exclamationmark.triangle.fill" : "checkmark.circle.fill")
                    .foregroundColor(toast.isError ? palette.negative : palette.positive)
                Text(toast.message)
                    .font(.ui(size: 12))
                    .foregroundColor(palette.textMain)
                    .lineLimit(2)
                if toast.undo != nil, toast.id == browser.lastUndo?.id {
                    Button("Undo", action: browser.performUndo)
                    .font(.ui(size: 12, weight: .semibold))
                    .buttonStyle(.borderless)
                }
                Button(action: browser.dismissToast) {
                    Image(systemName: "xmark").font(.system(size: StudioTheme.scaleFont(9), weight: .semibold))
                }
                .buttonStyle(.borderless)
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 9)
            .background(RoundedRectangle(cornerRadius: Radius.container).fill(palette.bgPanel).shadow(color: .black.opacity(0.25), radius: 8, y: 2))
            .overlay(RoundedRectangle(cornerRadius: Radius.container).stroke(palette.borderLine))
            .padding(.bottom, 16)
            .padding(.horizontal, 20)
            .transition(.move(edge: .bottom).combined(with: .opacity))
            .id(toast.id)
        }
    }
}
