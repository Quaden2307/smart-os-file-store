import FileStoreCore
import FileStoreIntelligence
import Foundation

/// What the app hands the chat's tools from the engine, with nothing of the window in it. The app
/// (`ChatModel`) and the evals (`ChatEvals`) compile this same file, so the evals plan, find copies
/// and copy rows exactly as the chat bar does (docs/decisions/0033). The chat module imports none
/// of the engine, so the app copies what the chat may know, field for field (docs/decisions/0020).
enum ChatPlanning {
    /// The actions `proposeCleanup` offers, from the action registry: an action added there is
    /// offered with no other change.
    static var cleanupActions: [String] {
        CleanupAction.allCases.filter(CleanupPlanners.hasPlanner).map(\.definition.identifier)
    }

    /// The actions `request` names that the folder's rules turn off. They are never planned there
    /// (the planners refuse them); the reply says so instead.
    static func notOffered(_ request: CleanupRequest, rules: FolderRules?) -> [String] {
        CleanupAction.allCases
            .filter { request.actions.contains($0.definition.identifier) && rules?.offers($0) == false }
            .map(\.definition.identifier)
    }

    /// Plans the cleanups `request` names, narrowed to `ids`, as Tidy Now plans them. The
    /// request's own numbers stand in for `stored`, for this plan only. Reads files, changes none.
    static func plan(
        _ request: CleanupRequest, only ids: Set<URL>?, records: [FileRecord], folder: ManagedFolder,
        eligibility: CandidateEligibility, keptItems: KeptItems, installers: InstallerSources,
        stored: CleanupSettings, hashCache: ContentHashCache, now: Date
    ) async throws(CleanupPlanningError) -> TidyNowPlan {
        let settings = CleanupSettings(
            unusedAfterDays: request.archiveAfterDays ?? stored.unusedAfterDays,
            oldAfterDays: stored.oldAfterDays,
            largeDownloadMegabytes: request.largeFileMB ?? stored.largeDownloadMegabytes
        )
        let planner = TidyNowPlanner(
            actions: CleanupAction.allCases.filter { request.actions.contains($0.definition.identifier) },
            eligibility: eligibility, keptItems: keptItems, installers: installers,
            settings: settings, records: records, folder: folder, now: now
        )
        return try await planner.plan(only: ids, hashCache: hashCache)
    }

    /// False when nothing was found and an action could not be checked: "nothing to clean up"
    /// would then be a guess. With something found, the card says which action failed.
    static func isWorthACard(_ plan: TidyNowPlan) -> Bool {
        plan.plans.contains(where: { !$0.isEmpty }) || !plan.outcomes.contains(where: { $0.outcome == .failed })
    }

    /// The rows `proposeCleanup` hands back for `plan`: per action a count, the bytes and the ticks.
    static func proposal(_ plan: TidyNowPlan, for request: CleanupRequest, notOffered: [String]) -> CleanupProposal {
        let found = plan.plans.filter { !$0.isEmpty }
        return CleanupProposal(
            request: request,
            rows: found.map { plan in
                CleanupProposal.Row(
                    action: plan.action.definition.identifier, count: plan.changes.count, bytes: plan.bytesToFree,
                    tickedCount: plan.defaultTickedIDs.count
                )
            },
            sampleNames: found.flatMap(\.changes).prefix(CleanupProposal.sampleNamesShown).map(\.record.displayName),
            notOffered: notOffered
        )
    }

    /// Find Duplicates as the Clean Up menu runs it, for a question in the chat. Reads files, changes none.
    static func findDuplicates(
        records: [FileRecord], folder: ManagedFolder, eligibility: CandidateEligibility, keptItems: KeptItems,
        installers: InstallerSources, hashCache: ContentHashCache, now: Date
    ) async throws(CleanupPlanningError) -> CleanupPlan? {
        try await CleanupPlanners.plan(
            .findDuplicates, records: records, in: folder, eligibility: eligibility, keptItems: keptItems,
            installers: installers, now: now, hashCache: hashCache
        )
    }

    /// Find Duplicates' groups as plain rows, with the marks the list shows on each file, and how
    /// many files were left out for being new.
    static func duplicateScan(
        _ plan: CleanupPlan, records: [FileRecord], folder: ManagedFolder, eligibility: CandidateEligibility,
        marks: (FileRecord) -> [FileMark], folderName: String?, now: Date
    ) -> DuplicateScan {
        func row(_ record: FileRecord) -> FolderSnapshot.File {
            FolderSnapshot.File(record, marks: marks(record), folder: folderName)
        }
        let recent = records.filter { $0.kind == .file && eligibility.refusal(for: $0, in: folder, now: now) == .insideGracePeriod }.count
        return DuplicateScan(
            groups: plan.duplicateGroups.map { DuplicateScan.Group(kept: row($0.kept), copies: $0.duplicates.map(row)) },
            unreadableCount: plan.skippedItems.count,
            recentCount: recent
        )
    }
}

extension FolderSnapshot.File {
    init(_ record: FileRecord, marks: [FileMark], folder: String? = nil) {
        self.init(
            id: record.id,
            name: record.displayName,
            contentType: record.contentType,
            sizeInBytes: record.sizeInBytes,
            dateAdded: record.dateAdded,
            lastOpened: record.lastOpened,
            recordsOpens: record.recordsLastOpened,
            isDownloading: record.isDownloading,
            sourceSite: record.downloadSource?.site,
            marks: Set(marks.compactMap(\.chatMark)),
            folder: folder
        )
    }
}

extension FileMark {
    /// Exhaustive on purpose: a new mark does not compile until the chat knows it. Nil for
    /// Duplicate, which only says what the last Tidy Now found: the chat reads the files instead.
    var chatMark: FolderSnapshot.Mark? {
        switch self {
        case .kept: .kept
        case .failedDownload: .failedDownload
        case .installed: .installed
        case .duplicate: nil
        case .neverOpened: .neverOpened
        case .unused: .unused
        case .old: .old
        }
    }
}

extension FolderSnapshot.Mark {
    var fileMark: FileMark {
        switch self {
        case .kept: .kept
        case .failedDownload: .failedDownload
        case .installed: .installed
        case .neverOpened: .neverOpened
        case .unused: .unused
        case .old: .old
        }
    }
}
