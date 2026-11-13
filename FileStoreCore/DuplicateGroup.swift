import Foundation

/// Files with identical content. One is kept; the rest are proposed for the Trash.
public struct DuplicateGroup: Sendable, Hashable, Identifiable {
    /// The hash identifies the group: files with the same hash always land in the same group.
    public var id: ContentHash { contentHash }

    public let contentHash: ContentHash

    /// The copy that stays: the cleanest name, then the oldest.
    public let kept: FileRecord

    /// The copies proposed for the Trash, sorted by name.
    public let duplicates: [FileRecord]

    /// Size of each file in the group. They are identical, so they all share it.
    public let fileSizeInBytes: Int64

    /// Space freed if every duplicate goes to the Trash.
    public var reclaimableBytes: Int64 { fileSizeInBytes * Int64(duplicates.count) }

    public init(contentHash: ContentHash, kept: FileRecord, duplicates: [FileRecord], fileSizeInBytes: Int64) {
        self.contentHash = contentHash
        self.kept = kept
        self.duplicates = duplicates
        self.fileSizeInBytes = fileSizeInBytes
    }
}
