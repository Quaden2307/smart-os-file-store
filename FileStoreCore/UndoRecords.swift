import Foundation

// What the executor writes down while it carries out an undo, through `CleanupRecording`. An undo
// is a run of its own in the activity log, with one row per change it was asked to reverse; each
// row names the change it reverses.

public struct UndoRunStart: Sendable, Hashable {
    public let target: UndoTarget
    public let folderURL: URL
    /// The action of the run being undone, as stored, so the undo can be named after it.
    public let undoneActionCode: String
    /// How many changes the user confirmed undoing, the refused ones included.
    public let confirmedCount: Int
    public let startedAt: Date

    public init(target: UndoTarget, folderURL: URL, undoneActionCode: String, confirmedCount: Int, startedAt: Date) {
        self.target = target
        self.folderURL = folderURL
        self.undoneActionCode = undoneActionCode
        self.confirmedCount = confirmedCount
        self.startedAt = startedAt
    }
}

public struct UndoChangeIntent: Sendable, Hashable {
    public let runID: Int64
    /// The item's place in the undo, from zero.
    public let sequence: Int
    public let step: UndoStep
    /// The disk ID of the file undo is about to move, as it read it a moment ago. A crash after the
    /// move leaves the reconciler this to find the file by.
    public let fileNumber: UInt64
    public let attemptedAt: Date

    public init(runID: Int64, sequence: Int, step: UndoStep, fileNumber: UInt64, attemptedAt: Date) {
        self.runID = runID
        self.sequence = sequence
        self.step = step
        self.fileNumber = fileNumber
        self.attemptedAt = attemptedAt
    }
}

/// What the log answered when undo asked to start reversing a change.
public enum UndoIntentDecision: Sendable, Hashable {
    /// The started row is in, with this identifier: the move may go ahead.
    case recorded(rowID: Int64)
    /// The change is undone already, or another row is undoing it.
    case alreadyUndone
    /// The step does not describe the change as the log recorded it (other paths or other
    /// evidence), so it is not this change's file that would move.
    case notAsRecorded
}

public struct UndoChangeResult: Sendable, Hashable {
    public let runID: Int64
    /// The item's `started` row, when it got that far.
    public let rowID: Int64?
    public let sequence: Int
    public let item: UndoItemResult
    public let attemptedAt: Date

    public init(runID: Int64, rowID: Int64?, sequence: Int, item: UndoItemResult, attemptedAt: Date) {
        self.runID = runID
        self.rowID = rowID
        self.sequence = sequence
        self.item = item
        self.attemptedAt = attemptedAt
    }
}

public struct UndoRunFinish: Sendable, Hashable {
    /// A change the undo did not try: refused when it was planned, or not reached before it was stopped.
    public struct NotTried: Sendable, Hashable {
        public let sequence: Int
        public let item: UndoItemResult

        public init(sequence: Int, item: UndoItemResult) {
            self.sequence = sequence
            self.item = item
        }
    }

    public let runID: Int64
    public let finishedAt: Date
    public let wasCancelled: Bool
    /// Recorded as not undone with their reasons, so the run's counts add up to what was confirmed.
    public let notTried: [NotTried]

    public init(runID: Int64, finishedAt: Date, wasCancelled: Bool, notTried: [NotTried]) {
        self.runID = runID
        self.finishedAt = finishedAt
        self.wasCancelled = wasCancelled
        self.notTried = notTried
    }
}
