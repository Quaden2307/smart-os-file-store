import FileStoreCore
import SwiftUI

/// Tidy Now: every action's findings over one scan, in one overview. Each row opens that action's
/// own preview, where the user ticks and unticks as usual; back in the overview their choices stay.
/// One Tidy Up asks once for everything ticked, then carries it out as one run that one Undo
/// reverses, and shows what each action did.
struct TidyNowSheet: View {
    @State private var model: TidyNowModel
    @Environment(\.dismiss) private var dismiss

    private let eligibility: CandidateEligibility
    private let applicationFolders: [URL]
    private let log: ActivityLog
    private let activity: ActivityLogModel
    private let markKept: @MainActor ([FileRecord], @escaping @MainActor (Bool) -> Void) -> Void
    private let onUndo: @MainActor (ActivityRun.ID) -> Void

    init(
        model: TidyNowModel,
        eligibility: CandidateEligibility,
        applicationFolders: [URL],
        log: ActivityLog,
        activity: ActivityLogModel,
        markKept: @escaping @MainActor ([FileRecord], @escaping @MainActor (Bool) -> Void) -> Void,
        onUndo: @escaping @MainActor (ActivityRun.ID) -> Void
    ) {
        _model = State(initialValue: model)
        self.eligibility = eligibility
        self.applicationFolders = applicationFolders
        self.log = log
        self.activity = activity
        self.markKept = markKept
        self.onUndo = onUndo
    }

    var body: some View {
        Group {
            if let action = model.openAction, let plan = model.plans[action] {
                CleanupPreviewSheet(
                    plan: plan,
                    eligibility: eligibility,
                    applicationFolders: applicationFolders,
                    log: log,
                    activity: activity,
                    markKept: markKept,
                    initialTicked: model.ticked[action],
                    onChoose: { plan, ticked in
                        model.choose(plan, ticked: ticked)
                    },
                    onExecuted: { _ in }
                )
                // Each opening starts from the overview's choices, never an earlier preview's state.
                .id(action)
            } else {
                overview
            }
        }
        .interactiveDismissDisabled(model.isExecuting)
        .sheet(isPresented: $model.isConfirming) {
            TidyNowConfirmationSheet(totals: model.totals) {
                model.execute()
            }
        }
    }

    private var overview: some View {
        SheetScaffold(title: Text("Tidy Now"), subtitle: subtitle) {
            content
        } status: {
            footerStatus
        } buttons: {
            footerButtons
        }
        .onExitCommand {
            if !model.isExecuting {
                close()
            }
        }
    }

    private var subtitle: Text {
        switch model.phase {
        case .planning:
            Text("Checking the folder with every cleanup…")
        case .reviewing where model.isTidy:
            Text("Nothing to tidy")
        case .reviewing, .executing:
            Text("Everything ticked is carried out as one cleanup. One Undo puts it all back.")
        case .finished:
            Text("What each cleanup did. Every file is listed in Activity.")
        }
    }

    @ViewBuilder
    private var content: some View {
        switch model.phase {
        case .planning:
            List {
                ForEach(model.actions, id: \.self) { action in
                    TidyNowPlanningRow(
                        action: action,
                        progress: model.progress[action],
                        isFinished: model.finishedActions.contains(action),
                        failed: model.failedActions.contains(action)
                    )
                }
            }
        case .reviewing where model.isTidy:
            StateView(
                title: Text("This folder is tidy"),
                symbol: "checkmark.circle",
                message: Text("No cleanup found anything to do.")
            )
        case .reviewing, .executing:
            VStack(spacing: 0) {
                summaryCard
                    .padding([.horizontal, .top], Design.Space.l)
                categoryList
                    .disabled(!model.isReviewing)
            }
        case .finished(let result):
            TidyNowSummaryView(result: result)
        }
    }

    /// What is ticked across every cleanup, and that nothing changes yet.
    private var summaryCard: some View {
        Card {
            let totals = model.totals
            if totals.isEmpty {
                Text("Nothing is ticked. Open a list to choose files.")
                    .foregroundStyle(.secondary)
            } else {
                TidyNowFigures(totals: totals)
                Text(model.isReviewing ? "Nothing changes until you click Tidy up." : "Carrying out what is ticked.")
                    .font(Design.Typography.secondary)
                    .foregroundStyle(.secondary)
            }
        }
    }

    private var categoryList: some View {
        let categories = model.categories
        let toTidy = categories.filter { !$0.isReview }
        let toReview = categories.filter(\.isReview)
        return List {
            if !toTidy.isEmpty {
                Section("To tidy") {
                    ForEach(toTidy) { category in
                        categoryRow(category)
                    }
                }
            }
            if !toReview.isEmpty {
                Section {
                    ForEach(toReview) { category in
                        categoryRow(category)
                    }
                } header: {
                    Text("For you to review")
                } footer: {
                    Text("Nothing here is ticked. Open a list to tick what you want in the Trash.")
                        .foregroundStyle(.secondary)
                }
            }
            let failed = model.actions.filter(model.failedActions.contains)
            if !failed.isEmpty {
                Section("Couldn’t finish checking") {
                    ForEach(failed, id: \.self) { action in
                        Label(action.title, systemImage: "exclamationmark.triangle")
                            .foregroundStyle(.secondary)
                            .accessibilityLabel(Text("\(action.title): couldn’t finish checking. Run it from the Clean Up menu to try again."))
                    }
                }
            }
            let nothing = model.actionsWithNothingToDo
            if !nothing.isEmpty {
                Section("Nothing to do") {
                    ForEach(nothing, id: \.self) { action in
                        Text(action.title)
                            .foregroundStyle(.secondary)
                            .accessibilityLabel(Text("\(action.title): nothing to do"))
                    }
                }
            }
        }
    }

