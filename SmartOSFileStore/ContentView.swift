import SwiftUI

/// Placeholder for the main window. The file list arrives in the next segment.
struct ContentView: View {
    var body: some View {
        ContentUnavailableView(
            "No Files Yet",
            systemImage: "folder",
            description: Text("Files in your Downloads folder will appear here.")
        )
    }
}
