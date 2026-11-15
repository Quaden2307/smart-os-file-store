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

    /// For `findDuplicates`: which kept file each change is a copy of. Empty for plans without
    /// groups, such as renames and moves, which the preview then lists one change per row.
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
            case .rename, .move:
                total
            }
        }
    }
}

/// Why a file was left out of a plan, or left alone when a plan was carried out.
public enum CleanupSkipReason: Sendable, Hashable {
    /// The file is no longer what the scan saw: a different size or modification date, or content
    /// that no longer matches the group it was planned in.
    case changedSinceScan

    /// The file disappeared between the scan and the check.
    case notFound

    /// The file exists but may not be read.
    case accessDenied

    /// The file's content is not on this Mac yet (a cloud placeholder); reading it would start a download.
    case notDownloaded

    /// A symbolic link, folder or other non-regular item now sits at the path. Links are never followed.
    case notARegularFile

    /// Reading failed for another reason. `reason` is the system's description.
    case unreadable(reason: String)

    // The reasons below only arise while a plan is carried out.

    /// The item is the copy the plan keeps, or the same file as it (a hard link). It is never moved.
    case keptFile

    /// The item is not something this plan may act on: it is not among the plan's proposed changes,
    /// or it no longer fits the action's scope (empty, still downloading, hidden).
    case notInPlan

    /// The item is not directly inside the scanned folder.
    case outsideFolder

    /// The scanned folder itself could not be reached, so nothing in it was checked or moved.
    case folderUnavailable

    /// The group's kept copy is gone, so the whole group was left alone. `name` is the kept file's name.
    case keptFileMissing(name: String)

    /// The group's kept copy could not be confirmed to still hold the group's content, so the whole
    /// group was left alone. `name` is the kept file's name.
    case keptFileNotVerified(name: String)

    /// Execution was stopped before this item was reached.
    case cancelled

    // The reasons below only arise for a rename or a move.

    /// Something already has the new name where the item would go. It is never overwritten.
    /// `name` is the name that is taken.
    case destinationExists(name: String)

    /// The new name, or the name of a folder on the way, is not one valid file name: empty, `.` or
    /// `..`, containing `/` or NUL, too long for the disk, or a name no action may give (hidden,
    /// the archive's, a download still in progress).
    case invalidName

    /// The destination is not inside the scanned folder: it lies elsewhere, is the folder itself,
    /// or is reached through a symbolic link or onto another disk.
    case destinationOutsideFolder

    /// A file or a package sits where the destination folder should be.
    case destinationNotAFolder

    /// The destination folder, or one on the way, is hidden (by flag), so the file would vanish
    /// from view in it.
    case destinationHidden

    // The reason below arises for any operation.

    /// The activity log could not be written, so the run stopped before this item was changed.
    /// Nothing is ever changed that could not be recorded first.
    case activityLogUnavailable
}

extension CleanupSkipReason {
    /// The reason matching a hashing failure. Nil for `.cancelled`, which is not a reason to skip a
    /// file but to stop.
    init?(hashError: ContentHashError) {
        switch hashError {
        case .fileNotFound:
            self = .notFound
        case .accessDenied:
            self = .accessDenied
        case .notARegularFile:
            self = .notARegularFile
        case .changedSinceScan:
            self = .changedSinceScan
        case .notDownloaded:
            self = .notDownloaded
        case .readFailed(_, let reason):
            self = .unreadable(reason: reason)
        case .cancelled:
            return nil
        }
    }
}
