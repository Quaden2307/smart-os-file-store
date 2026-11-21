import Foundation
internal import GRDB

/// The executor's writes. Each call is one transaction, so a row and the counts that go with it
/// are both there or neither is, whenever the app stops.
extension ActivityLog: CleanupRecording {
    public func beginRun(_ start: CleanupRunStart) throws(ActivityLogError) -> Int64 {
        try write { db in
            try db.execute(
                sql: "INSERT INTO runs (action, folderPath, startedAt, state, confirmedCount, origin, folderID) VALUES (?, ?, ?, ?, ?, ?, ?)",
                arguments: [
                    start.logCode,
                    start.folderURL.path(percentEncoded: false),
                    start.startedAt.timeIntervalSinceReferenceDate,
                    ActivityRun.State.running.logCode,
                    start.confirmedCount,
                    start.origin.logCode,
                    start.folder.id.uuidString,
                ]
            )
            return db.lastInsertedRowID
        }
    }

    public func recordIntent(_ intent: CleanupChangeIntent) throws(ActivityLogError) -> CleanupIntentDecision {
        try write { db in
            // In the same transaction as the row, so no Kept mark can land in between.
            if try Self.isKept(intent.keptProbe, in: db) {
                return .markedKept
            }
            try Self.insertChange(
                db,
                runID: intent.runID,
                sequence: intent.sequence,
                change: intent.change,
                contentHash: intent.contentHash,
                outcome: ActivityLogOutcomeCode(outcome: ActivityLogOutcomeCode.started),
                createdFolders: intent.foldersToMake,
                fileNumber: intent.fileNumber,
                attemptedAt: intent.attemptedAt
            )
            return .recorded(rowID: db.lastInsertedRowID)
        }
    }

    public func recordResult(_ result: CleanupChangeResult) throws(ActivityLogError) {
        let item = result.item
        let outcome = ActivityLogOutcomeCode(item.outcome)
        try write { db in
            if let changeID = result.changeID {
                // Only a row still in the started state is completed, and only once: a second
                // result for the same row would count the item twice.
                try db.execute(
                    sql: """
                        UPDATE changes
                        SET outcome = ?, outcomeCode = ?, outcomeDetail = ?, errorDomain = ?, errorCode = ?, errorText = ?,
                            resultingPath = COALESCE(?, resultingPath), createdFolders = ?
                        WHERE id = ? AND runID = ? AND outcome = ?
                        """,
                    arguments: [
                        outcome.outcome, outcome.code, outcome.detail, outcome.errorDomain, outcome.errorNumber, outcome.errorText,
                        outcome.resultingPath, try Self.encoded(item.createdFolders),
                        changeID, result.runID, ActivityLogOutcomeCode.started,
                    ]
                )
                guard db.changesCount == 1 else {
                    throw ActivityLogError.inconsistent
                }
            } else {
                try Self.insertChange(
                    db,
                    runID: result.runID,
                    sequence: result.sequence,
                    change: item.change,
                    contentHash: nil,
                    outcome: outcome,
                    createdFolders: item.createdFolders,
                    attemptedAt: result.attemptedAt
                )
            }

            let isSkipped: Bool
            let isFailed: Bool
            switch item.outcome {
            case .trashed, .renamed, .moved:
                (isSkipped, isFailed) = (false, false)
            case .skipped:
                (isSkipped, isFailed) = (true, false)
            case .failed:
                (isSkipped, isFailed) = (false, true)
            }
            let bytesMovedToTrash: Int64 = item.isTrashed ? item.change.sizeInBytes : 0
            try db.execute(
                sql: """
                    UPDATE runs
                    SET doneCount = doneCount + ?, skippedCount = skippedCount + ?, failedCount = failedCount + ?,
                        bytesMovedToTrash = bytesMovedToTrash + ?
                    WHERE id = ?
                    """,
                arguments: [item.isDone ? 1 : 0, isSkipped ? 1 : 0, isFailed ? 1 : 0, bytesMovedToTrash, result.runID]
            )
            guard db.changesCount == 1 else {
                throw ActivityLogError.inconsistent
            }
            if item.isDone {
                try db.execute(
                    sql: "UPDATE totals SET bytesMovedToTrash = bytesMovedToTrash + ?, filesCleaned = filesCleaned + 1 WHERE id = 1",
                    arguments: [bytesMovedToTrash]
                )
                guard db.changesCount == 1 else {
                    throw ActivityLogError.inconsistent
                }
            }
        }
    }

    public func finishRun(_ finish: CleanupRunFinish) throws(ActivityLogError) {
        let skipped = ActivityLogOutcomeCode(.skipped(.cancelled))
        try write { db in
            for item in finish.notReached {
                try Self.insertChange(
                    db,
                    runID: finish.runID,
                    sequence: item.sequence,
                    change: item.change,
                    contentHash: nil,
                    outcome: skipped,
                    createdFolders: [],
                    attemptedAt: finish.finishedAt
                )
            }
            let state: ActivityRun.State = finish.wasCancelled ? .cancelled : .finished
            try db.execute(
                sql: "UPDATE runs SET state = ?, finishedAt = ?, skippedCount = skippedCount + ? WHERE id = ?",
                arguments: [state.logCode, finish.finishedAt.timeIntervalSinceReferenceDate, finish.notReached.count, finish.runID]
            )
            guard db.changesCount == 1 else {
                throw ActivityLogError.inconsistent
            }
        }
        truncateWriteAheadFile()
    }

    /// One `changes` row. `resultingPath` is where the file went when the outcome says so, and
    /// otherwise where a rename or a move was to put it. Its folder is its run's, read from the run
    /// so the two can never disagree.
    private static func insertChange(
        _ db: Database,
        runID: Int64,
        sequence: Int,
        change: ProposedChange,
        contentHash: ContentHash?,
        outcome: ActivityLogOutcomeCode,
        createdFolders: [URL],
        fileNumber: UInt64? = nil,
        attemptedAt: Date
    ) throws {
        let reason = change.reason.logCode
        let statement = try db.cachedStatement(sql: """
            INSERT INTO changes (
                runID, sequence, operation, originalPath, resultingPath, sizeInBytes, dateModified, contentHash,
                reasonCode, reasonDetail, outcome, outcomeCode, outcomeDetail, errorDomain, errorCode, errorText,
                createdFolders, attemptedAt, fileNumber, isFolder, folderID
            ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, (SELECT folderID FROM runs WHERE id = ?))
            """)
        try statement.execute(arguments: [
            runID, sequence, ActivityChange.Operation(change.operation).logCode, change.originalPath,
            outcome.resultingPath ?? change.destinationPath, change.sizeInBytes,
            change.dateModified?.timeIntervalSinceReferenceDate, contentHash.map { Data($0.bytes) },
            reason.code, reason.detail, outcome.outcome, outcome.code, outcome.detail,
            outcome.errorDomain, outcome.errorNumber, outcome.errorText,
            try encoded(createdFolders), attemptedAt.timeIntervalSinceReferenceDate,
            fileNumber.map(ActivityLog.storedFileNumber), change.isFolder, runID,
        ])
    }

    /// The folders made for a move, as a JSON array of paths. Nil when there are none.
    static func encoded(_ folders: [URL]) throws -> String? {
        guard !folders.isEmpty else {
            return nil
        }
        let data = try JSONEncoder().encode(folders.map { $0.path(percentEncoded: false) })
        return String(decoding: data, as: UTF8.self)
    }
}
