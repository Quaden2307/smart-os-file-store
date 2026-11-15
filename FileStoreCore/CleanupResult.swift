import Foundation

/// Why a confirmed change could not be carried out. Each case has a message in the app's words.
public enum CleanupExecutionError: Error, Sendable, Hashable {
    /// The file is locked (Finder's "Locked", `uchg`). It is never unlocked on the user's behalf.
    case fileIsLocked

    /// The file system refused to move the file.
    case accessDenied

    /// The volume is read-only.
    case volumeReadOnly

    /// The volume has no Trash, so nothing on it can be moved there.
    case trashUnavailable

    /// The volume cannot rename without the risk of replacing an existing item (it has no
    /// exclusive rename), so nothing on it is renamed or moved.
    case renameUnsupported

    /// Another failure. `description` is the system's text; `domain` and `code` identify it in logs.
    case other(domain: String, code: Int, description: String)
}

/// What happened to one confirmed change.
public enum CleanupItemOutcome: Sendable, Hashable {
    /// The file is in the Trash. `trashURL` is where it went, when the system reported it.
    case trashed(trashURL: URL?)

    /// The file has a new name in the same folder.
    case renamed(from: URL, to: URL)

    /// The file is in another folder inside the scanned folder.
    case moved(from: URL, to: URL)

    /// The file was left alone because a check right before acting did not pass.
    case skipped(CleanupSkipReason)

    /// Moving the file was attempted, or would have been, and failed.
    case failed(CleanupExecutionError)
}

public struct CleanupItemResult: Sendable, Hashable, Identifiable {
    public var id: URL { change.id }

    /// The change as the plan proposed it.
    public let change: ProposedChange

    public let outcome: CleanupItemOutcome

    /// Folders made for this item's move, outermost first. Reported whatever the outcome, since a
    /// folder made just before a move that then failed is a change on disk too.
    public let createdFolders: [URL]

    public init(change: ProposedChange, outcome: CleanupItemOutcome, createdFolders: [URL] = []) {
        self.change = change
        self.outcome = outcome
        self.createdFolders = createdFolders
    }

    public var isTrashed: Bool {
        if case .trashed = outcome {
            return true
        }
        return false
    }

    /// True when the change was carried out: trashed, renamed or moved.
    public var isDone: Bool {
        switch outcome {
        case .trashed, .renamed, .moved:
            true
        case .skipped, .failed:
            false
        }
    }
}

/// The activity log failed while a plan was being carried out, which stopped the run.
public struct CleanupLogFailure: Sendable, Hashable {
    public let error: ActivityLogError

    /// The one change whose row could not be completed after the log had recorded it as started:
    /// its file may have been changed (the item's own result says what happened), and the log shows
    /// it as started, not how it ended. Nil when the log failed before anything was started for an
    /// item, or after every item was recorded.
    public let unrecordedChangeID: ProposedChange.ID?

    public init(error: ActivityLogError, unrecordedChangeID: ProposedChange.ID?) {
        self.error = error
        self.unrecordedChangeID = unrecordedChangeID
    }
}

/// What carrying out a plan did: one result per confirmed change, in plan order.
public struct CleanupResult: Sendable, Hashable {
    public let action: CleanupAction

    public let folderURL: URL

    public let items: [CleanupItemResult]

    /// True when the task was cancelled before every item was reached. The items not reached are
    /// reported as skipped; changes already made stand, since each one can be undone.
    public let wasCancelled: Bool

    /// Set when the activity log could not be written. The run stopped there: the items after it
    /// are reported as skipped and were not touched.
    public let logFailure: CleanupLogFailure?

    /// The run's row in the activity log, so the run can be undone from its summary. Nil when the
    /// run could not be opened in the log.
    public let runID: ActivityRun.ID?

    public init(
        action: CleanupAction,
        folderURL: URL,
        items: [CleanupItemResult],
        wasCancelled: Bool,
        logFailure: CleanupLogFailure? = nil,
        runID: ActivityRun.ID? = nil
    ) {
        self.action = action
        self.folderURL = folderURL
        self.items = items
        self.wasCancelled = wasCancelled
        self.logFailure = logFailure
        self.runID = runID
    }

    /// True when at least one confirmed change was carried out, so there is something to undo.
    public var hasDoneItems: Bool {
        items.contains(where: \.isDone)
    }

    public var trashed: [CleanupItemResult] {
        items.filter(\.isTrashed)
    }

    public var renamed: [CleanupItemResult] {
        items.filter { item in
            if case .renamed = item.outcome {
                return true
            }
            return false
        }
    }

    public var moved: [CleanupItemResult] {
        items.filter { item in
            if case .moved = item.outcome {
                return true
            }
            return false
        }
    }

    public var skipped: [CleanupItemResult] {
        items.filter { item in
            if case .skipped = item.outcome {
                return true
            }
            return false
        }
    }

    public var failed: [CleanupItemResult] {
        items.filter { item in
            if case .failed = item.outcome {
                return true
            }
            return false
        }
    }

    /// Skipped and failed items together, in plan order: everything that stayed as it was.
    public var leftAlone: [CleanupItemResult] {
        items.filter { !$0.isDone }
    }

    public var trashedCount: Int { trashed.count }

    /// Bytes of the files now in the Trash, by the sizes the scan saw (which the executor rechecked).
    public var bytesFreed: Int64 {
        trashed.reduce(0) { $0 + $1.change.sizeInBytes }
    }
}
