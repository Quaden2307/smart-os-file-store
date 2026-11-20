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
        SheetScaffold(
            title: Text("Tidy up this folder?"),
            subtitle: Text("Everything ticked is carried out. One Undo puts it all back."),
            size: .small
        ) {
            Card {
                TidyNowFigures(totals: totals)
            }
            .padding(Design.Space.l)
        } buttons: {
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
        .onExitCommand {
            dismiss()
        }
    }
}

/// What the ticked changes of a Tidy Now come to, as a card's numbers.
struct TidyNowFigures: View {
    let totals: TidyNowTotals

    var body: some View {
        CardFigures {
            if totals.trashCount > 0 {
                CardFigure(value: Text("\(totals.trashCount)"), label: Text("to the Trash"))
                CardFigure(value: Text(totals.trashBytes.formattedFileSize), label: Text("to free"))
            }
            if totals.archiveCount > 0 {
                CardFigure(value: Text("\(totals.archiveCount)"), label: Text("to archive"))
            }
            if totals.renameCount > 0 {
                CardFigure(value: Text("\(totals.renameCount)"), label: Text("to rename"))
            }
        }
    }
}

/// What a Tidy Now came to, as a card's numbers.
struct TidyNowResultFigures: View {
    let result: TidyNowResult

    var body: some View {
        let done = result.results.reduce(0) { $0 + $1.items.filter(\.isDone).count }
        let leftAlone = result.results.reduce(0) { $0 + $1.leftAlone.count }
        CardFigures {
            CardFigure(value: Text("\(done)"), label: Text("changed"))
            if leftAlone > 0 {
                CardFigure(value: Text("\(leftAlone)"), label: Text("left alone"))
            }
            if result.bytesFreed > 0 {
                CardFigure(value: Text(result.bytesFreed.formattedFileSize), label: Text("moved to the Trash"))
            }
        }
    }
}

/// Why a Tidy Now ended early, when it did.
struct TidyNowResultNotes: View {
    let result: TidyNowResult

    var body: some View {
        if result.wasCancelled {
            Text("Stopped before every change was tried.")
                .foregroundStyle(.secondary)
        }
        if result.logFailure != nil {
            Label("The activity log stopped working, so the cleanup stopped. Nothing after that was changed.", systemImage: "exclamationmark.triangle")
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}

/// What a Tidy Now did, per action: how many changes were made, left alone and failed, and the
/// space moved to the Trash, with every file left alone and why.
struct TidyNowSummaryView: View {
    let result: TidyNowResult

    var body: some View {
        VStack(spacing: 0) {
            Card {
                TidyNowResultFigures(result: result)
                TidyNowResultNotes(result: result)
            }
            .padding([.horizontal, .top], Design.Space.l)
            list
        }
    }

    private var list: some View {
        List {
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
