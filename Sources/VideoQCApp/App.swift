import SwiftUI
import AppKit
import VideoQCLib

final class AppDelegate: NSObject, NSApplicationDelegate {
    private var didFinishInitialLaunch: Bool = false
    
    func application(_ application: NSApplication, open urls: [URL]) {
        let isInitial = !didFinishInitialLaunch
        FileOpenManager.shared.handleOpenedFiles(urls, isInitialLaunch: isInitial)
    }
    
    func applicationDidFinishLaunching(_ notification: Notification) {
        Log.app.notice("QCpie \(AppVersionInfo.version) started, macOS \(ProcessInfo.processInfo.operatingSystemVersionString)")
        let args = CommandLine.arguments.dropFirst()
        let urls = args.compactMap { arg -> URL? in
            guard !arg.starts(with: "-") else { return nil }
            let url = URL(fileURLWithPath: arg)
            return FileManager.default.fileExists(atPath: url.path) ? url : nil
        }
        if !urls.isEmpty {
            FileOpenManager.shared.handleOpenedFiles(urls, isInitialLaunch: true)
        }
        
        DispatchQueue.main.async {
            self.didFinishInitialLaunch = true
            FileOpenManager.shared.isAppAlreadyRunning = true
        }
    }
    
    /// Set once the quit questions were answered for an update's relaunch: quitting then asks nothing again.
    @MainActor static var quitConfirmed = false

    func applicationWillTerminate(_ notification: Notification) {
        MainActor.assumeIsolated { UpdateManager.shared.installStagedUpdateOnQuit() }
    }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        if Self.quitConfirmed { return .terminateNow }
        guard let stopTransfers = Self.askToQuit() else { return .terminateCancel }
        guard stopTransfers else { return .terminateNow }
        Self.stopTransfers { sender.reply(toApplicationShouldTerminate: true) }
        return .terminateLater
    }

    /// The quit questions: unsaved subtitle edits, a running check, transfers. Nil when the user chose to stay; true
    /// when uploads or downloads must stop first (`stopTransfers`). Also asked before an update quits QCpie.
    @MainActor static func askToQuit() -> Bool? {
        // Subtitle edits live in memory until saved: quitting dropped them without a word.
        let unsaved = PlayerEngine.unsavedSubtitleFileNames
        if !unsaved.isEmpty {
            let alert = NSAlert()
            alert.messageText = unsaved.count == 1 ? "“\(unsaved[0])” has unsaved subtitle edits."
                : "\(unsaved.count) subtitle files have unsaved edits."
            alert.informativeText = "Quitting now loses them. Save them from the Player's Subtitles panel first."
            alert.addButton(withTitle: "Cancel")
            alert.addButton(withTitle: "Quit Without Saving")
            guard alert.runModal() == .alertSecondButtonReturn else { return nil }
        }
        // A running check's results are only in memory: an hour's Line Check went with a stray ⌘Q.
        if let check = ScannerState.main?.runningCheckName {
            let alert = NSAlert()
            alert.messageText = "\(check) is still running."
            alert.informativeText = "Quitting now stops it, and its results so far are lost."
            alert.addButton(withTitle: "Keep Checking")
            alert.addButton(withTitle: "Stop and Quit")
            guard alert.runModal() == .alertSecondButtonReturn else { return nil }
        }
        let uploading = UploadQueue.shared.isRunning
        // Paused downloads count: their partial files are removed on quit (downloads don't resume across launches).
        let downloading = DownloadQueue.shared.isRunning || DownloadQueue.shared.isPaused
        guard uploading || downloading else { return false }
        let alert = NSAlert()
        switch (uploading, downloading) {
        case (true, true):
            alert.messageText = "Uploads and downloads are still running."
            alert.informativeText = "Uploads pause and can be resumed from the Upload tab when you open QCpie again. Unfinished downloads stop and need to be downloaded again."
        case (true, false):
            alert.messageText = "Uploads to Frame.io are still running."
            alert.informativeText = "QCpie will pause them and save where they got to. Resume them from the Upload tab when you open QCpie again."
        default:
            alert.messageText = "Downloads from Frame.io are still running."
            alert.informativeText = "Unfinished downloads stop and need to be downloaded again."
        }
        alert.addButton(withTitle: uploading ? "Keep Uploading" : "Keep Downloading")
        alert.addButton(withTitle: uploading ? "Pause and Quit" : "Stop and Quit")
        guard alert.runModal() == .alertSecondButtonReturn else { return nil }
        return true
    }

    /// Both stop (uploads save their progress, downloads remove their partial files), then `done`.
    @MainActor static func stopTransfers(_ done: @escaping () -> Void) {
        var waiting = 2
        let stopped = { waiting -= 1; if waiting == 0 { done() } }
        UploadQueue.shared.pauseForQuit(stopped)
        DownloadQueue.shared.stopForQuit(stopped)
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        true
    }
}

