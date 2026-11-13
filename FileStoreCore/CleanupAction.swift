import Foundation

/// Identifies a cleanup action. Every plan carries one, so previews, logs and, later, undo and
/// on-device AI tools know which action proposed a change.
public enum CleanupAction: String, Sendable, Codable, CaseIterable, Hashable {
    /// Finds files with identical content and proposes all but one copy for the Trash.
    case findDuplicates
}
