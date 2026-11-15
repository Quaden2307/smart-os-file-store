import Foundation
internal import GRDB

/// The Kept list: the files and folders the user marked Kept, which no plan may ever propose. Each
/// call is one transaction. An entry follows the file by its identity, or by its path where the
/// volume gives no lasting identity; `KeptItems` holds the matching rule, and `keptMatch` below
/// is the same rule in SQL (decision record 0009).
extension ActivityLog {
    /// Marks `records` Kept as of `now`. An item already Kept stays as it was.
    ///
    /// Each item is marked by the identity it has now, read again from disk: a file saved since the
    /// scan by writing a new copy is the one at its place now, and that is the file the user sees and
    /// means. Only when nothing can be read there does the scan's identity stand.
    @concurrent
    public func keep(_ records: [FileRecord], now: Date = .now) async throws(ActivityLogError) {
        guard !records.isEmpty else { return }
        var volumes: [String: VolumeIdentity?] = [:]
        let entries = records.map { record in
            (identity: Self.identityNow(of: record, volumes: &volumes), path: record.keptItemPath)
        }
        try write { db in
            for entry in entries {
                // Uniqueness only: a row that broke the table's CHECK must fail, not vanish.
                try db.execute(
                    sql: """
                        INSERT INTO keptItems (volumeUUID, fileNumber, path, keptAt) VALUES (?, ?, ?, ?)
                        ON CONFLICT DO NOTHING
                        """,
                    arguments: [
                        entry.identity?.volumeUUID,
                        entry.identity.map { Self.storedFileNumber($0.fileNumber) },
                        entry.path,
                        now.timeIntervalSinceReferenceDate,
                    ]
                )
            }
        }
        Self.logger.info("Marked \(records.count) items Kept")
    }

    /// Removes the Kept mark from `records`: every entry that makes one of them Kept, by the rule
    /// `KeptItems.contains` applies.
    @concurrent
    public func stopKeeping(_ records: [FileRecord]) async throws(ActivityLogError) {
        guard !records.isEmpty else { return }
        try write { db in
            for record in records {
                let match = Self.keptMatch(identity: record.persistentIdentity, paths: [record.keptItemPath])
                try db.execute(sql: "DELETE FROM keptItems WHERE \(match.condition)", arguments: match.arguments)
            }
        }
        Self.logger.info("Stopped keeping \(records.count) items")
    }

    /// Empties the Kept list.
    @concurrent
    public func stopKeepingAll() async throws(ActivityLogError) {
        let removed = try write { db in
            try db.execute(sql: "DELETE FROM keptItems")
            return db.changesCount
        }
        Self.logger.info("Stopped keeping all \(removed) items")
    }

    /// The Kept list, once the entries for items that no longer exist are dropped: an entry whose
    /// number nothing on the volume of `folderURL` has any more, or, for an entry without one, an
    /// item inside the folder whose path leads nowhere. An entry is dropped only when the system
    /// says the item is gone; one it cannot tell about, or one on another volume, stays, and while
    /// the folder cannot be reached (its disk is not connected, say) nothing is dropped. An item
    /// moved into a subfolder, or out of the folder, still exists and stays Kept.
    ///
    /// The list is read, then looked up on disk with no lock held; it is written to only when an
    /// entry is to be dropped.
    ///
    /// - Parameter folderURL: The scanned folder, whose volume the entries are looked up on.
    @concurrent
    public func keptItems(forFolder folderURL: URL) async throws(ActivityLogError) -> KeptItems {
        let folderPath = folderURL.path(percentEncoded: false)
        let volume = VolumeIdentity.of(folderPath: folderPath)
        let pathPrefix = folderPath.hasSuffix("/") ? folderPath : folderPath + "/"
        let rows = try read { db in
            try KeptItemRow.fetchAll(db, sql: "SELECT * FROM keptItems")
        }
        var items: [KeptItem] = []
        var missing: [Int64] = []
        var unknown = 0
        for row in rows {
            switch Self.presence(of: row.value, volume: volume, pathPrefix: pathPrefix) {
            case .gone:
                missing.append(row.id)
            case .present:
                items.append(row.value)
            case .unknown:
                unknown += 1
                items.append(row.value)
            }
        }
        if !missing.isEmpty {
            try write { db in
                for id in missing {
                    try db.execute(sql: "DELETE FROM keptItems WHERE id = ?", arguments: [id])
                }
            }
        }
        if !missing.isEmpty || unknown > 0 {
            Self.logger.info("Dropped \(missing.count) Kept entries for items that no longer exist; \(unknown) could not be checked and stay")
        }
        return KeptItems(items)
    }

