import Foundation
internal import GRDB

/// A `folders` row: a managed folder as the log holds it, before it is looked for on disk.
struct StoredFolder: Sendable, Hashable {
    let id: UUID

    let kind: ManagedFolder.Kind

    /// A custom folder's name. Nil for a standard folder.
    let displayName: String?

    /// A custom folder's bookmark. Nil for a standard folder.
    let bookmark: Data?

    /// Which folder a custom folder is on its volume, as it was when it was added. Nil for a
    /// standard folder, and where the volume gives its items no lasting identity.
    let identity: PersistentFileIdentity?

    /// True when the folder was taken off the list. Its row stays for the runs made in it.
    let isRemoved: Bool
}

/// The managed folders the log holds. `FolderRegistry` finds them on disk and applies the safety
/// rules; nothing here looks at a folder. A row of a kind this version does not know is not listed.
extension ActivityLog {
    /// Every folder the log has ever held, in the order they were added, the removed ones included.
    func storedFolders() throws(ActivityLogError) -> [StoredFolder] {
        try read { db in
            try FolderRow.fetchAll(db, sql: "SELECT * FROM folders ORDER BY rowid").compactMap(\.value)
        }
    }

    /// The ID the log gave one of the user's standard folders, whether it is on the list now or was
    /// taken off it. Nil when it was never on it.
    public func folderID(of kind: ManagedFolder.Kind) throws(ActivityLogError) -> ManagedFolder.ID? {
        try storedFolders().first { $0.kind == kind && kind != .custom }?.id
    }

    /// Puts a standard folder on the list: its row from before when it was ever there, since a kind
    /// has one row and one ID for good, or a new one.
    func addStandardFolder(_ kind: ManagedFolder.Kind) throws(ActivityLogError) -> StoredFolder {
        try write { db in
            try db.execute(
                sql: """
                    INSERT INTO folders (id, kind) VALUES (?, ?)
                    ON CONFLICT (kind) WHERE kind != 'custom' DO UPDATE SET removedAt = NULL
                    """,
                arguments: [UUID().uuidString, kind.logCode]
            )
            guard let stored = try FolderRow.fetchOne(db, sql: "SELECT * FROM folders WHERE kind = ?", arguments: [kind.logCode])?.value else {
                throw ActivityLogError.inconsistent
            }
            return stored
        }
    }

    /// Puts a folder the user chose on the list, under the ID it was found with.
    func addCustomFolder(_ folder: StoredFolder) throws(ActivityLogError) {
        try write { db in
            try db.execute(
                sql: "INSERT INTO folders (id, kind, displayName, bookmark, volumeUUID, fileNumber) VALUES (?, ?, ?, ?, ?, ?)",
                arguments: [
                    folder.id.uuidString, ManagedFolder.Kind.custom.logCode, folder.displayName, folder.bookmark,
                    folder.identity?.volumeUUID, folder.identity.map { Self.storedFileNumber($0.fileNumber) },
                ]
            )
        }
    }

    /// Takes a folder off the list. Its row, and every run made in it, stay.
    func removeFolder(id: ManagedFolder.ID, at now: Date) throws(ActivityLogError) {
        try write { db in
            try db.execute(
                sql: "UPDATE folders SET removedAt = ? WHERE id = ? AND removedAt IS NULL",
                arguments: [now.timeIntervalSinceReferenceDate, id.uuidString]
            )
        }
    }

    /// Keeps a bookmark the system made again because the old one had gone stale.
    func updateBookmark(_ bookmark: Data, ofFolder id: ManagedFolder.ID) throws(ActivityLogError) {
        try write { db in
            try db.execute(
                sql: "UPDATE folders SET bookmark = ? WHERE id = ? AND kind = ?",
                arguments: [bookmark, id.uuidString, ManagedFolder.Kind.custom.logCode]
            )
        }
    }
}

private struct FolderRow: Decodable, FetchableRecord {
    let id: String
    let kind: String
    let displayName: String?
    let bookmark: Data?
    let volumeUUID: String?
    let fileNumber: Int64?
    let removedAt: Double?

    /// Nil for a kind this version does not know, whose folder is left alone, and for an ID that
    /// is not one, which no version wrote.
    var value: StoredFolder? {
        guard let id = UUID(uuidString: id), let kind = ManagedFolder.Kind(logCode: kind) else {
            return nil
        }
        let identity: PersistentFileIdentity? = if let volumeUUID, let fileNumber {
            PersistentFileIdentity(volumeUUID: volumeUUID, fileNumber: ActivityLog.fileNumber(stored: fileNumber))
        } else {
            nil
        }
        return StoredFolder(
            id: id,
            kind: kind,
            displayName: displayName,
            bookmark: bookmark,
            identity: identity,
            isRemoved: removedAt != nil
        )
    }
}
