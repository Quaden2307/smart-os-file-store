import SwiftUI

@main
struct SmartOSFileStoreApp: App {
    /// The activity log, one for the whole app: every cleanup writes to it and Activity shows it.
    @State private var activity = ActivityLogModel()

    init() {
        // Debug builds only, with -SnapshotTo: the window drawn off screen for a check of its look.
        if DebugSnapshot.snapshotName != nil {
            let activity = ActivityLogModel()
            _activity = State(initialValue: activity)
            DebugSnapshot.renderOffscreen(ContentView().environment(activity))
        }
    }

    var body: some Scene {
        Window("Smart OS File Store", id: "main") {
            ContentView()
                .environment(activity)
        }
        // The six columns at their ideal widths, plus the sidebar. The system keeps the size and the
        // sidebar's width the user leaves it at.
        .defaultSize(width: 1_280, height: 720)
        .commands {
            AboutCommands()
            UndoCommands()
            RevealInFinderCommands()
            KeepCommands()
            CleanUpCommands()
            CopyDownloadSourceCommands()
            FilterCommands()
            ChatCommands()
            // View > Show/Hide Sidebar, so the toolbar's sidebar button has a menu item and a shortcut.
            SidebarCommands()
            PlaceCommands()
        }

        // App menu > Settings… (⌘,).
        Settings {
            SettingsView()
                .environment(activity)
        }
    }
}