    /// True when `record`, as the scan saw it, is Kept.
    @concurrent
    public func isKept(_ record: FileRecord) async throws(ActivityLogError) -> Bool {
        let probe = KeptItemProbe(identity: record.persistentIdentity, paths: [record.keptItemPath])
        return try read { db in
            try Self.isKept(probe, in: db)
        }
    }

    /// The Kept list as it is now, every entry, read on the calling thread.
    public func currentKeptItems() throws(ActivityLogError) -> KeptItems {
        KeptItems(try read { db in
            try KeptItemRow.fetchAll(db, sql: "SELECT * FROM keptItems").map(\.value)
        })
    }

    /// True when an entry makes the item `probe` describes Kept. Used inside the transaction that
    /// writes a change's started row, so nothing can be marked Kept in between.
    static func isKept(_ probe: KeptItemProbe, in db: Database) throws -> Bool {
        let match = keptMatch(identity: probe.identity, paths: probe.paths)
        return try Bool.fetchOne(db, sql: "SELECT EXISTS (SELECT 1 FROM keptItems WHERE \(match.condition))", arguments: match.arguments)
            ?? false
    }

    /// The rows that make an item with `identity` (nil when it has none), going by any of `paths`,
    /// Kept: `KeptItems.contains` in SQL. With an identity, the rows with that identity and the rows
    /// made without one at one of its paths; without, every row made at one of its paths.
    private static func keptMatch(identity: PersistentFileIdentity?, paths: [String]) -> (condition: String, arguments: StatementArguments) {
        let unique = Array(Set(paths))
        let placeholders = unique.map { _ in "?" }.joined(separator: ", ")
        guard let identity else {
            return ("path IN (\(placeholders))", StatementArguments(unique))
        }
        var arguments: StatementArguments = [identity.volumeUUID, storedFileNumber(identity.fileNumber)]
        arguments += StatementArguments(unique)
        return ("(volumeUUID = ? AND fileNumber = ?) OR (volumeUUID IS NULL AND path IN (\(placeholders)))", arguments)
    }

    /// The identity of the item at `record`'s place now, or the scan's when nothing can be read
    /// there. `volumes` remembers each folder's volume, read once.
    private static func identityNow(of record: FileRecord, volumes: inout [String: VolumeIdentity?]) -> PersistentFileIdentity? {
        // Without a folder URL's trailing `/`, which would make `lstat` follow a link at the name.
        guard let status = try? FileStatus.of(path: record.url.storedPath) else {
            return record.persistentIdentity
        }
        let folderPath = record.url.deletingLastPathComponent().path(percentEncoded: false)
        if volumes[folderPath] == nil {
            volumes[folderPath] = .some(VolumeIdentity.of(folderPath: folderPath))
        }
        guard let volume = volumes[folderPath] ?? nil else {
            return record.persistentIdentity
        }
        return volume.identity(of: status)
    }

    private enum Presence {
        case present
        case gone
        /// Not checked: another volume, a path outside the folder, or a lookup that failed.
        case unknown
    }

    /// Gone only when the system says the entry's item no longer exists.
    private static func presence(of item: KeptItem, volume: VolumeIdentity?, pathPrefix: String) -> Presence {
        guard let volume else {
            return .unknown
        }
        if let identity = item.identity {
            guard volume.uuid == identity.volumeUUID else {
                return .unknown
            }
            switch volume.fileExists(number: identity.fileNumber) {
            case true?:
                return .present
            case false?:
                return .gone
            case nil:
                return .unknown
            }
        }
        guard item.path.hasPrefix(pathPrefix) else {
            return .unknown
        }
        do throws(FileStatus.Failure) {
            _ = try FileStatus.of(path: item.path)
            return .present
        } catch {
            return error == .notFound ? .gone : .unknown
        }
    }
}

/// A `keptItems` row as the table holds it.
private struct KeptItemRow: Decodable, FetchableRecord {
    let id: Int64
    let volumeUUID: String?
    let fileNumber: Int64?
    let path: String
    let keptAt: Double

    var value: KeptItem {
        let identity: PersistentFileIdentity? = if let volumeUUID, let fileNumber {
            PersistentFileIdentity(volumeUUID: volumeUUID, fileNumber: ActivityLog.fileNumber(stored: fileNumber))
        } else {
            nil
        }
        return KeptItem(identity: identity, path: path, keptAt: Date(timeIntervalSinceReferenceDate: keptAt))
    }
}
