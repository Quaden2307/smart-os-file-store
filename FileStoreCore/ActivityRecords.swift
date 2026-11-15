import Foundation

/// One confirmed cleanup, as the activity log holds it.
public struct ActivityRun: Sendable, Hashable, Identifiable {
    /// How a run ended, or that it has not ended.
    public enum State: Sendable, Hashable {
        /// Still being carried out by this copy of the app.
        case running

        /// Every confirmed change was looked at.
        case finished

        /// Stopped by the user before every change was reached.
        case cancelled

        /// The app stopped, or the log failed, before the run ended. Found when the log is next opened.
        case interrupted
    }

    public let id: Int64

    /// The action as stored. `action` is nil when this version of the app does not know the code.
    public let actionCode: String

    /// The folder the run was planned for.
    public let folderPath: String

    public let startedAt: Date

    /// Nil while the run is running, and for a run that was interrupted.
    public let finishedAt: Date?

    public let state: State

    /// How many changes the user confirmed.
    public let confirmedCount: Int

    /// Changes carried out: trashed, renamed or moved.
    public let doneCount: Int

    public let skippedCount: Int

    public let failedCount: Int

    /// Bytes of the files this run moved to the Trash. The space is free once the Trash is emptied.
    public let bytesMovedToTrash: Int64

    public var action: CleanupAction? { CleanupAction(logCode: actionCode) }

    public init(
        id: Int64,
        actionCode: String,
        folderPath: String,
        startedAt: Date,
        finishedAt: Date?,
        state: State,
        confirmedCount: Int,
        doneCount: Int,
        skippedCount: Int,
        failedCount: Int,
        bytesMovedToTrash: Int64
    ) {
        self.id = id
        self.actionCode = actionCode
        self.folderPath = folderPath
        self.startedAt = startedAt
        self.finishedAt = finishedAt
        self.state = state
        self.confirmedCount = confirmedCount
        self.doneCount = doneCount
        self.skippedCount = skippedCount
        self.failedCount = failedCount
        self.bytesMovedToTrash = bytesMovedToTrash
    }
}

/// One item of a run, as the activity log holds it: what was to be done, to which file, and what
/// happened. Enough to undo the change later; never the file's content.
public struct ActivityChange: Sendable, Hashable, Identifiable {
    /// What was to be done to the file. The names an operation carries are in the paths.
    public enum Operation: Sendable, Hashable {
        case moveToTrash
        case rename
        case move
    }

    public enum Outcome: Sendable, Hashable {
        /// Written right before the change. A row still in this state belongs to a run that is
        /// running, or to one that was interrupted: the change may or may not have happened.
        case started

        /// The file is in the Trash; `resultingPath` is where, when the system reported it.
        case trashed

        /// The file has a new name; `resultingPath` is its new place.
        case renamed

        /// The file is in another folder; `resultingPath` is its new place.
        case moved

        case skipped(CleanupSkipReason)

        case failed(CleanupExecutionError)

        /// A code this version of the app does not know, as stored.
        case unrecognized(code: String)
    }

    public let id: Int64

    public let runID: Int64

    /// The item's place among the run's confirmed changes, from zero.
    public let sequence: Int

    /// Nil when this version of the app does not know the stored code.
    public let operation: Operation?

    /// Where the file was.
    public let originalPath: String

    /// Where the file went, or was to go: the place in the Trash once the system reported it, the
    /// new name or folder for a rename or a move. Nil for the Trash until the move has happened.
    public let resultingPath: String?

    /// Size at scan time, which the executor rechecked.
    public let sizeInBytes: Int64

    /// Modification date at scan time, exactly as the scan read it.
    public let dateModified: Date?

    /// The content the executor confirmed right before the change, when the action compares content.
    public let contentHash: ContentHash?

    /// Why the action proposed the change. Nil when this version does not know the stored code.
    public let reason: ProposedChange.Reason?

    public let outcome: Outcome

    /// Folders made for this item's move, outermost first. For a row still in the `started` state,
    /// the folders the move was about to make: like the file, they may or may not have been made.
    public let createdFolders: [String]

    /// When the item was attempted.
    public let attemptedAt: Date

    /// When the change was undone. Always nil until undo exists.
    public let undoneAt: Date?

    public init(
        id: Int64,
        runID: Int64,
        sequence: Int,
        operation: Operation?,
        originalPath: String,
        resultingPath: String?,
        sizeInBytes: Int64,
        dateModified: Date?,
        contentHash: ContentHash?,
        reason: ProposedChange.Reason?,
        outcome: Outcome,
        createdFolders: [String],
        attemptedAt: Date,
        undoneAt: Date?
    ) {
        self.id = id
        self.runID = runID
        self.sequence = sequence
        self.operation = operation
        self.originalPath = originalPath
        self.resultingPath = resultingPath
        self.sizeInBytes = sizeInBytes
        self.dateModified = dateModified
        self.contentHash = contentHash
        self.reason = reason
        self.outcome = outcome
        self.createdFolders = createdFolders
        self.attemptedAt = attemptedAt
        self.undoneAt = undoneAt
    }

    /// True when the change was carried out: trashed, renamed or moved.
    public var isDone: Bool {
        switch outcome {
        case .trashed, .renamed, .moved:
            true
        case .started, .skipped, .failed, .unrecognized:
            false
        }
    }

    /// Where the file should be now, going by the log alone: its new place once the change was
    /// carried out, otherwise where it was. Nil for a file in the Trash whose place the system did
    /// not report. Whether anything is still there is for the caller to check.
    public var expectedPath: String? {
        isDone ? resultingPath : originalPath
    }
}

/// Running counters since the log began. Pruning old runs never lowers them.
public struct ActivityTotals: Sendable, Hashable {
    /// Bytes of every file moved to the Trash. The space is free once the Trash is emptied.
    public let bytesMovedToTrash: Int64

    /// Files trashed, renamed or moved.
    public let filesCleaned: Int

    public init(bytesMovedToTrash: Int64, filesCleaned: Int) {
        self.bytesMovedToTrash = bytesMovedToTrash
        self.filesCleaned = filesCleaned
    }

    public static let zero = ActivityTotals(bytesMovedToTrash: 0, filesCleaned: 0)
}

/// Whether a logged item is still where the log expects it.
public enum ActivityChangePresence: Sendable, Hashable {
    /// Something is at the expected place.
    case present

    /// Nothing is there any more, or the log does not know the place.
    case missing

    /// The place may not be looked at. The Trash is like that for an app without full disk access.
    case unknown
}

extension ActivityChange {
    /// Looks, right now, for each change's file at its expected place. Reads names only, never content.
    @concurrent
    public static func presence(of changes: [ActivityChange]) async -> [ActivityChange.ID: ActivityChangePresence] {
        var result: [ActivityChange.ID: ActivityChangePresence] = [:]
        result.reserveCapacity(changes.count)
        for change in changes {
            guard let path = change.expectedPath else {
                result[change.id] = .missing
                continue
            }
            do throws(FileStatus.Failure) {
                _ = try FileStatus.of(path: path)
                result[change.id] = .present
            } catch {
                switch error {
                case .notFound:
                    result[change.id] = .missing
                case .accessDenied, .other:
                    result[change.id] = .unknown
                }
            }
        }
        return result
    }
}
