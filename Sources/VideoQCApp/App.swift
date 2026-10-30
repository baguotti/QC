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
    
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        let uploading = UploadQueue.shared.isRunning
        // Paused downloads count: their partial files are removed on quit (downloads don't resume across launches).
        let downloading = DownloadQueue.shared.isRunning || DownloadQueue.shared.isPaused
        guard uploading || downloading else { return .terminateNow }
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
        guard alert.runModal() == .alertSecondButtonReturn else { return .terminateCancel }
        // Both stop (uploads save their progress, downloads remove their partial files), then the app quits.
        var waiting = 2
        let stopped = { waiting -= 1; if waiting == 0 { sender.reply(toApplicationShouldTerminate: true) } }
        UploadQueue.shared.pauseForQuit(stopped)
        DownloadQueue.shared.stopForQuit(stopped)
        return .terminateLater
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        true
    }
}

@main
struct QCpieApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var appDelegate
    
    init() {
        ProVideoFormats.register()
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
        ])
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
            CommandGroup(after: .appInfo) {
                Button("Check for Updates...") {
                    UpdateManager.shared.checkForUpdates(userInitiated: true)
                }
            }
            CommandMenu("View") {
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
    }
}
