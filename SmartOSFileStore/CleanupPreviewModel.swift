import FileStoreCore
import Foundation
import Observation
import os

/// State of the cleanup preview: which proposed changes are ticked, whether the confirmation is
/// up, and the execution with its result. Lives on the main actor; the executor runs elsewhere.
@MainActor
@Observable
final class CleanupPreviewModel {
    enum Phase: Equatable {
        case reviewing
        case executing(CleanupExecutionProgress)
        case finished(CleanupResult)
    }

    /// The plan as shown: the one found, less any files taken out with Keep This File.
    private(set) var plan: CleanupPlan

    /// Whether the preview shows duplicate groups or one change per row, worked out once.
    let isGroupedByDuplicates: Bool

    /// Whether the preview shows near-duplicate groups, worked out once.
    let isGroupedByNearDuplicates: Bool

    /// Changes the user has left ticked. Everything but a possible match and a near-duplicate is
    /// ticked to begin with.
    private(set) var ticked: Set<ProposedChange.ID>

    /// True while the confirmation sheet is up, so it is never shown twice.
    var isConfirming = false

    private(set) var phase: Phase = .reviewing

    /// True once files taken out with Keep This File could not be marked Kept. They stay out of
    /// this cleanup all the same.
    private(set) var keepFailed = false

    /// How many files Keep This File has taken out of the plan, so an empty plan is not shown as one
    /// in which nothing was found.
    private(set) var keptCount = 0

    private let onExecuted: @MainActor (CleanupResult) -> Void
    private let markKept: @MainActor ([FileRecord], @escaping @MainActor (Bool) -> Void) -> Void
    private var executionTask: Task<Void, Never>?
    private let executor: CleanupExecutor
    private let activity: ActivityLogModel
    private let logger = Logger(subsystem: "com.quaden2307.SmartOSFileStore", category: "Cleanup")

    /// - Parameters:
    ///   - eligibility: The rules the plan was made with; the executor checks them again.
    ///   - applicationFolders: Where installed apps are, the same folders the search used: an
    ///     installer's app must still be in one of them. The window's own, never the plan's.
    ///   - log: The open activity log. Every change is written to it as it happens; there is no
    ///     way to carry out a plan without one.
    ///   - activity: Told when the run has ended, so the totals and the Activity place follow.
    ///   - markKept: Marks files Kept, then says whether it could; the main window's list does it,
    ///     so its badges follow and a search started next sees the change.
    init(
        plan: CleanupPlan,
        eligibility: CandidateEligibility,
        applicationFolders: [URL],
        log: ActivityLog,
        activity: ActivityLogModel,
        markKept: @escaping @MainActor ([FileRecord], @escaping @MainActor (Bool) -> Void) -> Void,
        onExecuted: @escaping @MainActor (CleanupResult) -> Void
    ) {
        self.plan = plan
        self.markKept = markKept
        self.isGroupedByDuplicates = plan.isGroupedByDuplicates
        self.isGroupedByNearDuplicates = plan.isGroupedByNearDuplicates
        self.executor = CleanupExecutor(recorder: log, eligibility: eligibility, applicationFolders: applicationFolders)
        self.activity = activity
        self.onExecuted = onExecuted
        self.ticked = Set(plan.changes.filter { !$0.reason.isPossibleMatch && !$0.reason.isReviewOnly }.map(\.id))
    }

    // Isolated, so it may touch main-actor state: the sheet is gone, stop between items.
    isolated deinit {
        executionTask?.cancel()
    }

    var isReviewing: Bool { phase == .reviewing }

    /// What every change in the plan does, for the words on the buttons, progress and summary.
    var operation: CleanupActionDefinition.OperationKind { plan.operation }

    /// Whether the plan can be carried out from here: moves to the Trash and renames can be.
    var canBeApplied: Bool { plan.canBeApplied }

    var isExecuting: Bool {
        if case .executing = phase {
            return true
        }
        return false
    }

    var result: CleanupResult? {
        if case .finished(let result) = phase {
            return result
        }
        return nil
    }

    /// The ticked changes, in plan order.
    var tickedChanges: [ProposedChange] {
        plan.changes.filter { ticked.contains($0.id) }
    }

    var tickedCount: Int { tickedChanges.count }

