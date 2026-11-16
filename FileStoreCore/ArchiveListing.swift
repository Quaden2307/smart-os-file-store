import Foundation

/// Why the archive folder cannot be used: Archive Old Downloads then proposes nothing and says why.
public enum ArchiveProblem: Sendable, Hashable {
    /// Something other than a folder has the archive's name: a file, say.
    case notAFolder
    /// A symbolic link has the archive's name. It is never followed.
    case symbolicLink
    /// The archive folder is there and could not be read.
    case unreadable
}

/// What the archive folder holds, as read right before planning (`ArchivePlanner`).
public struct ArchiveListing: Sendable, Hashable {
    /// One item in the archive.
    public struct Entry: Sendable, Hashable {
        public let name: String

        /// The item's content hash, read only for a regular file that has a candidate's name and
        /// size. Nil for every other item: it is then a different file.
        public let contentHash: ContentHash?

        public init(name: String, contentHash: ContentHash? = nil) {
            self.name = name
            self.contentHash = contentHash
        }
    }

    /// Nil when the archive can be used: it is a folder, or missing and made on the first move.
    public let problem: ArchiveProblem?

    /// Everything directly inside the archive. Empty when it is missing or has a problem.
    public let entries: [Entry]

    public init(problem: ArchiveProblem? = nil, entries: [Entry] = []) {
        self.problem = problem
        self.entries = problem == nil ? entries : []
    }

    /// No archive folder yet.
    public static let missing = ArchiveListing()
}
