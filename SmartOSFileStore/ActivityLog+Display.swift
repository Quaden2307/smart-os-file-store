import FileStoreCore
import Foundation

/// A log that cannot be used, in the user's words: what is wrong and what can be done about it.
/// The codes SQLite and the system report stay in the log.
struct ActivityLogFailure: Equatable {
    let title: String
    let message: String

    /// False when a fresh log could not help: there is nowhere to put one, or the file is most likely
    /// sound and only needs another try.
    let canStartFresh: Bool

    init(_ error: ActivityLogError) {
        switch error {
        case .damaged:
            title = String(localized: "The Activity Log Is Damaged")
            message = String(localized: "Its file can’t be read as a database, so nothing can be cleaned up for now. You can start a fresh log; the damaged file is kept beside it. A fresh log has no history and no files marked Kept.")
            canStartFresh = true
        case .unreadable:
            title = String(localized: "The Activity Log Can’t Be Opened")
            message = String(localized: "Its file or folder can’t be read or written, so nothing can be cleaned up for now. Check that the disk isn’t full and try again, or start a fresh log; the existing file is kept beside it. A fresh log has no history and no files marked Kept.")
            canStartFresh = true
        case .newerVersion:
            title = String(localized: "The Activity Log Is From a Newer Version")
            message = String(localized: "A newer version of Smart OS File Store made this log, and this version must not change it. Update the app, or start a fresh log; the existing file is kept beside it. A fresh log has no history and no files marked Kept.")
            canStartFresh = true
        case .writeFailed:
            // The file itself is most likely sound: a full disk, or another copy of the app holding
            // it. Setting it aside would hide its history for nothing.
            title = String(localized: "The Activity Log Can’t Be Written")
            message = String(localized: "A change couldn’t be recorded, so cleanup stopped. Check that the disk isn’t full and that no other copy of the app is running, then try again.")
            canStartFresh = false
        case .inconsistent:
            title = String(localized: "The Activity Log Can’t Be Trusted")
            message = String(localized: "The log no longer holds what was just written to it, so cleanup stopped. Try again, or start a fresh log; the existing file is kept beside it. A fresh log has no history and no files marked Kept.")
            canStartFresh = true
        case .locationUnavailable:
            title = String(localized: "The Activity Log Has Nowhere to Go")
            message = String(localized: "The Application Support folder in your Library couldn’t be found, so nothing can be cleaned up for now. Quit the app and open it again once the folder is back.")
            canStartFresh = false
        }
    }
}

extension ActivityRun {
    /// The run's heading: its action, or a general word for an action this version does not know.
    /// An undo is named after the run it undid: "Undo Find Duplicates".
    var title: String {
        if isUndo {
            return UndoPlan.title(undoing: undoneAction)
        }
        return action?.title ?? String(localized: "Cleanup")
    }

    /// For a cleanup run some of whose changes were undone since: whether all or some were. Nil otherwise.
    var undoLabel: String? {
        guard !isUndo, undoneCount > 0 else { return nil }
        return undoneCount >= doneCount ? String(localized: "Undone") : String(localized: "Partly Undone")
    }

    /// True while the run still has a change that was carried out and not undone: what Undo may try.
    var hasChangesLeftToUndo: Bool {
        !isUndo && doneCount > undoneCount
    }

    /// A word for a run that did not simply finish. Nil for one that did.
    var stateLabel: String? {
        switch state {
        case .finished:
            nil
        case .running:
            String(localized: "In Progress")
        case .cancelled:
            String(localized: "Stopped")
        case .interrupted:
            String(localized: "Interrupted")
        }
    }

    /// Items that stayed as they were: skipped or failed.
    var leftAloneCount: Int { skippedCount + failedCount }
}

extension ActivityChange {
    /// The file's name as it was before the change.
    var displayName: String {
        Self.name(of: originalPath)
    }

    /// The name a row shows: the name before the change, or for a row of an undo, the name the file
    /// was given back. Taken from the path as stored, so it keeps its Unicode form.
    func displayName(in run: ActivityRun) -> String {
        if run.isUndo, let resultingPath {
            return Self.name(of: resultingPath)
        }
        return displayName
    }

    private static func name(of path: String) -> String {
        path.split(separator: "/").last.map(String.init) ?? path
    }

    /// What was to be done, in two or three words.
    func operationTitle(in run: ActivityRun) -> String {
        switch operation {
        case .moveToTrash:
            String(localized: "Move to Trash")
        case .rename:
            run.isUndo ? String(localized: "Rename Back") : String(localized: "Rename")
        case .move:
            run.isUndo ? String(localized: "Move Back") : String(localized: "Move")
        case .putBackFromTrash:
            String(localized: "Put Back")
        case nil:
            String(localized: "Change")
        }
    }

    /// How undo would reverse this change, for wording that depends on it.
    var undoOperation: UndoStep.Operation? {
        operation.flatMap(UndoStep.Operation.init(reversing:))
    }

    /// What happened to the file, in the user's words. An item that was started and never completed
    /// is still under way in a run that is running, and interrupted in any other.
    func outcomeDescription(in run: ActivityRun) -> String {
        switch outcome {
        case .started:
            run.state == .running
                ? String(localized: "In progress")
                : String(localized: "Interrupted. The file may or may not have been changed.")
        case .trashed:
            String(localized: "Moved to the Trash")
        case .renamed:
            if let resultingPath {
                String(localized: "Renamed to \(URL(filePath: resultingPath).lastPathComponent)")
            } else {
                String(localized: "Renamed")
            }
        case .moved:
            if let resultingPath {
                String(localized: "Moved to \(URL(filePath: resultingPath).deletingLastPathComponent().lastPathComponent)")
            } else {
                String(localized: "Moved")
            }
        case .skipped(let reason):
            reason.localizedDescription
        case .failed(let error):
            run.isUndo
                ? UndoItemOutcome.failed(error).localizedDescription(for: undoRowOperation)
                : error.localizedMessage
        case .undone:
            UndoItemOutcome.undone(to: URL(filePath: resultingPath ?? originalPath)).localizedDescription(for: undoRowOperation)
        case .notUndone(let refusal):
            refusal.localizedDescriptionInUndo(for: undoRowOperation)
        case .unrecognized:
            String(localized: "Recorded by a newer version of the app.")
        }
    }

    /// For an undo row: the reversal it recorded.
    private var undoRowOperation: UndoStep.Operation? {
        operation.flatMap(UndoStep.Operation.init(undoRowOperation:))
    }

    /// The symbol beside the item: what became of it, at a glance.
    var symbolName: String {
        switch outcome {
        case .trashed:
            "trash"
        case .renamed:
            "pencil"
        case .moved:
            "folder"
        case .undone:
            "arrow.uturn.backward"
        case .skipped, .notUndone:
            "minus.circle"
        case .failed:
            "exclamationmark.triangle"
        case .started, .unrecognized:
            "questionmark.circle"
        }
    }
}
