import Foundation

/// The checks for moving an empty folder to the Trash. Each folder is re-verified right before it
/// moves, through the handle on the scanned folder: still a real folder (never a link), read inside
/// again and still empty, past the grace period by the Date Added read now, with the size and last
/// change the scan saw. Anything added to it since, at any depth, leaves it alone.
extension CleanupExecutor {
    /// One empty folder, checked from the cheapest test to the dearest. The first failing check
    /// decides.
    func trashEmptyFolder(
        _ change: ProposedChange,
        folder: DirectoryHandle,
        context: PlanContext,
        folderIdentity: FileIdentity,
        now: Date,
        journal: inout RunJournal,
        beforeChange: (@Sendable (ProposedChange) -> Void)?
    ) -> CleanupItemOutcome {
        // Membership: the plan must propose it as an empty folder, and as a plain folder.
        guard change.reason == .emptyFolder, change.record.kind == .folder else {
            return .skipped(.notInPlan)
        }

        // Containment: act on `<folder>/<name>`, and only through the folder's handle from here on.
        guard let itemURL = Self.urlInsideFolder(
            change.record.url.standardizedFileURL,
            folderURL: context.folderURL,
            folderIdentity: folderIdentity
        ) else {
            return .skipped(.outsideFolder)
        }
        let name = itemURL.lastPathComponent

        // The item as it is now.
        let status: FileStatus
        do throws(FileStatus.Failure) {
            status = try folder.status(of: name)
        } catch {
            return .skipped(CleanupSkipReason(statusFailure: error))
        }
        guard Self.isExpectedKind(status, isFolder: true) else {
            return .skipped(.notARegularFile)
        }
        // A placeholder is never read: listing a folder in iCloud only would download it.
        if status.isDataless {
            return .skipped(.notDownloaded)
        }
        // Read again now: anything added since the scan, at any depth, and it stays.
        let contents: PackageContents
        switch PackageContents.read(named: name, in: folder) {
        case .success(let read) where read.isEmptyFolder:
            contents = read
        case .success:
            return .skipped(.changedSinceScan)
        case .failure(let failure):
            return .skipped(CleanupSkipReason(packageFailure: failure) ?? .changedSinceScan)
        }

        // The rules every action shares, on what the disk says now rather than the scan's record.
        let readDateAdded = { () throws(FileStatus.Failure) -> Date? in
            try FileStatus.dateAdded(path: name, relativeTo: folder.descriptor)
        }
        if let refused = sharedRefusal(status, itemURL: itemURL, change: change, now: now, contents: contents, readDateAdded: readDateAdded) {
            return refused
        }

        // The activity log first: whether the folder is Kept by the list as it is now, then a row
        // that says this change was started, with its disk ID, which undo checks.
        let permit: ChangePermit
        switch journal.intend(
            change,
            contentHash: nil,
            fileNumber: UInt64(status.identity.inode),
            itemURL: itemURL,
            identity: context.volume?.identity(of: status)
        ) {
        case .permitted(let granted):
            permit = granted
        case .markedKept:
            return .skipped(.markedKept)
        case .stopped:
            return .skipped(.activityLogUnavailable)
        }

        // Last look, after the reads and right before the move: the very folder checked above, with
        // the same, still empty, contents.
        let folderContents = (checked: contents, reread: { PackageContents.read(named: name, in: folder) })
        if let refused = Self.lastLookRefusal(try? folder.status(of: name), checked: status, folderContents: folderContents) {
            return refused
        }
        if Task.isCancelled {
            return .skipped(.cancelled)
        }
        beforeChange?(change)
        return DiskChange.trash(itemURL, permit: permit)
    }
}
