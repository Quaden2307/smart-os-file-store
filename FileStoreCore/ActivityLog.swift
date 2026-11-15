import Foundation
internal import GRDB
import os

/// The activity log: a local SQLite database that records every confirmed cleanup and what happened
/// to each item, with enough to undo it later. It holds records about files (paths, sizes, dates,
/// content hashes), never their content. Nothing in it leaves the Mac.
///
/// The executor writes to it through `CleanupRecording`, on its own background thread, one small
/// transaction per row. The app reads it through the `async` methods, which run off the main actor.
///
/// Durability: the database is in write-ahead mode with `synchronous = FULL`, so each row is synced
/// (`fsync`) before the executor goes on to change the file it describes. A row survives the app
/// crashing, being force-quit, or the system crashing. Only a sudden loss of power before the drive
/// has written its own cache can lose the last rows; ruling that out too (`F_FULLFSYNC`) costs six
/// times as much per row (decision record 0006).
public struct ActivityLog: Sendable {
    /// How long a write waits when another connection holds the database, before it fails.
    static let busyTimeout: TimeInterval = 2

    /// The most the write-ahead file may keep on disk once its rows are in the database.
    static let writeAheadSizeLimit = 1_048_576

    static let logger = Logger(subsystem: "com.quaden2307.FileStoreCore", category: "ActivityLog")

    public let location: ActivityLogLocation

    let queue: DatabaseQueue

    /// A fresh log, and where the database it replaced was set aside.
    public struct Fresh: Sendable {
        public let log: ActivityLog
        /// The damaged database under its new name, kept beside the fresh one. Nil when there was
        /// no file to keep.
        public let setAsideURL: URL?
    }

    /// Opens the log at `location`, making its folder and its database on first use.
    ///
    /// Opening checks the whole file, so a damaged database is found here and not in the middle of
    /// a cleanup; it also writes once, so a database that can be read but not written fails here too.
    @concurrent
    public static func open(_ location: ActivityLogLocation, now: Date = .now) async throws(ActivityLogError) -> ActivityLog {
        try opened(location, now: now)
    }

    /// Sets the database at `location` and its side files aside under a new name in the same folder,
    /// so a fresh log can be made in their place. The files are kept exactly as they are.
    ///
    /// - Returns: Where the database is now, or nil when there was none to set aside.
    @concurrent
    public static func setAsideDatabase(at location: ActivityLogLocation, now: Date = .now) async throws(ActivityLogError) -> URL? {
        let setAsideURL = try ActivityLogStorage.setAside(location, now: now)
        if let setAsideURL {
            logger.notice("Set an activity log aside as \(setAsideURL.lastPathComponent, privacy: .public)")
        }
        return setAsideURL
    }

    /// Sets the database at `location` aside and opens a fresh log in its place. The old file is
    /// kept, never removed. The fresh log's totals start from zero.
    @concurrent
    public static func startFresh(at location: ActivityLogLocation, now: Date = .now) async throws(ActivityLogError) -> Fresh {
        let setAsideURL = try await setAsideDatabase(at: location, now: now)
        return Fresh(log: try opened(location, now: now), setAsideURL: setAsideURL)
    }

    /// Closes the database. This log, and every copy of it, fails from then on.
    @concurrent
    public func close() async throws(ActivityLogError) {
        do {
            try queue.close()
        } catch {
            throw ActivityLogError(reading: error)
        }
    }

    // MARK: - Opening

    private static func opened(_ location: ActivityLogLocation, now: Date) throws(ActivityLogError) -> ActivityLog {
        let path = try ActivityLogStorage.prepare(location)
        var configuration = Configuration()
        configuration.label = "ActivityLog"
        configuration.busyMode = .timeout(busyTimeout)
        let queue: DatabaseQueue
        do {
            if let path {
                configuration.journalMode = .wal
                queue = try DatabaseQueue(path: path, configuration: configuration)
            } else {
                queue = try DatabaseQueue(configuration: configuration)
            }
        } catch {
            throw ActivityLogError(reading: error)
        }
        let log = ActivityLog(location: location, queue: queue)
        do throws(ActivityLogError) {
            try log.setUp(isFile: path != nil, now: now)
        } catch {
            logger.error("The activity log could not be opened: \(String(describing: error), privacy: .public)")
            throw error
        }
        logger.info("Opened the activity log (\(String(describing: location.kind), privacy: .public))")
        return log
    }

