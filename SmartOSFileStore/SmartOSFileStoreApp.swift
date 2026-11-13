import SwiftUI

@main
struct SmartOSFileStoreApp: App {
    var body: some Scene {
        Window("Smart OS File Store", id: "main") {
            ContentView()
        }
        .defaultSize(width: 960, height: 600)
        .commands {
            RevealInFinderCommands()
        }
    }
}
