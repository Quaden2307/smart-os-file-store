import FileStoreCore
import Foundation

extension CleanupPlan {
    /// True when there are duplicate groups and every change belongs to one, so the preview can show
    /// the groups with their kept copies. Any other plan is shown one change per row, so that no change is
    /// ever ticked without being on screen.
    var isGroupedByDuplicates: Bool {
        guard !duplicateGroups.isEmpty else {
            return false
        }
        let groupedURLs = Set(duplicateGroups.flatMap { $0.duplicates.map(\.url) })
        return changes.allSatisfy { groupedURLs.contains($0.id) }
    }

    /// True when every change is a move to the Trash: the only kind the preview can confirm and
    /// carry out so far. Renames and moves are shown but not applied until an action uses them.
    var isTrashOnly: Bool {
        changes.allSatisfy { $0.operation == .moveToTrash }
    }
}

extension ProposedChange {
    /// Where a rename or a move would put the file, as the preview names it: the new name, or the
    /// folder inside the scanned folder plus the name ("Old downloads/report.pdf"). Nil for the Trash.
    func destinationDisplayName(in folderURL: URL) -> String? {
        switch operation {
        case .moveToTrash:
            nil
        case .rename(to: let newName):
            newName
        case .move(to: let folder, name: let name):
            Self.displayPath(of: folder, in: folderURL) + "/" + name
        }
    }

    /// The checkbox's label, which VoiceOver reads: what ticking it would do.
    func checkboxLabel(in folderURL: URL) -> String {
        let name = record.displayName
        switch operation {
        case .moveToTrash:
            return String(localized: "Move \(name) to the Trash")
        case .rename(to: let newName):
            return String(localized: "Rename \(name) to \(newName)")
        case .move(to: let folder, name: let newName):
            let folderName = Self.displayPath(of: folder, in: folderURL)
            if newName == name {
                return String(localized: "Move \(name) to \(folderName)")
            }
            return String(localized: "Move \(name) to \(folderName) as \(newName)")
        }
    }

    /// `folder` relative to the scanned folder, such as "Old downloads", or its full path when it
    /// is not inside (the executor refuses such a move, but the preview still names it truthfully).
    private static func displayPath(of folder: URL, in folderURL: URL) -> String {
        let base = folderURL.pathComponents
        let components = folder.pathComponents
        let inside = components.dropFirst(base.count)
        guard components.count > base.count,
              components.starts(with: base),
              !inside.contains(where: { $0 == "." || $0 == ".." }) else {
            return folder.path(percentEncoded: false)
        }
        return inside.joined(separator: "/")
    }
}

extension ProposedChange.Reason {
    /// The reason in the user's words when the change was made, for Activity: what the preview said,
    /// in the past tense where the preview spoke of the folder as it was.
    var historyDescription: String {
        switch self {
        case .failedDownload(let stoppedOn, let finishedFileName?):
            let date = stoppedOn.formatted(.dateTime.day().month(.abbreviated).year())
            return String(localized: "Download stopped on \(date) and never finished. \(finishedFileName) was next to it.")
        case .sameContent, .messyName, .oldDownload, .failedDownload, .unpackedZip:
            return localizedDescription
        }
    }

    /// The reason in the user's words, for the preview.
    var localizedDescription: String {
        switch self {
        case .sameContent(let fileName):
            return String(localized: "Same content as \(fileName)")
        case .messyName:
            return String(localized: "Messy name")
        case .oldDownload:
            return String(localized: "Old download")
        case .failedDownload(let stoppedOn, let finishedFileName):
            let date = stoppedOn.formatted(.dateTime.day().month(.abbreviated).year())
            guard let finishedFileName else {
                return String(localized: "Download stopped on \(date) and never finished")
            }
            return String(localized: "Download stopped on \(date) and never finished. \(finishedFileName) is next to it.")
        case .unpackedZip(let unpackedTo):
            return String(localized: "Already unpacked to \(unpackedTo)")
        }
    }
}

