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
    public let folder: ManagedFolder

    public var folderURL: URL { folder.url }

    /// Every proposed change, in the order the preview shows them.
    public let changes: [ProposedChange]

    /// For `findDuplicates`: which kept file each change is a copy of. Empty for plans without
    /// groups, such as renames and moves, which the preview then lists one change per row.
    public let duplicateGroups: [DuplicateGroup]

    /// For `reviewNearDuplicates`: the files with the same cleaned name and different content, by
    /// group. Every change belongs to one. Empty for every other action.
    public let nearDuplicateGroups: [NearDuplicateGroup]

    /// Files the action saw but could not check.
    public let skippedItems: [SkippedItem]

    /// For `archiveOldDownloads`: why the archive folder cannot be used. The plan then proposes
    /// nothing, and the preview says why. Nil for every other action.
    public let archiveProblem: ArchiveProblem?

    /// For `reviewLargeDownloads`: the space on disk taken by every file and package at the top
    /// level of the folder whose size is known, which the preview compares the list with. Nil for
    /// every other action.
    public let topLevelSizeOnDisk: Int64?

    /// For `removeUsedInstallers`: what was read from installers while planning and not cached yet,
    /// for the app to store in the activity log. The planner writes nothing itself.
    public let installerFactsRead: [InstallerFactsEntry]

    public init(
        action: CleanupAction,
        folder: ManagedFolder,
        changes: [ProposedChange],
        duplicateGroups: [DuplicateGroup] = [],
        nearDuplicateGroups: [NearDuplicateGroup] = [],
        skippedItems: [SkippedItem] = [],
        installerFactsRead: [InstallerFactsEntry] = [],
        archiveProblem: ArchiveProblem? = nil,
        topLevelSizeOnDisk: Int64? = nil
    ) {
        self.action = action
        self.folder = folder
        self.changes = changes
        self.duplicateGroups = duplicateGroups
        self.nearDuplicateGroups = nearDuplicateGroups
        self.skippedItems = skippedItems
        self.installerFactsRead = installerFactsRead
        self.archiveProblem = archiveProblem
        self.topLevelSizeOnDisk = topLevelSizeOnDisk
    }

    /// A plan that proposes nothing.
    public static func empty(action: CleanupAction, folder: ManagedFolder) -> CleanupPlan {
        CleanupPlan(action: action, folder: folder, changes: [])
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

    /// The zip was read, and its list of contents cannot be: it is damaged, the list is encrypted,
    /// it declares more than the reader accepts, or its names are not UTF-8.
    case zipUnlistable(ZipListing.Problem)

    /// The installer could not be read, and its name matches no installed app.
    case installerUnreadable(InstallerFacts.Problem)

    /// The disk image is attached (open), or whether it is could not be told. It is never moved.
    case diskImageInUse

    // The reasons below arise while a plan is carried out. `folderUnavailable` also arises when Remove
    // Unpacked Zips and Remove Used Installers plan, since they read through the folder, and
    // `diskImageInUse` when Remove Used Installers plans.

    /// The item is the copy the plan keeps, or the same file as it (a hard link). It is never moved.
    case keptFile

    /// The item is not something this plan may act on: it is not among the plan's proposed changes,
    /// or it no longer fits the action's scope (empty, still downloading, hidden).
    case notInPlan

    /// The user marked the item Kept, after the plan was made. A Kept item is never changed.
    case markedKept

    /// The item is not directly inside the scanned folder.
    case outsideFolder

    /// The scanned folder itself could not be reached, so nothing in it was checked or moved.
    case folderUnavailable

    /// The group's kept copy is gone, so the whole group was left alone. `name` is the kept file's name.
    case keptFileMissing(name: String)

    /// The group's kept copy could not be confirmed to still hold the group's content, so the whole
    /// group was left alone. `name` is the kept file's name.
    case keptFileNotVerified(name: String)

    /// The item a zip was unpacked to is no longer next to it, so the zip was left alone. `name` is
    /// that item's name.
    case unpackedCopyMissing(name: String)

    /// The item a zip was unpacked to could not be confirmed to still hold everything in the zip,
    /// so the zip was left alone. `name` is that item's name.
    case unpackedCopyNotVerified(name: String)

    /// The item a zip was unpacked to arrived, or something in it was written, within the grace
    /// period, so it may still be being unpacked, and the zip was left alone. `name` is its name.
    case unpackedCopyRecentlyChanged(name: String)

    /// The installed app an installer was matched with is no longer there, so the installer was left
    /// alone. `name` is the app's name.
    case installedAppMissing(name: String)

    /// The installed app an installer was matched with is no longer the one matched: another
    /// identifier, an older version, or not a real app any more. `name` is the app's name.
    case installedAppChanged(name: String)

    /// Every other file of its near-duplicate group is gone, or is being moved to the Trash in this
    /// same run, so this one stays: a near-duplicate group always keeps at least one file.
    case lastInGroup

    /// The identical copy in the archive that a file was to be trashed for is gone, or is no longer
    /// a regular file there, so the file was left alone. `name` is the copy's name.
    case archivedCopyMissing(name: String)

    /// The identical copy in the archive could not be confirmed to still hold the file's bytes, so
    /// the file was left alone. `name` is the copy's name.
    case archivedCopyNotVerified(name: String)

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
