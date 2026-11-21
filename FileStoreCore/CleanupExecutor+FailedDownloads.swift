import Foundation

/// The checks for moving a failed download to the Trash. Each item is re-verified right before it
/// moves, through the handle on the scanned folder: it is still a partial download of the shape its
/// name requires (a regular file for `.crdownload` and `.part`, a folder for `.download`, never a
/// link), past the grace period by the Date Added read now, with the size and last change the scan
/// saw. Any difference means the download may have resumed, and the item is left alone.
extension CleanupExecutor {
    /// One failed download, checked from the cheapest test to the dearest. The first failing check
    /// decides.
    func trashFailedDownload(
        _ change: ProposedChange,
        folder: DirectoryHandle,
        context: PlanContext,
        folderIdentity: FileIdentity,
        now: Date,
        journal: inout RunJournal,
        beforeChange: (@Sendable (ProposedChange) -> Void)?
    ) -> CleanupItemOutcome {
        // Membership: the plan must propose it as a failed download.
        guard case .failedDownload = change.reason else {
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
        // The name decides what the item must be, and the plan must say the same: the log records
        // a folder or a file as the plan describes it, and undo proves it by that.
        guard let shape = FailedDownloadPlanner.partialShape(ofName: name), change.isFolder == (shape == .folder) else {
            return .skipped(.notInPlan)
        }

        // The item as it is now.
        let status: FileStatus
        do throws(FileStatus.Failure) {
            status = try folder.status(of: name)
        } catch {
            return .skipped(CleanupSkipReason(statusFailure: error))
        }
        guard Self.isExpectedKind(status, isFolder: shape == .folder) else {
            return .skipped(.notARegularFile)
        }
        // The cheap refusals before anything inside a folder is read. A placeholder is never read:
        // listing a folder in iCloud only would download it.
        if status.isDataless {
            return .skipped(.notDownloaded)
        }
        if status.isHidden {
            return .skipped(.notInPlan)
        }
        var contents: PackageContents?
        if shape == .folder {
            switch PackageContents.read(named: name, in: folder) {
            case .success(let read):
                contents = read
            case .failure(let failure):
                // Too many items to be a download: not something this plan may act on.
                return .skipped(CleanupSkipReason(packageFailure: failure) ?? .notInPlan)
            }
        }

        // The rules every action shares, downloads in progress let in, on what the disk says now.
        let readDateAdded = { () throws(FileStatus.Failure) -> Date? in
            try FileStatus.dateAdded(path: name, relativeTo: folder.descriptor)
        }
        if let refused = sharedRefusal(
            status,
            itemURL: itemURL,
            change: change,
            in: context.folder,
            now: now,
            contents: contents,
            downloads: .allowed,
            readDateAdded: readDateAdded
        ) {
            return refused
        }

        // The activity log first: whether the item is Kept by the list as it is now, then a row that
        // says this change was started, with the item's disk ID, which undo checks. Without the row
        // there is no permit, and no move.
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

        // Last look, after the reads and right before the move: the very item checked above,
        // unchanged, and for a folder, with the same contents.
        let folderContents = contents.map { checked in
            (checked: checked, reread: { PackageContents.read(named: name, in: folder) })
        }
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
