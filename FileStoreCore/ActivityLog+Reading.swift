import Foundation
internal import GRDB

/// How the database is set up for durability, as SQLite reports it. For checks and diagnostics.
public struct ActivityLogStorageSettings: Sendable, Hashable {
    /// `wal` for a database in a file.
    public let journalMode: String

    /// SQLite's `synchronous` level: 2 is FULL.
    public let synchronous: Int
}

/// What the app reads from the log. Each call runs off the main actor.
extension ActivityLog {
    /// Every run the log holds, newest first.
    @concurrent
    public func runs() async throws(ActivityLogError) -> [ActivityRun] {
        try read { db in
            try RunRow.fetchAll(db, sql: "SELECT * FROM runs ORDER BY startedAt DESC, id DESC").map(\.value)
        }
    }

    /// The items of one run, in the order the run took them.
    @concurrent
    public func changes(inRun runID: ActivityRun.ID) async throws(ActivityLogError) -> [ActivityChange] {
        try read { db in
            try ChangeRow.fetchAll(
                db,
                sql: "SELECT * FROM changes WHERE runID = ? ORDER BY sequence, id",
                arguments: [runID]
            ).map(\.value)
        }
    }

    /// The running counters since the log began.
    @concurrent
    public func totals() async throws(ActivityLogError) -> ActivityTotals {
        try read { db in
            guard let row = try TotalsRow.fetchOne(db, sql: "SELECT bytesMovedToTrash, filesCleaned FROM totals WHERE id = 1") else {
                throw ActivityLogError.damaged
            }
            return ActivityTotals(bytesMovedToTrash: row.bytesMovedToTrash, filesCleaned: row.filesCleaned)
        }
    }

    @concurrent
    public func storageSettings() async throws(ActivityLogError) -> ActivityLogStorageSettings {
        try read { db in
            ActivityLogStorageSettings(
                journalMode: try String.fetchOne(db, sql: "PRAGMA journal_mode") ?? "",
                synchronous: try Int.fetchOne(db, sql: "PRAGMA synchronous") ?? -1
            )
        }
    }
}

// The rows as the tables hold them. Decoding goes through `Decodable`, which throws on a value of
// the wrong kind where a column subscript would stop the app.

private struct RunRow: Decodable, FetchableRecord {
    let id: Int64
    let action: String
    let folderPath: String
    let startedAt: Double
    let finishedAt: Double?
    let state: String
    let confirmedCount: Int
    let doneCount: Int
    let skippedCount: Int
    let failedCount: Int
    let bytesMovedToTrash: Int64

    var value: ActivityRun {
        ActivityRun(
            id: id,
            actionCode: action,
            folderPath: folderPath,
            startedAt: Date(timeIntervalSinceReferenceDate: startedAt),
            finishedAt: finishedAt.map { Date(timeIntervalSinceReferenceDate: $0) },
            state: ActivityRun.State(logCode: state),
            confirmedCount: confirmedCount,
            doneCount: doneCount,
            skippedCount: skippedCount,
            failedCount: failedCount,
            bytesMovedToTrash: bytesMovedToTrash
        )
    }
}

private struct ChangeRow: Decodable, FetchableRecord {
    let id: Int64
    let runID: Int64
    let sequence: Int
    let operation: String
    let originalPath: String
    let resultingPath: String?
    let sizeInBytes: Int64
    let dateModified: Double?
    let contentHash: Data?
    let reasonCode: String
    let reasonDetail: String?
    let outcome: String
    let outcomeCode: String?
    let outcomeDetail: String?
    let errorDomain: String?
    let errorCode: Int?
    let errorText: String?
    let createdFolders: String?
    let attemptedAt: Double
    let undoneAt: Double?

    var value: ActivityChange {
        let outcomeCode = ActivityLogOutcomeCode(
            outcome: outcome,
            code: outcomeCode,
            detail: outcomeDetail,
            errorDomain: errorDomain,
            errorNumber: errorCode,
            errorText: errorText
        )
        return ActivityChange(
            id: id,
            runID: runID,
            sequence: sequence,
            operation: ActivityChange.Operation(logCode: operation),
            originalPath: originalPath,
            resultingPath: resultingPath,
            sizeInBytes: sizeInBytes,
            dateModified: dateModified.map { Date(timeIntervalSinceReferenceDate: $0) },
            contentHash: contentHash.map { ContentHash(bytes: Array($0)) },
            reason: ProposedChange.Reason(logCode: ActivityLogCode(code: reasonCode, detail: reasonDetail)),
            outcome: outcomeCode.value,
            createdFolders: Self.folders(from: createdFolders),
            attemptedAt: Date(timeIntervalSinceReferenceDate: attemptedAt),
            undoneAt: undoneAt.map { Date(timeIntervalSinceReferenceDate: $0) }
        )
    }

    /// The folder paths in a stored JSON array. Text that is not one reads as no folders.
    private static func folders(from text: String?) -> [String] {
        guard let text else {
            return []
        }
        return (try? JSONDecoder().decode([String].self, from: Data(text.utf8))) ?? []
    }
}

private struct TotalsRow: Decodable, FetchableRecord {
    let bytesMovedToTrash: Int64
    let filesCleaned: Int
}
