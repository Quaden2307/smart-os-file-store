import SwiftUI

@main
struct SmartOSFileStoreApp: App {
    /// The activity log, one for the whole app: every cleanup writes to it and Activity shows it.
    @State private var activity = ActivityLogModel()

    var body: some Scene {
        Window("Smart OS File Store", id: "main") {
            ContentView()
                .environment(activity)
        }
        // The six columns at their ideal widths, plus the sidebar.
        .defaultSize(width: 1_320, height: 640)
        .commands {
            UndoCommands()
            RevealInFinderCommands()
            KeepCommands()
            CopyDownloadSourceCommands()
            FilterCommands()
            // View > Show/Hide Sidebar, so the toolbar's sidebar button has a menu item and a shortcut.
            SidebarCommands()
            PlaceCommands()
            #if DEBUG
            DebugCommands()
            #endif
        }
    }
}
