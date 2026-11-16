import Foundation

/// What the executor writes down while it carries out a plan. `ActivityLog` is the real one; tests
/// supply their own to watch the calls or to make one fail.
///
/// The methods are synchronous on purpose. The executor calls them on its own background thread,
/// between its checks and the change on disk, and a write must finish even when the run's task has
/// just been cancelled: the file that was moved a moment ago still has to be recorded.
///
/// Every method throws when the row could not be written. The executor then stops the run: it never
/// changes a file whose change it could not record first.
public protocol CleanupRecording: Sendable {
    /// Opens a run. Nothing on disk has changed yet.
    /// - Returns: The run's identifier, for the calls that follow.
    func beginRun(_ start: CleanupRunStart) throws(ActivityLogError) -> Int64

    /// Records that a change is about to happen, as a row in the `started` state, but only while the
    /// file is not Kept: the Kept list is checked in the same step as the row is written, so a file
    /// marked Kept at any moment before is never changed. Called once the item has passed every
    /// other check and before anything is changed for it.
    /// - Returns: The row's identifier, for `recordResult`, or that the file is Kept and must be left
    ///   exactly as it is.
    func recordIntent(_ intent: CleanupChangeIntent) throws(ActivityLogError) -> CleanupIntentDecision

    /// Records what happened to one item, in one step with the run's counts and the running totals.
    /// With `changeID`, completes that item's `started` row; without, the item was refused before
    /// anything was started and gets its only row here.
    func recordResult(_ result: CleanupChangeResult) throws(ActivityLogError)

    /// Closes a run, and records every item a cancelled run never reached as skipped.
    func finishRun(_ finish: CleanupRunFinish) throws(ActivityLogError)

    // An undo is a run of its own, written the same way: a started row before each move, the result
    // right after it.

    /// Opens an undo run. Nothing on disk has changed yet.
    func beginUndoRun(_ start: UndoRunStart) throws(ActivityLogError) -> Int64

    /// Records that a change is about to be reversed, as a row in the `started` state, but only
    /// while the step describes the change exactly as the log recorded it (its paths and evidence),
    /// and the change is done, not undone, and not being undone by another row.
    /// - Returns: The row's identifier, or why the log refused: the file must then be left as it is.
    func recordUndoIntent(_ intent: UndoChangeIntent) throws(ActivityLogError) -> UndoIntentDecision

    /// Records what happened to one change, in one step with the run's counts. When it was undone,
    /// the same step marks the change it reverses as undone and lowers the running totals by what
    /// that change added to them.
    func recordUndoResult(_ result: UndoChangeResult) throws(ActivityLogError)

    /// Closes an undo run, and records every change it did not try as not undone.
    func finishUndoRun(_ finish: UndoRunFinish) throws(ActivityLogError)
}

public struct CleanupRunStart: Sendable, Hashable {
    /// The action whose plan the run carries out. Nil for a Tidy Now run, which carries out the
    /// plans of several actions as one run.
    public let action: CleanupAction?
    /// What the log stores as the run's action: the action's identifier, or
    /// `ActivityRun.tidyNowActionCode`.
    public let logCode: String
    public let folderURL: URL
    /// How many changes the user confirmed.
    public let confirmedCount: Int
    public let startedAt: Date

    public init(action: CleanupAction, folderURL: URL, confirmedCount: Int, startedAt: Date) {
        self.action = action
        self.logCode = action.logCode
        self.folderURL = folderURL
        self.confirmedCount = confirmedCount
        self.startedAt = startedAt
    }

    /// A Tidy Now run: the confirmed changes of every action's plan, recorded as one run so that one
    /// undo reverses all of it.
    public static func tidyNow(folderURL: URL, confirmedCount: Int, startedAt: Date) -> CleanupRunStart {
        CleanupRunStart(logCode: ActivityRun.tidyNowActionCode, folderURL: folderURL, confirmedCount: confirmedCount, startedAt: startedAt)
    }

    private init(logCode: String, folderURL: URL, confirmedCount: Int, startedAt: Date) {
        self.action = nil
        self.logCode = logCode
        self.folderURL = folderURL
        self.confirmedCount = confirmedCount
        self.startedAt = startedAt
    }
}

/// What the log said to a change about to happen.
public enum CleanupIntentDecision: Sendable, Hashable {
    /// The started row is in, with this identifier: the change may go ahead.
    case recorded(rowID: Int64)
    /// The user has marked the file Kept: no row was written, and the file must be left alone.
    case markedKept
}

public struct CleanupChangeIntent: Sendable, Hashable {
    public let runID: Int64
    /// The item's place among the run's confirmed changes, from zero.
    public let sequence: Int
    public let change: ProposedChange
    /// The content the executor has just confirmed the file to hold, when the action compares content.
    public let contentHash: ContentHash?
    /// For a move, the folders it is about to make, outermost first. Recorded with the intent, so
    /// that if the run stops after making them the log still names them.
    public let foldersToMake: [URL]
    /// The file's number on its disk (inode), as the executor read it right before the change.
    /// Undo checks it to know the file it finds later is this one.
    public let fileNumber: UInt64?
    /// The file as the Kept list is asked about it: its identity as just read and its paths.
    public let keptProbe: KeptItemProbe
    public let attemptedAt: Date

    public init(
        runID: Int64,
        sequence: Int,
        change: ProposedChange,
        contentHash: ContentHash?,
        foldersToMake: [URL] = [],
        fileNumber: UInt64? = nil,
        keptProbe: KeptItemProbe? = nil,
        attemptedAt: Date
    ) {
        self.runID = runID
        self.sequence = sequence
        self.change = change
        self.contentHash = contentHash
        self.foldersToMake = foldersToMake
        self.fileNumber = fileNumber
        // Without an identity, every entry made at the plan's path counts: the protective reading.
        self.keptProbe = keptProbe ?? KeptItemProbe(identity: nil, paths: [change.record.keptItemPath])
        self.attemptedAt = attemptedAt
    }
}

public struct CleanupChangeResult: Sendable, Hashable {
    public let runID: Int64
    /// The item's `started` row, when it got that far.
    public let changeID: Int64?
    public let sequence: Int
    public let item: CleanupItemResult
    public let attemptedAt: Date

    public init(runID: Int64, changeID: Int64?, sequence: Int, item: CleanupItemResult, attemptedAt: Date) {
        self.runID = runID
        self.changeID = changeID
        self.sequence = sequence
        self.item = item
        self.attemptedAt = attemptedAt
    }
}

public struct CleanupRunFinish: Sendable, Hashable {
    /// A confirmed change the run stopped before reaching.
    public struct NotReached: Sendable, Hashable {
        public let sequence: Int
        public let change: ProposedChange

        public init(sequence: Int, change: ProposedChange) {
            self.sequence = sequence
            self.change = change
        }
    }

    public let runID: Int64
    public let finishedAt: Date
    public let wasCancelled: Bool
    /// The changes a cancelled run never reached, in plan order. They are recorded as skipped, so
    /// the run's counts add up to what the user confirmed.
    public let notReached: [NotReached]

    public init(runID: Int64, finishedAt: Date, wasCancelled: Bool, notReached: [NotReached]) {
        self.runID = runID
        self.finishedAt = finishedAt
        self.wasCancelled = wasCancelled
        self.notReached = notReached
    }
}
