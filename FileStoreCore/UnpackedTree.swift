import Foundation

/// An item, and for a folder everything inside it by relative path: what the matching rule of
/// Remove Unpacked Zips compares. It describes what a zip holds for one place beside it
/// (`UnpackedZipPlanner.expectation`), and what is on disk at that place (`read(named:in:expecting:)`).
public struct UnpackedTree: Sendable, Hashable {
    /// One item, as the rule compares it. Links are described, never followed.
    public enum Item: Sendable, Hashable {
        case file(sizeInBytes: Int64)
        case folder
        /// The size of a link is the length of the path it points to.
        case symbolicLink(sizeInBytes: Int64)
        /// Anything else: a device, a named pipe. It never matches.
        case other
    }

    /// The item at the place itself.
    public let root: Item

    /// For a folder, the items inside it, at any depth, by their path below the root with `/`
    /// between names (`src`, `src/main.swift`). Empty for anything else.
    public let contents: [String: Item]

    public init(root: Item, contents: [String: Item] = [:]) {
        self.root = root
        self.contents = contents
    }
}

extension UnpackedTree.Item {
    /// What one look (`lstat`) says the item is.
    init(_ status: FileStatus) {
        if status.isSymbolicLink {
            self = .symbolicLink(sizeInBytes: status.sizeInBytes)
        } else if status.isDirectory {
            self = .folder
        } else if status.isRegularFile {
            self = .file(sizeInBytes: status.sizeInBytes)
        } else {
            self = .other
        }
    }
}
