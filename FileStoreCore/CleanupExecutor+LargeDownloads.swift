import Foundation

/// The checks for moving a large download to the Trash. Each item is re-verified right before it
/// moves, through the handle on the scanned folder: it is still the kind the plan says (a regular
/// file, or for a package a folder, never a link), past the grace period by the Date Added read now,
/// with the size and last change the scan saw; for a package, those of its contents, read again.
extension CleanupExecutor {
    /// One large download, checked from the cheapest test to the dearest. The first failing check
    /// decides.
    func trashLargeDownload(
        _ change: ProposedChange,
        folder: DirectoryHandle,
        context: PlanContext,
        folderIdentity: FileIdentity,
        now: Date,
        journal: inout RunJournal,
        beforeChange: (@Sendable (ProposedChange) -> Void)?
    ) -> CleanupItemOutcome {
        // Membership: the plan must propose it as a large download, of a kind the action lists.
        guard case .largeDownload = change.reason, change.record.kind == .file || change.record.kind == .package else {
            return .skipped(.notInPlan)
        }
        let isPackage = change.record.kind == .package

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
        guard Self.isExpectedKind(status, isFolder: isPackage) else {
            return .skipped(.notARegularFile)
        }
        // The cheap refusals before anything inside a package is read. A placeholder is never read.
        if status.isDataless {
            return .skipped(.notDownloaded)
        }
        if status.isHidden {
            return .skipped(.notInPlan)
        }
        var contents: PackageContents?
        if isPackage {
            switch PackageContents.read(named: name, in: folder, limits: .package) {
            case .success(let read):
                contents = read
            case .failure(let failure):
                // Read in full at the scan, too big now: it changed.
                return .skipped(CleanupSkipReason(packageFailure: failure) ?? .changedSinceScan)
            }
        }

        // The rules every action shares, on what the disk says now rather than the scan's record.
        let readDateAdded = { () throws(FileStatus.Failure) -> Date? in
            try FileStatus.dateAdded(path: name, relativeTo: folder.descriptor)
        }
        if let refused = sharedRefusal(status, itemURL: itemURL, change: change, in: context.folder, now: now, contents: contents, readDateAdded: readDateAdded) {
            return refused
        }

        // The activity log first: whether the item is Kept by the list as it is now, then a row that
        // says this change was started, with its disk ID, which undo checks. No content hash is
        // recorded: the content was never read. Without the row there is no permit.
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
        // unchanged, and for a package, with the same contents.
        let folderContents = contents.map { checked in
            (checked: checked, reread: { PackageContents.read(named: name, in: folder, limits: .package) })
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
