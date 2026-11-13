import Foundation

/// What a cleanup action proposes for one folder.
///
/// A plan is a plain value: building one changes nothing on disk, and nothing happens until the
/// user confirms the changes in the preview. Every action produces this same shape, so one preview
/// screen, one executor and, later, one activity log serve all of them.
public struct CleanupPlan: Sendable, Hashable {
    /// A file the action could not assess. It is left alone and reported, never guessed about.
    public struct SkippedItem: Sendable, Hashable, Identifiable {
        public var id: URL { url }
        public let url: URL
        public let reason: CleanupSkipReason

        public init(url: URL, reason: CleanupSkipReason) {
            self.url = url
            self.reason = reason
        }
    }

    public let action: CleanupAction

    /// The folder the action was planned for. Every change lies directly inside it.
    public let folderURL: URL

    /// Every proposed change, in the order the preview shows them.
    public let changes: [ProposedChange]

    /// For `findDuplicates`: which kept file each change is a copy of. Empty for other actions.
    public let duplicateGroups: [DuplicateGroup]

    /// Files the action saw but could not check.
    public let skippedItems: [SkippedItem]

    public init(
        action: CleanupAction,
        folderURL: URL,
        changes: [ProposedChange],
        duplicateGroups: [DuplicateGroup] = [],
        skippedItems: [SkippedItem] = []
    ) {
        self.action = action
        self.folderURL = folderURL
        self.changes = changes
        self.duplicateGroups = duplicateGroups
        self.skippedItems = skippedItems
    }

    /// A plan that proposes nothing.
    public static func empty(action: CleanupAction, folderURL: URL) -> CleanupPlan {
        CleanupPlan(action: action, folderURL: folderURL, changes: [])
    }

    public var isEmpty: Bool { changes.isEmpty }

    /// Bytes the Trash would receive if every change were confirmed.
    public var bytesToFree: Int64 {
        changes.reduce(0) { total, change in
            switch change.operation {
            case .moveToTrash:
                total + change.sizeInBytes
            }
        }
    }
}

/// Why a file was left out of a plan.
public enum CleanupSkipReason: Sendable, Hashable {
    /// The file is no longer what the scan saw: a different size, or no longer a regular file.
    case changedSinceScan

    /// The file disappeared between the scan and the check.
    case notFound

    /// The file exists but may not be read.
    case accessDenied

    /// The file's content is not on this Mac yet (a cloud placeholder); reading it would start a download.
    case notDownloaded

    /// Reading failed for another reason. `reason` is the system's description.
    case unreadable(reason: String)
}
