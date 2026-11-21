import FileStoreCore
import Foundation

/// A log as an earlier version of the app left it: the database one shipped schema version made,
/// with rows written the way that version wrote them. Migration tests open it with today's code.
///
/// The statements are each shipped migration's own, copied here and frozen. A shipped migration is
/// never edited, so neither is its copy; a new migration is tested from these, not added to them.
/// Earlier tests made an old database by undoing the newest migrations on a current one, which
/// SQLite no longer allows: it refuses to drop a column that has a foreign key or a trigger.
enum LegacyLog {
    static let folderPath = "/Users/someone/Downloads"

    /// The newest version this file can build: the last one before folders.
    static let newestVersion = 6

    private static let migrations: [String] = [
        // v1
        """
        CREATE TABLE runs (
            id INTEGER PRIMARY KEY AUTOINCREMENT,
            action TEXT NOT NULL,
            folderPath TEXT NOT NULL,
            startedAt REAL NOT NULL,
            finishedAt REAL,
            state TEXT NOT NULL,
            confirmedCount INTEGER NOT NULL,
            doneCount INTEGER NOT NULL DEFAULT 0,
            skippedCount INTEGER NOT NULL DEFAULT 0,
            failedCount INTEGER NOT NULL DEFAULT 0,
            bytesMovedToTrash INTEGER NOT NULL DEFAULT 0
        ) STRICT;

        CREATE INDEX runs_startedAt ON runs (startedAt);

        CREATE TABLE changes (
            id INTEGER PRIMARY KEY AUTOINCREMENT,
            runID INTEGER NOT NULL REFERENCES runs (id) ON DELETE CASCADE,
            sequence INTEGER NOT NULL,
            operation TEXT NOT NULL,
            originalPath TEXT NOT NULL,
            resultingPath TEXT,
            sizeInBytes INTEGER NOT NULL,
            dateModified REAL,
            contentHash BLOB,
            reasonCode TEXT NOT NULL,
            reasonDetail TEXT,
            outcome TEXT NOT NULL,
            outcomeCode TEXT,
            outcomeDetail TEXT,
            errorDomain TEXT,
            errorCode INTEGER,
            errorText TEXT,
            createdFolders TEXT,
            attemptedAt REAL NOT NULL,
            undoneAt REAL
        ) STRICT;

        CREATE INDEX changes_runID_sequence ON changes (runID, sequence);

        CREATE TABLE totals (
            id INTEGER PRIMARY KEY CHECK (id = 1),
            bytesMovedToTrash INTEGER NOT NULL DEFAULT 0,
            filesCleaned INTEGER NOT NULL DEFAULT 0
        ) STRICT;

        INSERT INTO totals (id) VALUES (1);

        CREATE TABLE maintenance (
            id INTEGER PRIMARY KEY CHECK (id = 1),
            lastPrunedAt REAL,
            lastOpenedAt REAL
        ) STRICT;

        INSERT INTO maintenance (id) VALUES (1);
        """,
        // v2
        """
        ALTER TABLE changes ADD COLUMN fileNumber INTEGER;
        ALTER TABLE changes ADD COLUMN undoesChangeID INTEGER REFERENCES changes (id) ON DELETE SET NULL;
        CREATE INDEX changes_undoesChangeID ON changes (undoesChangeID);
        ALTER TABLE runs ADD COLUMN undoneAction TEXT;
        ALTER TABLE runs ADD COLUMN bytesTakenFromTrash INTEGER NOT NULL DEFAULT 0;
        """,
        // v3
        """
        CREATE TABLE keptItems (
            id INTEGER PRIMARY KEY AUTOINCREMENT,
            volumeUUID TEXT,
            fileNumber INTEGER,
            path TEXT NOT NULL,
            keptAt REAL NOT NULL,
            CHECK ((volumeUUID IS NULL) = (fileNumber IS NULL))
        ) STRICT;

        CREATE UNIQUE INDEX keptItems_identity ON keptItems (volumeUUID, fileNumber) WHERE volumeUUID IS NOT NULL;
        CREATE UNIQUE INDEX keptItems_path ON keptItems (path) WHERE volumeUUID IS NULL;
        """,
        // v4
        """
        ALTER TABLE changes ADD COLUMN isFolder INTEGER NOT NULL DEFAULT 0 CHECK (isFolder IN (0, 1));
        """,
        // v5
        """
        CREATE TABLE installerFacts (
            id INTEGER PRIMARY KEY AUTOINCREMENT,
            volumeUUID TEXT,
            fileNumber INTEGER,
            path TEXT NOT NULL,
            sizeInBytes INTEGER NOT NULL,
            dateModified REAL NOT NULL,
            statusChanged REAL NOT NULL,
            readerVersion INTEGER NOT NULL,
            facts TEXT NOT NULL,
            readAt REAL NOT NULL,
            CHECK ((volumeUUID IS NULL) = (fileNumber IS NULL))
        ) STRICT;

        CREATE UNIQUE INDEX installerFacts_identity ON installerFacts (volumeUUID, fileNumber) WHERE volumeUUID IS NOT NULL;
        CREATE UNIQUE INDEX installerFacts_path ON installerFacts (path) WHERE volumeUUID IS NULL;
        """,
        // v6
        """
        ALTER TABLE runs ADD COLUMN origin TEXT
        """,
    ]

