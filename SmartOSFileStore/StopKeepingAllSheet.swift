import SwiftUI

/// The question before the Kept list is emptied. As with Move to Trash, Cancel is the default
/// button, so Return and Escape both decline: the marks would be gone, and nothing brings them
/// back. Only a click on Stop Keeping All, or Command-Delete, goes ahead.
struct StopKeepingAllSheet: View {
    let itemCount: Int
    let onConfirm: @MainActor () -> Void

    @Environment(\.dismiss) private var dismiss

    var body: some View {
        SheetScaffold(
            title: Text("Stop keeping all ^[\(itemCount) Kept item](inflect: true)?"),
            subtitle: Text("Cleanups can then propose changes to them again."),
            size: .small
        ) {
        } buttons: {
            Button("Stop keeping all", role: .destructive) {
                dismiss()
                onConfirm()
            }
            .keyboardShortcut(.delete, modifiers: .command)
            .help("Remove the Kept mark from every item (⌘⌫)")
            Button("Cancel", role: .cancel) {
                dismiss()
            }
            .keyboardShortcut(.defaultAction)
        }
        .onExitCommand {
            dismiss()
        }
    }
}
