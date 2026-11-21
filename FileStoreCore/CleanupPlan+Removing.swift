import Foundation

extension CleanupPlan {
    /// This plan without the changes in `ids`: what the preview shows once the user has taken files
    /// out of it (Keep This File). Each change leaves its duplicate group too, and a group left with
    /// nothing proposed goes; a near-duplicate group left with one file goes with that file.
    /// Everything else stays as it was, skipped items and what was read from installers included. Pure.
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
        // A near-duplicate group left with one file is no group: a replan would not show it either,
        // since a Kept file takes no part. Its last change goes with it.
        var droppedIDs = ids
        let nearGroups = nearDuplicateGroups.compactMap { group -> NearDuplicateGroup? in
            let members = group.members.filter { !ids.contains($0.id) }
            guard members.count >= 2 else {
                droppedIDs.formUnion(members.map(\.id))
                return nil
            }
            return NearDuplicateGroup(cleanedName: group.cleanedName, members: members)
        }
        return CleanupPlan(
            action: action,
            folder: folder,
            changes: changes.filter { !droppedIDs.contains($0.id) },
            duplicateGroups: groups,
            nearDuplicateGroups: nearGroups,
            skippedItems: skippedItems,
            installerFactsRead: installerFactsRead,
            archiveProblem: archiveProblem,
            topLevelSizeOnDisk: topLevelSizeOnDisk
        )
    }
}
