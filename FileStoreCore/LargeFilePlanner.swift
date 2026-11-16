import Foundation

/// Plans Review Large Downloads: the regular files and packages at the top level of the folder that
/// take at least the large-download setting on disk, largest first.
///
/// The size is the space the item really occupies (`FileRecord.allocatedSizeInBytes`): a sparse file
/// or a cloud placeholder not downloaded counts what it takes, not its length, and a package the total
/// of its contents. It is a review list: every item is a proposed move to the Trash that the preview
/// leaves unticked (`ProposedChange.Reason.isReviewOnly`). Plain folders, links, items whose space is
/// unknown, and the items the shared rules keep out (hidden, the archive, downloads in progress, the
/// grace period, Kept) take no part. Pure: it reads only the records.
public struct LargeFilePlanner: Sendable {
    /// The rules every action shares, with the Kept list.
    public let eligibility: CandidateEligibility

    /// The size threshold, `largeDownloadThreshold`.
    public let settings: CleanupSettings

    public init(eligibility: CandidateEligibility = CandidateEligibility(), settings: CleanupSettings = CleanupSettings()) {
        self.eligibility = eligibility
        self.settings = settings
    }

    /// The files and packages directly inside `folderURL` that the shared rules allow at `now` and
    /// that take at least the threshold on disk, largest first, then by name.
    public func candidates(in records: [FileRecord], folderURL: URL, now: Date) -> [FileRecord] {
        DuplicatePlanner.recordsDirectlyInside(folderURL, among: records)
            .filter { record in
                guard record.kind == .file || record.kind == .package,
                      let sizeOnDisk = record.allocatedSizeInBytes,
                      sizeOnDisk >= settings.largeDownloadThreshold else {
                    return false
                }
                return eligibility.allows(record, now: now)
            }
            .sorted { lhs, rhs in
                let left = lhs.allocatedSizeInBytes ?? 0
                let right = rhs.allocatedSizeInBytes ?? 0
                if left != right {
                    return left > right
                }
                switch lhs.displayName.localizedStandardCompare(rhs.displayName) {
                case .orderedAscending:
                    return true
                case .orderedDescending:
                    return false
                case .orderedSame:
                    return lhs.url.path(percentEncoded: false) < rhs.url.path(percentEncoded: false)
                }
            }
    }

    /// The review list for `records`, from one scan of `folderURL`, at `now`.
    public func plan(records: [FileRecord], in folderURL: URL, now: Date = .now) -> CleanupPlan {
        let topLevel = DuplicatePlanner.recordsDirectlyInside(folderURL, among: records)
        let changes = candidates(in: records, folderURL: folderURL, now: now).map { record in
            ProposedChange(
                record: record,
                operation: .moveToTrash,
                reason: .largeDownload(
                    sizeOnDisk: record.allocatedSizeInBytes ?? 0,
                    lastOpened: record.lastOpened,
                    opensRecorded: record.recordsLastOpened
                )
            )
        }
        return CleanupPlan(
            action: .reviewLargeDownloads,
            folderURL: folderURL,
            changes: changes,
            topLevelSizeOnDisk: topLevel.reduce(0) { $0 + ($1.allocatedSizeInBytes ?? 0) }
        )
    }
}
