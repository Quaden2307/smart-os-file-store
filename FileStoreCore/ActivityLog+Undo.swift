import Foundation
internal import GRDB

/// Undo's writes, and what the reconciler reads and settles. Each call is one transaction, so a
/// row, the run's counts, the mark on the change it reverses and the totals are all there or none
/// of them is, whenever the app stops.
extension ActivityLog {
    /// The disk ID as SQLite's signed 64-bit integer holds it, bit for bit.
    static func storedFileNumber(_ fileNumber: UInt64) -> Int64 {
        Int64(bitPattern: fileNumber)
    }

    static func fileNumber(stored: Int64) -> UInt64 {
        UInt64(bitPattern: stored)
    }

    /// The outcomes of a change that was carried out, and so can be undone.
    private static let doneOutcomes = "'trashed', 'renamed', 'moved'"

    /// What an undo row stores for its reason: no cleanup action proposed it.
    private static let undoReasonCode = "undo"

    // MARK: - Recording

    public func beginUndoRun(_ start: UndoRunStart) throws(ActivityLogError) -> Int64 {
        try write { db in
            try db.execute(
                sql: "INSERT INTO runs (action, folderPath, startedAt, state, confirmedCount, undoneAction) VALUES (?, ?, ?, ?, ?, ?)",
                arguments: [
                    ActivityRun.undoActionCode,
                    start.folderURL.path(percentEncoded: false),
                    start.startedAt.timeIntervalSinceReferenceDate,
                    ActivityRun.State.running.logCode,
                    start.confirmedCount,
                    start.undoneActionCode,
                ]
            )
            return db.lastInsertedRowID
        }
    }

    public func recordUndoIntent(_ intent: UndoChangeIntent) throws(ActivityLogError) -> UndoIntentDecision {
        let step = intent.step
        return try write { db -> UndoIntentDecision in
            // The step must describe the change exactly as recorded, so a plan built elsewhere cannot
            // pair one change with another file.
            guard let change = try ChangeRow.fetchOne(db, sql: "SELECT * FROM changes WHERE id = ?", arguments: [step.changeID])?.value,
                  change.isDone,
                  change.undoesChangeID == nil,
                  change.operation.flatMap(UndoStep.Operation.init(reversing:)) == step.operation,
                  change.resultingPath == step.currentPath,
                  change.originalPath == step.originalPath,
                  change.undoEvidence == step.evidence else {
                return .notAsRecorded
            }
            // Not undone, and no other row undoing it.
            let isBeingUndone = try Bool.fetchOne(
                db,
                sql: "SELECT EXISTS (SELECT 1 FROM changes WHERE undoesChangeID = ? AND outcome = ?)",
                arguments: [step.changeID, ActivityLogOutcomeCode.started]
            ) ?? false
            guard change.undoneAt == nil, !isBeingUndone else {
                return .alreadyUndone
            }
            try Self.insertUndoRow(
                db,
                runID: intent.runID,
                sequence: intent.sequence,
                item: UndoItemResult(step, outcome: .notUndone(.interrupted)),
                outcome: ActivityLogOutcomeCode(outcome: ActivityLogOutcomeCode.started),
                evidence: UndoEvidence(
                    sizeInBytes: step.evidence.sizeInBytes,
                    dateModified: step.evidence.dateModified,
                    fileNumber: intent.fileNumber,
                    contentHash: step.evidence.contentHash
                ),
                attemptedAt: intent.attemptedAt
            )
            return .recorded(rowID: db.lastInsertedRowID)
        }
    }

    public func recordUndoResult(_ result: UndoChangeResult) throws(ActivityLogError) {
        let item = result.item
        let outcome = ActivityLogOutcomeCode(item.outcome)
        try write { db in
            if let rowID = result.rowID {
                // Only a row still in the started state is completed, and only once.
                try Self.complete(db, rowID: rowID, runID: result.runID, outcome: outcome)
            } else {
                try Self.insertUndoRow(db, runID: result.runID, sequence: result.sequence, item: item, outcome: outcome, attemptedAt: result.attemptedAt)
            }
            try Self.count(db, item, undoing: item.changeID, runID: result.runID, at: result.attemptedAt)
        }
    }

