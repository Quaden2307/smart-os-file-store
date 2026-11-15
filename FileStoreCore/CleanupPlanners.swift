import Foundation

/// Why a planner produced no plan.
public enum CleanupPlanningError: Error, Sendable, Hashable {
    /// The task running the planner was cancelled before it finished.
    case cancelled
}

/// Every cleanup action's planner, reached the same way: the app plans only through here, and tests
/// run every planner listed here, so a planner that proposed a Kept item, say, would fail them
/// without a test of its own. A new action states its planner here, and the switch makes that a
/// compile-time duty.
public enum CleanupPlanners {
    /// Plans `action` for `records`, which come from one scan of `folderURL`. Nothing on disk changes.
    ///
    /// - Parameters:
    ///   - eligibility: The rules every action shares.
    ///   - keptItems: The Kept list as just read from the activity log. It is not optional: a plan
    ///     made without the list could propose a Kept file.
    ///   - onProgress: Called from planning threads while files are read, quickly and not too often.
    /// - Returns: The plan, or nil while the action has no planner yet.
    /// - Throws: `.cancelled` when the task is cancelled.
    @concurrent
    public static func plan(
        _ action: CleanupAction,
        records: [FileRecord],
        in folderURL: URL,
        eligibility: CandidateEligibility,
        keptItems: KeptItems,
        now: Date = .now,
        onProgress: (@Sendable (DuplicateScanProgress) -> Void)? = nil
    ) async throws(CleanupPlanningError) -> CleanupPlan? {
        let eligibility = eligibility.keeping(keptItems)
        switch action {
        case .findDuplicates:
            do throws(DuplicatePlanError) {
                return try await DuplicatePlanner(eligibility: eligibility)
                    .plan(records: records, in: folderURL, now: now, onProgress: onProgress)
            } catch {
                switch error {
                case .cancelled:
                    throw .cancelled
                }
            }
        case .fixMessyNames, .archiveOldDownloads:
            return nil
        }
    }
}
