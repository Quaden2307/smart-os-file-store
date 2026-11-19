import Foundation

/// What the app's Find Duplicates found by reading the files: groups of files with the same
/// content, as plain rows. The app runs the scan with the same rules as the Clean Up menu and hands
/// the result over; this module cannot run it, or act on it (docs/decisions/0021).
public struct DuplicateScan: Sendable, Equatable {
    public struct Group: Sendable, Equatable {
        /// The copy Find Duplicates would keep.
        public var kept: FolderSnapshot.File
        /// The copies it would propose for the Trash.
        public var copies: [FolderSnapshot.File]

        public init(kept: FolderSnapshot.File, copies: [FolderSnapshot.File]) {
            self.kept = kept
            self.copies = copies
        }
    }

    /// Most space to free first, as Find Duplicates orders them.
    public var groups: [Group]
    /// Files that could not be read, so they are in no group.
    public var unreadableCount: Int
    /// Files added in the last hour, which Find Duplicates leaves for later (the grace period). A
    /// file just downloaded twice is the likeliest reason to ask, so the answer must say so.
    public var recentCount: Int

    public init(groups: [Group], unreadableCount: Int = 0, recentCount: Int = 0) {
        self.groups = groups
        self.unreadableCount = unreadableCount
        self.recentCount = recentCount
    }

    /// Every copy beyond the one kept in its group.
    public var copyCount: Int {
        groups.reduce(0) { $0 + $1.copies.count }
    }

    /// The space the copies take.
    public var copyBytes: Int64 {
        groups.reduce(0) { total, group in total + group.copies.reduce(0) { $0 + ($1.sizeInBytes ?? 0) } }
    }
}
