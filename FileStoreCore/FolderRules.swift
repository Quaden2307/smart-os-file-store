import Foundation

/// What one managed folder allows: which cleanup actions are offered there, which of them Tidy Now
/// runs, whether a preview ticks anything for the user, and its own thresholds where it has any.
///
/// Rules are applied where plans are made (`CleanupPlanners`, `TidyNowPlanner`), so an action a
/// folder does not offer cannot be planned for it from any caller, the chat included. Changing
/// rules changes nothing on disk and is not recorded in the activity log.
public struct FolderRules: Sendable, Hashable, Codable {
    /// The actions offered for the folder.
    public var offered: Set<CleanupAction>

    /// The actions Tidy Now runs for the folder. Only offered actions count.
    public var inTidyNow: Set<CleanupAction>

    /// False where nothing is ticked in a preview until the user ticks it (Documents and folders
    /// the user added: files there are things people made).
    public var ticksByDefault: Bool

    /// The folder's own thresholds. Nil uses the global setting.
    public var unusedAfterDays: Int?
    public var oldAfterDays: Int?
    public var largeFileMegabytes: Int?

    public init(
        offered: Set<CleanupAction>,
        inTidyNow: Set<CleanupAction>,
        ticksByDefault: Bool,
        unusedAfterDays: Int? = nil,
        oldAfterDays: Int? = nil,
        largeFileMegabytes: Int? = nil
    ) {
        self.offered = offered
        self.inTidyNow = inTidyNow
        self.ticksByDefault = ticksByDefault
        self.unusedAfterDays = unusedAfterDays
        self.oldAfterDays = oldAfterDays
        self.largeFileMegabytes = largeFileMegabytes
    }

    /// True when `action` may be planned for the folder.
    public func offers(_ action: CleanupAction) -> Bool {
        offered.contains(action)
    }

    /// The actions Tidy Now runs, in `TidyNowPlan.order`.
    public var tidyNowActions: [CleanupAction] {
        TidyNowPlan.order.filter { inTidyNow.contains($0) && offered.contains($0) }
    }

    /// The thresholds for the folder: its own where it has one, the global one otherwise.
    public func settings(over global: CleanupSettings) -> CleanupSettings {
        CleanupSettings(
            unusedAfterDays: unusedAfterDays ?? global.unusedAfterDays,
            oldAfterDays: oldAfterDays ?? global.oldAfterDays,
            largeDownloadMegabytes: largeFileMegabytes ?? global.largeDownloadMegabytes
        )
    }

    /// The defaults, in one table (decision record 0028):
    ///
    /// | Folder | Offered | Tidy Now | Ticks |
    /// |---|---|---|---|
    /// | Downloads | every action | every action | yes |
    /// | Desktop | every action but Archive Old | duplicates, messy names, near-duplicates, large, empty folders | yes |
    /// | Documents, custom | duplicates, near-duplicates, large, empty folders | none | no |
    public static func defaults(for kind: ManagedFolder.Kind) -> FolderRules {
        switch kind {
        case .downloads:
            let all = Set(CleanupAction.allCases)
            return FolderRules(offered: all, inTidyNow: all, ticksByDefault: true)
        case .desktop:
            return FolderRules(
                offered: Set(CleanupAction.allCases).subtracting([.archiveOldDownloads]),
                inTidyNow: [.findDuplicates, .fixMessyNames, .reviewNearDuplicates, .reviewLargeDownloads, .removeEmptyFolders],
                ticksByDefault: true
            )
        case .documents, .custom:
            // Nothing that removes a file because of its age: Archive Old is not offered, and
            // nothing else plans by age.
            return FolderRules(
                offered: [.findDuplicates, .reviewNearDuplicates, .reviewLargeDownloads, .removeEmptyFolders],
                inTidyNow: [],
                ticksByDefault: false
            )
        }
    }
}

extension CleanupPlan {
    /// The changes a preview ticks before the user does: those whose reason code may tick, in a
    /// folder whose rules let a preview tick anything. None in Documents.
    public var defaultTickedIDs: Set<ProposedChange.ID> {
        guard folder.rules.ticksByDefault else { return [] }
        return Set(changes.filter(\.reason.isTickedByCode).map(\.id))
    }
}
