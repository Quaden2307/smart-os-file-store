import SwiftUI

/// The question before the Kept list is emptied. As with Move to Trash, Cancel is the default
/// button, so Return and Escape both decline: the marks would be gone, and nothing brings them
/// back. Only a click on Stop Keeping All, or Command-Delete, goes ahead.
struct StopKeepingAllSheet: View {
    let itemCount: Int
    let onConfirm: @MainActor () -> Void

    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(spacing: 16) {
            Image(systemName: "pin.slash")
                .font(.largeTitle)
                .imageScale(.large)
                .foregroundStyle(.secondary)
                .accessibilityHidden(true)
            VStack(spacing: 6) {
                Text("Stop keeping all ^[\(itemCount) Kept item](inflect: true)?")
                    .font(.headline)
                Text("Cleanup actions can then propose changes to them again.")
                    .foregroundStyle(.secondary)
            }
            .multilineTextAlignment(.center)
            .fixedSize(horizontal: false, vertical: true)
            HStack(spacing: 12) {
                Spacer()
                Button("Stop Keeping All", role: .destructive) {
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
        }
        .padding(20)
        .frame(width: 380)
        .onExitCommand {
            dismiss()
        }
    }
}
