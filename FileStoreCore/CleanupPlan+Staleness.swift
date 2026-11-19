import Foundation

extension ProposedChange {
    /// True when an item of this size, last changed then, is still the one the plan saw. The
    /// executor asks it of the disk right before a change; a waiting plan is asked it of a newer scan.
    func isUnchanged(sizeInBytes: Int64, lastChange: Date?) -> Bool {
        guard sizeInBytes == self.sizeInBytes, let lastChange, let scannedDate = dateModified else {
            return false
        }
        return abs(lastChange.timeIntervalSince(scannedDate)) <= CleanupExecutor.modificationDateTolerance
    }
}

extension CleanupPlan {
    /// The changes that no longer stand as this plan saw them, judged against `records`, a newer
    /// scan of the same folder: the item is gone, has another size or changed since, or it is a
    /// duplicate whose kept copy is. Pure. A plan that waits on screen is out of date once this is
    /// not empty; the executor still checks every item itself, and more than this can (an installed
    /// app, what a zip was unpacked to).
    public func staleChangeIDs(in records: [FileRecord]) -> Set<ProposedChange.ID> {
        // Only the records this plan names: a plan with one change must not index the whole folder.
        let named = Set(changes.map(\.id)).union(duplicateGroups.map(\.kept.url))
        var current: [URL: FileRecord] = [:]
        for record in records where named.contains(record.url) {
            current[record.url] = record
        }
        var stale = Set(changes.filter { change in
            guard let record = current[change.id] else { return true }
            return !change.isUnchanged(sizeInBytes: record.contentSizeInBytes ?? 0, lastChange: record.lastChange)
        }.map(\.id))
        for group in duplicateGroups {
            let kept = current[group.kept.url]
            if kept?.contentSizeInBytes != group.kept.contentSizeInBytes || kept?.lastChange != group.kept.lastChange {
                stale.formUnion(group.duplicates.map(\.url))
            }
        }
        return stale.intersection(changes.map(\.id))
    }
}
