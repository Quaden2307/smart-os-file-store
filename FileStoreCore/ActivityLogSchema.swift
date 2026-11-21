import Foundation
internal import GRDB

/// The activity log's tables, as versioned migrations. A change to the schema is a new migration
/// added below; one that has shipped is never edited.
///
/// - `runs`: one row per confirmed cleanup.
/// - `changes`: one row per item of a run, with what is needed to undo it.
/// - `totals`: one row of running counters, which pruning never touches.
/// - `maintenance`: one row of housekeeping times.
///
/// `v2` adds what undo needs: each change's disk ID (`fileNumber`), and for an undo run, the action
/// it undid and the bytes it took back out of the Trash; an undo row names the change it reverses
/// (`undoesChangeID`). An undo run is a `runs` row with the action `undo`.
///
/// `v3` adds `keptItems`: one row per file or folder the user marked Kept, by its volume's UUID and
/// its number there, or by its path alone where the volume gives no lasting numbers (decision
/// record 0009). It has no link to `runs`, so pruning never touches it.
///
/// `v4` adds `changes.isFolder`: 1 when the item was a folder (a package included), which undo
/// proves by its disk ID and contents rather than its size and date (decision record 0010). Every
/// row written before it describes a regular file, since no action could change anything else.
///
/// `v5` adds `installerFacts`: what Remove Used Installers read from each installer, as JSON, keyed
/// like `keptItems` by identity or path, with the size, modification date and status-change time it
/// was read at, so a second scan reads nothing again (decision record 0013). No link to `runs`;
/// `pruneIfDue` removes rows read more than the retention period ago.
///
/// `v6` adds `runs.origin`: where a run was started from (decision record 0023).
///
/// `v7` adds `folders`: one row per folder the app looks after, by an ID made once and never by its
/// path, with how a custom folder is found again (a bookmark, and which folder it is on its volume,
/// as `keptItems` records a file, so a different folder at the old place is never taken for it)
/// and the name the user gave it. A standard folder (Downloads, Desktop, Documents) is found by
/// its kind and has none of them. A folder
/// taken off the list keeps its row (`removedAt`), so an old run still names its folder. `runs`,
/// `changes` and `keptItems` gain `folderID`; every row from before belongs to Downloads, whose
/// row the migration makes. The column cannot be `NOT NULL`, since SQLite adds a column only with
/// one default for every database, so triggers refuse a row without it (decision record 0026).
///
/// `v8` adds `folders.rules`: the folder's own cleanup rules as JSON, NULL for its kind's defaults
/// (decision record 0028).
///
/// Every time is a `Date.timeIntervalSinceReferenceDate`, the number a `Date` itself holds, so a
/// modification date read back is bit for bit the one the scan saw. Paths are stored as text;
/// file content never is.
enum ActivityLogSchema {
    static var migrator: DatabaseMigrator {
        var migrator = DatabaseMigrator()
        migrator.registerMigration("v1") { db in
            try db.execute(sql: """
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
                """)
        }
        migrator.registerMigration("v2") { db in
            // Pruning removes old runs with their changes; an undo row that reverses one of them
            // keeps its own history and forgets which change it was.
            try db.execute(sql: """
                ALTER TABLE changes ADD COLUMN fileNumber INTEGER;
                ALTER TABLE changes ADD COLUMN undoesChangeID INTEGER REFERENCES changes (id) ON DELETE SET NULL;
                CREATE INDEX changes_undoesChangeID ON changes (undoesChangeID);
                ALTER TABLE runs ADD COLUMN undoneAction TEXT;
                ALTER TABLE runs ADD COLUMN bytesTakenFromTrash INTEGER NOT NULL DEFAULT 0;
                """)
        }
        migrator.registerMigration("v3") { db in
            // An item is recorded once: by its identity when it has one, by its path when it has
            // none. The two kinds of row never share a uniqueness rule.
            try db.execute(sql: """
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
                """)
        }
        migrator.registerMigration("v4") { db in
            try db.execute(sql: """
                ALTER TABLE changes ADD COLUMN isFolder INTEGER NOT NULL DEFAULT 0 CHECK (isFolder IN (0, 1));
                """)
        }
        migrator.registerMigration("v5") { db in
            try db.execute(sql: """
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
                """)
        }
        migrator.registerMigration("v6") { db in
            // Where a run was started from. NULL is the app itself, which is every run before this.
            try db.execute(sql: "ALTER TABLE runs ADD COLUMN origin TEXT")
        }
        migrator.registerMigration("v7") { db in
            try db.execute(sql: """
                CREATE TABLE folders (
                    id TEXT PRIMARY KEY,
                    kind TEXT NOT NULL,
                    displayName TEXT,
                    bookmark BLOB,
                    volumeUUID TEXT,
                    fileNumber INTEGER,
                    removedAt REAL,
                    CHECK ((kind = 'custom') = (bookmark IS NOT NULL)),
                    CHECK ((kind = 'custom') = (displayName IS NOT NULL)),
                    CHECK ((volumeUUID IS NULL) = (fileNumber IS NULL)),
                    CHECK (kind = 'custom' OR volumeUUID IS NULL)
                ) STRICT;

                CREATE UNIQUE INDEX folders_standardKind ON folders (kind) WHERE kind != 'custom';
                """)
            // The ID is text: GRDB's own binding for a `UUID` is a blob, which the column refuses.
            let downloads = UUID().uuidString
            try db.execute(sql: "INSERT INTO folders (id, kind) VALUES (?, 'downloads')", arguments: [downloads])
            for table in ["runs", "changes", "keptItems"] {
                try db.execute(sql: "ALTER TABLE \(table) ADD COLUMN folderID TEXT REFERENCES folders (id)")
                try db.execute(sql: "UPDATE \(table) SET folderID = ?", arguments: [downloads])
                try db.execute(sql: """
                    CREATE TRIGGER \(table)_folderID_insert BEFORE INSERT ON \(table) WHEN NEW.folderID IS NULL
                    BEGIN SELECT RAISE(ABORT, '\(table).folderID is required'); END;

                    CREATE TRIGGER \(table)_folderID_update BEFORE UPDATE OF folderID ON \(table) WHEN NEW.folderID IS NULL
                    BEGIN SELECT RAISE(ABORT, '\(table).folderID is required'); END;
                    """)
            }
        }
        migrator.registerMigration("v8") { db in
            // A folder's own rules, as JSON (`FolderRules`). NULL is its kind's defaults.
            try db.execute(sql: "ALTER TABLE folders ADD COLUMN rules TEXT")
        }
        return migrator
    }
}
