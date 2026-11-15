import SwiftUI

@main
struct SmartOSFileStoreApp: App {
    /// The activity log, one for the whole app: both windows show it and every cleanup writes to it.
    @State private var activity = ActivityLogModel()

    var body: some Scene {
        Window("Smart OS File Store", id: "main") {
            ContentView()
                .environment(activity)
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

        // A window of its own, which the Window menu lists by itself. The shortcut belongs to that
        // menu item: it opens the window, or brings it forward when it is open.
        Window("Activity", id: ActivityWindow.id) {
            ActivityWindow()
                .environment(activity)
        }
        .defaultSize(width: 760, height: 520)
        .keyboardShortcut("a", modifiers: [.command, .shift])
    }
}
