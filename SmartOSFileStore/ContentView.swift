import FileStoreCore
import SwiftUI

/// The main window: the file table with its toolbar and status line, or the loading, empty and
/// error states in its place.
struct ContentView: View {
    @State private var model = FileListModel()
    @State private var selection: Set<FileRecord.ID> = []

    var body: some View {
        VStack(spacing: 0) {
            content
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            Divider()
            StatusBar(model: model)
        }
        // Wide enough for all five columns at their ideal widths, so the table never has to
        // scroll sideways in a window the user has not resized.
        .frame(minWidth: 840, minHeight: 400)
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button {
                    model.refresh()
                } label: {
                    Label("Refresh", systemImage: "arrow.clockwise")
                }
                .keyboardShortcut("r", modifiers: .command)
                .help("Refresh the list (⌘R)")
                .disabled(!model.canRefresh)
            }
        }
        .focusedSceneValue(\.selectedFileURLs, Array(selection))
        .onAppear {
            model.refresh()
        }
        .onChange(of: model.scanGeneration) {
            // The listing was replaced: drop selected rows that are gone, so menu commands never
            // act on files that are no longer listed, and forget per-file icons.
            selection = selection.intersection(Set(model.records.map(\.id)))
            FileIconCache.shared.removeAll()
        }
    }

    @ViewBuilder
    private var content: some View {
        if let failure = model.failure {
            ScanErrorView(failure: failure, retry: model.canRefresh ? model.refresh : nil)
        } else if !model.hasLoadedOnce {
            ProgressView("Loading…")
                .controlSize(.large)
        } else if model.isEmpty {
            ContentUnavailableView(
                "Folder Is Empty",
                systemImage: "folder",
                description: Text("There are no files in this folder.")
            )
        } else {
            FileTableView(model: model, selection: $selection)
        }
    }
}
