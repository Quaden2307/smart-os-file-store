import FileStoreCore
import Foundation

extension CleanupAction {
    /// The preview's title.
    var title: String {
        switch self {
        case .findDuplicates:
            String(localized: "Duplicates")
        case .fixMessyNames:
            String(localized: "Messy Names")
        case .archiveOldDownloads:
            String(localized: "Old Downloads")
        }
    }

    /// The action as a command, as the toolbar names it: what an undo is named after
    /// ("Undo Find Duplicates").
    var commandTitle: String {
        switch self {
        case .findDuplicates:
            String(localized: "Find Duplicates")
        case .fixMessyNames:
            String(localized: "Fix Messy Names")
        case .archiveOldDownloads:
            String(localized: "Archive Old Downloads")
        }
    }

    /// What the preview says when the action found nothing to change.
    var emptyTitle: String {
        switch self {
        case .findDuplicates:
            String(localized: "No Duplicates Found")
        case .fixMessyNames:
            String(localized: "No Messy Names Found")
        case .archiveOldDownloads:
            String(localized: "No Old Downloads Found")
        }
    }

    var emptyDescription: String {
        switch self {
        case .findDuplicates:
            String(localized: "No two of the files checked have the same content. Files added or changed in the last hour are checked once they are an hour old.")
        case .fixMessyNames:
            String(localized: "Every file checked already has a clean name. Files added or changed in the last hour are checked once they are an hour old.")
        case .archiveOldDownloads:
            String(localized: "None of the files checked is old enough to archive.")
        }
    }
}

extension CleanupPlan {
    /// True when every change belongs to a duplicate group, so the preview can show the groups
    /// with their kept copies. Any other plan is shown one change per row, so that no change is
    /// ever ticked without being on screen.
    var isGroupedByDuplicates: Bool {
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
    /// The reason in the user's words, for the preview.
    var localizedDescription: String {
        switch self {
        case .sameContent(let fileName):
            String(localized: "Same content as \(fileName)")
        case .messyName:
            String(localized: "Messy name")
        case .oldDownload:
            String(localized: "Old download")
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
        case .destinationExists(let name):
            String(localized: "Something called \(name) is already there, so nothing was replaced.")
        case .invalidName:
            String(localized: "The new name can’t be used for a file here, so it was left alone.")
        case .destinationOutsideFolder:
            String(localized: "The destination isn’t inside the folder, or is reached through a link, so it was left alone.")
        case .destinationNotAFolder:
            String(localized: "Something other than a folder is where the destination folder should be, so it was left alone.")
        case .destinationHidden:
            String(localized: "The destination folder is hidden, so the file was left where it is.")
        case .activityLogUnavailable:
            String(localized: "Left alone because the activity log stopped working.")
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
    /// What happened to the file, in the user's words, for the summary.
    var localizedDescription: String {
        switch self {
        case .trashed:
            String(localized: "Moved to the Trash")
        case .renamed(_, let newURL):
            String(localized: "Renamed to \(newURL.lastPathComponent)")
        case .moved(_, let newURL):
            String(localized: "Moved to \(newURL.deletingLastPathComponent().lastPathComponent)")
        case .skipped(let reason):
            reason.localizedDescription
        case .failed(let error):
            error.localizedMessage
        }
    }
}
