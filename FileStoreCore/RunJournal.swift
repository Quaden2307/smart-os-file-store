import Foundation

/// Proof that a change's `started` row is in the activity log. Only `RunJournal` can make one, and
/// every `DiskChange` call that touches a user's file asks for one, so the compiler holds the rule
/// that nothing on disk changes before the log says it is about to.
struct ChangePermit {
    fileprivate init() {}
}

/// The executor's side of the activity log for one run: opens the run, checks the Kept list and
/// records each item before and after its change, and remembers the first failure. Once the log has
/// failed the journal is stopped: it hands out no more permits and writes nothing more, so the run
/// ends there.
///
/// It lives inside one `execute` call and is passed along `inout`, like the other state of a run.
struct RunJournal {
    private let recorder: any CleanupRecording

    /// The run's row, once it was opened in the log.
    private(set) var runID: Int64?

    /// The item being processed: its place in the run and, once it has one, its `started` row.
    private var sequence = 0
    private var pendingChangeID: Int64?

    /// The first failure of the log. Nil while the log works.
    private(set) var failure: CleanupLogFailure?

    init(recorder: any CleanupRecording) {
        self.recorder = recorder
    }

    /// True once the log has failed: nothing more may be changed or written.
    var isStopped: Bool { failure != nil }

    /// Opens the run. When this fails nothing on disk has been touched, and nothing will be.
    mutating func begin(action: CleanupAction, folderURL: URL, confirmedCount: Int) {
        do throws(ActivityLogError) {
            runID = try recorder.beginRun(
                CleanupRunStart(action: action, folderURL: folderURL, confirmedCount: confirmedCount, startedAt: .now)
            )
        } catch {
            failure = CleanupLogFailure(error: error, unrecordedChangeID: nil)
        }
    }

    /// Moves on to the confirmed change at `sequence`.
    mutating func startItem(sequence: Int) {
        self.sequence = sequence
        pendingChangeID = nil
    }

    /// What the log said when asked to start a change.
    enum Intent {
        /// The row is in: the change may go ahead.
        case permitted(ChangePermit)
        /// The user has marked the file Kept: leave it exactly as it is.
        case markedKept
        /// The log failed, or had already: leave the file alone, and stop.
        case stopped
    }

    /// Asks to start `change`: first whether the file is Kept, by the list as the log holds it now,
    /// then records that the change is about to happen, with the folders a move is about to make and
    /// the file's disk ID as just read. Every permit comes from here, so no file is ever changed
    /// without this last look at the Kept list, however long its other checks took.
    ///
    /// - Parameters:
    ///   - itemURL: Where the change acts: `<folder>/<name>`. With the plan's own spelling of the
    ///     path, it is what the Kept list compares when the file has no identity.
    ///   - identity: The file's identity as just read, nil when its volume gives none.
    /// - Returns: The permit the change needs, or why there is none: the file must then be left
    ///   exactly as it is.
    mutating func intend(
        _ change: ProposedChange,
        contentHash: ContentHash?,
        foldersToMake: [URL] = [],
        fileNumber: UInt64,
        itemURL: URL,
        identity: PersistentFileIdentity?
    ) -> Intent {
        guard !isStopped, let runID else {
            return .stopped
        }
        do throws(ActivityLogError) {
            // The user may have marked the file Kept since the plan was made; the log checks in the
            // same step as it writes the row.
            let decision = try recorder.recordIntent(
                CleanupChangeIntent(
                    runID: runID,
                    sequence: sequence,
                    change: change,
                    contentHash: contentHash,
                    foldersToMake: foldersToMake,
                    fileNumber: fileNumber,
                    keptProbe: KeptItemProbe(
                        identity: identity,
                        paths: [change.record.keptItemPath, itemURL.path(percentEncoded: false)]
                    ),
                    attemptedAt: .now
                )
            )
            switch decision {
            case .recorded(let rowID):
                pendingChangeID = rowID
                return .permitted(ChangePermit())
            case .markedKept:
                return .markedKept
            }
        } catch {
            failure = CleanupLogFailure(error: error, unrecordedChangeID: nil)
            return .stopped
        }
    }