    var tickedBytes: Int64 {
        tickedChanges.reduce(0) { $0 + $1.sizeInBytes }
    }

    /// True when Move to Trash, Rename or Archive may be offered: still reviewing, with at least one
    /// change ticked, in a plan that can be applied.
    var canExecute: Bool { isReviewing && tickedCount > 0 && canBeApplied }

    func isTicked(_ id: ProposedChange.ID) -> Bool {
        ticked.contains(id)
    }

    /// False for the last unticked file of a near-duplicate group: one file of each group always
    /// stays, and the executor refuses a run that would move them all.
    func canTick(_ id: ProposedChange.ID) -> Bool {
        guard let group = plan.nearDuplicateGroups.first(where: { $0.members.contains { $0.id == id } }) else {
            return true
        }
        return group.members.contains { $0.id != id && !ticked.contains($0.id) }
    }

    func setTicked(_ id: ProposedChange.ID, _ isTicked: Bool) {
        guard isReviewing else { return }
        if isTicked {
            guard canTick(id) else { return }
            ticked.insert(id)
        } else {
            ticked.remove(id)
        }
    }

    /// Ticks every change except those only the user may tick, one by one (near-duplicates).
    func selectAll() {
        guard isReviewing else { return }
        ticked.formUnion(plan.changes.filter { !$0.reason.isReviewOnly }.map(\.id))
    }

    func selectNone() {
        guard isReviewing else { return }
        ticked = []
    }

    /// True when Keep This File can take the rows in `ids` out of the plan: still reviewing, and at
    /// least one of them is a proposed change.
    func canKeep(_ ids: Set<URL>) -> Bool {
        isReviewing && plan.changes.contains { ids.contains($0.id) }
    }

    /// Keep This File: unticks the proposed changes in `ids`, takes them out of the plan, and marks
    /// their files Kept. They are out of this cleanup whether or not the mark could be written.
    func keep(_ ids: Set<URL>) {
        guard isReviewing else { return }
        let records = plan.changes.filter { ids.contains($0.id) }.map(\.record)
        guard !records.isEmpty else { return }
        let removed = Set(records.map(\.id))
        ticked.subtract(removed)
        plan = plan.removing(removed)
        // A near-duplicate left alone in its group leaves the plan with the kept file.
        ticked.formIntersection(plan.changes.map(\.id))
        // A group now ticked in full, its Kept file gone from the list: untick it, so that the user
        // decides again with one file left unticked rather than the executor keeping one back.
        for group in plan.nearDuplicateGroups where group.members.allSatisfy({ ticked.contains($0.id) }) {
            ticked.subtract(group.members.map(\.id))
        }
        keptCount += records.count
        logger.info("Took \(records.count) files out of the plan to keep them")
        markKept(records) { [weak self] succeeded in
            if !succeeded {
                self?.keepFailed = true
            }
        }
    }

    /// Carries out the ticked changes. The sheet calls this from the confirmation's Move to Trash or
    /// Rename button and from nowhere else.
    func execute() {
        guard canExecute else { return }
        let confirmed = ticked
        let total = tickedCount
        phase = .executing(CleanupExecutionProgress(itemsCompleted: 0, itemsTotal: total, bytesFreed: 0))
        logger.info("Carrying out \(total) changes")

        let executor = executor
        let plan = plan
        let activity = activity
        // Weak throughout: the task must not keep the model alive, and `deinit` cancels the task.
        executionTask = Task { [weak self] in
            let result = await executor.execute(plan: plan, confirmedChangeIDs: confirmed) { progress in
                Task { @MainActor in
                    self?.report(progress)
                }
            }
            // The app's log state hears of every run, even one whose sheet has gone meanwhile.
            activity.runFinished(result)
            self?.finish(result)
        }
    }

    private func report(_ progress: CleanupExecutionProgress) {
        guard isExecuting else { return }
        phase = .executing(progress)
    }

    private func finish(_ result: CleanupResult) {
        guard isExecuting else { return }
        phase = .finished(result)
        executionTask = nil
        logger.info(
            "Trashed \(result.trashedCount) files (\(result.bytesFreed) bytes), renamed \(result.renamed.count); \(result.skipped.count) skipped, \(result.failed.count) failed"
        )
        onExecuted(result)
    }
}
