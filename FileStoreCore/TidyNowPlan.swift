import Foundation

/// What Tidy Now found: every action's plan over one scan, with the overlap between them resolved,
/// so that each file appears in exactly one of them. A pure value, like every plan: nothing on disk
/// changes until the user confirms, and the executor checks every item again
/// (`CleanupExecutor.executeTidyNow`).
public struct TidyNowPlan: Sendable, Hashable {
    /// What one action's planner gave.
    public enum Outcome: Sendable, Hashable {
        /// Its plan, less what a higher-ranked action claimed.
        case planned(CleanupPlan)
        /// It could not finish: it threw, or stopped on its own. The other actions are unaffected.
        case failed
    }

    public let folder: ManagedFolder

    public var folderURL: URL { folder.url }

    /// Each action's outcome, in `TidyNowPlan.order`.
    public let outcomes: [(action: CleanupAction, outcome: Outcome)]

    public init(folder: ManagedFolder, outcomes: [(action: CleanupAction, outcome: Outcome)]) {
        self.folder = folder
        self.outcomes = outcomes
    }

    public static func == (lhs: TidyNowPlan, rhs: TidyNowPlan) -> Bool {
        lhs.folderURL == rhs.folderURL && lhs.outcomes.elementsEqual(rhs.outcomes) { $0.action == $1.action && $0.outcome == $1.outcome }
    }

    public func hash(into hasher: inout Hasher) {
        hasher.combine(folderURL)
        for entry in outcomes {
            hasher.combine(entry.action)
            hasher.combine(entry.outcome)
        }
    }

    /// The resolved plans, in `order`.
    public var plans: [CleanupPlan] {
        outcomes.compactMap { entry in
            if case .planned(let plan) = entry.outcome {
                return plan
            }
            return nil
        }
    }

    /// The copies Find Duplicates would remove: the files the list marks Duplicate after a Tidy
    /// Now scan.
    public var duplicateURLs: Set<URL> {
        Set(plans.filter { $0.action == .findDuplicates }.flatMap { $0.changes.map(\.id) })
    }

    // MARK: - The priority rule

    /// Where a change stands when two actions propose the same file.
    enum Rank: Int, Comparable, CaseIterable {
        case failedDownload, usedInstaller, unpackedZip, duplicate, emptyFolder, archive, messyName
        // Review only: shown, never ticked, and below everything that is.
        case possibleInstaller, nearDuplicate, largeDownload

        static func < (lhs: Rank, rhs: Rank) -> Bool { lhs.rawValue < rhs.rawValue }

        init?(_ change: ProposedChange, in action: CleanupAction) {
            switch action {
            case .clearFailedDownloads: self = .failedDownload
            case .removeUsedInstallers: self = change.reason.isPossibleMatch ? .possibleInstaller : .usedInstaller
            case .removeUnpackedZips: self = .unpackedZip
            case .findDuplicates: self = .duplicate
            case .removeEmptyFolders: self = .emptyFolder
            case .archiveOldDownloads: self = .archive
            case .fixMessyNames: self = .messyName
            case .reviewNearDuplicates: self = .nearDuplicate
            case .reviewLargeDownloads: self = .largeDownload
            }
        }
    }

    /// The order the overview lists actions in, and the order their Trash changes are carried out:
    /// the priority, highest first. Each action appears once; Remove Used Installers' possible
    /// matches rank with the review lists, below every ticked change.
    public static let order: [CleanupAction] = [
        .clearFailedDownloads, .removeUsedInstallers, .removeUnpackedZips, .findDuplicates,
        .removeEmptyFolders, .archiveOldDownloads, .fixMessyNames, .reviewNearDuplicates, .reviewLargeDownloads,
    ]

