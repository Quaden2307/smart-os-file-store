import SwiftUI

@main
struct SmartOSFileStoreApp: App {
    var body: some Scene {
        Window("Smart OS File Store", id: "main") {
            ContentView()
        }
        .defaultSize(width: 1_140, height: 640)
        .commands {
            RevealInFinderCommands()
            CopyDownloadSourceCommands()
            FilterCommands()
            #if DEBUG
            DebugCommands()
            #endif
        }
    }
}
