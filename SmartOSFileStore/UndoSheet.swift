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
        VStack(spacing: 16) {
            Image(systemName: "arrow.uturn.backward")
                .font(.largeTitle)
                .imageScale(.large)
                .foregroundStyle(.secondary)
                .accessibilityHidden(true)
            VStack(spacing: 6) {
                Text("\(plan.title)?")
                    .font(.headline)
                    .accessibilityAddTraits(.isHeader)
                Text("^[\(plan.steps.count) file](inflect: true) will be put back where they were.")
                    .multilineTextAlignment(.center)
                if !plan.refused.isEmpty {
                    Text("^[\(plan.refused.count) file](inflect: true) can’t be:")
                        .foregroundStyle(.secondary)
                }
            }
            .fixedSize(horizontal: false, vertical: true)
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
            HStack(spacing: 12) {
                Spacer()
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
        .padding(20)
        .frame(width: 440)
    }
}

/// The move back under way, with a Stop button.
private struct UndoProgressView: View {
    let plan: UndoPlan
    let progress: UndoProgress
    let stop: @MainActor () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(plan.title)
                .font(.headline)
                .accessibilityAddTraits(.isHeader)
            HStack(spacing: 12) {
                ProgressView(value: progress.fractionCompleted)
                    .accessibilityLabel("Progress putting files back")
                Button("Stop") {
                    stop()
                }
                .help("Stop after the file being put back now")
            }
            Text("Putting back file \(min(progress.itemsCompleted + 1, progress.itemsTotal)) of \(progress.itemsTotal)…")
                .monospacedDigit()
                .foregroundStyle(.secondary)
        }
        .padding(20)
        .frame(width: 440)
    }
}

/// What the undo did: how many files are back, then every file that is not, with the reason.
private struct UndoSummaryView: View {
    let result: UndoResult
    let done: @MainActor () -> Void

    var body: some View {
        VStack(spacing: 0) {
            VStack(spacing: 6) {
                Image(systemName: "arrow.uturn.backward")
                    .font(.largeTitle)
                    .imageScale(.large)
                    .foregroundStyle(.secondary)
                    .accessibilityHidden(true)
                if result.undone.isEmpty {
                    Text("Nothing Was Put Back")
                        .font(.title2.weight(.semibold))
                        .accessibilityAddTraits(.isHeader)
                    Text("No file was changed.")
                        .foregroundStyle(.secondary)
                } else {
                    Text("^[\(result.undone.count) file](inflect: true) put back")
                        .font(.title2.weight(.semibold))
                        .accessibilityAddTraits(.isHeader)
                    if result.bytesTakenFromTrash > 0 {
                        Text("\(result.bytesTakenFromTrash.formattedFileSize) taken back out of the Trash.")
                            .foregroundStyle(.secondary)
                    }
                }
                if result.logFailure != nil {
                    Text("The activity log stopped working, so undo stopped. See the message at the bottom of the main window.")
                        .font(.callout)
                }
            }
            .multilineTextAlignment(.center)
            .fixedSize(horizontal: false, vertical: true)
            .padding(24)
            .frame(maxWidth: .infinity)
            .accessibilityElement(children: .combine)

            List {
                if !result.undone.isEmpty {
                    Section("Put Back") {
                        ForEach(result.undone) { item in
                            UndoFileRow(name: item.displayName, detail: item.outcome.localizedDescription(for: item.operation))
                        }
                    }
                }
                if !result.notUndone.isEmpty {
                    Section("Not Put Back") {
                        ForEach(result.notUndone) { item in
                            UndoFileRow(name: item.displayName, detail: item.outcome.localizedDescription(for: item.operation))
                        }
                    }
                }
            }
            .accessibilityLabel("Files")

            Divider()
            HStack {
                if !result.notUndone.isEmpty {
                    Text("^[\(result.notUndone.count) file](inflect: true) not put back")
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Button("Done") {
                    done()
                }
                .keyboardShortcut(.defaultAction)
            }
            .padding(12)
        }
        .frame(minWidth: 520, idealWidth: 560, minHeight: 360, idealHeight: 420)
    }
}

/// A file's name and what undo did, or why it did not.
private struct UndoFileRow: View {
    let name: String
    let detail: String

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Text(name)
                .lineLimit(1)
                .truncationMode(.middle)
            Spacer(minLength: 12)
            Text(detail)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.trailing)
        }
        .accessibilityElement(children: .combine)
    }
}
