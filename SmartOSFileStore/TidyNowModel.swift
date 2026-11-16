import FileStoreCore
import Foundation
import Observation
import os

/// State of a Tidy Now: every action planned over one scan, the overview of what they found, each
/// action's ticks as the user leaves them in its preview, one confirmation for all of it, and the
/// run with its summary. Lives on the main actor; planning and the executor run elsewhere.
@MainActor
@Observable
final class TidyNowModel {
    enum Phase: Equatable {
        case planning
        case reviewing
        case executing(CleanupExecutionProgress)
        case finished(TidyNowResult)
    }

    /// One row of the overview: an action's changes, or for Remove Used Installers, its strong
    /// matches in one row and its possible matches, for review, in another.
    struct Category: Identifiable, Equatable {
        enum Kind: Equatable {
            case action
            case possibleInstallers
        }

        let action: CleanupAction
        let kind: Kind
        let changes: [ProposedChange]

        var id: String { "\(action.definition.identifier).\(kind)" }

        /// Shown in "For you to review", never ticked for the user.
        var isReview: Bool {
            kind == .possibleInstallers || action == .reviewNearDuplicates || action == .reviewLargeDownloads
        }

        var title: String {
            kind == .possibleInstallers ? String(localized: "Possible Installer Matches") : action.title
        }
    }

    private(set) var phase: Phase = .planning

    /// How far each action has got while planning, for those that report it.
    private(set) var progress: [CleanupAction: CleanupPlanningProgress] = [:]

    /// The actions that have finished planning.
    private(set) var finishedActions: Set<CleanupAction> = []

    /// The actions whose planner could not finish. Their rows say so; the rest are unaffected.
    private(set) var failedActions: Set<CleanupAction> = []

    /// Each action's resolved plan, less what Keep This File took out of it in its preview.
    private(set) var plans: [CleanupAction: CleanupPlan] = [:]

    /// Each action's ticked changes, as its preview last left them.
    private(set) var ticked: [CleanupAction: Set<ProposedChange.ID>] = [:]

    /// The action whose preview is shown in place of the overview, if any.
    private(set) var openAction: CleanupAction?

    /// True while the confirmation sheet is up.
    var isConfirming = false

    /// The actions planned, in overview order.
    let actions = TidyNowPlan.order.filter(CleanupPlanners.hasPlanner)

    private let executor: CleanupExecutor
    private let activity: ActivityLogModel
    private let onPlanned: @MainActor (TidyNowPlan) -> Void
    private let onExecuted: @MainActor () -> Void
    private var task: Task<Void, Never>?
    private let logger = Logger(subsystem: "com.quaden2307.SmartOSFileStore", category: "TidyNow")

    /// - Parameters:
    ///   - onPlanned: Hears the plan once every planner has finished, for the list's Duplicate marks.
    ///   - onExecuted: Hears that the run has ended, so the list can be read again.
    init(
        eligibility: CandidateEligibility,
        applicationFolders: [URL],
        log: ActivityLog,
        activity: ActivityLogModel,
        onPlanned: @escaping @MainActor (TidyNowPlan) -> Void,
        onExecuted: @escaping @MainActor () -> Void
    ) {
        self.executor = CleanupExecutor(recorder: log, eligibility: eligibility, applicationFolders: applicationFolders)
        self.activity = activity
        self.onPlanned = onPlanned
        self.onExecuted = onExecuted
    }

    // Isolated, so it may touch main-actor state: the sheet is gone, stop planning or stop between items.
    isolated deinit {
        task?.cancel()
    }

    // MARK: - Planning

