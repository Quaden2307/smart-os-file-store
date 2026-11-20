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
        SheetScaffold(title: question, subtitle: explanation, size: .small) {
            Card {
                TidyNowFigures(totals: totals)
            }
            .padding(Design.Space.l)
        } buttons: {
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
        .onExitCommand {
            dismiss()
        }
    }

    /// The counts as a Tidy Now's are given, so every confirmation shows the same figures.
    private var totals: TidyNowTotals {
        var totals = TidyNowTotals([])
        switch operation {
        case .rename:
            totals.renameCount = fileCount
        case .archive:
            totals.archiveCount = fileCount - trashCount
            totals.trashCount = trashCount
            totals.trashBytes = trashBytes
        case .moveToTrash, .move:
            totals.trashCount = fileCount
            totals.trashBytes = bytes
        }
        return totals
    }

    /// The question in a few words. The numbers are the card's figures.
    private var question: Text {
        switch operation {
        case .rename:
            Text("Rename what is ticked?")
        case .archive where trashCount == fileCount:
            Text("Move what is ticked to the Trash?")
        case .archive:
            Text("Archive what is ticked?")
        case .moveToTrash, .move:
            Text("Move what is ticked to the Trash?")
        }
    }

    private var explanation: Text {
        switch operation {
        case .rename:
            Text("Each file gets the name shown in the preview. Undo gives back every old name.")
        case .archive where trashCount == fileCount:
            Text("Old downloads already holds an identical copy of each. Undo puts everything back.")
        case .archive where trashCount > 0:
            Text("What is ticked moves into Old downloads; where it already holds an identical copy, the file goes to the Trash. Undo puts everything back.")
        case .archive:
            Text("What is ticked moves into Old downloads. Undo puts everything back.")
        case .moveToTrash, .move:
            Text("Everything stays in the Trash until you empty it. Undo puts everything back.")
        }
    }
}
