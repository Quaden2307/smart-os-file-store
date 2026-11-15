import FileStoreCore
import Foundation
import Observation
import os

/// One undo in the main window: the plan, the question when more than one file would move, the
/// move back with its progress, and the summary. Lives on the main actor; the planner and the
/// executor run elsewhere. Only one undo runs at a time.
@MainActor
@Observable
final class UndoModel {
    enum Phase: Equatable {
        /// More than one file would move: asking first.
        case confirming(UndoPlan)
        case executing(UndoPlan, UndoProgress)
        case finished(UndoResult)
    }

    /// Identifies one presentation of the sheet, so a later undo starts with a fresh one.
    struct Presented: Identifiable, Equatable {
        let id = UUID()
    }

    private(set) var phase: Phase?

    /// Set while the sheet is up.
    private(set) var presented: Presented?

    /// True while the plan is being worked out, before anything is shown.
    private(set) var isPlanning = false

    /// True from the moment an undo is asked for until its sheet is closed.
    var isBusy: Bool { isPlanning || presented != nil }

    var isExecuting: Bool {
        if case .executing = phase {
            return true
        }
        return false
    }

    private var task: Task<Void, Never>?
    private let logger = Logger(subsystem: "com.quaden2307.SmartOSFileStore", category: "Undo")

    // Isolated, so it may touch main-actor state: the window is gone, stop between files.
    isolated deinit {
        task?.cancel()
    }

    /// Works out what undoing `target` would do, then asks when more than one file would move, goes
    /// straight ahead for one, and shows why when there is nothing that can be undone.
    ///
    /// - Parameters:
    ///   - folderURL: The folder the app looks after; every file goes back into it.
    ///   - log: The open activity log. The undo is written to it as it happens.
    ///   - activity: Told when the undo has ended, so the totals and the Activity place follow.
    ///   - onFinished: Called once files may have moved, so the file list can be read again.
    func start(
        _ target: UndoTarget,
        folderURL: URL,
        log: ActivityLog,
        activity: ActivityLogModel,
        onFinished: @escaping @MainActor () -> Void
    ) {
        guard !isBusy else { return }
        isPlanning = true
        let planner = UndoPlanner()
        Task {
            do throws(ActivityLogError) {
                let plan = try await planner.plan(target, log: log, folderURL: folderURL)
                isPlanning = false
                presented = Presented()
                switch plan.steps.count {
                case 0:
                    phase = .finished(UndoResult(nothingToUndo: plan))
                case 1:
                    execute(plan, log: log, activity: activity, onFinished: onFinished)
                default:
                    phase = .confirming(plan)
                    pending = Pending(log: log, activity: activity, onFinished: onFinished)
                }
            } catch {
                isPlanning = false
                logger.error("Undo could not be planned: \(String(describing: error), privacy: .public)")
                activity.readFailed(error)
            }
        }
    }

    /// What a confirmed undo needs, kept while the question is up.
    private struct Pending {
        let log: ActivityLog
        let activity: ActivityLogModel
        let onFinished: @MainActor () -> Void
    }

    private var pending: Pending?

    /// The question's Undo button.
    func confirm() {
        guard case .confirming(let plan) = phase, let pending else { return }
        self.pending = nil
        execute(plan, log: pending.log, activity: pending.activity, onFinished: pending.onFinished)
    }

    /// Stops between files. Files already put back stay put back.
    func stop() {
        task?.cancel()
    }

    /// Closes the sheet: declines the question, or leaves the summary. Never while files are moving.
    func dismiss() {
        guard !isExecuting else { return }
        phase = nil
        pending = nil
        presented = nil
    }

    private func execute(_ plan: UndoPlan, log: ActivityLog, activity: ActivityLogModel, onFinished: @escaping @MainActor () -> Void) {
        phase = .executing(plan, UndoProgress(itemsCompleted: 0, itemsTotal: plan.steps.count))
        logger.info("Undoing \(plan.steps.count) changes")
        let executor = CleanupExecutor(recorder: log)
        // Weak throughout: the task must not keep the model alive, and `deinit` cancels the task.
        task = Task { [weak self] in
            let result = await executor.undo(plan) { progress in
                Task { @MainActor in
                    self?.report(progress)
                }
            }
            // The log state and the file list hear of every undo, even one whose window has gone.
            activity.undoFinished(result)
            onFinished()
            self?.finish(result)
        }
    }

    private func report(_ progress: UndoProgress) {
        guard case .executing(let plan, _) = phase else { return }
        phase = .executing(plan, progress)
    }

    private func finish(_ result: UndoResult) {
        guard isExecuting else { return }
        phase = .finished(result)
        task = nil
        logger.info("Undid \(result.undone.count) changes; \(result.notUndone.count) not undone")
    }
}