    /// Makes the database at `location` as schema `version` (1 to 6) left it, holding one finished
    /// Find Duplicates run of `count` trashed files and, from version 3 on, two Kept entries: one
    /// with an identity and one by its path alone.
    ///
    /// - Returns: The run's identifier.
    @discardableResult
    static func make(
        at location: ActivityLogLocation,
        version: Int,
        count: Int = 2,
        startedAt: Date = Date(timeIntervalSince1970: 1_800_000_000)
    ) throws -> Int64 {
        precondition((1...newestVersion).contains(version))
        guard let folderURL = location.folderURL, let databaseURL = location.databaseURL else {
            throw CocoaError(.fileNoSuchFile)
        }
        try FileManager.default.createDirectory(at: folderURL, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        guard FileManager.default.createFile(atPath: databaseURL.path(percentEncoded: false), contents: nil, attributes: [.posixPermissions: 0o600]) else {
            throw CocoaError(.fileWriteUnknown)
        }
        let raw = try RawDatabase(databaseURL)
        // The table GRDB keeps its applied migrations in.
        try raw.execute("CREATE TABLE grdb_migrations (identifier TEXT NOT NULL PRIMARY KEY)")
        for (index, sql) in migrations.prefix(version).enumerated() {
            try raw.execute(sql)
            try raw.execute("INSERT INTO grdb_migrations (identifier) VALUES ('v\(index + 1)')")
        }

        let moment = startedAt.timeIntervalSinceReferenceDate
        try raw.execute("""
            INSERT INTO runs (id, action, folderPath, startedAt, finishedAt, state, confirmedCount, doneCount, bytesMovedToTrash)
            VALUES (1, 'findDuplicates', '\(folderPath)', \(moment), \(moment), 'finished', \(count), \(count), \(count * 1_024))
            """)
        for index in 0..<count {
            let name = "report (\(index + 1)).pdf"
            try raw.execute("""
                INSERT INTO changes (
                    runID, sequence, operation, originalPath, resultingPath, sizeInBytes, dateModified, contentHash,
                    reasonCode, reasonDetail, outcome, attemptedAt
                ) VALUES (
                    1, \(index), 'trash', '\(folderPath)/\(name)', '/Users/someone/.Trash/\(name)', 1024, 721692800,
                    x'\(String(repeating: "ab", count: 32))', 'sameContent', 'kept.pdf', 'trashed', \(moment)
                )
                """)
        }
        try raw.execute("UPDATE totals SET bytesMovedToTrash = \(count * 1_024), filesCleaned = \(count) WHERE id = 1")
        if version >= 3 {
            try raw.execute("""
                INSERT INTO keptItems (volumeUUID, fileNumber, path, keptAt)
                VALUES ('11111111-2222-3333-4444-555555555555', 42, '\(folderPath)/kept.pdf', \(moment));
                INSERT INTO keptItems (path, keptAt) VALUES ('\(folderPath)/kept by path.pdf', \(moment));
                """)
        }
        return 1
    }
}