    private func setUp(isFile: Bool, now: Date) throws(ActivityLogError) {
        do {
            if isFile {
                // GRDB's own write-ahead setup lowers `synchronous` to NORMAL after every
                // configuration hook has run, so FULL is set here, once the queue exists.
                try queue.writeWithoutTransaction { db in
                    try db.execute(sql: "PRAGMA synchronous = FULL")
                    try db.execute(sql: "PRAGMA journal_size_limit = \(Self.writeAheadSizeLimit)")
                }
            }
            // The whole file, before anything is built on it.
            let check = try queue.read { db in
                try String.fetchAll(db, sql: "PRAGMA quick_check")
            }
            guard check == ["ok"] else {
                throw ActivityLogError.damaged
            }
            let migrator = ActivityLogSchema.migrator
            // A database a newer version of the app has migrated is left exactly as it is.
            guard try !queue.read(migrator.hasBeenSuperseded) else {
                throw ActivityLogError.newerVersion
            }
            try migrator.migrate(queue)
            try queue.write { db in
                // A real write: a database that opens but cannot be written must fail now.
                try db.execute(
                    sql: "UPDATE maintenance SET lastOpenedAt = ? WHERE id = 1",
                    arguments: [now.timeIntervalSinceReferenceDate]
                )
                guard db.changesCount == 1 else {
                    throw ActivityLogError.damaged
                }
                // A run still marked as running was left by a copy of the app that stopped in the
                // middle of it, or whose log failed: nothing of this copy's has started yet.
                try db.execute(sql: "UPDATE runs SET state = 'interrupted' WHERE state = 'running'")
            }
        } catch {
            throw ActivityLogError(reading: error)
        }
    }

    // MARK: - Access

    /// Reads on the calling thread, with GRDB's errors put into the log's own.
    func read<T>(_ body: (Database) throws -> T) throws(ActivityLogError) -> T {
        do {
            return try queue.read(body)
        } catch {
            throw ActivityLogError(reading: error)
        }
    }

    /// Writes in one transaction on the calling thread: everything `body` does is kept, or none of it.
    func write<T>(_ body: (Database) throws -> T) throws(ActivityLogError) -> T {
        do {
            return try queue.write(body)
        } catch {
            throw ActivityLogError(writing: error)
        }
    }

    /// Rebuilds the database file without the space removed rows left behind. Not `async`, so the
    /// call is GRDB's synchronous one, which cancelling the caller's task cannot interrupt.
    func compact() throws(ActivityLogError) {
        do {
            try queue.vacuum()
        } catch {
            throw ActivityLogError(writing: error)
        }
    }

    /// Folds the write-ahead file back into the database and empties it. Best effort: the rows are
    /// safe either way, the file is only larger until the next time.
    func truncateWriteAheadFile() {
        guard location.kind != .inMemory else { return }
        do {
            try queue.writeWithoutTransaction { db in
                _ = try db.checkpoint(.truncate)
            }
        } catch {
            Self.logger.notice("Could not empty the activity log's write-ahead file: \(String(describing: ActivityLogError(reading: error)), privacy: .public)")
        }
    }
}

extension ActivityLogError {
    /// The error for a failure while the log was being opened or read.
    init(reading error: any Error) {
        self = Self.known(error) ?? .unreadable(code: Self.code(of: error))
    }

    /// The error for a failure while the log was being written.
    init(writing error: any Error) {
        self = Self.known(error) ?? .writeFailed(code: Self.code(of: error))
    }

    /// An error that is already the log's own, or SQLite's word that the file is damaged.
    private static func known(_ error: any Error) -> ActivityLogError? {
        if let own = error as? ActivityLogError {
            return own
        }
        if let databaseError = error as? DatabaseError {
            switch databaseError.resultCode {
            case .SQLITE_CORRUPT, .SQLITE_NOTADB:
                return .damaged
            default:
                return nil
            }
        }
        return nil
    }

    private static func code(of error: any Error) -> Int32 {
        (error as? DatabaseError)?.extendedResultCode.rawValue ?? -1
    }
}
