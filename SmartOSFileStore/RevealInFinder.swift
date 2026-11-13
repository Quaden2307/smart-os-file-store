import AppKit
import SwiftUI

enum RevealInFinder {
    /// Opens Finder with `urls` selected. Does nothing for an empty list.
    @MainActor
    static func reveal(_ urls: [URL]) {
        guard !urls.isEmpty else { return }
        NSWorkspace.shared.activateFileViewerSelecting(urls)
    }
}

extension FocusedValues {
    /// The URLs selected in the frontmost window's table, for menu commands.
    @Entry var selectedFileURLs: [URL]?
}

/// File menu: Reveal in Finder (Command-Option-R), enabled while rows are selected.
struct RevealInFinderCommands: Commands {
    @FocusedValue(\.selectedFileURLs) private var selectedFileURLs

    var body: some Commands {
        CommandGroup(after: .newItem) {
            Button("Reveal in Finder") {
                RevealInFinder.reveal(selectedFileURLs ?? [])
            }
            .keyboardShortcut("r", modifiers: [.command, .option])
            .disabled(selectedFileURLs?.isEmpty ?? true)
        }
    }
}
