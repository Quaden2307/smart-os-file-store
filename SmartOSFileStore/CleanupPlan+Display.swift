import FileStoreCore
import Foundation

extension ProposedChange.Reason {
    /// The reason in the user's words, for the preview.
    var localizedDescription: String {
        switch self {
        case .sameContent(let fileName):
            String(localized: "Same content as \(fileName)")
        }
    }
}

extension CleanupSkipReason {
    /// Why a file was not checked or not moved, in the user's words: what happened and what to do.
    /// The system's own wording never appears here; it goes to the log.
    var localizedDescription: String {
        switch self {
        case .changedSinceScan:
            String(localized: "Changed since the folder was scanned. Run Find Duplicates again.")
        case .notFound:
            String(localized: "No longer in the folder.")
        case .accessDenied:
            String(localized: "Not allowed to read it. Check its permissions in Finder (Get Info).")
        case .notDownloaded:
            String(localized: "Not downloaded to this Mac yet. Download it first if you want it checked.")
        case .notARegularFile:
            String(localized: "Something else now has this name, so it was left alone.")
        case .unreadable:
            String(localized: "Could not be read. Check that its disk is connected and try again.")
        case .keptFile:
            String(localized: "This is the copy that is kept.")
        case .notInPlan:
            String(localized: "Not proposed by this scan. Run Find Duplicates again.")
        case .outsideFolder:
            String(localized: "No longer directly inside the folder.")
        case .folderUnavailable:
            String(localized: "The folder could not be reached. Check that its disk is connected, then try again.")
        case .keptFileMissing(let name):
            String(localized: "The kept copy, \(name), is no longer in the folder, so this group was left alone. Run Find Duplicates again.")
        case .keptFileNotVerified(let name):
            String(localized: "The kept copy, \(name), could not be checked, so this group was left alone. Run Find Duplicates again.")
        case .cancelled:
            String(localized: "Stopped before this file was reached.")
        }
    }
}

extension CleanupExecutionError {
    /// Why a file could not be moved, in the user's words. Not named `localizedDescription`, which
    /// `Error` already defines and would silently take over when the value is typed `any Error`.
    var localizedMessage: String {
        switch self {
        case .fileIsLocked:
            String(localized: "The file is locked. Unlock it in Finder (File > Get Info) and try again.")
        case .accessDenied:
            String(localized: "You don’t have permission to move this file. Check its permissions in Finder (Get Info).")
        case .volumeReadOnly:
            String(localized: "The disk is read-only. Move it from Finder once the disk can be written to.")
        case .trashUnavailable:
            String(localized: "This disk has no Trash. Move it from Finder instead.")
        case .other(_, let code, _):
            // The code identifies the failure in a report; the system's sentence stays in the log.
            String(localized: "Couldn’t move it to the Trash (error \(code)). Try again, or move it from Finder.")
        }
    }
}

extension CleanupItemOutcome {
    /// What happened to the file, in the user's words, for the summary.
    var localizedDescription: String {
        switch self {
        case .trashed:
            String(localized: "Moved to the Trash")
        case .skipped(let reason):
            reason.localizedDescription
        case .failed(let error):
            error.localizedMessage
        }
    }
}
