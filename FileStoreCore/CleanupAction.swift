import Foundation

/// Identifies a cleanup action. Every plan carries one, so previews, logs and, later, undo and
/// on-device AI tools know which action proposed a change. What the engine knows about each action
/// is its `definition`. The declaration order is the order the app lists actions in.
public enum CleanupAction: String, Sendable, Codable, CaseIterable, Hashable {
    /// Finds files with identical content and proposes all but one copy for the Trash.
    case findDuplicates

    /// Proposes partial downloads that stopped more than the grace period ago, and never finished,
    /// for the Trash: the one action that handles downloads in progress.
    case clearFailedDownloads

    /// Proposes for the Trash the zips whose every entry already sits next to them, unpacked, at the
    /// same size. What they were unpacked to is never touched.
    case removeUnpackedZips

    /// Proposes cleaner names for files with copy numbers or leftover junk in their names. Its
    /// planner arrives in its own segment; until then no plan of this action is ever made.
    case fixMessyNames

    /// Proposes moving old downloads into the archive folder. Its planner arrives in its own
    /// segment; until then no plan of this action is ever made.
    case archiveOldDownloads

    /// True when a plan of this action may propose `operation`: the one its definition states. The
    /// executor refuses every other operation, so a plan built elsewhere cannot make Find Duplicates
    /// rename a file, say.
    public func allows(_ operation: ProposedChange.Operation) -> Bool {
        definition.operation.matches(operation)
    }
}
