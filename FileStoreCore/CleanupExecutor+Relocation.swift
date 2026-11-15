import Foundation

/// The checks for a rename or a move. Every name is looked up through a handle on the scanned
/// folder, never through a path, so nothing a plan or another app does to a path can send a change
/// outside the folder. The item must still be a regular file directly inside the folder, as the scan
/// saw it and past the grace period; the new name must be one valid name; the destination folder
/// must be reached from the folder without passing a symbolic link or a hidden folder, or leaving
/// its disk. Whether the
/// new name is taken is left to the exclusive rename, which asks the volume in the same step as it
/// renames, so nothing is ever overwritten.
extension CleanupExecutor {
    /// Where a rename or a move puts an item: the folders below the scanned folder, outermost first
    /// (none for a rename), and the item's name there.
    struct Relocation {
        let folderNames: [String]
        let name: String

        var isMove: Bool { !folderNames.isEmpty }
    }

    /// One rename or move, checked from the cheapest test to the dearest. The first failing check
    /// decides. Folders made on the way are reported with the result whatever happens next.
    func relocate(
        _ change: ProposedChange,
        to relocation: Relocation,
        folder: DirectoryHandle,
        context: PlanContext,
        folderIdentity: FileIdentity,
        now: Date,
        journal: inout RunJournal,
        beforeChange: (@Sendable (ProposedChange) -> Void)?
    ) -> CleanupItemResult {
        func result(_ outcome: CleanupItemOutcome, createdFolders: [URL] = []) -> CleanupItemResult {
            CleanupItemResult(change: change, outcome: outcome, createdFolders: createdFolders)
        }

        // Names, before anything is read: the new name and every folder name on the way.
        let maximumLength = folder.maximumNameLength
        for name in relocation.folderNames {
            if FileNameRules.isPackageName(name) {
                return result(.skipped(.destinationNotAFolder))
            }
            guard FileNameRules.isAllowedFolderName(name, maximumLength: maximumLength) else {
                return result(.skipped(.invalidName))
            }
        }
        guard FileNameRules.isAllowedFileName(relocation.name, maximumLength: maximumLength) else {
            return result(.skipped(.invalidName))
        }

        // Containment: the item's parent is the folder, and only its own name is used from here on.
        guard let itemURL = Self.urlInsideFolder(
            change.record.url.standardizedFileURL,
            folderURL: context.folderURL,
            folderIdentity: folderIdentity
        ) else {
            return result(.skipped(.outsideFolder))
        }
        let name = itemURL.lastPathComponent
        // A rename to the very same bytes would change nothing. Compared byte for byte with the
        // name the scan read, which keeps the form the volume stores (`itemURL`'s does not: a URL
        // built with `appending(path:)` decomposes it), since a name in another Unicode
        // normalisation is a real change, which the volume carries out.
        if !relocation.isMove, Array(relocation.name.utf8) == Array(change.record.url.lastPathComponent.utf8) {
            return result(.skipped(.notInPlan))
        }

        // The item as it is now, and the rules every action shares, on what the disk says.
        let status: FileStatus
        do throws(FileStatus.Failure) {
            status = try folder.status(of: name)
        } catch {
            return result(.skipped(CleanupSkipReason(statusFailure: error)))
        }
        guard status.isRegularFile, !status.isSymbolicLink else {
            return result(.skipped(.notARegularFile))
        }
        if status.isDataless {
            return result(.skipped(.notDownloaded))
        }
        let readDateAdded = { () throws(FileStatus.Failure) -> Date? in
            try FileStatus.dateAdded(path: name, relativeTo: folder.descriptor)
        }
        if let refused = sharedRefusal(status, itemURL: itemURL, change: change, now: now, readDateAdded: readDateAdded) {
            return result(refused)
        }

        // The destination folder: each folder on the way opened directly inside the one before,
        // never through a link, never hidden and never onto another disk. Missing ones are made below.
        var destination = folder
        var destinationURL = context.folderURL
        var missing: ArraySlice<String> = []
        walk: for (index, folderName) in relocation.folderNames.enumerated() {
            switch Self.step(into: folderName, from: destination, device: folderIdentity.device) {
            case .opened(let child):
                destination = child
                destinationURL.append(path: folderName, directoryHint: .isDirectory)
            case .missing:
                missing = relocation.folderNames[index...]
                break walk
            case .refused(let outcome):
                return result(outcome)
            }
        }

        // The activity log first: a row that says this change was started, with the folders it is
        // about to make, written before the last look so the write does not sit in the gap between
        // that look and the change. Without the row there is no permit: no folder is made and
        // nothing is renamed.
        var foldersToMake: [URL] = []
        var folderToMake = destinationURL
        for folderName in missing {
            folderToMake.append(path: folderName, directoryHint: .isDirectory)
            foldersToMake.append(folderToMake)
        }
        guard let permit = journal.intend(change, contentHash: nil, foldersToMake: foldersToMake) else {
            return result(.skipped(.activityLogUnavailable))
        }

        // Last look before anything changes: the very file checked above, unchanged.
        if let refused = Self.lastLookRefusal(try? folder.status(of: name), checked: status) {
            return result(refused)
        }
        if Task.isCancelled {
            return result(.skipped(.cancelled))
        }
        beforeChange?(change)

        // Make the missing folders, one level at a time inside the last one opened. A folder another
        // app made meanwhile is opened and checked like any other, and is not reported as made here.
        var createdFolders: [URL] = []
        for folderName in missing {
            let failure = DiskChange.makeFolder(named: folderName, in: destination, permit: permit)
            if let failure, failure != EEXIST {
                // ENOENT: the folder it was to be made in went away after it was opened.
                let outcome = failure == ENOENT ? .skipped(.changedSinceScan) : Self.outcome(changeFailure: failure, name: folderName)
                return result(outcome, createdFolders: createdFolders)
            }
            destinationURL.append(path: folderName, directoryHint: .isDirectory)
            if failure == nil {
                createdFolders.append(destinationURL)
            }
            switch Self.step(into: folderName, from: destination, device: folderIdentity.device) {
            case .opened(let child):
                destination = child
            case .missing:
                // Made a moment ago and already gone again.
                return result(.skipped(.changedSinceScan), createdFolders: createdFolders)
            case .refused(let outcome):
                return result(outcome, createdFolders: createdFolders)
            }
        }

        // Once more right before the rename, since making folders took a moment.
        if let refused = Self.lastLookRefusal(try? folder.status(of: name), checked: status) {
            return result(refused, createdFolders: createdFolders)
        }
        if let failure = DiskChange.renameWithoutReplacing(name, in: folder, to: relocation.name, in: destination, permit: permit) {
            // ENOENT is "not found" only when the file is gone; otherwise the destination folder
            // went away after it was opened.
            if failure == ENOENT, (try? folder.status(of: name)) != nil {
                return result(.skipped(.changedSinceScan), createdFolders: createdFolders)
            }
            return result(Self.outcome(changeFailure: failure, name: relocation.name), createdFolders: createdFolders)
        }
        let newURL = destinationURL.appending(path: relocation.name)
        let outcome: CleanupItemOutcome = relocation.isMove ? .moved(from: itemURL, to: newURL) : .renamed(from: itemURL, to: newURL)
        return result(outcome, createdFolders: createdFolders)
    }

