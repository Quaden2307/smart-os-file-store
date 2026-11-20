import SwiftUI

/// The question before the Kept list is emptied. As with Move to Trash, Cancel is the default
/// button, so Return and Escape both decline: the marks would be gone, and nothing brings them
/// back. Only a click on Stop Keeping All, or Command-Delete, goes ahead.
struct StopKeepingAllSheet: View {
    let itemCount: Int
    let onConfirm: @MainActor () -> Void

    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(spacing: Design.Space.l) {
            Image(systemName: "pin.slash")
                .font(Design.Icon.large)
                .imageScale(.large)
                .foregroundStyle(.secondary)
                .accessibilityHidden(true)
            VStack(spacing: Design.Space.s) {
                Text("Stop keeping all ^[\(itemCount) Kept item](inflect: true)?")
                    .font(Design.Typography.sectionTitle)
                Text("Cleanup actions can then propose changes to them again.")
                    .foregroundStyle(.secondary)
            }
            .multilineTextAlignment(.center)
            .fixedSize(horizontal: false, vertical: true)
            HStack(spacing: Design.Space.m) {
                Spacer()
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
        }
        .padding(Design.Space.xl)
        .frame(width: Design.Size.confirmationSheet)
        .onExitCommand {
            dismiss()
        }
    }
}