    public func finishUndoRun(_ finish: UndoRunFinish) throws(ActivityLogError) {
        try write { db in
            for notTried in finish.notTried {
                try Self.insertUndoRow(
                    db,
                    runID: finish.runID,
                    sequence: notTried.sequence,
                    item: notTried.item,
                    outcome: ActivityLogOutcomeCode(notTried.item.outcome),
                    attemptedAt: finish.finishedAt
                )
            }
            let state: ActivityRun.State = finish.wasCancelled ? .cancelled : .finished
            try db.execute(
                sql: "UPDATE runs SET state = ?, finishedAt = ?, skippedCount = skippedCount + ? WHERE id = ?",
                arguments: [state.logCode, finish.finishedAt.timeIntervalSinceReferenceDate, finish.notTried.count, finish.runID]
            )
            guard db.changesCount == 1 else {
                throw ActivityLogError.inconsistent
            }
        }
        truncateWriteAheadFile()
    }

    // MARK: - Reconciling

    /// Every undo row still in the started state in a run that is not running: a move back that a
    /// crash, or a failed write, left unrecorded. Opening the log marks every run left running as
    /// interrupted, so after `open` these are all of them.
    @concurrent
    public func interruptedUndoRows() async throws(ActivityLogError) -> [ActivityChange] {
        try read { db in
            try ChangeRow.fetchAll(
                db,
                sql: """
                    SELECT changes.* FROM changes JOIN runs ON runs.id = changes.runID
                    WHERE runs.action = ? AND runs.state != ? AND changes.outcome = ?
                    ORDER BY changes.id
                    """,
                arguments: [ActivityRun.undoActionCode, ActivityRun.State.running.logCode, ActivityLogOutcomeCode.started]
            ).map(\.value)
        }
    }

    /// Completes an interrupted undo row with what the disk shows. When the file was moved back, the
    /// row is completed exactly as `recordUndoResult` would have: the change it reverses is marked
    /// undone and the totals go down.
    @concurrent
    public func resolveInterruptedUndo(_ row: ActivityChange, wasUndone: Bool, at date: Date = .now) async throws(ActivityLogError) {
        let outcome: UndoItemOutcome = wasUndone ? .undone(to: URL(filePath: row.resultingPath ?? row.originalPath)) : .notUndone(.interrupted)
        let item = UndoItemResult(
            changeID: row.undoesChangeID ?? row.id,
            operation: row.operation.flatMap(UndoStep.Operation.init(undoRowOperation:)),
            originalPath: row.resultingPath ?? row.originalPath,
            currentPath: row.originalPath,
            sizeInBytes: row.sizeInBytes,
            outcome: outcome
        )
        try write { db in
            try Self.complete(db, rowID: row.id, runID: row.runID, outcome: ActivityLogOutcomeCode(outcome))
            try Self.count(db, item, undoing: row.undoesChangeID, runID: row.runID, at: date)
        }
    }

    // MARK: - Rows

    /// Completes the started row `rowID` of run `runID` with `outcome`.
    private static func complete(_ db: Database, rowID: Int64, runID: Int64, outcome: ActivityLogOutcomeCode) throws {
        try db.execute(
            sql: """
                UPDATE changes
                SET outcome = ?, outcomeCode = ?, outcomeDetail = ?, errorDomain = ?, errorCode = ?, errorText = ?
                WHERE id = ? AND runID = ? AND outcome = ?
                """,
            arguments: [
                outcome.outcome, outcome.code, outcome.detail, outcome.errorDomain, outcome.errorNumber, outcome.errorText,
                rowID, runID, ActivityLogOutcomeCode.started,
            ]
        )
        guard db.changesCount == 1 else {
            throw ActivityLogError.inconsistent
        }
    }