    /// One step down the way to the destination folder.
    private enum FolderStep {
        case opened(DirectoryHandle)
        case missing
        case refused(CleanupItemOutcome)
    }

    /// Opens the folder `name` inside `parent`: never through a link, never a hidden one, and only
    /// on the scanned folder's disk, since a disk mounted inside the folder is somewhere else.
    private static func step(into name: String, from parent: DirectoryHandle, device: dev_t) -> FolderStep {
        let child: DirectoryHandle
        do throws(DirectoryHandle.OpenFailure) {
            child = try parent.openFolder(named: name)
        } catch .notFound {
            return .missing
        } catch {
            return .refused(outcome(destinationFailure: error))
        }
        guard let status = try? child.status(), status.identity.device == device else {
            return .refused(.skipped(.destinationOutsideFolder))
        }
        // A folder hidden by flag would hide the file too, like a name starting with a dot.
        if status.isHidden {
            return .refused(.skipped(.destinationHidden))
        }
        return .opened(child)
    }

    private static func outcome(destinationFailure failure: DirectoryHandle.OpenFailure) -> CleanupItemOutcome {
        switch failure {
        case .symbolicLink:
            .skipped(.destinationOutsideFolder)
        case .notAFolder:
            .skipped(.destinationNotAFolder)
        case .accessDenied:
            .failed(.accessDenied)
        case .notFound:
            failed(code: ENOENT)
        case .other(let code):
            failed(code: code)
        }
    }

    /// The outcome for a rename or a folder made that the system refused with `code`. `name` is
    /// the name that would have been taken.
    private static func outcome(changeFailure code: Int32, name: String) -> CleanupItemOutcome {
        switch code {
        case EEXIST:
            .skipped(.destinationExists(name: name))
        case ENOENT:
            .skipped(.notFound)
        case EPERM, EACCES:
            .failed(.accessDenied)
        case EROFS:
            .failed(.volumeReadOnly)
        case ENOTSUP:
            .failed(.renameUnsupported)
        case ELOOP, ENOTCAPABLE, EXDEV:
            .skipped(.destinationOutsideFolder)
        case ENAMETOOLONG:
            .skipped(.invalidName)
        default:
            failed(code: code)
        }
    }

    private static func failed(code: Int32) -> CleanupItemOutcome {
        .failed(.other(domain: NSPOSIXErrorDomain, code: Int(code), description: String(cString: strerror(code))))
    }
}