    /// Plans every action over `records`, one scan of `folderURL`, with the Kept list as `log` holds
    /// it now. If the list cannot be read, nothing is planned and the failure goes to `activity`.
    func start(
        records: [FileRecord],
        folderURL: URL,
        eligibility: CandidateEligibility,
        applicationFolders: [URL],
        hashCache: ContentHashCache,
        log: ActivityLog
    ) {
        guard phase == .planning, task == nil else { return }
        let settings = CleanupSettings.load(from: UserDefaults.standard)
        let activity = activity
        let opening = activity.openings
        logger.info("Tidy Now over \(records.count) records")
        task = Task { [weak self] in
            let keptItems: KeptItems
            do throws(ActivityLogError) {
                keptItems = try await log.keptItems(forFolder: folderURL)
            } catch {
                guard !Task.isCancelled else { return }
                if activity.openings == opening {
                    activity.logFailed(error)
                }
                self?.failAll()
                return
            }
            let planner = TidyNowPlanner(
                eligibility: eligibility,
                keptItems: keptItems,
                installers: .standard(applicationFolders: applicationFolders, cache: log),
                settings: settings,
                records: records,
                folderURL: folderURL
            )
            do throws(CleanupPlanningError) {
                let plan = try await planner.plan(hashCache: hashCache) { event in
                    Task { @MainActor in
                        self?.report(event)
                    }
                }
                // What was read from installers is kept, so the next search reads none of them again.
                let read = plan.plans.flatMap(\.installerFactsRead)
                if !read.isEmpty {
                    do throws(ActivityLogError) {
                        try await log.storeInstallerFacts(read)
                    } catch {
                        self?.logger.error("What was read from installers could not be kept: \(String(describing: error), privacy: .public)")
                    }
                }
                guard !Task.isCancelled else { return }
                self?.finishPlanning(plan)
            } catch {
                // Cancelled: the sheet has gone, or is going.
            }
        }
    }

    func cancel() {
        task?.cancel()
        task = nil
    }

    private func report(_ event: TidyNowPlanningEvent) {
        guard phase == .planning else { return }
        switch event {
        case .progress(let action, let progress):
            if !finishedActions.contains(action) {
                self.progress[action] = progress
            }
        case .finished(let action, let failed):
            finishedActions.insert(action)
            if failed {
                failedActions.insert(action)
            }
        }
    }

    private func failAll() {
        task = nil
        failedActions = Set(actions)
        finishedActions = Set(actions)
        phase = .reviewing
    }

    private func finishPlanning(_ plan: TidyNowPlan) {
        guard phase == .planning else { return }
        task = nil
        for (action, outcome) in plan.outcomes {
            switch outcome {
            case .planned(let resolved):
                plans[action] = resolved
                // As in each action's own preview: nothing review-only, and no possible match.
                ticked[action] = Set(resolved.changes.filter { !$0.reason.isReviewOnly && !$0.reason.isPossibleMatch }.map(\.id))
            case .failed:
                failedActions.insert(action)
            }
            finishedActions.insert(action)
        }
        phase = .reviewing
        logger.info("Tidy Now planned: \(self.allChanges.count) changes, \(self.failedActions.count) actions failed")
        onPlanned(plan)
    }

    // MARK: - The overview

    var isPlanning: Bool { phase == .planning }
    var isReviewing: Bool { phase == .reviewing }

    var isExecuting: Bool {
        if case .executing = phase {
            return true
        }
        return false
    }

    var result: TidyNowResult? {
        if case .finished(let result) = phase {
            return result
        }
        return nil
    }

    /// Every category that found something, in overview order.
    var categories: [Category] {
        actions.flatMap { action -> [Category] in
            guard let changes = plans[action]?.changes else { return [] }
            if action == .removeUsedInstallers {
                return [
                    Category(action: action, kind: .action, changes: changes.filter { !$0.reason.isPossibleMatch }),
                    Category(action: action, kind: .possibleInstallers, changes: changes.filter(\.reason.isPossibleMatch)),
                ].filter { !$0.changes.isEmpty }
            }
            return changes.isEmpty ? [] : [Category(action: action, kind: .action, changes: changes)]
        }
    }

    /// The actions that planned and found nothing.
    var actionsWithNothingToDo: [CleanupAction] {
        actions.filter { plans[$0]?.changes.isEmpty == true }
    }

    /// True when every action planned and none found anything: the folder is tidy.
    var isTidy: Bool {
        isReviewing && failedActions.isEmpty && categories.isEmpty
    }

