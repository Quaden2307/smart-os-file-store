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

    /// Records that a change is about to happen, as a row in the `started` state. Called once the
    /// item has passed its checks and before anything is changed for it.
    /// - Returns: The row's identifier, for `recordResult`.
    func recordIntent(_ intent: CleanupChangeIntent) throws(ActivityLogError) -> Int64

    /// Records what happened to one item, in one step with the run's counts and the running totals.
    /// With `changeID`, completes that item's `started` row; without, the item was refused before
    /// anything was started and gets its only row here.
    func recordResult(_ result: CleanupChangeResult) throws(ActivityLogError)

    /// Closes a run, and records every item a cancelled run never reached as skipped.
    func finishRun(_ finish: CleanupRunFinish) throws(ActivityLogError)
}

public struct CleanupRunStart: Sendable, Hashable {
    public let action: CleanupAction
    public let folderURL: URL
    /// How many changes the user confirmed.
    public let confirmedCount: Int
    public let startedAt: Date

    public init(action: CleanupAction, folderURL: URL, confirmedCount: Int, startedAt: Date) {
        self.action = action
        self.folderURL = folderURL
        self.confirmedCount = confirmedCount
        self.startedAt = startedAt
    }
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
    public let attemptedAt: Date

    public init(
        runID: Int64,
        sequence: Int,
        change: ProposedChange,
        contentHash: ContentHash?,
        foldersToMake: [URL] = [],
        attemptedAt: Date
    ) {
        self.runID = runID
        self.sequence = sequence
        self.change = change
        self.contentHash = contentHash
        self.foldersToMake = foldersToMake
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
