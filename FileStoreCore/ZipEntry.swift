import Foundation

/// One item a zip archive lists in its central directory, the index at the end of every zip. It is
/// data to compare with what is on disk, never a path to write to: nothing is ever extracted.
public struct ZipEntry: Sendable, Hashable {
    /// What the item is, as the archive records it.
    public enum Kind: Sendable, Hashable {
        case file
        case folder
        /// A symbolic link. Its size is the length of the path it points to.
        case symbolicLink
        /// Something else the archive's maker recorded, such as a device or a named pipe. It never
        /// matches anything on disk.
        case other
    }

    /// The name as stored, decoded as UTF-8, with `/` between folders. A folder's may end in `/`.
    public let path: String

    public let kind: Kind

    /// The item's size once unpacked, as the central directory records it.
    public let uncompressedSize: Int64

    public init(path: String, kind: Kind, uncompressedSize: Int64) {
        self.path = path
        self.kind = kind
        self.uncompressedSize = uncompressedSize
    }
}