    /// `plans` with the overlap between them resolved. Pure.
    ///
    /// - A change that is not directly inside the folder, or that the shared rules refuse at `now`
    ///   (Kept, in the grace period, a hidden or archive name, a download in progress except for
    ///   Clear Failed Downloads), is dropped, whatever its planner said.
    /// - Each file belongs to the highest-ranked change proposing it (`Rank`): failed downloads,
    ///   used installers (strong matches), unpacked zips, duplicates, empty folders, archive, messy
    ///   names, then the review lists. Lower-ranked changes to it are dropped.
    /// - A duplicate group whose kept copy goes to the Trash by a higher-ranked change loses its
    ///   duplicates, which may then belong to a lower-ranked action, so one copy always stays. A
    ///   group that stays keeps its kept copy out of every lower-ranked Trash change; the kept copy
    ///   may still be archived or renamed.
    /// - A zip that goes to the Trash because it sits unpacked beside it keeps its unpacked copy
    ///   out of every lower-ranked Trash change, so the run never trashes both.
    /// - Two changes never share a destination; the lower-ranked one is dropped.
    /// - A near-duplicate group left with one file goes (`CleanupPlan.removing`).
    public static func resolve(_ plans: [CleanupPlan], eligibility: CandidateEligibility, now: Date) -> [CleanupPlan] {
        let plans = order.compactMap { action in plans.first { $0.action == action } }
        // Every change, by rank, then by its plan's order, then by its place in the plan.
        var ranked: [(rank: Rank, planIndex: Int, change: ProposedChange)] = []
        for (index, plan) in plans.enumerated() {
            for change in plan.changes {
                if let rank = Rank(change, in: plan.action) {
                    ranked.append((rank, index, change))
                }
            }
        }
        ranked = ranked.enumerated()
            .sorted { ($0.element.rank, $0.offset) < ($1.element.rank, $1.offset) }
            .map(\.element)

        var dropped = Array(repeating: Set<ProposedChange.ID>(), count: plans.count)
        var claimed: Set<URL> = []
        var trashedAbove: Set<URL> = []
        var destinations: Set<String> = []
        // Kept copies of the duplicate groups that stay, once duplicates have been ranked.
        var protectedKept: Set<URL> = []
        // The unpacked copies of the zips that go to the Trash, by `pathKey`.
        var protectedUnpacked: Set<String> = []
        var duplicatesRanked = false
        // Each duplicate's kept copy, by the first group that lists it.
        var keptCopyOf: [URL: URL] = [:]
        for plan in plans where plan.action == .findDuplicates {
            for group in plan.duplicateGroups {
                for duplicate in group.duplicates where keptCopyOf[duplicate.url] == nil {
                    keptCopyOf[duplicate.url] = group.kept.url
                }
            }
        }

        for (rank, planIndex, change) in ranked {
            let plan = plans[planIndex]
            if rank > .duplicate, !duplicatesRanked {
                duplicatesRanked = true
                protectedKept = keptCopies(in: plans, excluding: dropped, trashedAbove: trashedAbove)
            }
            let url = change.id
            let destination = destinationKey(of: change, in: plan.folder)
            let keep = isAllowed(change, in: plan, eligibility: eligibility, now: now)
                && !claimed.contains(url)
                && !(change.operation == .moveToTrash && protectedKept.contains(url))
                && !(change.operation == .moveToTrash && protectedUnpacked.contains(pathKey(url)))
                && !(rank == .duplicate && keptCopyOf[url].map(trashedAbove.contains) == true)
                && destination.map { !destinations.contains($0) } ?? true
            guard keep else {
                dropped[planIndex].insert(url)
                continue
            }
            // shortcut: a near-duplicate claims its file before its group is known to survive, so a
            // partner whose group collapses later is in no list this time; rank groups whole if that matters.
            claimed.insert(url)
            if let destination {
                destinations.insert(destination)
            }
            if change.operation == .moveToTrash {
                trashedAbove.insert(url)
            }
            if case .unpackedZip(unpackedTo: let name) = change.reason {
                protectedUnpacked.insert(pathKey(plan.folderURL.appending(path: name)))
            }
        }
        return plans.enumerated().map { index, plan in plan.removing(dropped[index]) }
    }

    /// The order a confirmed Tidy Now is carried out in: every move to the Trash, by priority, then
    /// the moves into the archive, then the renames, so nothing is renamed or filed away before the
    /// files whose checks name it have gone.
    static func executionSegments(_ plans: [CleanupPlan]) -> [CleanupExecutor.Segment] {
        let plans = order.compactMap { action in plans.first { $0.action == action } }
        func segments(_ matches: (ProposedChange.Operation) -> Bool) -> [CleanupExecutor.Segment] {
            plans.map { plan in CleanupExecutor.Segment(plan: plan, changes: plan.changes.filter { matches($0.operation) }) }
        }
        return segments { $0 == .moveToTrash }
            + segments { if case .move = $0 { true } else { false } }
            + segments { if case .rename = $0 { true } else { false } }
    }

    // MARK: - Helpers

    private static func isAllowed(_ change: ProposedChange, in plan: CleanupPlan, eligibility: CandidateEligibility, now: Date) -> Bool {
        guard change.record.url.deletingLastPathComponent().standardizedFileURL.pathComponents
            == plan.folderURL.standardizedFileURL.pathComponents else {
            return false
        }
        let downloads: CandidateEligibility.DownloadsInProgress = plan.action == .clearFailedDownloads ? .allowed : .refused
        return eligibility.refusal(for: change.record, in: plan.folder, now: now, downloads: downloads) == nil
    }

    /// For a rename or a move, where the file would end up, compared without regard to case or
    /// Unicode form, as the disk would. Nil for the Trash.
    private static func destinationKey(of change: ProposedChange, in folder: ManagedFolder) -> String? {
        let folderURL = folder.url
        let url: URL
        switch change.operation {
        case .moveToTrash:
            return nil
        case .rename(to: let name):
            url = folderURL.appending(path: name)
        case .move(to: let folder, name: let name):
            url = folder.appending(path: name)
        }
        return pathKey(url)
    }

    /// A path compared without regard to case, Unicode form or a folder's trailing slash, as the
    /// disk would compare it.
    private static func pathKey(_ url: URL) -> String {
        var path = url.standardizedFileURL.path(percentEncoded: false)
        if path.count > 1, path.hasSuffix("/") {
            path.removeLast()
        }
        return path.precomposedStringWithCanonicalMapping.lowercased()
    }

    /// The kept copies of the duplicate groups that keep at least one duplicate.
    private static func keptCopies(in plans: [CleanupPlan], excluding dropped: [Set<ProposedChange.ID>], trashedAbove: Set<URL>) -> Set<URL> {
        var kept: Set<URL> = []
        for (index, plan) in plans.enumerated() where plan.action == .findDuplicates {
            for group in plan.duplicateGroups
            where !trashedAbove.contains(group.kept.url) && group.duplicates.contains(where: { !dropped[index].contains($0.id) }) {
                kept.insert(group.kept.url)
            }
        }
        return kept
    }
}
