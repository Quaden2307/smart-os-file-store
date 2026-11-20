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

    /// True when there are near-duplicate groups and every change belongs to one, so the preview
    /// can show the groups.
    var isGroupedByNearDuplicates: Bool {
        guard !nearDuplicateGroups.isEmpty else {
            return false
        }
        let groupedURLs = Set(nearDuplicateGroups.flatMap { $0.members.map(\.id) })
        return changes.allSatisfy { groupedURLs.contains($0.id) }
    }

    /// What every change in the plan does: its action's one operation.
    var operation: CleanupActionDefinition.OperationKind {
        action.definition.operation
    }

    /// True when the preview can confirm and carry out the plan: every change is of its action's kind.
    var canBeApplied: Bool {
        changes.allSatisfy { action.allows($0.operation) }
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
        case .usedInstaller(let evidence):
            return evidence.historyDescription
        case .messyName(let fix):
            return fix.historyDescription
        case .alreadyArchived(let copyName):
            return String(localized: "An identical copy, \(copyName), was already in Old downloads")
        case .sameContent, .notOpenedSince, .neverOpened, .failedDownload, .unpackedZip, .nearDuplicate, .largeDownload, .emptyFolder:
            return localizedDescription
        }
    }

    /// The reason in the user's words, for the preview.
    var localizedDescription: String {
        switch self {
        case .sameContent(let fileName):
            return String(localized: "Same content as \(fileName)")
        case .messyName(let fix):
            return fix.localizedDescription
        case .notOpenedSince(let lastOpened):
            let date = lastOpened.formatted(.dateTime.day().month(.abbreviated).year())
            return String(localized: "Not opened since \(date)")
        case .neverOpened(let downloadedOn):
            let date = downloadedOn.formatted(.dateTime.day().month(.abbreviated).year())
            return String(localized: "Never opened, downloaded \(date)")
        case .alreadyArchived(let copyName):
            return String(localized: "An identical copy, \(copyName), is already in Old downloads, so this copy goes to the Trash")
        case .failedDownload(let stoppedOn, let finishedFileName):
            let date = stoppedOn.formatted(.dateTime.day().month(.abbreviated).year())
            guard let finishedFileName else {
                return String(localized: "Download stopped on \(date) and never finished")
            }
            return String(localized: "Download stopped on \(date) and never finished. \(finishedFileName) is next to it.")
        case .unpackedZip(let unpackedTo):
            return String(localized: "Already unpacked to \(unpackedTo)")
        case .usedInstaller(let evidence):
            return evidence.localizedDescription
        case .nearDuplicate(let otherName):
            return String(localized: "Same name as \(otherName), different content")
        case .largeDownload(let sizeOnDisk, let lastOpened, let opensRecorded):
            let size = sizeOnDisk.formattedFileSize
            if let lastOpened {
                let date = lastOpened.formatted(.dateTime.day().month(.abbreviated).year())
                return String(localized: "\(size), last opened \(date)")
            }
            // macOS records no open date for some kinds, such as apps: then nothing is said about it.
            return opensRecorded ? String(localized: "\(size), never opened") : size
        case .emptyFolder:
            return String(localized: "Empty folder")
        }
    }
}

extension MessyNameFix {
    /// What was removed, and why the date was added if it was: "Removed (1) · invoice.pdf is taken,
    /// so the date was added", for the preview.
    var localizedDescription: String {
        described(taken: takenName.map { String(localized: "\($0) is taken, so the date was added") })
    }

    /// The same, in the past tense, for Activity.
    var historyDescription: String {
        described(taken: takenName.map { String(localized: "\($0) was taken, so the date was added") })
    }

    private func described(taken: String?) -> String {
        let parts = fixes.map(\.localizedDescription) + [taken].compactMap { $0 }
        // A row from a later version may name no fix this version knows.
        guard !parts.isEmpty else {
            return String(localized: "Messy name")
        }
        return parts.joined(separator: " · ")
    }
}

extension NameFix {
    /// One rule's work in the user's words: "Turned %20 back into text", "Removed (2)".
    var localizedDescription: String {
        switch self {
        case .decodedPercentEncoding(let escapes):
            String(localized: "Turned \(escapes.formatted(.list(type: .and))) back into text")
        case .removedWebLeftover(let text):
            String(localized: "Removed \(text)")
        case .removedDoubledExtension(let text):
            String(localized: "Removed doubled \(text)")
        case .removedCopySuffix(let text):
            String(localized: "Removed \(text.trimmingCharacters(in: .whitespaces))")
        case .collapsedSpaces:
            String(localized: "Removed extra spaces")
        case .trimmedEnds:
            String(localized: "Trimmed the ends of the name")
        }
    }
}

extension UsedInstallerEvidence {
    /// "SomeApp 2.1 is installed in /Applications", for the preview.
    var localizedDescription: String {
        switch (version, folderDescription) {
        case (let version?, let folder?):
            String(localized: "\(name) \(version) is installed in \(folder)")
        case (nil, let folder?):
            String(localized: "\(name) is installed in \(folder)")
        case (let version?, nil):
            String(localized: "\(name) \(version) is installed")
        case (nil, nil):
            String(localized: "\(name) is installed")
        }
    }

