import FileStoreCore
import SwiftUI

/// The question before anything changes. A sheet of its own rather than an alert, because neither
/// SwiftUI's alert nor NSAlert lets one button answer both Return and Escape on macOS 26.
///
/// For the Trash, Cancel is the default button, so Return and Escape both decline; only a click on
/// Move to Trash, or Command-Delete, goes ahead. For a rename or an archive that trashes nothing,
/// which replace nothing and Undo reverses, the action's button is the default and Escape declines.
struct CleanupConfirmationSheet: View {
    let operation: CleanupActionDefinition.OperationKind
    let fileCount: Int
    let bytes: Int64
    /// For Archive Old Downloads: how many of the files go to the Trash, since the archive already
    /// has an identical copy.
    var trashCount = 0
    /// Their size.
    var trashBytes: Int64 = 0
    let onConfirm: @MainActor () -> Void

    @Environment(\.dismiss) private var dismiss

    /// A rename, or an archive that trashes nothing, replaces nothing and Undo reverses it: its
    /// button answers Return. Anything that goes to the Trash keeps Cancel as the default.
    private var confirmIsDefault: Bool {
        operation == .rename || (operation == .archive && trashCount == 0)
    }

    var body: some View {
        VStack(spacing: Design.Space.l) {
            Image(systemName: symbol)
                .font(Design.Icon.large)
                .imageScale(.large)
                .foregroundStyle(.secondary)
                .accessibilityHidden(true)
            Group {
                switch operation {
                case .rename:
                    Text("Rename ^[\(fileCount) file](inflect: true)?")
                case .archive where trashCount == fileCount:
                    Text("Move ^[\(trashCount) identical copy](inflect: true) (\(trashBytes.formattedFileSize)) to the Trash? Old downloads already holds them.")
                case .archive where trashCount > 0:
                    Text("Move ^[\(fileCount - trashCount) file](inflect: true) into Old downloads, and ^[\(trashCount) identical copy](inflect: true) (\(trashBytes.formattedFileSize)) to the Trash?")
                case .archive:
                    Text("Move ^[\(fileCount) file](inflect: true) into Old downloads?")
                case .moveToTrash, .move:
                    Text("Move ^[\(fileCount) file](inflect: true) (\(bytes.formattedFileSize)) to the Trash?")
                }
            }
            .font(Design.Typography.sectionTitle)
            .multilineTextAlignment(.center)
            .fixedSize(horizontal: false, vertical: true)
            HStack(spacing: Design.Space.m) {
                Spacer()
                if confirmIsDefault {
                    Button("Cancel", role: .cancel) {
                        dismiss()
                    }
                    .keyboardShortcut(.cancelAction)
                    Button {
                        dismiss()
                        onConfirm()
                    } label: {
                        operation == .rename ? Text("Rename") : Text("Archive")
                    }
                    .keyboardShortcut(.defaultAction)
                    .help(operation == .rename ? Text("Give the files their new names (Return)") : Text("Move the files into Old downloads (Return)"))
                } else {
                    // Finder's own shortcut for Move to Trash, so the keyboard has a way to confirm
                    // without Return ever doing it.
                    Button(role: .destructive) {
                        dismiss()
                        onConfirm()
                    } label: {
                        operation == .archive ? Text("Archive") : Text("Move to Trash")
                    }
                    .keyboardShortcut(.delete, modifiers: .command)
                    .help(operation == .archive ? Text("Archive the files, and move the identical copies to the Trash (⌘⌫)") : Text("Move the files to the Trash (⌘⌫)"))
                    Button("Cancel", role: .cancel) {
                        dismiss()
                    }
                    .keyboardShortcut(.defaultAction)
                }
            }
        }
        .padding(Design.Space.xl)
        .frame(width: Design.Size.confirmationSheet)
        .onExitCommand {
            dismiss()
        }
    }

    private var symbol: String {
        switch operation {
        case .rename:
            "pencil"
        case .archive:
            "archivebox"
        case .moveToTrash, .move:
            "trash"
        }
    }
}
