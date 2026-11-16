import FileStoreCore
import SwiftUI

/// The question before anything changes. A sheet of its own rather than an alert, because neither
/// SwiftUI's alert nor NSAlert lets one button answer both Return and Escape on macOS 26.
///
/// For the Trash, Cancel is the default button, so Return and Escape both decline; only a click on
/// Move to Trash, or Command-Delete, goes ahead. For a rename, which replaces nothing and Undo
/// reverses, Rename is the default button and Escape declines.
struct CleanupConfirmationSheet: View {
    let operation: CleanupActionDefinition.OperationKind
    let fileCount: Int
    let bytes: Int64
    let onConfirm: @MainActor () -> Void

    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(spacing: 16) {
            Image(systemName: operation == .rename ? "pencil" : "trash")
                .font(.largeTitle)
                .imageScale(.large)
                .foregroundStyle(.secondary)
                .accessibilityHidden(true)
            Group {
                if operation == .rename {
                    Text("Rename ^[\(fileCount) file](inflect: true)?")
                } else {
                    Text("Move ^[\(fileCount) file](inflect: true) (\(bytes.formattedFileSize)) to the Trash?")
                }
            }
            .font(.headline)
            .multilineTextAlignment(.center)
            .fixedSize(horizontal: false, vertical: true)
            HStack(spacing: 12) {
                Spacer()
                if operation == .rename {
                    Button("Cancel", role: .cancel) {
                        dismiss()
                    }
                    .keyboardShortcut(.cancelAction)
                    Button("Rename") {
                        dismiss()
                        onConfirm()
                    }
                    .keyboardShortcut(.defaultAction)
                    .help("Give the files their new names (Return)")
                } else {
                    // Finder's own shortcut for Move to Trash, so the keyboard has a way to confirm
                    // without Return ever doing it.
                    Button("Move to Trash", role: .destructive) {
                        dismiss()
                        onConfirm()
                    }
                    .keyboardShortcut(.delete, modifiers: .command)
                    .help("Move the files to the Trash (⌘⌫)")
                    Button("Cancel", role: .cancel) {
                        dismiss()
                    }
                    .keyboardShortcut(.defaultAction)
                }
            }
        }
        .padding(20)
        .frame(width: 380)
        .onExitCommand {
            dismiss()
        }
    }
}
