import FileStoreCore
import SwiftUI

/// The one question before a Tidy Now changes anything: the counts per operation. As for any
/// cleanup that goes to the Trash, Cancel is the default button, so Return and Escape both decline;
/// only a click on Tidy Up, or Command-Delete, goes ahead (`CleanupConfirmationSheet`).
struct TidyNowConfirmationSheet: View {
    let totals: TidyNowTotals
    let onConfirm: @MainActor () -> Void

    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(spacing: Design.Space.l) {
            Image(systemName: "checklist")
                .font(Design.Icon.large)
                .imageScale(.large)
                .foregroundStyle(.secondary)
                .accessibilityHidden(true)
            Text("\(totals.sentence)?")
                .font(Design.Typography.sectionTitle)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
            Text("One Undo puts everything back.")
                .foregroundStyle(.secondary)
            HStack(spacing: Design.Space.m) {
                Spacer()
                Button(role: .destructive) {
                    dismiss()
                    onConfirm()
                } label: {
                    Text("Tidy up")
                }
                .keyboardShortcut(.delete, modifiers: .command)
                .help(Text("Carry out everything ticked (⌘⌫)"))
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

/// What a Tidy Now did, per action: how many changes were made, left alone and failed, and the
/// space moved to the Trash, with every file left alone and why.
struct TidyNowSummaryView: View {
    let result: TidyNowResult

    var body: some View {
        List {
            if result.wasCancelled {
                Text("Stopped before every change was tried.")
                    .foregroundStyle(.secondary)
            }
            if result.logFailure != nil {
                Label("The activity log stopped working, so the tidy stopped. Nothing after that was changed.", systemImage: "exclamationmark.triangle")
                    .foregroundStyle(.secondary)
            }
            ForEach(result.results, id: \.action) { item in
                Section(item.action.title) {
                    let done = item.items.filter(\.isDone).count
                    VStack(alignment: .leading, spacing: Design.Space.tight) {
                        Text("\(done) done, \(item.skipped.count) skipped, \(item.failed.count) failed")
                        if item.bytesFreed > 0 {
                            Text("\(item.bytesFreed.formattedFileSize) moved to the Trash")
                                .foregroundStyle(.secondary)
                        }
                    }
                    .accessibilityElement(children: .combine)
                    ForEach(item.leftAlone) { left in
                        NotMovedRow(item: left, action: item.action)
                    }
                }
            }
        }
    }
}
