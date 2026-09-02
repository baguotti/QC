import SwiftUI
import AppKit

@main
struct LineFinder5000App: App {
    init() {
        NSColorPanel.setPickerMask(.wheelModeMask)
        NSColorPanel.setPickerMode(.wheel)
    }
    
    var body: some Scene {
        WindowGroup("THE LINEFINDER 5000") {
            ContentView()
        }
        .windowStyle(.titleBar)
        .windowToolbarStyle(.unified)
        .commands {
            SidebarCommands()
        }
    }
}
