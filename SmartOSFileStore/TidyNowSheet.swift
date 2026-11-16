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
        .frame(minWidth: 620, idealWidth: 700, minHeight: 420, idealHeight: 540)
        .interactiveDismissDisabled(model.isExecuting)
        .sheet(isPresented: $model.isConfirming) {
            TidyNowConfirmationSheet(totals: model.totals) {
                model.execute()
            }
        }
    }

    private var overview: some View {
        VStack(spacing: 0) {
            header
                .padding(16)
            Divider()
            content
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            Divider()
            footer
                .padding(12)
        }
        .onExitCommand {
            if !model.isExecuting {
                close()
            }
        }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("Tidy Now")
                .font(.title2.weight(.semibold))
                .accessibilityAddTraits(.isHeader)
            Group {
                switch model.phase {
                case .planning:
                    Text("Checking the folder with every cleanup…")
                case .reviewing where model.isTidy:
                    Text("Nothing to tidy")
                case .reviewing, .executing:
                    let totals = model.totals
                    if totals.isEmpty {
                        Text("Nothing ticked yet")
                    } else {
                        Text("Ticked: \(totals.sentence)")
                            .monospacedDigit()
                    }
                case .finished(let result):
                    Text("\(result.bytesFreed.formattedFileSize) moved to the Trash")
                        .monospacedDigit()
                }
            }
            .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
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
            ContentUnavailableView(
                "This Folder Is Tidy",
                systemImage: "checkmark.circle",
                description: Text("No cleanup found anything to do.")
            )
        case .reviewing, .executing:
            categoryList
                .disabled(!model.isReviewing)
        case .finished(let result):
            TidyNowSummaryView(result: result)
        }
    }

    private var categoryList: some View {
        let categories = model.categories
        let toTidy = categories.filter { !$0.isReview }
        let toReview = categories.filter(\.isReview)
        return List {
            if !toTidy.isEmpty {
                Section("To Tidy") {
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
                    Text("For You to Review")
                } footer: {
                    Text("Nothing here is ticked. Open a list to tick what you want in the Trash.")
                        .foregroundStyle(.secondary)
                }
            }
            let failed = model.actions.filter(model.failedActions.contains)
            if !failed.isEmpty {
                Section("Couldn’t Finish Checking") {
                    ForEach(failed, id: \.self) { action in
                        Label(action.title, systemImage: "exclamationmark.triangle")
                            .foregroundStyle(.secondary)
                            .accessibilityLabel(Text("\(action.title): couldn’t finish checking. Run it from the Clean Up menu to try again."))
                    }
                }
            }
            let nothing = model.actionsWithNothingToDo
            if !nothing.isEmpty {
                Section("Nothing to Do") {
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

    @ViewBuilder
    private var footer: some View {
        switch model.phase {
        case .planning:
            HStack {
                ProgressView()
                    .controlSize(.small)
                    .accessibilityLabel(Text("Checking the folder"))
                Text("Checked by \(model.finishedActions.count) of \(model.actions.count) cleanups")
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
                Spacer()
                Button("Cancel") {
                    close()
                }
                .keyboardShortcut(.cancelAction)
            }
        case .reviewing:
            HStack {
                Spacer()
                Button("Cancel") {
                    close()
                }
                .keyboardShortcut(.cancelAction)
                if !model.isTidy {
                    Button("Tidy Up…") {
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
            }
        case .executing(let progress):
            HStack(spacing: 12) {
                let current = min(progress.itemsCompleted + 1, progress.itemsTotal)
                ProgressView(value: progress.fractionCompleted)
                    .frame(maxWidth: 240)
                    .accessibilityLabel(Text("Progress tidying the folder"))
                Text("Tidying item \(current) of \(progress.itemsTotal)…")
                    .monospacedDigit()
                Spacer()
                Button("Stop") {
                    model.cancel()
                }
                .keyboardShortcut(.cancelAction)
                .help(Text("Stop after the item being changed now; everything done so far stays and can be undone"))
            }
        case .finished(let result):
            HStack {
                Spacer()
                if let runID = result.runID, result.hasDoneItems, result.logFailure == nil {
                    Button("Undo") {
                        onUndo(runID)
                        close()
                    }
                    .help(Text("Put everything this tidy changed back as it was"))
                }
                Button("Done") {
                    close()
                }
                .keyboardShortcut(.defaultAction)
            }
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
        HStack(spacing: 8) {
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
                    .frame(width: 120)
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
            HStack(spacing: 10) {
                Image(systemName: category.action.display.symbol)
                    .frame(width: 20)
                    .foregroundStyle(.secondary)
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 2) {
                    Text(category.title)
                    detail
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .monospacedDigit()
                }
                Spacer()
                let bytes = ticked.filter { $0.operation == .moveToTrash }.reduce(Int64(0)) { $0 + $1.sizeInBytes }
                if bytes > 0 {
                    Text(bytes.formattedFileSize)
                        .monospacedDigit()
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
