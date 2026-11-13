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
    /// Why a file was not checked, in the user's words.
    var localizedDescription: String {
        switch self {
        case .changedSinceScan:
            String(localized: "Changed since the folder was scanned")
        case .notFound:
            String(localized: "No longer in the folder")
        case .accessDenied:
            String(localized: "Not allowed to read it")
        case .notDownloaded:
            String(localized: "Not downloaded to this Mac yet")
        case .notARegularFile:
            String(localized: "A link or folder now sits at this path")
        case .unreadable(let reason):
            String(localized: "Could not be read: \(reason)")
        case .keptFile:
            String(localized: "This is the copy that is kept")
        case .notInPlan:
            String(localized: "Not part of this cleanup")
        case .outsideFolder:
            String(localized: "Not inside the scanned folder")
        case .folderUnavailable:
            String(localized: "The scanned folder could not be reached")
        case .keptFileMissing(let name):
            String(localized: "The kept copy, \(name), is no longer in the folder, so this group was left alone")
        case .keptFileNotVerified(let name):
            String(localized: "The kept copy, \(name), could not be checked, so this group was left alone")
        case .cancelled:
            String(localized: "Stopped before this file was reached")
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
            String(localized: "You don’t have permission to move this file.")
        case .volumeReadOnly:
            String(localized: "The disk is read-only.")
        case .trashUnavailable:
            String(localized: "This disk has no Trash.")
        case .other(_, _, let description):
            String(localized: "Couldn’t move it to the Trash: \(description)")
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