/// Started from `main.swift` (after the worker-mode check).
struct QCpieApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var appDelegate
    
    init() {
        ProVideoFormats.register()
        // The plan window sets this again when it actually opens (restored or not); a stale true hid the drawer.
        UserDefaults.standard.set(false, forKey: DeliveryPlanWindow.poppedOutKey)
        UserDefaults.standard.set(false, forKey: InspectPreviewWindow.poppedOutKey)
        NSApplication.shared.setActivationPolicy(.regular)
        NSApplication.shared.activate(ignoringOtherApps: true)

        NSColorPanel.setPickerMask(.wheelModeMask)
        NSColorPanel.setPickerMode(.wheel)
        
        // Ensure List View is the high-performance default for both tabs
        if UserDefaults.standard.object(forKey: "hasSetDefaultListViewV2") == nil {
            UserDefaults.standard.set("inline", forKey: "queueDisplayMode")
            UserDefaults.standard.set("inline", forKey: "specsDisplayMode")
            UserDefaults.standard.set(true, forKey: "hasSetDefaultListViewV2")
        }
        UserDefaults.standard.register(defaults: [
            "queueDisplayMode": "inline",
            "specsDisplayMode": "inline",
            "uploadQueueOpen": true   // the Upload tab's Assets & Queue panel (⌘⇧← reads it as a plain bool)
        ].merging(Notifier.registeredDefaults) { a, _ in a })
        Notifier.shared.start()
    }
    
    var body: some Scene {
        Window("QCpie", id: "main") {
            ContentView()
                .onOpenURL { url in
                    FileOpenManager.shared.handleOpenedFiles([url])
                }
        }
        .windowStyle(.hiddenTitleBar)
        .windowToolbarStyle(.unified)
        .commands {
            SidebarCommands()
            CommandGroup(replacing: .appSettings) {
                Button("Settings…") { NotificationCenter.default.post(name: UserSettingsModalView.toggle, object: nil) }
                    .keyboardShortcut(",", modifiers: .command)
            }
            CommandGroup(after: .appInfo) {
                Button("Check for Updates...") {
                    UpdateManager.shared.checkForUpdates(userInitiated: true)
                }
            }
            CommandMenu("View") {
                OpenDeliveryPlanButton()
                Divider()
                Button("Increase Button Size") {
                    _ = ThemeManager.shared.increaseButtonZoom()
                }
                .keyboardShortcut("+", modifiers: .command)
                
                Button("Decrease Button Size") {
                    _ = ThemeManager.shared.decreaseButtonZoom()
                }
                .keyboardShortcut("-", modifiers: .command)
            }
        }

        // Popped-out Delivery Plan (Inspect drawer ⇄ its own window, any screen; SwiftUI remembers its frame).
        // Declared after the main window: SwiftUI opens the first `Window` scene at launch.
        Window("Delivery Plan", id: DeliveryPlanWindow.id) {
            DeliveryPlanWindow()
        }
        .defaultSize(width: 560, height: 780)

        // Popped-out Inspect preview.
        Window("Preview", id: InspectPreviewWindow.id) {
            InspectPreviewWindow()
        }
        .defaultSize(width: 640, height: 420)
    }
}

/// View → Delivery Plan Window.
private struct OpenDeliveryPlanButton: View {
    @Environment(\.openWindow) private var openWindow
    var body: some View {
        Button("Delivery Plan Window") { openWindow(id: DeliveryPlanWindow.id) }
            .keyboardShortcut("d", modifiers: [.command, .option])
    }
}