    private var allChanges: [ProposedChange] {
        actions.flatMap { plans[$0]?.changes ?? [] }
    }

    /// `category`'s ticked changes.
    func tickedChanges(in category: Category) -> [ProposedChange] {
        let ticked = ticked[category.action] ?? []
        return category.changes.filter { ticked.contains($0.id) }
    }

    /// Every ticked change, of every action.
    var tickedChanges: [ProposedChange] {
        actions.flatMap { action in
            let ticked = ticked[action] ?? []
            return (plans[action]?.changes ?? []).filter { ticked.contains($0.id) }
        }
    }

    var totals: TidyNowTotals {
        TidyNowTotals(tickedChanges)
    }

    var canTidyUp: Bool { isReviewing && openAction == nil && !totals.isEmpty }

    // MARK: - Each action's preview

    func open(_ action: CleanupAction) {
        guard isReviewing, plans[action] != nil else { return }
        openAction = action
    }

    /// The preview's choices, kept for the overview: its plan, less what Keep This File took out,
    /// and its ticks.
    func choose(_ plan: CleanupPlan, ticked: Set<ProposedChange.ID>) {
        guard isReviewing, plans[plan.action] != nil else { return }
        plans[plan.action] = plan
        self.ticked[plan.action] = ticked.intersection(plan.changes.map(\.id))
        openAction = nil
    }

    // MARK: - Carrying out

    func confirm() {
        guard canTidyUp, !isConfirming else { return }
        isConfirming = true
    }

    /// Carries out every ticked change as one run. The confirmation sheet calls this and nothing else.
    func execute() {
        guard canTidyUp else { return }
        let plans = actions.compactMap { self.plans[$0] }
        let confirmed = Set(tickedChanges.map(\.id))
        phase = .executing(CleanupExecutionProgress(itemsCompleted: 0, itemsTotal: confirmed.count, bytesFreed: 0))
        logger.info("Tidy Now carrying out \(confirmed.count) changes")
        let executor = executor
        let activity = activity
        task = Task { [weak self] in
            let result = await executor.executeTidyNow(plans: plans, confirmedChangeIDs: confirmed) { progress in
                Task { @MainActor in
                    self?.report(progress)
                }
            }
            // The app's log state hears of the run, even when its sheet has gone meanwhile.
            activity.runFinished(logFailure: result.logFailure)
            self?.finish(result)
        }
    }

    private func report(_ progress: CleanupExecutionProgress) {
        guard isExecuting else { return }
        phase = .executing(progress)
    }

    private func finish(_ result: TidyNowResult) {
        guard isExecuting else { return }
        task = nil
        phase = .finished(result)
        logger.info("Tidy Now done: \(result.bytesFreed) bytes moved to the Trash, cancelled: \(result.wasCancelled)")
        onExecuted()
    }
}

/// What the ticked changes of a Tidy Now add up to, by operation.
struct TidyNowTotals: Equatable {
    var trashCount = 0
    var trashBytes: Int64 = 0
    var archiveCount = 0
    var renameCount = 0

    init(_ changes: [ProposedChange]) {
        for change in changes {
            switch change.operation {
            case .moveToTrash:
                trashCount += 1
                trashBytes += change.sizeInBytes
            case .move:
                archiveCount += 1
            case .rename:
                renameCount += 1
            }
        }
    }

    var isEmpty: Bool { trashCount + archiveCount + renameCount == 0 }

    /// "Move 14 items to the Trash, archive 9, rename 6", leaving out what is zero.
    var sentence: String {
        var parts: [String] = []
        if trashCount > 0 {
            parts.append(String(localized: "move ^[\(trashCount) item](inflect: true) (\(trashBytes.formattedFileSize)) to the Trash"))
        }
        if archiveCount > 0 {
            parts.append(String(localized: "archive \(archiveCount)"))
        }
        if renameCount > 0 {
            parts.append(String(localized: "rename \(renameCount)"))
        }
        let joined = parts.formatted(.list(type: .and, width: .narrow))
        return joined.prefix(1).uppercased() + joined.dropFirst()
    }
}
