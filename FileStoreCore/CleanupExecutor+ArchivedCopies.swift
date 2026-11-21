import Foundation

/// The checks for moving a file to the Trash because the archive already holds an identical copy
/// (Archive Old Downloads, `alreadyArchived`). Each item is re-verified right before it moves: it is
/// still a regular file directly inside the scanned folder, as the scan saw it, and the copy the
/// plan names is still a regular file in the archive, reached without following a link, with
/// exactly the same bytes, read again now. So the file's content always stays on disk.
extension CleanupExecutor {
    /// One file whose copy is archived, checked from the cheapest test to the dearest. The first
    /// failing check decides.
    func trashArchivedCopy(
        _ change: ProposedChange,
        folder: DirectoryHandle,
        context: PlanContext,
        folderIdentity: FileIdentity,
        now: Date,
        journal: inout RunJournal,
        beforeChange: (@Sendable (ProposedChange) -> Void)?
    ) async -> CleanupItemOutcome {
        // Membership: the plan must name the archived copy this file is trashed for.
        guard case .alreadyArchived(let copyName) = change.reason,
              FileNameRules.isSingleName(copyName, maximumLength: folder.maximumNameLength),
              change.sizeInBytes > 0 else {
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
        guard status.isRegularFile, !status.isSymbolicLink else {
            return .skipped(.notARegularFile)
        }
        if status.isDataless {
            return .skipped(.notDownloaded)
        }
        let readDateAdded = { () throws(FileStatus.Failure) -> Date? in
            try FileStatus.dateAdded(path: name, relativeTo: folder.descriptor)
        }
        if let refused = sharedRefusal(status, itemURL: itemURL, change: change, in: context.folder, now: now, readDateAdded: readDateAdded) {
            return refused
        }

        // The archived copy: a regular file in the archive folder, the same size, not this very file.
        let archiveName = context.folder.archiveFolderName
        guard case .opened(let archive) = Self.step(into: archiveName, from: folder, device: folderIdentity.device),
              let copyStatus = try? archive.status(of: copyName),
              copyStatus.isRegularFile, !copyStatus.isSymbolicLink, !copyStatus.isDataless,
              copyStatus.identity != status.identity else {
            return .skipped(.archivedCopyMissing(name: copyName))
        }
        guard copyStatus.sizeInBytes == status.sizeInBytes else {
            return .skipped(.archivedCopyNotVerified(name: copyName))
        }

        // Content: both read now, and equal.
        let itemHash: ContentHash
        do throws(ContentHashError) {
            itemHash = try await hasher.hash(contentsOf: itemURL, expectedSizeInBytes: change.sizeInBytes)
        } catch {
            guard let reason = CleanupSkipReason(hashError: error) else {
                return .skipped(.cancelled)
            }
            return .skipped(reason)
        }
        // The hasher reads by path. Before and after it, the path must reach the very file checked
        // through the archive's handle, so a link put in the archive's place is never read instead.
        let copyURL = ArchivePlanner.archiveURL(in: context.folder).appending(path: copyName)
        func pathReachesCopy() -> Bool {
            (try? FileStatus.of(path: copyURL.path(percentEncoded: false)))?.identity == copyStatus.identity
                && (try? folder.status(of: archiveName))?.isSymbolicLink == false
        }
        guard pathReachesCopy() else {
            return .skipped(.archivedCopyNotVerified(name: copyName))
        }
        do throws(ContentHashError) {
            let copyHash = try await hasher.hash(contentsOf: copyURL, expectedSizeInBytes: change.sizeInBytes)
            guard copyHash == itemHash else {
                return .skipped(.archivedCopyNotVerified(name: copyName))
            }
        } catch {
            switch error {
            case .cancelled:
                return .skipped(.cancelled)
            case .fileNotFound:
                return .skipped(.archivedCopyMissing(name: copyName))
            case .accessDenied, .notARegularFile, .changedSinceScan, .notDownloaded, .readFailed:
                return .skipped(.archivedCopyNotVerified(name: copyName))
            }
        }
        // The copy that was read is still the one checked through the archive's handle.
        guard pathReachesCopy(),
              let copyAgain = try? archive.status(of: copyName),
              copyAgain.identity == copyStatus.identity,
              copyAgain.sizeInBytes == copyStatus.sizeInBytes,
              copyAgain.modificationDate == copyStatus.modificationDate else {
            return .skipped(.archivedCopyNotVerified(name: copyName))
        }

        // The activity log first, with the content just confirmed and the file's disk ID, which undo
        // checks. Without the row there is no permit, and no move.
        let permit: ChangePermit
        switch journal.intend(
            change,
            contentHash: itemHash,
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
