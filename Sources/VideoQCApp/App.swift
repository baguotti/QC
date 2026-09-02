import SwiftUI

@main
struct LineFinder5000App: App {
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