    /// Records what happened to the current item. When this write fails after the item's `started`
    /// row went in, that row stays as it is and the failure names the item: the log still knows the
    /// file was being changed, only not how it ended.
    mutating func complete(_ item: CleanupItemResult) {
        guard !isStopped, let runID else {
            return
        }
        do throws(ActivityLogError) {
            try recorder.recordResult(
                CleanupChangeResult(runID: runID, changeID: pendingChangeID, sequence: sequence, item: item, attemptedAt: .now)
            )
        } catch {
            failure = CleanupLogFailure(error: error, unrecordedChangeID: pendingChangeID == nil ? nil : item.id)
        }
        pendingChangeID = nil
    }

    /// Closes the run. A run the log failed in is left open; it shows as interrupted from then on.
    mutating func finish(wasCancelled: Bool, notReached: [CleanupRunFinish.NotReached]) {
        guard !isStopped, let runID else {
            return
        }
        do throws(ActivityLogError) {
            try recorder.finishRun(
                CleanupRunFinish(runID: runID, finishedAt: .now, wasCancelled: wasCancelled, notReached: notReached)
            )
        } catch {
            failure = CleanupLogFailure(error: error, unrecordedChangeID: nil)
        }
    }

    // MARK: - Undo

    /// What the log said when undo asked to start reversing a change.
    enum UndoIntent {
        /// The row is in: the move may go ahead.
        case permitted(ChangePermit)
        /// The log says the change is undone already, or being undone: leave the file alone.
        case alreadyUndone
        /// The step is not the change as the log recorded it: leave the file alone.
        case notAsRecorded
        /// The log failed, or had already: leave the file alone, and stop.
        case stopped
    }

    /// Opens an undo run. When this fails nothing on disk has been touched, and nothing will be.
    mutating func beginUndo(_ plan: UndoPlan, confirmedCount: Int) {
        do throws(ActivityLogError) {
            runID = try recorder.beginUndoRun(
                UndoRunStart(
                    target: plan.target,
                    folderURL: plan.folderURL,
                    undoneActionCode: plan.undoneActionCode,
                    confirmedCount: confirmedCount,
                    startedAt: .now
                )
            )
        } catch {
            failure = CleanupLogFailure(error: error, unrecordedChangeID: nil)
        }
    }

    /// Records that `step` is about to be reversed, with the disk ID of the file about to move.
    mutating func intendUndo(_ step: UndoStep, fileNumber: UInt64) -> UndoIntent {
        guard !isStopped, let runID else {
            return .stopped
        }
        do throws(ActivityLogError) {
            switch try recorder.recordUndoIntent(
                UndoChangeIntent(runID: runID, sequence: sequence, step: step, fileNumber: fileNumber, attemptedAt: .now)
            ) {
            case .recorded(let rowID):
                pendingChangeID = rowID
                return .permitted(ChangePermit())
            case .alreadyUndone:
                return .alreadyUndone
            case .notAsRecorded:
                return .notAsRecorded
            }
        } catch {
            failure = CleanupLogFailure(error: error, unrecordedChangeID: nil)
            return .stopped
        }
    }

    /// Records what happened to the current step. As for a cleanup, a failure after the step's
    /// `started` row went in leaves that row as it is, and the reconciler settles it at the next launch.
    mutating func completeUndo(_ item: UndoItemResult) {
        guard !isStopped, let runID else {
            return
        }
        do throws(ActivityLogError) {
            try recorder.recordUndoResult(
                UndoChangeResult(runID: runID, rowID: pendingChangeID, sequence: sequence, item: item, attemptedAt: .now)
            )
        } catch {
            failure = CleanupLogFailure(error: error, unrecordedChangeID: nil)
        }
        pendingChangeID = nil
    }

    /// Closes the undo run, with the changes it did not try.
    mutating func finishUndo(wasCancelled: Bool, notTried: [UndoRunFinish.NotTried]) {
        guard !isStopped, let runID else {
            return
        }
        do throws(ActivityLogError) {
            try recorder.finishUndoRun(UndoRunFinish(runID: runID, finishedAt: .now, wasCancelled: wasCancelled, notTried: notTried))
        } catch {
            failure = CleanupLogFailure(error: error, unrecordedChangeID: nil)
        }
    }
}
