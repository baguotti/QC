import SwiftUI
import AppKit

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
    
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        true
    }
}

@main
struct QCpieApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var appDelegate
    
    init() {
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
            "specsDisplayMode": "inline"
        ])
    }
    
    var body: some Scene {
        Window("QCpie", id: "main") {
            ContentView()
                .onOpenURL { url in
                    FileOpenManager.shared.handleOpenedFiles([url])
                }
        }
        .windowStyle(.titleBar)
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
