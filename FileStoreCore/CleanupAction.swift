import Foundation

/// Identifies a cleanup action. Every plan carries one, so previews, logs and, later, undo and
/// on-device AI tools know which action proposed a change.
public enum CleanupAction: String, Sendable, Codable, CaseIterable, Hashable {
    /// Finds files with identical content and proposes all but one copy for the Trash.
    case findDuplicates

    /// Proposes cleaner names for files with copy numbers or leftover junk in their names. Its
    /// planner arrives in its own segment; until then no plan of this action is ever made.
    case fixMessyNames

    /// Proposes moving old downloads into the archive folder. Its planner arrives in its own
    /// segment; until then no plan of this action is ever made.
    case archiveOldDownloads

    /// True when a plan of this action may propose `operation`. The executor refuses every other
    /// operation, so a plan built elsewhere cannot make Find Duplicates rename a file, say. A new
    /// action states its operation here, and the switch makes that a compile-time duty.
    public func allows(_ operation: ProposedChange.Operation) -> Bool {
        switch (self, operation) {
        case (.findDuplicates, .moveToTrash), (.fixMessyNames, .rename), (.archiveOldDownloads, .move):
            true
        case (.findDuplicates, _), (.fixMessyNames, _), (.archiveOldDownloads, _):
            false
        }
    }
}
