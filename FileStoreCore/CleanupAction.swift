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

    /// Proposes for the Trash the disk images, packages and app zips whose apps are already
    /// installed: ticked when the identifier and version say so, unticked as a possible match when
    /// only the name does.
    case removeUsedInstallers

    /// Proposes cleaner names for files with copy numbers or leftover junk in their names, never a
    /// name that is taken (`MessyNamePlanner`).
    case fixMessyNames

    /// Lists files with the same cleaned name and different content, for review: nothing is ticked
    /// and nothing is chosen to stay (`NearDuplicatePlanner`). The user may tick files for the
    /// Trash, never every file of a group.
    case reviewNearDuplicates

    /// Proposes moving the files marked Never opened or Unused into the archive folder, or, for a file
    /// whose identical copy the archive already holds, the Trash (`ArchivePlanner`). Nothing is deleted.
    case archiveOldDownloads

    /// Lists the files and packages taking at least the large-download setting on disk, largest
    /// first, for review: nothing is ticked (`LargeFilePlanner`). The user may tick any for the Trash.
    case reviewLargeDownloads

    /// True when a plan of this action may propose `operation`: the kind its definition states. The
    /// executor refuses every other operation, so a plan built elsewhere cannot make Find Duplicates
    /// rename a file, say.
    public func allows(_ operation: ProposedChange.Operation) -> Bool {
        definition.operation.matches(operation)
    }
}
