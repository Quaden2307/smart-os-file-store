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
        return migrator
    }
}
