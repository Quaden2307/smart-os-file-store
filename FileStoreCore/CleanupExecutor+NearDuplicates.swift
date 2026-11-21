import Foundation

/// The checks for moving a near-duplicate to the Trash. Each item is re-verified right before it
/// moves, through the handle on the scanned folder: it is still a regular file of the plan's group,
/// with the size and modification date the scan saw. And another file of its group must stay: one
/// still in the folder that this run is not moving. So whatever a plan or an interface sends, every
/// near-duplicate group keeps at least one file.
extension CleanupExecutor {
    /// One near-duplicate, checked from the cheapest test to the dearest. The first failing check
    /// decides.
    func trashNearDuplicate(
        _ change: ProposedChange,
        folder: DirectoryHandle,
        context: PlanContext,
        folderIdentity: FileIdentity,
        now: Date,
        journal: inout RunJournal,
        beforeChange: (@Sendable (ProposedChange) -> Void)?
    ) -> CleanupItemOutcome {
        // Membership: the plan must propose it as a near-duplicate, in one of its groups.
        let recordURL = change.record.url
        guard case .nearDuplicate = change.reason, let group = context.nearDuplicateGroupsByURL[recordURL] else {
            return .skipped(.notInPlan)
        }
        // A confirmation of every file in the group: this is the one that stays.
        guard context.nearDuplicatesToTrash.contains(recordURL) else {
            return .skipped(.lastInGroup)
        }

        // Containment: act on `<folder>/<name>`, and only through the folder's handle from here on.
        guard let itemURL = Self.urlInsideFolder(
            recordURL.standardizedFileURL,
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
        guard status.isRegularFile, !status.isSymbolicLink else {
            return .skipped(.notARegularFile)
        }
        if status.isDataless {
            return .skipped(.notDownloaded)
        }

        // The rules every action shares, on what the disk says now rather than the scan's record.
        let readDateAdded = { () throws(FileStatus.Failure) -> Date? in
            try FileStatus.dateAdded(path: name, relativeTo: folder.descriptor)
        }
        if let refused = sharedRefusal(status, itemURL: itemURL, change: change, in: context.folder, now: now, readDateAdded: readDateAdded) {
            return refused
        }

        // Another file of the group stays: still here as the plan saw it (a regular file of the same
        // size and modification date, not this one), and not moved by this run. It must share this
        // file's cleaned name, so a crafted plan cannot pair unrelated files; letter case is ignored,
        // which every plan, on any volume, passes.
        let nameKey = NearDuplicatePlanner.nameKey(name, caseSensitive: false)
        // A file this run tried to move and could not does not count either, so the rule needs no
        // knowledge of earlier outcomes.
        let survivor = group.members.contains { member in
            let memberURL = member.record.url
            guard memberURL != recordURL, !context.nearDuplicatesToTrash.contains(memberURL),
                  NearDuplicatePlanner.nameKey(memberURL.lastPathComponent, caseSensitive: false) == nameKey,
                  let memberStatus = try? folder.status(of: memberURL.lastPathComponent) else {
                return false
            }
            return memberStatus.isRegularFile && !memberStatus.isSymbolicLink && memberStatus.identity != status.identity
                && memberStatus.sizeInBytes == member.record.sizeInBytes
                && member.record.dateModified.map { abs(memberStatus.modificationDate.timeIntervalSince($0)) <= Self.modificationDateTolerance } == true
        }
        guard survivor else {
            return .skipped(.lastInGroup)
        }

        // The activity log first: whether the file is Kept by the list as it is now, then a row that
        // says this change was started, with the file's disk ID, which undo checks. No content hash
        // is recorded: the content was not read again here. Without the row there is no permit.
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

        // Last look, after the reads and right before the move.
        if let refused = Self.lastLookRefusal(try? folder.status(of: name), checked: status) {
            return refused
        }
        if Task.isCancelled {
            return .skipped(.cancelled)
        }
        beforeChange?(change)
        return DiskChange.trash(itemURL, permit: permit)
    }
}
