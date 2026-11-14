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

/// What carrying out a plan did: one result per confirmed change, in plan order.
public struct CleanupResult: Sendable, Hashable {
    public let action: CleanupAction

    public let folderURL: URL

    public let items: [CleanupItemResult]

    /// True when the task was cancelled before every item was reached. The items not reached are
    /// reported as skipped; changes already made stand, since each one can be undone.
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
