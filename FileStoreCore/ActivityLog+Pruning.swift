import Foundation
internal import GRDB

/// What one call to `pruneIfDue` did.
public struct ActivityPruneResult: Sendable, Hashable {
    /// False when the log was pruned less than a day ago, so nothing was looked at.
    public let wasDue: Bool

    /// Runs removed, each with all of its changes.
    public let runsRemoved: Int

    /// True when the file was compacted afterwards.
    public let didCompact: Bool

    public init(wasDue: Bool, runsRemoved: Int, didCompact: Bool) {
        self.wasDue = wasDue
        self.runsRemoved = runsRemoved
        self.didCompact = didCompact
    }
}

/// Keeping the log small: runs older than the retention period go, at most once a day, and the
/// file is compacted afterwards. The totals are a separate table and are never lowered.
extension ActivityLog {
    /// How long a run stays in the log.
    public static let retention: TimeInterval = 90 * 24 * 60 * 60

    /// The least time between two prunings.
    public static let pruneInterval: TimeInterval = 24 * 60 * 60

    /// Removes the runs that started more than `retention` before `now`, with their changes, unless
    /// the log was pruned less than `pruneInterval` ago. A run exactly `retention` old stays. A run
    /// is removed whole or not at all, by when it started.
    @concurrent
    public func pruneIfDue(now: Date = .now) async throws(ActivityLogError) -> ActivityPruneResult {
        let moment = now.timeIntervalSinceReferenceDate
        let removed: Int? = try write { db in
            let lastPrunedAt = try Double.fetchOne(db, sql: "SELECT lastPrunedAt FROM maintenance WHERE id = 1")
            // A last pruning in the future means the clock was set back; prune then too.
            if let lastPrunedAt, moment >= lastPrunedAt, moment - lastPrunedAt < Self.pruneInterval {
                return nil
            }
            // The changes go with their run (ON DELETE CASCADE).
            try db.execute(sql: "DELETE FROM runs WHERE startedAt < ?", arguments: [moment - Self.retention])
            let removed = db.changesCount
            try db.execute(sql: "UPDATE maintenance SET lastPrunedAt = ? WHERE id = 1", arguments: [moment])
            return removed
        }
        guard let removed else {
            return ActivityPruneResult(wasDue: false, runsRemoved: 0, didCompact: false)
        }
        guard removed > 0 else {
            return ActivityPruneResult(wasDue: true, runsRemoved: 0, didCompact: false)
        }
        // The rows are gone either way; a failure to compact only leaves the file larger until the
        // next pruning, so it is logged and not thrown.
        var didCompact = false
        do throws(ActivityLogError) {
            try compact()
            didCompact = true
        } catch {
            Self.logger.notice("Could not compact the activity log: \(String(describing: error), privacy: .public)")
        }
        truncateWriteAheadFile()
        Self.logger.info("Pruned \(removed) runs from the activity log; compacted: \(didCompact)")
        return ActivityPruneResult(wasDue: true, runsRemoved: removed, didCompact: didCompact)
    }
}