    private func categoryRow(_ category: TidyNowModel.Category) -> some View {
        TidyNowCategoryRow(category: category, ticked: model.tickedChanges(in: category)) {
            model.open(category.action)
        }
    }

    /// The footer's left side: the progress while the folder is checked or tidied.
    @ViewBuilder
    private var footerStatus: some View {
        switch model.phase {
        case .planning:
            ProgressLine(
                fraction: nil,
                text: Text("Checked by \(model.finishedActions.count) of \(model.actions.count) cleanups"),
                label: Text("Checking the folder")
            )
        case .executing(let progress):
            let current = min(progress.itemsCompleted + 1, progress.itemsTotal)
            ProgressLine(
                fraction: progress.fractionCompleted,
                text: Text("Cleaning up item \(current) of \(progress.itemsTotal)…"),
                label: Text("Progress cleaning up")
            ) {
                Button("Stop") {
                    model.cancel()
                }
                .keyboardShortcut(.cancelAction)
                .help(Text("Stop after the item being changed now; everything done so far stays and can be undone"))
            }
        case .reviewing, .finished:
            EmptyView()
        }
    }

    @ViewBuilder
    private var footerButtons: some View {
        switch model.phase {
        case .planning:
            Button("Cancel") {
                close()
            }
            .keyboardShortcut(.cancelAction)
        case .reviewing:
            Button("Cancel") {
                close()
            }
            .keyboardShortcut(.cancelAction)
            if !model.isTidy {
                Button("Tidy up…") {
                    model.confirm()
                }
                .keyboardShortcut(.defaultAction)
                .disabled(!model.canTidyUp || model.isConfirming)
                .help(Text("Carry out everything ticked, after one confirmation"))
            } else {
                Button("Done") {
                    close()
                }
                .keyboardShortcut(.defaultAction)
            }
        case .executing:
            EmptyView()
        case .finished(let result):
            if let runID = result.runID, result.hasDoneItems, result.logFailure == nil {
                Button("Undo") {
                    onUndo(runID)
                    close()
                }
                .help(Text("Put everything this cleanup changed back as it was"))
            }
            Button("Done") {
                close()
            }
            .keyboardShortcut(.defaultAction)
        }
    }

    private func close() {
        model.cancel()
        dismiss()
    }
}

/// One action while Tidy Now plans: a bar when it reads files, a spinner otherwise, then a mark.
private struct TidyNowPlanningRow: View {
    let action: CleanupAction
    let progress: CleanupPlanningProgress?
    let isFinished: Bool
    let failed: Bool

    var body: some View {
        HStack(spacing: Design.Space.s) {
            Label(action.title, systemImage: action.display.symbol)
            Spacer()
            if failed {
                Image(systemName: "exclamationmark.triangle")
                    .foregroundStyle(.secondary)
                    .accessibilityLabel(Text("Couldn’t finish checking"))
            } else if isFinished {
                Image(systemName: "checkmark")
                    .foregroundStyle(.secondary)
                    .accessibilityLabel(Text("Checked"))
            } else if let progress, progress.itemsToCheck > 0 {
                ProgressView(value: progress.fractionCompleted)
                    .frame(width: Design.Size.progressBarCompact)
                    .accessibilityLabel(Text("Checking"))
            } else {
                ProgressView()
                    .controlSize(.small)
                    .accessibilityLabel(Text("Checking"))
            }
        }
        .accessibilityElement(children: .combine)
    }
}

/// One category of the overview: a button that opens its preview, with how much it found and how
/// much of it is ticked.
private struct TidyNowCategoryRow: View {
    let category: TidyNowModel.Category
    let ticked: [ProposedChange]
    let open: @MainActor () -> Void

    var body: some View {
        Button(action: open) {
            HStack(spacing: Design.Space.s) {
                Image(systemName: category.action.display.symbol)
                    .frame(width: Design.Icon.column)
                    .foregroundStyle(.secondary)
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: Design.Space.tight) {
                    Text(category.title)
                    detail
                        .font(Design.Typography.secondary)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                let bytes = ticked.filter { $0.operation == .moveToTrash }.reduce(Int64(0)) { $0 + $1.sizeInBytes }
                if bytes > 0 {
                    Text(bytes.formattedFileSize)
                        .foregroundStyle(.secondary)
                }
                Image(systemName: "chevron.right")
                    .foregroundStyle(.tertiary)
                    .accessibilityHidden(true)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityElement(children: .combine)
        .accessibilityHint(Text("Opens the list, to tick and untick"))
        .help(Text("Open the list"))
    }

    @ViewBuilder
    private var detail: some View {
        let count = category.changes.count
        if category.isReview && ticked.isEmpty {
            Text("^[\(count) item](inflect: true), none ticked")
        } else if ticked.count == count {
            Text("^[\(count) item](inflect: true)")
        } else {
            Text("\(ticked.count) of ^[\(count) item](inflect: true) ticked")
        }
    }
}
