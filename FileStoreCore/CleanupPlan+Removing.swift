import Foundation

extension CleanupPlan {
    /// This plan without the changes in `ids`: what the preview shows once the user has taken files
    /// out of it (Keep This File). Each change leaves its duplicate group too, and a group left with
    /// nothing proposed goes. Everything else stays as it was, skipped items included. Pure.
    public func removing(_ ids: Set<ProposedChange.ID>) -> CleanupPlan {
        guard !ids.isEmpty else {
            return self
        }
        let groups = duplicateGroups.compactMap { group -> DuplicateGroup? in
            let duplicates = group.duplicates.filter { !ids.contains($0.id) }
            guard !duplicates.isEmpty else {
                return nil
            }
            return DuplicateGroup(
                contentHash: group.contentHash,
                kept: group.kept,
                duplicates: duplicates,
                fileSizeInBytes: group.fileSizeInBytes
            )
        }
        return CleanupPlan(
            action: action,
            folderURL: folderURL,
            changes: changes.filter { !ids.contains($0.id) },
            duplicateGroups: groups,
            skippedItems: skippedItems
        )
    }
}
