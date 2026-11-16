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
    ///   - installers: What Remove Used Installers reads besides the folder: the application folders,
    ///     the facts cache, the mount folder and the receipts. The other actions read none of it. It
    ///     is not optional either: a default would read the real Applications folder from a test.
    ///   - hashCache: Content hashes read earlier in this session. Find Duplicates adds what it reads
    ///     to it; Review Near-Duplicates reads from it and adds to it. The default remembers nothing.
    ///   - onProgress: Called from planning threads while files are read, quickly and not too often.
    ///     Only an action that reads files reports any: Find Duplicates the files it hashes and their
    ///     bytes, Remove Unpacked Zips the zips it checks, Remove Used Installers the installers.
    ///     Fix Messy Names reads only files that might be duplicates of each other, and Review
    ///     Near-Duplicates only files with the same cleaned name; neither reports any.
    /// - Returns: The plan, or nil while the action has no planner yet.
    /// - Throws: `.cancelled` when the task is cancelled.
    @concurrent
    public static func plan(
        _ action: CleanupAction,
        records: [FileRecord],
        in folderURL: URL,
        eligibility: CandidateEligibility,
        keptItems: KeptItems,
        installers: InstallerSources,
        now: Date = .now,
        hashCache: ContentHashCache = ContentHashCache(),
        onProgress: (@Sendable (CleanupPlanningProgress) -> Void)? = nil
    ) async throws(CleanupPlanningError) -> CleanupPlan? {
        let eligibility = eligibility.keeping(keptItems)
        guard let planner = planner(for: action) else {
            return nil
        }
        switch planner {
        case .duplicates:
            var hashingProgress: (@Sendable (DuplicateScanProgress) -> Void)?
            if let onProgress {
                hashingProgress = { progress in onProgress(CleanupPlanningProgress(progress)) }
            }
            do throws(DuplicatePlanError) {
                return try await DuplicatePlanner(eligibility: eligibility, hashCache: hashCache)
                    .plan(records: records, in: folderURL, now: now, onProgress: hashingProgress)
            } catch {
                switch error {
                case .cancelled:
                    throw .cancelled
                }
            }
        case .failedDownloads:
            return FailedDownloadPlanner(eligibility: eligibility).plan(records: records, in: folderURL, now: now)
        case .unpackedZips:
            return try await UnpackedZipPlanner(eligibility: eligibility)
                .plan(records: records, in: folderURL, now: now, onProgress: onProgress)
        case .usedInstallers:
            return try await InstallerPlanner(eligibility: eligibility)
                .plan(records: records, in: folderURL, sources: installers, now: now, onProgress: onProgress)
        case .messyNames:
            return try await MessyNamePlanner(eligibility: eligibility).plan(records: records, in: folderURL, now: now)
        case .nearDuplicates:
            return try await NearDuplicatePlanner(eligibility: eligibility, hashCache: hashCache)
                .plan(records: records, in: folderURL, now: now)
        }
    }

    /// True when `action` has a planner: the actions the app offers. The rest arrive in their own
    /// segments; until then `plan` returns nil for them.
    public static func hasPlanner(_ action: CleanupAction) -> Bool {
        planner(for: action) != nil
    }

    /// The engine's planners.
    private enum Planner {
        case duplicates
        case failedDownloads
        case unpackedZips
        case usedInstallers
        case messyNames
        case nearDuplicates
    }

    /// Each action's planner, in one list that both `plan` and `hasPlanner` read. Nil while the
    /// action has none.
    private static func planner(for action: CleanupAction) -> Planner? {
        switch action {
        case .findDuplicates:
            .duplicates
        case .clearFailedDownloads:
            .failedDownloads
        case .removeUnpackedZips:
            .unpackedZips
        case .removeUsedInstallers:
            .usedInstallers
        case .fixMessyNames:
            .messyNames
        case .reviewNearDuplicates:
            .nearDuplicates
        case .archiveOldDownloads:
            nil
        }
    }
}
