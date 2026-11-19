import Foundation

/// What a confirmed Tidy Now did: one result per action that had changes confirmed, all from one
/// run of the activity log, so one undo reverses the whole tidy.
public struct TidyNowResult: Sendable, Hashable {
    /// Each action's items, in `TidyNowPlan.order`. Every result carries the run's identifier.
    public let results: [CleanupResult]

    public let runID: ActivityRun.ID?

    public let wasCancelled: Bool

    public let logFailure: CleanupLogFailure?

    public init(results: [CleanupResult], runID: ActivityRun.ID?, wasCancelled: Bool, logFailure: CleanupLogFailure?) {
        self.results = results
        self.runID = runID
        self.wasCancelled = wasCancelled
        self.logFailure = logFailure
    }

    /// Bytes moved to the Trash, across every action.
    public var bytesFreed: Int64 { results.reduce(0) { $0 + $1.bytesFreed } }

    public var hasDoneItems: Bool { results.contains(where: \.hasDoneItems) }
}

extension CleanupExecutor {
    /// Carries out the confirmed changes of a Tidy Now's resolved plans as one run: every move to
    /// the Trash by priority, then every move into the archive, then every rename
    /// (`TidyNowPlan.executionSegments`). Each item is checked by its own action's rules, as
    /// `execute(plan:)` checks it, against the disk as the earlier items left it.
    ///
    /// - Parameters:
    ///   - confirmedChangeIDs: The ticked changes of every plan. A file listed by two plans is
    ///     tried once, for the first.
    ///   - origin: Where the user confirmed it, which the activity log records.
    @concurrent
    public func executeTidyNow(
        plans: [CleanupPlan],
        confirmedChangeIDs: Set<ProposedChange.ID>,
        origin: RunOrigin = .app,
        now: Date = .now,
        onProgress: (@Sendable (CleanupExecutionProgress) -> Void)? = nil,
        beforeChange: (@Sendable (ProposedChange) -> Void)? = nil
    ) async -> TidyNowResult {
        let segments = TidyNowPlan.executionSegments(plans)
        // Every plan of one Tidy Now names the same folder; one that does not is not carried out.
        guard let folderURL = segments.first?.plan.folderURL else {
            return TidyNowResult(results: [], runID: nil, wasCancelled: false, logFailure: nil)
        }
        let usable = segments.filter { $0.plan.folderURL == folderURL }
        let outcome = await run(
            usable,
            confirmedChangeIDs: confirmedChangeIDs,
            start: { count in
                CleanupRunStart.tidyNow(folderURL: folderURL, confirmedCount: count, startedAt: .now, origin: origin)
            },
            now: now,
            onProgress: onProgress,
            beforeChange: beforeChange
        )
        let results = TidyNowPlan.order.compactMap { action -> CleanupResult? in
            let items = outcome.items.filter { $0.action == action }.map(\.item)
            guard !items.isEmpty, let plan = usable.first(where: { $0.plan.action == action })?.plan else {
                return nil
            }
            return CleanupResult(
                action: action,
                folderURL: plan.folderURL,
                items: items,
                wasCancelled: outcome.wasCancelled,
                logFailure: outcome.logFailure,
                runID: outcome.runID
            )
        }
        let done = results.reduce(0) { $0 + $1.items.filter(\.isDone).count }
        Self.logger.info(
            "Tidy Now: \(done) of \(outcome.items.count) confirmed changes done across \(results.count) actions, cancelled: \(outcome.wasCancelled)"
        )
        return TidyNowResult(results: results, runID: outcome.runID, wasCancelled: outcome.wasCancelled, logFailure: outcome.logFailure)
    }
}
