import Foundation

/// Why a logged change cannot be undone, now or when it was tried. Typed, so the app can put it
/// into words in the user's language. Undo never guesses: whatever it cannot prove is refused.
public enum UndoRefusal: Sendable, Hashable {
    /// The change was undone already. There is no redo, so it cannot be undone again.
    case alreadyUndone

    /// The change was skipped or failed when it was made, so the file was never changed.
    case nothingChanged

    /// The cleanup stopped while this change was under way, so nobody knows whether the file was
    /// changed.
    case interrupted

    /// The change is itself an undo. There is no redo.
    case isAnUndo

    /// A newer version of the app recorded the change in a way this version does not know.
    case unknownToThisVersion

    /// The change was made in another folder than the one the app looks after now.
    case otherFolder

    /// The scanned folder itself cannot be reached.
    case folderUnavailable

    /// The system did not report where in the Trash the file went, and undo never looks for it by name.
    case trashLocationUnknown

    /// The log names a place undo may not act on: outside the Trash or the scanned folder, a
    /// folder reached through a link, or a name that is not one valid name.
    case notWhereRecorded

    /// Nothing is at the place the change put the file: the Trash was emptied, or the file was
    /// moved, renamed or deleted since.
    case missing

    /// Something else is in the file's place: another file (another disk ID), a folder or a link.
    case replaced

    /// The file is there but has changed since: another size, modification date or content.
    case changed

    /// The file could not be shown to be the same one: its content cannot be read, and no disk ID
    /// was recorded to stand in for it.
    case cannotBeChecked

    /// Something already has the file's original name in the scanned folder. It is never
    /// overwritten. `name` is that name.
    case originalNameTaken(name: String)

    /// The file's content is not on this Mac (a cloud placeholder); reading it would start a download.
    case notDownloaded

    /// The file is hidden by flag now. Hidden items are never changed.
    case hidden

    /// The file, or where it would go, may not be looked at.
    case accessDenied

    // The reasons below only arise while undo is carried out.

    /// Undo was stopped before this change was reached.
    case cancelled

    /// The activity log could not be written, so undo stopped before this change.
    case activityLogUnavailable
}
