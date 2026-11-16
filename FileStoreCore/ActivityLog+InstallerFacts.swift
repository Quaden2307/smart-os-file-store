import Foundation
internal import GRDB

/// What Remove Used Installers read from each installer, kept so that the next scan reads nothing
/// again: no disk image is attached twice. A row is used only for the very same file, unchanged
/// (`InstallerFileKey`), read by the current reader (`readerVersion`); anything else is a miss.
extension ActivityLog: InstallerFactsReading {
    /// Raised when the reading of installers changes, so facts read the old way are read again.
    static let installerReaderVersion = 1

    /// The cached facts for each of `keys` that has a row for the very same file, unchanged.
    @concurrent
    public func installerFacts(for keys: [InstallerFileKey]) async throws(ActivityLogError) -> [InstallerFileKey: InstallerFacts] {
        guard !keys.isEmpty else { return [:] }
        let rows = try read { db in
            try keys.map { key in (key, try InstallerFactsRow.fetchOne(db, sql: "SELECT * FROM installerFacts WHERE \(Self.factsMatch)", arguments: Self.arguments(key))) }
        }
        let decoder = JSONDecoder()
        var facts: [InstallerFileKey: InstallerFacts] = [:]
        for (key, row) in rows {
            guard let row,
                  row.readerVersion == Self.installerReaderVersion,
                  row.sizeInBytes == key.sizeInBytes,
                  row.dateModified == key.dateModified.timeIntervalSinceReferenceDate,
                  row.statusChanged == key.statusChanged.timeIntervalSinceReferenceDate,
                  let value = try? decoder.decode(InstallerFacts.self, from: Data(row.facts.utf8)) else {
                continue
            }
            facts[key] = value
        }
        return facts
    }

    /// Stores `entries`, read at `now`, each replacing any row for the same file. Facts that say
    /// something about the moment, such as a timeout, are not stored.
    @concurrent
    public func storeInstallerFacts(_ entries: [InstallerFactsEntry], now: Date = .now) async throws(ActivityLogError) {
        let encoder = JSONEncoder()
        let lasting = entries.filter(\.facts.isLasting).compactMap { entry in
            (try? encoder.encode(entry.facts)).map { (entry.key, String(decoding: $0, as: UTF8.self)) }
        }
        guard !lasting.isEmpty else { return }
        try write { db in
            for (key, facts) in lasting {
                try db.execute(sql: "DELETE FROM installerFacts WHERE \(Self.factsMatch)", arguments: Self.arguments(key))
                try db.execute(
                    sql: """
                        INSERT INTO installerFacts
                            (volumeUUID, fileNumber, path, sizeInBytes, dateModified, statusChanged, readerVersion, facts, readAt)
                        VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?)
                        """,
                    arguments: [
                        key.identity?.volumeUUID,
                        key.identity.map { Self.storedFileNumber($0.fileNumber) },
                        key.path,
                        key.sizeInBytes,
                        key.dateModified.timeIntervalSinceReferenceDate,
                        key.statusChanged.timeIntervalSinceReferenceDate,
                        Self.installerReaderVersion,
                        facts,
                        now.timeIntervalSinceReferenceDate,
                    ]
                )
            }
        }
        Self.logger.info("Stored what was read from \(lasting.count) installers")
    }

    /// The row for a key's file: by identity when it has one, by path when it has none. Two `?`
    /// for the identity, one for the path; `arguments` fills them.
    private static let factsMatch = "(volumeUUID IS ? AND fileNumber IS ? AND (volumeUUID IS NOT NULL OR path = ?))"

    private static func arguments(_ key: InstallerFileKey) -> StatementArguments {
        [key.identity?.volumeUUID, key.identity.map { storedFileNumber($0.fileNumber) }, key.path]
    }
}

/// An `installerFacts` row as the table holds it.
private struct InstallerFactsRow: Decodable, FetchableRecord {
    let sizeInBytes: Int64
    let dateModified: Double
    let statusChanged: Double
    let readerVersion: Int
    let facts: String
}
