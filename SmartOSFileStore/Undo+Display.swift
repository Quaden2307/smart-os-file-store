import FileStoreCore
import Foundation

extension UndoRefusal {
    /// Why a change can't be undone, in a few words for a disabled Undo button and a summary row.
    /// `operation` tells a file that went to the Trash from one that was renamed or moved.
    func localizedDescription(for operation: UndoStep.Operation?) -> String {
        switch self {
        case .alreadyUndone:
            String(localized: "Already undone")
        case .nothingChanged:
            String(localized: "Nothing changed, so there is nothing to undo.")
        case .interrupted:
            String(localized: "Can’t tell whether this file was changed: the cleanup was interrupted.")
        case .isAnUndo:
            String(localized: "An undo can’t be undone.")
        case .unknownToThisVersion:
            String(localized: "Recorded by a newer version of the app")
        case .otherFolder:
            String(localized: "Cleaned up in another folder")
        case .folderUnavailable:
            String(localized: "The folder can’t be reached.")
        case .trashLocationUnknown:
            String(localized: "Where it went in the Trash wasn’t recorded.")
        case .notWhereRecorded:
            String(localized: "The activity log’s record of where it went can’t be used.")
        case .missing:
            switch operation {
            case .putBackFromTrash:
                String(localized: "The Trash was emptied, or the file was taken out of it.")
            case .renameBack, .moveBack, nil:
                String(localized: "The file was moved, renamed or deleted since.")
            }
        case .replaced:
            String(localized: "Another file is in its place.")
        case .changed:
            String(localized: "The file was changed since.")
        case .cannotBeChecked:
            String(localized: "It can’t be checked to be the same file.")
        case .originalNameTaken:
            String(localized: "A file with the original name now exists.")
        case .notDownloaded:
            String(localized: "The file’s content isn’t on this Mac.")
        case .hidden:
            String(localized: "The file is hidden now.")
        case .accessDenied:
            String(localized: "The app isn’t allowed to look at it.")
        case .cancelled:
            String(localized: "Stopped before this file was reached")
        case .activityLogUnavailable:
            String(localized: "The activity log couldn’t be written, so it was left as it was.")
        }
    }
}

extension UndoItemOutcome {
    /// What undo did to one file, in the user's words.
    func localizedDescription(for operation: UndoStep.Operation?) -> String {
        switch self {
        case .undone:
            switch operation {
            case .putBackFromTrash:
                String(localized: "Put back from the Trash")
            case .renameBack:
                String(localized: "Given its old name back")
            case .moveBack, nil:
                String(localized: "Moved back")
            }
        case .notUndone(let refusal):
            refusal.localizedDescription(for: operation)
        case .failed(.accessDenied) where operation == .putBackFromTrash:
            // macOS lets an app take out of the Trash only what that app put there.
            String(localized: "macOS didn’t let the app put it back from the Trash. Use Put Back in the Trash in Finder.")
        case .failed(let error):
            error.undoMessage
        }
    }
}

extension CleanupExecutionError {
    /// A move back the system refused, in the user's words. The system's own sentence stays in the log.
    var undoMessage: String {
        switch self {
        case .fileIsLocked:
            String(localized: "The file is locked. Unlock it in Finder (File > Get Info) and try again.")
        case .accessDenied:
            String(localized: "You don’t have permission to put this file back.")
        case .volumeReadOnly:
            String(localized: "The disk is read-only.")
        case .trashUnavailable, .renameUnsupported:
            String(localized: "This disk can’t put files back without the risk of replacing one.")
        case .other(_, let code, _):
            String(localized: "Couldn’t put it back (error \(code)). Try again.")
        }
    }
}

extension UndoPlan {
    /// "Undo Find Duplicates": the undo named after the run it undoes.
    var title: String {
        UndoPlan.title(undoingCode: undoneActionCode)
    }

    /// "Undo Find Duplicates", or "Undo Tidy Now", for the run stored with `code`.
    static func title(undoingCode code: String?) -> String {
        let actionTitle = if code == ActivityRun.tidyNowActionCode {
            String(localized: "Tidy Now")
        } else {
            CleanupAction.allCases.first { $0.definition.identifier == code }?.commandTitle ?? String(localized: "Cleanup")
        }
        return String(localized: "Undo \(actionTitle)")
    }
}

extension UndoResult {
    var title: String {
        UndoPlan.title(undoingCode: undoneActionCode)
    }
}

extension UndoRefusal {
    /// The same, for a row of an undo itself. There an interruption was the undo's: the reconciler
    /// found the file had not been put back.
    func localizedDescriptionInUndo(for operation: UndoStep.Operation?) -> String {
        self == .interrupted
            ? String(localized: "Undo was interrupted before this file was put back.")
            : localizedDescription(for: operation)
    }
}

extension UndoItemResult {
    /// The file's name as undo shows it: the name it has, or gets back.
    var displayName: String {
        originalName
    }
}
