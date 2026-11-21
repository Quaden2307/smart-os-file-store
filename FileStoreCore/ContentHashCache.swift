import Foundation
import Synchronization

/// Content hashes already read in this app session, so a planner need not read a file twice.
///
/// A hash is handed back only for a record with the size, modification date and disk identity
/// (volume and file number) it was read at; any other record misses, so a file replaced under the
/// /// same name, even at the same size and date, is read again. Find Duplicates only stores hashes here
/// and never reads them, since its hashes decide what goes to the Trash on their own; Review
/// Near-Duplicates, Fix Messy Names and Archive Old Downloads read them. A stale hash cannot do harm
/// there: the executor reads again the content of a copy the archive holds before trashing it, a
/// near-duplicate is trashed only by the user's own tick, and a rename never overwrites. Tidy Now
/// runs Find Duplicates first and those three after it, with one cache, so no file is read twice in
/// one Tidy Now scan. Each search drops the hashes of files its folder's scan no longer lists (`keepOnly`).
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

    /// Forgets the hash of every file directly inside `folder` that `records`, its latest scan, does
    /// not list, so the cache never holds more than one scan's files of a folder. Another folder's
    /// hashes stay.
    public func keepOnly(_ records: [FileRecord], in folder: ManagedFolder) {
        let listed = Set(records.map(\.url))
        // A directory listing spells its entries with links resolved (`/private/var/…` for a folder
        // given as `/var/…`), so the folder is known by both spellings.
        let prefixes = Set([folder.url.path(percentEncoded: false), FileStatus.realPath(of: folder.url)].compactMap(\.self).map { path in
            path.hasSuffix("/") ? path : path + "/"
        })
        entries.withLock { entries in
            entries = entries.filter { entry in
                if listed.contains(entry.key) {
                    return true
                }
                // Not listed: forgotten only when it was directly inside this folder.
                let path = entry.key.path(percentEncoded: false)
                guard let prefix = prefixes.first(where: path.hasPrefix) else {
                    return true
                }
                return path.dropFirst(prefix.count).contains("/")
            }
        }
    }

    /// How many hashes are remembered.
    public var count: Int {
        entries.withLock { $0.count }
    }
}
