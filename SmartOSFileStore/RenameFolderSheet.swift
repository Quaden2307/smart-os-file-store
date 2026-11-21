import SwiftUI

/// Rename… on a folder the user added: its name in the app only. The folder on disk keeps its own.
struct RenameFolderSheet: View {
    @State var name: String
    let onRename: @MainActor (String) -> Void

    @Environment(\.dismiss) private var dismiss

    private var trimmed: String { name.trimmingCharacters(in: .whitespacesAndNewlines) }

    var body: some View {
        SheetScaffold(
            title: Text("Rename folder"),
            subtitle: Text("This changes its name in Smart OS File Store only. The folder on disk keeps its name."),
            size: .small
        ) {
            TextField("Name", text: $name)
                .textFieldStyle(.roundedBorder)
                .accessibilityLabel("Folder name")
                .padding(Design.Space.l)
        } buttons: {
            Button("Cancel", role: .cancel) {
                dismiss()
            }
            .keyboardShortcut(.cancelAction)
            Button("Rename") {
                onRename(trimmed)
                dismiss()
            }
            .keyboardShortcut(.defaultAction)
            .disabled(trimmed.isEmpty)
        }
    }
}
