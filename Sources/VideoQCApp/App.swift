import SwiftUI
import AppKit

@main
struct QCpieApp: App {
    init() {
        NSColorPanel.setPickerMask(.wheelModeMask)
        NSColorPanel.setPickerMode(.wheel)
    }
    
    var body: some Scene {
        WindowGroup("QCpie") {
            ContentView()
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
        }
    }
}
