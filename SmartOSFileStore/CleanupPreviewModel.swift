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

    let plan: CleanupPlan

    /// Whether the preview shows duplicate groups or one change per row, worked out once.
    let isGroupedByDuplicates: Bool

    /// Whether the plan can be carried out from here: so far only moves to the Trash can be.
    let isTrashOnly: Bool

    /// Changes the user has left ticked. Everything is ticked to begin with.
    private(set) var ticked: Set<ProposedChange.ID>

    /// True while the confirmation sheet is up, so it is never shown twice.
    var isConfirming = false

    private(set) var phase: Phase = .reviewing

    private let onExecuted: @MainActor (CleanupResult) -> Void
    private var executionTask: Task<Void, Never>?
    private let executor: CleanupExecutor
    private let activity: ActivityLogModel
    private let logger = Logger(subsystem: "com.quaden2307.SmartOSFileStore", category: "Cleanup")

    /// - Parameters:
    ///   - eligibility: The rules the plan was made with; the executor checks them again.
    ///   - log: The open activity log. Every change is written to it as it happens; there is no
    ///     way to carry out a plan without one.
    ///   - activity: Told when the run has ended, so the totals and the Activity window follow.
    init(
        plan: CleanupPlan,
        eligibility: CandidateEligibility,
        log: ActivityLog,
        activity: ActivityLogModel,
        onExecuted: @escaping @MainActor (CleanupResult) -> Void
    ) {
        self.plan = plan
        self.isGroupedByDuplicates = plan.isGroupedByDuplicates
        self.isTrashOnly = plan.isTrashOnly
        self.executor = CleanupExecutor(recorder: log, eligibility: eligibility)
        self.activity = activity
        self.onExecuted = onExecuted
        self.ticked = Set(plan.changes.map(\.id))
    }

    // Isolated, so it may touch main-actor state: the sheet is gone, stop between items.
    isolated deinit {
        executionTask?.cancel()
    }

    var isReviewing: Bool { phase == .reviewing }

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

    /// True when Move to Trash may be offered: still reviewing, with at least one change ticked, in
    /// a plan of moves to the Trash. Renames and moves are previewed only, until an action that
    /// proposes them brings its own confirmation.
    var canExecute: Bool { isReviewing && tickedCount > 0 && isTrashOnly }

    func isTicked(_ id: ProposedChange.ID) -> Bool {
        ticked.contains(id)
    }

    func setTicked(_ id: ProposedChange.ID, _ isTicked: Bool) {
        guard isReviewing else { return }
        if isTicked {
            ticked.insert(id)
        } else {
            ticked.remove(id)
        }
    }

    func selectAll() {
        guard isReviewing else { return }
        ticked = Set(plan.changes.map(\.id))
    }

    func selectNone() {
        guard isReviewing else { return }
        ticked = []
    }

    /// Moves the ticked files to the Trash. The sheet calls this from the confirmation's
    /// Move to Trash button and from nowhere else.
    func execute() {
        guard canExecute else { return }
        let confirmed = ticked
        let total = tickedCount
        phase = .executing(CleanupExecutionProgress(itemsCompleted: 0, itemsTotal: total, bytesFreed: 0))
        logger.info("Moving \(total) files to the Trash")

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
            "Moved \(result.trashedCount) files to the Trash (\(result.bytesFreed) bytes); \(result.skipped.count) skipped, \(result.failed.count) failed"
        )
        onExecuted(result)
    }
}
