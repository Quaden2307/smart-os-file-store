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
    ///   - settings: The thresholds behind the age marks, which Archive Old Downloads plans by: the
    ///     ones the file list marks with, so the two never disagree. Review Large Downloads plans by
    ///     its size threshold.
    ///   - hashCache: Content hashes read earlier in this session. Find Duplicates adds what it reads
    ///     to it; Review Near-Duplicates, Fix Messy Names and Archive Old Downloads read from it and
    ///     add to it. The default remembers nothing.
    ///   - onProgress: Called from planning threads while files are read, quickly and not too often.
    ///     Only an action that reads files reports any: Find Duplicates the files it hashes and their
    ///     bytes, Remove Unpacked Zips the zips it checks, Remove Used Installers the installers.
    ///     Fix Messy Names reads only files that might be duplicates of each other, and Review
    ///     Near-Duplicates only files with the same cleaned name, and Archive Old Downloads only files
    ///     with the name of one in the archive; none of them reports any. Review Large Downloads reads
    ///     nothing, nor does Remove Empty Folders: the scan read what they need.
    /// - Returns: The plan, or nil while the action has no planner yet, or the folder's rules do not
    ///   offer it. `settings` gives way to the folder's own thresholds where it has any.
    /// - Throws: `.cancelled` when the task is cancelled.
    @concurrent
    public static func plan(
        _ action: CleanupAction,
        records: [FileRecord],
        in folder: ManagedFolder,
        eligibility: CandidateEligibility,
        keptItems: KeptItems,
        installers: InstallerSources,
        now: Date = .now,
        settings: CleanupSettings = CleanupSettings(),
        hashCache: ContentHashCache = ContentHashCache(),
        onProgress: (@Sendable (CleanupPlanningProgress) -> Void)? = nil
    ) async throws(CleanupPlanningError) -> CleanupPlan? {
        let eligibility = eligibility.keeping(keptItems)
        // An action the folder does not offer is never planned there, whoever asks.
        guard let planner = planner(for: action), folder.rules.offers(action) else {
            return nil
        }
        let settings = folder.rules.settings(over: settings)
        switch planner {
        case .duplicates:
            var hashingProgress: (@Sendable (DuplicateScanProgress) -> Void)?
            if let onProgress {
                hashingProgress = { progress in onProgress(CleanupPlanningProgress(progress)) }
            }
            do throws(DuplicatePlanError) {
                return try await DuplicatePlanner(eligibility: eligibility, hashCache: hashCache)
                    .plan(records: records, in: folder, now: now, onProgress: hashingProgress)
            } catch {
                switch error {
                case .cancelled:
                    throw .cancelled
                }
            }
        case .failedDownloads:
            return FailedDownloadPlanner(eligibility: eligibility).plan(records: records, in: folder, now: now)
        case .unpackedZips:
            return try await UnpackedZipPlanner(eligibility: eligibility)
                .plan(records: records, in: folder, now: now, onProgress: onProgress)
        case .usedInstallers:
            return try await InstallerPlanner(eligibility: eligibility)
                .plan(records: records, in: folder, sources: installers, now: now, onProgress: onProgress)
        case .messyNames:
            return try await MessyNamePlanner(eligibility: eligibility, hashCache: hashCache).plan(records: records, in: folder, now: now)
        case .nearDuplicates:
            return try await NearDuplicatePlanner(eligibility: eligibility, hashCache: hashCache)
                .plan(records: records, in: folder, now: now)
        case .archive:
            return try await ArchivePlanner(eligibility: eligibility, settings: settings, hashCache: hashCache).plan(records: records, in: folder, now: now)
        case .largeDownloads:
            return LargeFilePlanner(eligibility: eligibility, settings: settings).plan(records: records, in: folder, now: now)
        case .emptyFolders:
            return EmptyFolderPlanner(eligibility: eligibility).plan(records: records, in: folder, now: now)
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
        case archive
        case largeDownloads
        case emptyFolders
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
            .archive
        case .reviewLargeDownloads:
            .largeDownloads
        case .removeEmptyFolders:
            .emptyFolders
        }
    }
}
