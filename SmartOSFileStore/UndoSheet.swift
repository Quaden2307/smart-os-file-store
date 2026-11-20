import FileStoreCore
import SwiftUI

/// One undo, from the question to the summary. When more than one file would move it asks first,
/// with the count; Undo is the default button, since undo only puts files back and never replaces
/// anything, and Escape cancels. Then it shows the progress, and at the end what was put back and
/// what could not be, with the reason for each.
struct UndoSheet: View {
    let model: UndoModel

    var body: some View {
        VStack(spacing: 0) {
            switch model.phase {
            case .confirming(let plan):
                UndoQuestion(plan: plan, confirm: model.confirm, cancel: model.dismiss)
            case .executing(let plan, let progress):
                UndoProgressView(plan: plan, progress: progress, stop: model.stop)
            case .finished(let result):
                UndoSummaryView(result: result, done: model.dismiss)
            case nil:
                EmptyView()
            }
        }
        .interactiveDismissDisabled(model.isExecuting)
        .onExitCommand {
            // Escape declines the question or closes the summary, never while files are moving.
            model.dismiss()
        }
    }
}

/// "Undo Find Duplicates?", with how many files would be put back and which could not be.
private struct UndoQuestion: View {
    let plan: UndoPlan
    let confirm: @MainActor () -> Void
    let cancel: @MainActor () -> Void

    var body: some View {
        SheetScaffold(
            title: Text("\(plan.title)?"),
            subtitle: plan.refused.isEmpty
                ? Text("Every file goes back where it was. Nothing is replaced.")
                : Text("What can be put back goes where it was. Nothing is replaced."),
            size: .small
        ) {
            VStack(spacing: 0) {
                Card {
                    CardFigures {
                        CardFigure(value: Text("\(plan.steps.count)"), label: Text("to put back"))
                        if !plan.refused.isEmpty {
                            CardFigure(value: Text("\(plan.refused.count)"), label: Text("can’t be put back"))
                        }
                    }
                }
                .padding(Design.Space.l)
                if !plan.refused.isEmpty {
                    List(plan.refused) { refused in
                        UndoFileRow(
                            name: refused.change.displayName,
                            detail: refused.refusal.localizedDescription(for: refused.change.undoOperation)
                        )
                    }
                    .frame(minHeight: 80, maxHeight: 180)
                    .accessibilityLabel("Files that can’t be put back")
                }
            }
        } buttons: {
            Button("Cancel", role: .cancel) {
                cancel()
            }
            .keyboardShortcut(.cancelAction)
            Button("Undo") {
                confirm()
            }
            .keyboardShortcut(.defaultAction)
            .help("Put the files back where they were (Return)")
        }
    }
}

/// The move back under way, with a Stop button.
private struct UndoProgressView: View {
    let plan: UndoPlan
    let progress: UndoProgress
    let stop: @MainActor () -> Void

    var body: some View {
        SheetScaffold(
            title: Text(plan.title),
            subtitle: Text("Putting every file back where it was."),
            size: .small
        ) {
        } status: {
            ProgressLine(
                fraction: progress.fractionCompleted,
                text: Text("Putting back file \(min(progress.itemsCompleted + 1, progress.itemsTotal)) of \(progress.itemsTotal)…"),
                label: Text("Progress putting files back")
            ) {
                Button("Stop") {
                    stop()
                }
                .help("Stop after the file being put back now")
            }
        } buttons: {
        }
    }
}

/// What the undo did: how many files are back, then every file that is not, with the reason.
private struct UndoSummaryView: View {
    let result: UndoResult
    let done: @MainActor () -> Void

    var body: some View {
        SheetScaffold(title: Text(result.title), subtitle: subtitle) {
            VStack(spacing: 0) {
                Card {
                    CardFigures {
                        CardFigure(value: Text("\(result.undone.count)"), label: Text("put back"))
                        if !result.notUndone.isEmpty {
                            CardFigure(value: Text("\(result.notUndone.count)"), label: Text("not put back"))
                        }
                        if result.bytesTakenFromTrash > 0 {
                            CardFigure(value: Text(result.bytesTakenFromTrash.formattedFileSize), label: Text("put back from the Trash"))
                        }
                    }
                    if result.logFailure != nil {
                        StateBar(
                            symbol: "exclamationmark.triangle",
                            message: Text("The activity log stopped working, so undo stopped. See the message at the bottom of the main window.")
                        )
                    }
                }
                .padding([.horizontal, .top], Design.Space.l)
                List {
                    if !result.undone.isEmpty {
                        Section("Put back") {
                            ForEach(result.undone) { item in
                                UndoFileRow(name: item.displayName, detail: item.outcome.localizedDescription(for: item.operation))
                            }
                        }
                    }
                    if !result.notUndone.isEmpty {
                        Section("Not put back") {
                            ForEach(result.notUndone) { item in
                                UndoFileRow(name: item.displayName, detail: item.outcome.localizedDescription(for: item.operation))
                            }
                        }
                    }
                }
                .accessibilityLabel("Files")
            }
        } buttons: {
            Button("Done") {
                done()
            }
            .keyboardShortcut(.defaultAction)
        }
    }

    private var subtitle: Text {
        if result.undone.isEmpty {
            Text("Nothing was put back. No file changed.")
        } else if result.notUndone.isEmpty {
            Text("Every file is back where it was.")
        } else {
            Text("Some files could not be put back. The list says why.")
        }
    }
}

/// A file's name and what undo did, or why it did not.
private struct UndoFileRow: View {
    let name: String
    let detail: String

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: Design.Space.s) {
            Text(name)
                .lineLimit(1)
                .truncationMode(.middle)
            Spacer(minLength: Design.Space.m)
            Text(detail)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.trailing)
        }
        .accessibilityElement(children: .combine)
    }
}
