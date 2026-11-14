import Foundation

/// The checks for moving a duplicate to the Trash. Each item is re-verified right before it is
/// moved: it is still a regular file directly inside the scanned folder, with the size and
/// modification date the scan saw and the content the plan grouped it by, and the group's kept copy
/// is still there with that same content. A file with the same identity as any kept copy is
/// refused, so whatever a plan or an interface sends, every group keeps at least one copy.
extension CleanupExecutor {
    /// One duplicate, checked from the cheapest test to the dearest. The first failing check decides.
    ///
    /// `verifiedKept` remembers, per kept file, the state in which its content was confirmed during
    /// this run, so a kept file is read once per run rather than once per duplicate.
    func trashDuplicate(
        _ change: ProposedChange,
        context: PlanContext,
        folderIdentity: FileIdentity,
        now: Date,
        verifiedKept: inout [URL: VerifiedFile],
        beforeChange: (@Sendable (ProposedChange) -> Void)?
    ) async -> CleanupItemOutcome {
        // Membership: the plan's own data must propose exactly this change. The plan's URL values
        // are compared as they are: `standardizedFileURL` consults the file system (it drops a
        // `/private` prefix only while the path still exists), so it is no stable key.
        let recordURL = change.record.url
        guard let group = context.groupsByDuplicateURL[recordURL],
              group.fileSizeInBytes > 0,
              change.sizeInBytes == group.fileSizeInBytes else {
            return .skipped(.notInPlan)
        }
        if context.keptURLs.contains(recordURL) {
            return .skipped(.keptFile)
        }

        // Containment: act on `<folder>/<name>`, never on the plan's spelling of the path.
        guard let itemURL = Self.urlInsideFolder(recordURL.standardizedFileURL, folderURL: context.folderURL, folderIdentity: folderIdentity),
              let keptURL = Self.urlInsideFolder(
                  group.kept.url.standardizedFileURL,
                  folderURL: context.folderURL,
                  folderIdentity: folderIdentity
              ) else {
            return .skipped(.outsideFolder)
        }
        let keptName = group.kept.displayName

        // The item as it is now.
        let status: FileStatus
        do throws(FileStatus.Failure) {
            status = try FileStatus.of(path: itemURL.path(percentEncoded: false))
        } catch {
            return .skipped(CleanupSkipReason(statusFailure: error))
        }
        guard status.isRegularFile, !status.isSymbolicLink else {
            return .skipped(.notARegularFile)
        }
        if status.isDataless {
            return .skipped(.notDownloaded)
        }
        if context.keptIdentities.contains(status.identity) {
            return .skipped(.keptFile)
        }

        // The kept copy must be there, and must not be this very file under another name.
        guard let keptStatus = try? FileStatus.of(path: keptURL.path(percentEncoded: false)),
              keptStatus.isRegularFile else {
            return .skipped(.keptFileMissing(name: keptName))
        }
        if keptStatus.identity == status.identity {
            return .skipped(.keptFile)
        }

        // The rules every action shares, on what the disk says now rather than the scan's record.
        let readDateAdded = { () throws(FileStatus.Failure) -> Date? in
            try FileStatus.dateAdded(path: itemURL.path(percentEncoded: false))
        }
        if let refused = sharedRefusal(status, itemURL: itemURL, change: change, now: now, readDateAdded: readDateAdded) {
            return refused
        }

        // Content: the item still is a copy, and the kept file still holds the same bytes.
        do throws(ContentHashError) {
            let hash = try await hasher.hash(contentsOf: itemURL, expectedSizeInBytes: change.sizeInBytes)
            guard hash == group.contentHash else {
                return .skipped(.changedSinceScan)
            }
        } catch {
            guard let reason = CleanupSkipReason(hashError: error) else {
                return .skipped(.cancelled)
            }
            return .skipped(reason)
        }
        // The kept copy's content is confirmed once per run against this group's hash. For later
        // items it is enough that the very same file (identity, size, modification date) is still
        // there and that the hash it was confirmed against is this group's: a plan that names one
        // kept file in two groups with different content is caught on the second group. This
        // trusts "same identity, size and date" for the length of the run, as the item check
        // itself does between its reads and the move.
        let expectedKept = VerifiedFile(keptStatus, contentHash: group.contentHash)
        if verifiedKept[keptURL] != expectedKept {
            do throws(ContentHashError) {
                let keptHash = try await hasher.hash(contentsOf: keptURL, expectedSizeInBytes: group.fileSizeInBytes)
                guard keptHash == group.contentHash else {
                    return .skipped(.keptFileNotVerified(name: keptName))
                }
            } catch {
                switch error {
                case .cancelled:
                    return .skipped(.cancelled)
                case .fileNotFound:
                    return .skipped(.keptFileMissing(name: keptName))
                case .accessDenied, .notARegularFile, .changedSinceScan, .notDownloaded, .readFailed:
                    return .skipped(.keptFileNotVerified(name: keptName))
                }
            }
            verifiedKept[keptURL] = expectedKept
        }

        // Last look, after the reads and right before the move.
        if let refused = Self.lastLookRefusal(try? FileStatus.of(path: itemURL.path(percentEncoded: false)), checked: status) {
            return refused
        }
        if Task.isCancelled {
            return .skipped(.cancelled)
        }
        beforeChange?(change)
        return DiskChange.trash(itemURL)
    }
}

/// The state of a file whose content was confirmed to be `contentHash`: the same identity, size and
/// modification date read later, for the same hash, mean the confirmation still stands.
struct VerifiedFile: Equatable, Sendable {
    let identity: FileIdentity
    let sizeInBytes: Int64
    let modificationDate: Date
    let contentHash: ContentHash

    init(_ status: FileStatus, contentHash: ContentHash) {
        identity = status.identity
        sizeInBytes = status.sizeInBytes
        modificationDate = status.modificationDate
        self.contentHash = contentHash
    }
}
