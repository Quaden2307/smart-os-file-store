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

    /// Another failure. `description` is the system's text; `domain` and `code` identify it in logs.
    case other(domain: String, code: Int, description: String)
}

/// What happened to one confirmed change.
public enum CleanupItemOutcome: Sendable, Hashable {
    /// The file is in the Trash. `trashURL` is where it went, when the system reported it.
    case trashed(trashURL: URL?)

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

    public init(change: ProposedChange, outcome: CleanupItemOutcome) {
        self.change = change
        self.outcome = outcome
    }

    public var isTrashed: Bool {
        if case .trashed = outcome {
            return true
        }
        return false
    }
}

/// What carrying out a plan did: one result per confirmed change, in plan order.
public struct CleanupResult: Sendable, Hashable {
    public let action: CleanupAction

    public let folderURL: URL

    public let items: [CleanupItemResult]

    /// True when the task was cancelled before every item was reached. The items not reached are
    /// reported as skipped; moves already made stand, since each one was a move to the Trash.
    public let wasCancelled: Bool

    public init(action: CleanupAction, folderURL: URL, items: [CleanupItemResult], wasCancelled: Bool) {
        self.action = action
        self.folderURL = folderURL
        self.items = items
        self.wasCancelled = wasCancelled
    }

    public var trashed: [CleanupItemResult] {
        items.filter(\.isTrashed)
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

    /// Skipped and failed items together, in plan order.
    public var notMoved: [CleanupItemResult] {
        items.filter { !$0.isTrashed }
    }

    public var trashedCount: Int { trashed.count }

    /// Bytes of the files now in the Trash, by the sizes the scan saw (which the executor rechecked).
    public var bytesFreed: Int64 {
        trashed.reduce(0) { $0 + $1.change.sizeInBytes }
    }
}
