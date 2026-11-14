import SwiftUI

extension FocusedValues {
    /// Where the frontmost window's selected rows were downloaded from, for Copy Download Source.
    @Entry var selectedDownloadAddresses: [String]?

    /// The frontmost window's filter, for the View menu.
    @Entry var fileListFilter: Binding<FileListFilter>?
}

/// Edit menu: Copy Download Source, enabled while a selected row has a download address. The table's
/// context menu has the same command; the menu bar makes it reachable from the keyboard.
struct CopyDownloadSourceCommands: Commands {
    @FocusedValue(\.selectedDownloadAddresses) private var addresses

    var body: some Commands {
        CommandGroup(after: .pasteboard) {
            Button("Copy Download Source") {
                Clipboard.copy((addresses ?? []).joined(separator: "\n"))
            }
            .disabled(addresses?.isEmpty ?? true)
        }
    }
}

/// View menu: the filter's choices, so the filter can be changed from the keyboard too.
struct FilterCommands: Commands {
    @FocusedValue(\.fileListFilter) private var filter

    var body: some Commands {
        CommandGroup(before: .toolbar) {
            Picker("Filter", selection: filter ?? .constant(.all)) {
                ForEach(FileListFilter.options) { option in
                    Text(option.title)
                        .tag(option)
                }
            }
            .pickerStyle(.inline)
            .disabled(filter == nil)
            Divider()
        }
    }
}