    /// The run's counts for one item and, when it was undone, the mark on the change it reverses
    /// and the totals, lowered by exactly what that change added: its bytes when it went to the
    /// Trash, and one file. A change is marked undone once; a second mark is an inconsistency.
    private static func count(_ db: Database, _ item: UndoItemResult, undoing changeID: Int64?, runID: Int64, at date: Date) throws {
        let isUndone = item.isUndone
        let isFailed = if case .failed = item.outcome { true } else { false }
        let isSkipped = !isUndone && !isFailed
        try db.execute(
            sql: """
                UPDATE runs
                SET doneCount = doneCount + ?, skippedCount = skippedCount + ?, failedCount = failedCount + ?,
                    bytesTakenFromTrash = bytesTakenFromTrash + ?
                WHERE id = ?
                """,
            arguments: [isUndone ? 1 : 0, isSkipped ? 1 : 0, isFailed ? 1 : 0, item.bytesTakenFromTrash, runID]
        )
        guard db.changesCount == 1 else {
            throw ActivityLogError.inconsistent
        }
        guard isUndone else {
            return
        }
        if let changeID {
            try db.execute(
                sql: "UPDATE changes SET undoneAt = ? WHERE id = ? AND undoneAt IS NULL AND outcome IN (\(doneOutcomes))",
                arguments: [date.timeIntervalSinceReferenceDate, changeID]
            )
            guard db.changesCount == 1 else {
                throw ActivityLogError.inconsistent
            }
        }
        try db.execute(
            sql: "UPDATE totals SET bytesMovedToTrash = bytesMovedToTrash - ?, filesCleaned = filesCleaned - 1 WHERE id = 1",
            arguments: [item.bytesTakenFromTrash]
        )
        guard db.changesCount == 1 else {
            throw ActivityLogError.inconsistent
        }
    }

    /// One undo row. `originalPath` is where the file was before the undo, `resultingPath` where
    /// it goes back to; `undoesChangeID` names the change it reverses.
    private static func insertUndoRow(
        _ db: Database,
        runID: Int64,
        sequence: Int,
        item: UndoItemResult,
        outcome: ActivityLogOutcomeCode,
        evidence: UndoEvidence? = nil,
        attemptedAt: Date
    ) throws {
        let statement = try db.cachedStatement(sql: """
            INSERT INTO changes (
                runID, sequence, operation, originalPath, resultingPath, sizeInBytes, dateModified, contentHash,
                reasonCode, outcome, outcomeCode, outcomeDetail, errorDomain, errorCode, errorText,
                attemptedAt, fileNumber, undoesChangeID
            ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
            """)
        // A change refused before anything was known about it may be one this version cannot read;
        // its row keeps an operation code no version reads as one it knows.
        let operation = item.operation?.loggedOperation.logCode ?? "unknown"
        try statement.execute(arguments: [
            runID, sequence, operation, item.currentPath ?? item.originalPath, item.originalPath, item.sizeInBytes,
            evidence?.dateModified?.timeIntervalSinceReferenceDate, evidence?.contentHash.map { Data($0.bytes) },
            undoReasonCode, outcome.outcome, outcome.code, outcome.detail, outcome.errorDomain, outcome.errorNumber, outcome.errorText,
            attemptedAt.timeIntervalSinceReferenceDate, evidence?.fileNumber.map(storedFileNumber), item.changeID,
        ])
    }
}

extension UndoStep.Operation {
    /// The reversal an undo row stored as `operation`. Nil for a move to the Trash, which no undo row holds.
    public init?(undoRowOperation operation: ActivityChange.Operation) {
        switch operation {
        case .putBackFromTrash:
            self = .putBackFromTrash
        case .rename:
            self = .renameBack
        case .move:
            self = .moveBack
        case .moveToTrash:
            return nil
        }
    }
}
