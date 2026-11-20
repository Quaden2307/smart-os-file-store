import FileStoreCore
import FileStoreIntelligence
import SwiftUI

/// What a cleanup card's buttons do. The window hands them down: it owns the sheets and the undo,
/// and knows when another cleanup is in the way.
struct ChatCardActions {
    /// False while another cleanup, an undo or a sheet is in the way of starting one.
    var canStart: Bool
    var review: @MainActor (CleanupProposal.ID) -> Void
    var confirm: @MainActor (CleanupProposal.ID) -> Void
    var undo: @MainActor (ActivityRun.ID) -> Void
}

/// A cleanup the chat prepared, in the conversation: what the app understood, written by code from
/// what the tool was asked; what each cleanup found; Review, which opens the Tidy Now preview on
/// this plan, and Confirm, which asks once and then carries it out. Afterwards it is the run's
/// summary, with Undo. Nothing here comes from the model's sentence, and nothing changes on disk
/// before Confirm.
struct ChatCleanupCard: View {
    let proposal: CleanupProposal
    let chat: ChatModel
    let actions: ChatCardActions

    @Environment(ActivityLogModel.self) private var activity

    var body: some View {
        VStack(alignment: .leading, spacing: Design.Chat.cardGap) {
            VStack(alignment: .leading, spacing: Design.Space.tight) {
                Text("What I understood")
                    .font(Design.Chat.caption)
                    .foregroundStyle(.secondary)
                // The words may include text the model chose (a name to look for), so they go in
                // verbatim: nothing in them is read as Markdown or as a link.
                Text(verbatim: proposal.request.understood)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .accessibilityElement(children: .combine)
            Divider()
            if let model = chat.cleanups[proposal.id] {
                switch model.phase {
                case .planning, .reviewing:
                    preview(model)
                case .executing(let progress):
                    running(model, progress)
                case .finished(let result):
                    summary(result)
                }
            } else {
                Text("This preview is no longer here. Ask again to make a new one.")
                    .foregroundStyle(.secondary)
            }
        }
        .padding(Design.Space.m)
        .frame(maxWidth: Design.Chat.cardWidth, alignment: .leading)
        .overlay(RoundedRectangle(cornerRadius: Design.Radius.card, style: .continuous).strokeBorder(Design.Colour.hairline))
        .accessibilityElement(children: .contain)
        .accessibilityLabel(Text("Cleanup preview"))
    }

    // MARK: - Waiting for Confirm

    @ViewBuilder
    private func preview(_ model: TidyNowModel) -> some View {
        let categories = model.categories
        let isOutOfDate = chat.cards.state(of: proposal.id) == .outOfDate
        if categories.isEmpty {
            Text("Nothing left to clean up for this request.")
                .foregroundStyle(.secondary)
        }
        ForEach(categories) { category in
            CardCategoryRow(category: category, tickedCount: model.tickedChanges(in: category).count)
        }
        let failed = model.actions.filter(model.failedActions.contains)
        if !failed.isEmpty {
            Label("Couldn’t check: \(failed.map(\.title).formatted(.list(type: .and)))", systemImage: "exclamationmark.triangle")
                .foregroundStyle(.secondary)
        }
        if isOutOfDate {
            Label("Out of date: a file changed, or a newer preview took its place.", systemImage: "clock.arrow.circlepath")
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        } else if !categories.isEmpty {
            Group {
                if model.totals.isEmpty {
                    Text("Nothing is ticked. Review to choose files.")
                } else {
                    Text("Ticked: \(model.totals.sentence). Nothing changes until you confirm.")
                }
            }
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
        }
        HStack(spacing: Design.Space.s) {
            if isOutOfDate {
                if chat.refreshing.contains(proposal.id) {
                    ProgressView()
                        .controlSize(.small)
                        .accessibilityLabel(Text("Checking the folder again"))
                }
                Button("Refresh") {
                    chat.refresh(proposal)
                }
                .disabled(!chat.canRefresh(proposal.id) || !actions.canStart)
                .help(Text("Plan this cleanup again for the folder as it is now"))
            } else if !categories.isEmpty {
                Button("Review…") {
                    actions.review(proposal.id)
                }
                .disabled(!actions.canStart)
                .help(Text("Open the full preview of these files, where you can tick and untick each one"))
                Button("Confirm…") {
                    actions.confirm(proposal.id)
                }
                .disabled(!actions.canStart || model.totals.isEmpty)
                .help(Text("Carry out everything ticked, after one confirmation"))
            }
        }
    }

    // MARK: - Running

    private func running(_ model: TidyNowModel, _ progress: CleanupExecutionProgress) -> some View {
        HStack(spacing: Design.Space.m) {
            let current = min(progress.itemsCompleted + 1, progress.itemsTotal)
            ProgressView(value: progress.fractionCompleted)
                .frame(maxWidth: 200)
                .accessibilityLabel(Text("Progress cleaning up"))
            Text("Cleaning up item \(current) of \(progress.itemsTotal)…")
            Spacer()
            Button("Stop") {
                model.cancel()
            }
            .help(Text("Stop after the item being changed now; everything done so far stays and can be undone"))
        }
    }

    // MARK: - The run's summary

    @ViewBuilder
    private func summary(_ result: TidyNowResult) -> some View {
        if result.wasCancelled {
            Text("Stopped before every change was tried.")
                .foregroundStyle(.secondary)
        }
        if result.logFailure != nil {
            Label("The activity log stopped working, so the cleanup stopped. Nothing after that was changed.", systemImage: "exclamationmark.triangle")
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        if result.results.isEmpty {
            Text("Nothing was changed.")
                .foregroundStyle(.secondary)
        }
        ForEach(result.results, id: \.action) { item in
            HStack(alignment: .firstTextBaseline) {
                Label(item.action.title, systemImage: item.action.display.symbol)
                Spacer(minLength: Design.Space.m)
                Text("\(item.items.filter(\.isDone).count) done, \(item.skipped.count) skipped, \(item.failed.count) failed")
                    .foregroundStyle(.secondary)
            }
            .accessibilityElement(children: .combine)
        }
        HStack(spacing: Design.Space.s) {
            Text(result.bytesFreed > 0
                ? "\(result.bytesFreed.formattedFileSize) moved to the Trash. Every file is listed in Activity."
                : "Every file is listed in Activity.")
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: Design.Space.m)
            // The log's own record of the run decides, so an undo from Edit > Undo or from Activity
            // shows here too. Only the newest cleanup is offered, as Edit > Undo offers it.
            if let runID = result.runID, let run = activity.latestCleanupRun, run.id == runID {
                if run.hasChangesLeftToUndo, result.logFailure == nil {
                    Button("Undo") {
                        actions.undo(runID)
                    }
                    .disabled(chat.isCleaningUp)
                    .help(Text("Put everything this cleanup changed back as it was"))
                } else if let undoLabel = run.undoLabel {
                    Text(undoLabel)
                        .foregroundStyle(.secondary)
                }
            }
        }
    }
}

/// One cleanup of a card: what it is, how many items it found and how much they would free.
private struct CardCategoryRow: View {
    let category: TidyNowModel.Category
    let tickedCount: Int

    private var bytes: Int64 {
        category.changes.filter { $0.operation == .moveToTrash }.reduce(0) { $0 + $1.sizeInBytes }
    }

    var body: some View {
        HStack(alignment: .firstTextBaseline) {
            Label(category.title, systemImage: category.action.display.symbol)
            Spacer(minLength: Design.Space.m)
            Group {
                if bytes > 0 {
                    Text("^[\(category.changes.count) item](inflect: true), \(bytes.formattedFileSize)")
                } else {
                    Text("^[\(category.changes.count) item](inflect: true)")
                }
            }
            .foregroundStyle(.secondary)
            if tickedCount < category.changes.count {
                Text(tickedCount == 0 ? "for you to review" : "\(tickedCount) ticked")
                    .font(Design.Chat.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .accessibilityElement(children: .combine)
    }
}