    /// The same, in the past tense, for Activity.
    var historyDescription: String {
        switch (version, folderDescription) {
        case (let version?, let folder?):
            String(localized: "\(name) \(version) was installed in \(folder)")
        case (nil, let folder?):
            String(localized: "\(name) was installed in \(folder)")
        case (let version?, nil):
            String(localized: "\(name) \(version) was installed")
        case (nil, nil):
            String(localized: "\(name) was installed")
        }
    }

    /// The folder the installed app is in, with `~` for the home folder.
    private var folderDescription: String? {
        installedAppPath.map { (($0 as NSString).deletingLastPathComponent as NSString).abbreviatingWithTildeInPath }
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
            return String(localized: "It changed since the folder was listed, so the download may have resumed. It was left alone.")
        case .changedSinceScan where action == .removeUnpackedZips:
            // Starting a cleanup plans from the list as it is, so only a refresh sees the change.
            return String(localized: "It changed since the folder was listed, so it was left alone. Refresh the list (⌘R), then run Remove Unpacked Zips again.")
        case .changedSinceScan where action == .removeUsedInstallers:
            return String(localized: "It changed since the folder was listed, so it was left alone. Refresh the list (⌘R), then run Remove Used Installers again.")
        case .changedSinceScan:
            return String(localized: "Changed since the folder was listed. \(runAgain)")
        case .notFound:
            return String(localized: "No longer in the folder")
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
        case .installerUnreadable(let problem):
            return problem.localizedDescription
        case .diskImageInUse:
            return String(localized: "It is open (mounted), or the app could not tell whether it is, so it was left alone.")
        case .keptFile:
            return String(localized: "This is the copy that stays.")
        case .notInPlan:
            return String(localized: "Not proposed this time. \(runAgain)")
        case .markedKept:
            return String(localized: "You marked it Kept, so it was left alone.")
        case .outsideFolder:
            return String(localized: "No longer directly inside the folder")
        case .folderUnavailable:
            return String(localized: "The folder could not be reached. Check that its disk is connected, then try again.")
        case .keptFileMissing(let name):
            return String(localized: "The copy that stays, \(name), is no longer in the folder, so this group was left alone. \(runAgain)")
        case .keptFileNotVerified(let name):
            return String(localized: "The copy that stays, \(name), could not be checked, so this group was left alone. \(runAgain)")
        case .unpackedCopyMissing(let name):
            return String(localized: "The unpacked copy, \(name), is no longer next to it, so the zip was left alone. \(runAgain)")
        case .unpackedCopyNotVerified(let name):
            return String(localized: "The unpacked copy, \(name), could not be confirmed to hold everything in the zip, so the zip was left alone. \(runAgain)")
        case .unpackedCopyRecentlyChanged(let name):
            return String(localized: "The unpacked copy, \(name), was added or changed in the last hour and may still be unpacking, so the zip was left alone. It can go once the copy has gone untouched for an hour.")
        case .installedAppMissing(let name):
            return String(localized: "\(name) is no longer installed, so the installer was left alone.")
        case .installedAppChanged(let name):
            return String(localized: "\(name) has changed since the check, so the installer was left alone. \(runAgain)")
        case .lastInGroup:
            return String(localized: "It was the last file of its group left in the folder, so it stays. At least one file of each group always stays.")
        case .archivedCopyMissing(let name):
            return String(localized: "The identical copy, \(name), is no longer in Old downloads, so this file was left alone. \(runAgain)")
        case .archivedCopyNotVerified(let name):
            return String(localized: "The copy in Old downloads, \(name), could not be confirmed identical, so this file was left alone. \(runAgain)")
        case .cancelled:
            return String(localized: "Stopped before this file was reached")
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

extension InstallerFacts.Problem {
    /// Why an installer could not be read, in the user's words.
    var localizedDescription: String {
        switch self {
        case .passwordProtected:
            String(localized: "It asks for a password, so only its name could be compared.")
        case .licenseAgreement:
            String(localized: "It asks you to accept a licence, so only its name could be compared.")
        case .timedOut:
            String(localized: "It took too long to open, so only its name could be compared.")
        case .couldNotOpen:
            String(localized: "It could not be opened this time, so only its name could be compared. It is tried again next time.")
        case .damaged:
            String(localized: "It is damaged, or not an installer.")
        case .tooLarge:
            String(localized: "It holds too much to check.")
        case .unsupported:
            String(localized: "It uses a format this app can’t read.")
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
            String(localized: "Couldn’t change it (error \(code)). Try again, or do it in Finder.")
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

extension ArchiveProblem {
    /// Why Archive Old Downloads stopped, and what to do, for the preview.
    var localizedDescription: String {
        switch self {
        case .notAFolder:
            String(localized: "Something called Old downloads is in the folder and is not a folder, so nothing was archived. Rename or move it, then run Archive Old Downloads again.")
        case .symbolicLink:
            String(localized: "Old downloads in the folder is a link, which is never followed, so nothing was archived. Replace it with a real folder, then run Archive Old Downloads again.")
        case .unreadable:
            String(localized: "The Old downloads folder could not be read, so nothing was archived. Check its permissions in Finder, then run Archive Old Downloads again.")
        }
    }
}
