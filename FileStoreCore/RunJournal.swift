import Foundation

/// Proof that a change's `started` row is in the activity log. Only `RunJournal` can make one, and
/// every `DiskChange` call that touches a user's file asks for one, so the compiler holds the rule
/// that nothing on disk changes before the log says it is about to.
struct ChangePermit {
    fileprivate init() {}
}

/// The executor's side of the activity log for one run: opens the run, records each item before
/// and after its change, and remembers the first failure. Once a write has failed the journal is
/// stopped: it hands out no more permits and writes nothing more, so the run ends there.
///
/// It lives inside one `execute` call and is passed along `inout`, like the other state of a run.
struct RunJournal {
    private let recorder: any CleanupRecording
    private var runID: Int64?

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

    /// Records that `change` is about to happen, with the folders a move is about to make.
    /// - Returns: The permit the change needs, or nil when the row could not be written: the file
    ///   must then be left exactly as it is.
    mutating func intend(_ change: ProposedChange, contentHash: ContentHash?, foldersToMake: [URL] = []) -> ChangePermit? {
        guard !isStopped, let runID else {
            return nil
        }
        do throws(ActivityLogError) {
            pendingChangeID = try recorder.recordIntent(
                CleanupChangeIntent(
                    runID: runID,
                    sequence: sequence,
                    change: change,
                    contentHash: contentHash,
                    foldersToMake: foldersToMake,
                    attemptedAt: .now
                )
            )
            return ChangePermit()
        } catch {
            failure = CleanupLogFailure(error: error, unrecordedChangeID: nil)
            return nil
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
}
