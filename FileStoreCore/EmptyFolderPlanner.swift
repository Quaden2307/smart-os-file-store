import Foundation

/// Plans Remove Empty Folders: the plain folders at the top level of the folder that hold nothing
/// but empty folders and the files macOS makes by itself (`PackageContents.systemFileNames`), as the
/// scan read them (`FileRecord.packageContents`, within `PackageContents.Limits.standard`). Each is a
/// move to the Trash, ticked.
///
/// A folder whose inside could not be read, or that is too big or too deep to read in full, is not
/// empty: unknown is never empty. Those the shared rules allow are listed as not checked, unless they
/// were merely too big. Packages, links, and the items the shared rules keep out (hidden, the
/// archive, downloads in progress, the grace period, Kept) take no part. Pure: it reads only the
/// records.
public struct EmptyFolderPlanner: Sendable {
    /// The rules every action shares, with the Kept list.
    public let eligibility: CandidateEligibility

    public init(eligibility: CandidateEligibility = CandidateEligibility()) {
        self.eligibility = eligibility
    }

    /// The plan for `records`, from one scan of `folderURL`, at `now`.
    public func plan(records: [FileRecord], in folder: ManagedFolder, now: Date = .now) -> CleanupPlan {
        let folderURL = folder.url
        let folders = DuplicatePlanner.recordsDirectlyInside(folderURL, among: records)
            .filter { $0.kind == .folder && eligibility.allows($0, in: folder, now: now) }
            .sorted { $0.displayName.localizedStandardCompare($1.displayName) == .orderedAscending }
        var changes: [ProposedChange] = []
        var skippedItems: [CleanupPlan.SkippedItem] = []
        for folder in folders {
            switch folder.packageContents {
            case .success(let contents) where contents.isEmptyFolder:
                changes.append(ProposedChange(record: folder, operation: .moveToTrash, reason: .emptyFolder))
            case .failure(let failure):
                if let reason = CleanupSkipReason(packageFailure: failure) {
                    skippedItems.append(CleanupPlan.SkippedItem(url: folder.url, reason: reason))
                }
            case .success, nil:
                break
            }
        }
        return CleanupPlan(action: .removeEmptyFolders, folder: folder, changes: changes, skippedItems: skippedItems)
    }
}
