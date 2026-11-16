import Foundation
import Synchronization

/// Content hashes already read in this app session, so a planner need not read a file twice.
///
/// A hash is handed back only for a record with the size, modification date and disk identity
/// (volume and file number) it was read at; any other record misses, so a file replaced under the
/// same name, even at the same size and date, is read again. Find Duplicates only stores hashes here and never reads them, since its
/// hashes decide what goes to the Trash; Review Near-Duplicates reads them, since its hashes only
/// decide which files are shown together, and the executor rechecks every file before it moves.
public final class ContentHashCache: Sendable {
    private struct Entry {
        let sizeInBytes: Int64
        let dateModified: Date
        let identity: PersistentFileIdentity
        let hash: ContentHash
    }

    private let entries = Mutex<[URL: Entry]>([:])

    public init() {}

    /// The hash read for `record`'s file, if it was read at the record's size, modification date
    /// and disk identity.
    public func hash(for record: FileRecord) -> ContentHash? {
        guard let size = record.sizeInBytes, let date = record.dateModified, let identity = record.persistentIdentity else {
            return nil
        }
        return entries.withLock { entries in
            guard let entry = entries[record.url], entry.sizeInBytes == size, entry.dateModified == date,
                  entry.identity == identity else {
                return nil
            }
            return entry.hash
        }
    }

    /// Remembers `hash` for `record`'s file at its size, modification date and disk identity. A
    /// record without any of them is not remembered.
    public func store(_ hash: ContentHash, for record: FileRecord) {
        guard let size = record.sizeInBytes, let date = record.dateModified, let identity = record.persistentIdentity else {
            return
        }
        entries.withLock { $0[record.url] = Entry(sizeInBytes: size, dateModified: date, identity: identity, hash: hash) }
    }

    /// How many hashes are remembered.
    public var count: Int {
        entries.withLock { $0.count }
    }
}
