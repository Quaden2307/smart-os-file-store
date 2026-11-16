import Foundation

/// The checks for moving an unpacked zip to the Trash. Right before it moves, through the handle on
/// the scanned folder, the zip must still be the very file the plan saw, and the match is made again
/// from what is on disk now: the zip's listing is read afresh, and the copy the plan names must still
/// hold every entry at the same size and pass the shared rules itself. The copy is only ever read.
extension CleanupExecutor {
    /// One unpacked zip, checked from the cheapest test to the dearest. The first failing check decides.
    func trashUnpackedZip(
        _ change: ProposedChange,
        folder: DirectoryHandle,
        context: PlanContext,
        folderIdentity: FileIdentity,
        now: Date,
        journal: inout RunJournal,
        beforeChange: (@Sendable (ProposedChange) -> Void)?
    ) -> CleanupItemOutcome {
        // Membership: the plan must propose it as an unpacked zip.
        guard case .unpackedZip(let copyName) = change.reason else {
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
        // The plan's own claims: a zip, by the rule the planner applied too, and a copy that is one
        // plain name and never a zip, which this action could move too (the zip itself included).
        guard !change.isFolder,
              UnpackedZipPlanner.isZipName(name),
              UnpackedZipPlanner.isPlainName(copyName),
              !UnpackedZipPlanner.isZipName(copyName) else {
            return .skipped(.notInPlan)
        }

        // The zip as it is now.
        let status: FileStatus
        do throws(FileStatus.Failure) {
            status = try folder.status(of: name)
        } catch {
            return .skipped(CleanupSkipReason(statusFailure: error))
        }
        guard Self.isExpectedKind(status, isFolder: false) else {
            return .skipped(.notARegularFile)
        }
        if status.isDataless {
            return .skipped(.notDownloaded)
        }

        // The rules every action shares, on what the disk says now, a hidden zip included.
        let readDateAdded = { () throws(FileStatus.Failure) -> Date? in
            try FileStatus.dateAdded(path: name, relativeTo: folder.descriptor)
        }
        if let refused = sharedRefusal(status, itemURL: itemURL, change: change, now: now, readDateAdded: readDateAdded) {
            return refused
        }

        // The match, made again from the disk as it is now.
        let copy: FileStatus
        switch verifiedCopy(named: copyName, ofZipNamed: name, checked: status, in: folder, now: now) {
        case .verified(let copyStatus):
            copy = copyStatus
        case .refused(let outcome):
            return outcome
        }

        // The activity log first: whether the zip is Kept by the list as it is now, then a row that
        // says this change was started, with the zip's disk ID, which undo checks. Without the row
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

        // Last look, after the log's row and right before the move: the very zip checked above,
        // unchanged, and beside it the very copy matched, unchanged and still neither hidden nor in
        // iCloud only. For a zip of one file, that file is all the evidence there is. What is inside
        // a copied folder was read just before the row; like a kept duplicate's content, it is not
        // read again in the moment the row takes.
        if let refused = Self.lastLookRefusal(try? folder.status(of: name), checked: status) {
            return refused
        }
        do throws(FileStatus.Failure) {
            let copyNow = try folder.status(of: copyName)
            guard Self.isSameItem(copyNow, as: copy), !copyNow.isHidden, !copyNow.isDataless else {
                return .skipped(.unpackedCopyNotVerified(name: copyName))
            }
        } catch {
            return .skipped(error == .notFound ? .unpackedCopyMissing(name: copyName) : .unpackedCopyNotVerified(name: copyName))
        }
        if Task.isCancelled {
            return .skipped(.cancelled)
        }
        beforeChange?(change)
        return DiskChange.trash(itemURL, permit: permit)
    }

    /// The copy a plan names, checked again, or why the zip is left alone.
    private enum VerifiedCopy {
        /// The copy holds everything; this is it as it was looked at.
        case verified(FileStatus)
        case refused(CleanupItemOutcome)
    }

    /// The copy called `copyName` as it is now, when it still holds everything the zip called `name`
    /// lists now and has settled, by the planner's own check (`UnpackedZipPlanner.checkCopy`);
    /// otherwise why the zip is left alone.
    private func verifiedCopy(
        named copyName: String,
        ofZipNamed name: String,
        checked status: FileStatus,
        in folder: DirectoryHandle,
        now: Date
    ) -> VerifiedCopy {
        // The listing, read from the very file just checked.
        let listing: ZipListing
        do throws(ZipListing.Failure) {
            listing = try ZipListing.read(named: name, in: folder, limits: .standard) { looked in
                Self.isSameItem(looked, as: status)
            }
        } catch {
            guard let reason = CleanupSkipReason(zipFailure: error) else {
                return .refused(.skipped(.cancelled))
            }
            // It was listed when the plan was made, so it is not the same file any more.
            if case .zipUnlistable = reason {
                return .refused(.skipped(.changedSinceScan))
            }
            return .refused(.skipped(reason))
        }

        // Where it would have been unpacked: the plan's copy must be that place, or one of its
        // numbered names, never any other item.
        guard case .success(let expectation) = UnpackedZipPlanner.expectation(for: listing.entries, zipName: name) else {
            return .refused(.skipped(.changedSinceScan))
        }
        guard copyName == expectation.name || UnpackedZipPlanner.copyNumber(of: copyName, for: expectation.name) != nil else {
            return .refused(.skipped(.notInPlan))
        }

        // Every entry, read now, and whether the copy has settled, by the planner's own check.
        switch UnpackedZipPlanner(eligibility: eligibility).checkCopy(named: copyName, of: expectation, in: folder, now: now) {
        case .matches(let rootStatus):
            return .verified(rootStatus)
        case .missing:
            return .refused(.skipped(.unpackedCopyMissing(name: copyName)))
        case .notVerified:
            return .refused(.skipped(.unpackedCopyNotVerified(name: copyName)))
        case .recentlyChanged:
            return .refused(.skipped(.unpackedCopyRecentlyChanged(name: copyName)))
        case .cancelled:
            return .refused(.skipped(.cancelled))
        }
    }

    /// True when `current` is the very item `checked` described, unchanged: the same identity, kind,
    /// size and modification date.
    private static func isSameItem(_ current: FileStatus, as checked: FileStatus) -> Bool {
        current.identity == checked.identity
            && current.isRegularFile == checked.isRegularFile
            && current.isDirectory == checked.isDirectory
            && current.isSymbolicLink == checked.isSymbolicLink
            && current.sizeInBytes == checked.sizeInBytes
            && current.modificationDate == checked.modificationDate
    }
}
