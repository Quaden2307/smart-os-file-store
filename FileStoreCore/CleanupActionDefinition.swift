import Foundation

/// What the engine knows about one cleanup action, in one place: the name it is stored and called
/// by, and the kind of plan it makes. Adding an action means adding its entry to
/// `CleanupAction.definition`, whose switch makes that a compile-time duty, and stating its planner
/// in `CleanupPlanners`.
public struct CleanupActionDefinition: Sendable, Hashable {
    /// The kind of change every change in the action's plans makes.
    public enum OperationKind: Sendable, Hashable {
        case moveToTrash
        case rename
        case move
        /// A move into the archive folder, or, for a file whose identical copy the archive already
        /// holds, the Trash: Archive Old Downloads, the one action with two operations.
        case archive
    }

    /// The name the activity log stores for the action, and later on-device tools call it by. It is
    /// written out, never derived from the case's name, so renaming a case cannot change what an
    /// existing log means, and it is never reused for another action.
    public let identifier: String

    /// The kind of plan the action makes: what each of its changes does.
    public let operation: OperationKind

    public init(identifier: String, operation: OperationKind) {
        self.identifier = identifier
        self.operation = operation
    }
}

extension CleanupAction {
    /// The action's definition. Every action has exactly one.
    public var definition: CleanupActionDefinition {
        switch self {
        case .findDuplicates:
            CleanupActionDefinition(identifier: "findDuplicates", operation: .moveToTrash)
        case .clearFailedDownloads:
            CleanupActionDefinition(identifier: "clearFailedDownloads", operation: .moveToTrash)
        case .removeUnpackedZips:
            CleanupActionDefinition(identifier: "removeUnpackedZips", operation: .moveToTrash)
        case .removeUsedInstallers:
            CleanupActionDefinition(identifier: "removeUsedInstallers", operation: .moveToTrash)
        case .fixMessyNames:
            CleanupActionDefinition(identifier: "fixMessyNames", operation: .rename)
        case .reviewNearDuplicates:
            CleanupActionDefinition(identifier: "reviewNearDuplicates", operation: .moveToTrash)
        case .archiveOldDownloads:
            CleanupActionDefinition(identifier: "archiveOldDownloads", operation: .archive)
        case .reviewLargeDownloads:
            CleanupActionDefinition(identifier: "reviewLargeDownloads", operation: .moveToTrash)
        case .removeEmptyFolders:
            CleanupActionDefinition(identifier: "removeEmptyFolders", operation: .moveToTrash)
        }
    }
}

extension CleanupActionDefinition.OperationKind {
    /// True when `operation` is of this kind.
    func matches(_ operation: ProposedChange.Operation) -> Bool {
        switch (self, operation) {
        case (.moveToTrash, .moveToTrash), (.rename, .rename), (.move, .move), (.archive, .move), (.archive, .moveToTrash):
            true
        case (.moveToTrash, _), (.rename, _), (.move, _), (.archive, .rename):
            false
        }
    }
}
