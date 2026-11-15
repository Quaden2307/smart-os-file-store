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
            message = String(localized: "Its file can’t be read as a database, so nothing can be cleaned up for now. You can start a fresh log; the damaged file is kept beside it.")
            canStartFresh = true
        case .unreadable:
            title = String(localized: "The Activity Log Can’t Be Opened")
            message = String(localized: "Its file or folder can’t be read or written, so nothing can be cleaned up for now. Check that the disk isn’t full and try again, or start a fresh log; the existing file is kept beside it.")
            canStartFresh = true
        case .newerVersion:
            title = String(localized: "The Activity Log Is From a Newer Version")
            message = String(localized: "A newer version of Smart OS File Store made this log, and this version must not change it. Update the app, or start a fresh log; the existing file is kept beside it.")
            canStartFresh = true
        case .writeFailed:
            // The file itself is most likely sound: a full disk, or another copy of the app holding
            // it. Setting it aside would hide its history for nothing.
            title = String(localized: "The Activity Log Can’t Be Written")
            message = String(localized: "A change couldn’t be recorded, so cleanup stopped. Check that the disk isn’t full and that no other copy of the app is running, then try again.")
            canStartFresh = false
        case .inconsistent:
            title = String(localized: "The Activity Log Can’t Be Trusted")
            message = String(localized: "The log no longer holds what was just written to it, so cleanup stopped. Try again, or start a fresh log; the existing file is kept beside it.")
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
    var title: String {
        action?.title ?? String(localized: "Cleanup")
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
        URL(filePath: originalPath).lastPathComponent
    }

    /// What was to be done, in two or three words.
    var operationTitle: String {
        switch operation {
        case .moveToTrash:
            String(localized: "Move to Trash")
        case .rename:
            String(localized: "Rename")
        case .move:
            String(localized: "Move")
        case nil:
            String(localized: "Change")
        }
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
            error.localizedMessage
        case .unrecognized:
            String(localized: "Recorded by a newer version of the app.")
        }
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
        case .skipped:
            "minus.circle"
        case .failed:
            "exclamationmark.triangle"
        case .started, .unrecognized:
            "questionmark.circle"
        }
    }
}