extension CleanupSkipReason {
    /// Why a file was not checked or not moved by `action`, in the user's words: what happened and
    /// what to do. `action` is nil when a log written by a later version names one this version
    /// does not know. The system's own wording never appears here; it goes to the log.
    func localizedDescription(for action: CleanupAction?) -> String {
        // "Run Find Duplicates again." for the action that made the plan.
        let runAgain = action.map { String(localized: "Run \($0.commandTitle) again.") } ?? String(localized: "Run the cleanup again.")
        switch self {
        case .changedSinceScan where action == .clearFailedDownloads:
            return String(localized: "It changed since the folder was scanned, so the download may have resumed. It was left alone.")
        case .changedSinceScan where action == .removeUnpackedZips:
            // Starting a cleanup plans from the list as it is, so only a refresh sees the change.
            return String(localized: "It changed since the folder was listed, so it was left alone. Refresh the list (⌘R), then run Remove Unpacked Zips again.")
        case .changedSinceScan:
            return String(localized: "Changed since the folder was scanned. \(runAgain)")
        case .notFound:
            return String(localized: "No longer in the folder.")
        case .accessDenied:
            return String(localized: "Not allowed to read it. Check its permissions in Finder (Get Info).")
        case .notDownloaded:
            return String(localized: "Not downloaded to this Mac yet. Download it first if you want it checked.")
        case .notARegularFile:
            return String(localized: "Something else now has this name, so it was left alone.")
        case .unreadable:
            return String(localized: "Could not be read. Check that its disk is connected and try again.")
        case .zipUnlistable(let problem):
            return problem.localizedDescription
        case .keptFile:
            return String(localized: "This is the copy that is kept.")
        case .notInPlan:
            return String(localized: "Not proposed by this scan. \(runAgain)")
        case .markedKept:
            return String(localized: "You marked it Kept, so it was left alone.")
        case .outsideFolder:
            return String(localized: "No longer directly inside the folder.")
        case .folderUnavailable:
            return String(localized: "The folder could not be reached. Check that its disk is connected, then try again.")
        case .keptFileMissing(let name):
            return String(localized: "The kept copy, \(name), is no longer in the folder, so this group was left alone. \(runAgain)")
        case .keptFileNotVerified(let name):
            return String(localized: "The kept copy, \(name), could not be checked, so this group was left alone. \(runAgain)")
        case .unpackedCopyMissing(let name):
            return String(localized: "The unpacked copy, \(name), is no longer next to it, so the zip was left alone. \(runAgain)")
        case .unpackedCopyNotVerified(let name):
            return String(localized: "The unpacked copy, \(name), could not be confirmed to hold everything in the zip, so the zip was left alone. \(runAgain)")
        case .unpackedCopyRecentlyChanged(let name):
            return String(localized: "The unpacked copy, \(name), was added or changed in the last hour and may still be unpacking, so the zip was left alone. It can go once the copy has gone untouched for an hour.")
        case .cancelled:
            return String(localized: "Stopped before this file was reached.")
        case .destinationExists(let name):
            return String(localized: "Something called \(name) is already there, so nothing was replaced.")
        case .invalidName:
            return String(localized: "The new name can’t be used for a file here, so it was left alone.")
        case .destinationOutsideFolder:
            return String(localized: "The destination isn’t inside the folder, or is reached through a link, so it was left alone.")
        case .destinationNotAFolder:
            return String(localized: "Something other than a folder is where the destination folder should be, so it was left alone.")
        case .destinationHidden:
            return String(localized: "The destination folder is hidden, so the file was left where it is.")
        case .activityLogUnavailable:
            return String(localized: "Left alone because the activity log stopped working.")
        }
    }
}

extension ZipListing.Problem {
    /// Why a zip's list of contents could not be read, in the user's words.
    var localizedDescription: String {
        switch self {
        case .damaged:
            String(localized: "It is damaged or incomplete, so what it holds could not be listed.")
        case .encryptedListing:
            String(localized: "Its list of contents is encrypted, so it could not be checked.")
        case .tooManyEntries, .nameTooLong:
            String(localized: "It holds too much to check.")
        case .unreadableNames:
            String(localized: "Its file names use an encoding this app can’t read.")
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
        case .renameUnsupported:
            String(localized: "This disk can’t rename files without the risk of replacing one. Rename it in Finder instead.")
        case .other(_, let code, _):
            // The code identifies the failure in a report; the system's sentence stays in the log.
            String(localized: "Couldn’t move it to the Trash (error \(code)). Try again, or move it from Finder.")
        }
    }
}

extension CleanupItemOutcome {
    /// What happened to the file in a run of `action`, in the user's words, for the summary.
    func localizedDescription(for action: CleanupAction?) -> String {
        switch self {
        case .trashed:
            String(localized: "Moved to the Trash")
        case .renamed(_, let newURL):
            String(localized: "Renamed to \(newURL.lastPathComponent)")
        case .moved(_, let newURL):
            String(localized: "Moved to \(newURL.deletingLastPathComponent().lastPathComponent)")
        case .skipped(let reason):
            reason.localizedDescription(for: action)
        case .failed(let error):
            error.localizedMessage
        }
    }
}
