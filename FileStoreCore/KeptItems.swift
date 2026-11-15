import Foundation

/// One item the user marked Kept, as the activity log holds it.
public struct KeptItem: Sendable, Hashable {
    /// The item's identity when it was marked. Nil only where the volume gives items none; the path
    /// then stands in.
    public let identity: PersistentFileIdentity?

    /// Where the item was when it was marked.
    public let path: String

    public let keptAt: Date

    public init(identity: PersistentFileIdentity?, path: String, keptAt: Date) {
        self.identity = identity
        self.path = path
        self.keptAt = keptAt
    }
}

/// The items the user marked Kept: a plain value that planners match records against without
/// touching the disk. No plan ever proposes a change to an item it contains.
///
/// Kept follows the file, not its name (decision record 0009):
/// - An item with an identity is Kept when an entry has that identity, or when an entry made
///   without one has its path. A different file that later takes the name has another identity, so
///   it is not Kept.
/// - An item without an identity is Kept when any entry was made at its path. When the app cannot
///   tell, it protects.
public struct KeptItems: Sendable, Hashable {
    /// Every entry, in no particular order.
    public let items: [KeptItem]

    private let identities: Set<PersistentFileIdentity>
    private let pathsWithoutIdentity: Set<String>
    private let allPaths: Set<String>

    public init(_ items: [KeptItem] = []) {
        self.items = items
        identities = Set(items.compactMap(\.identity))
        pathsWithoutIdentity = Set(items.filter { $0.identity == nil }.map(\.path))
        allPaths = Set(items.map(\.path))
    }

    public var isEmpty: Bool { items.isEmpty }

    public var count: Int { items.count }

    /// True when the item with `identity` (nil when none could be read) at `path` is Kept.
    public func contains(identity: PersistentFileIdentity?, path: String) -> Bool {
        if let identity {
            return identities.contains(identity) || pathsWithoutIdentity.contains(path)
        }
        return allPaths.contains(path)
    }

    /// True when `record`, as the scan saw it, is Kept.
    public func contains(_ record: FileRecord) -> Bool {
        contains(identity: record.persistentIdentity, path: record.keptItemPath)
    }
}

/// An item as the executor asks the Kept list about it, right before changing it: the identity it
/// has now (nil when none could be read) and every path it goes by, the plan's spelling and the one
/// acted on. It is Kept when it is Kept by any of them.
public struct KeptItemProbe: Sendable, Hashable {
    public let identity: PersistentFileIdentity?
    public let paths: [String]

    public init(identity: PersistentFileIdentity?, paths: [String]) {
        self.identity = identity
        self.paths = paths
    }
}

extension FileRecord {
    /// The path the Kept list records and compares for this item: its URL's, exactly as the scan
    /// spelled it.
    public var keptItemPath: String {
        url.path(percentEncoded: false)
    }
}
