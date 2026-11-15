import FileStoreCore
import Foundation
import Observation

/// A row of the Activity window: a run, or one item of a run.
enum ActivityRowID: Hashable {
    case run(ActivityRun.ID)
    case change(ActivityChange.ID)
}

/// State of the Activity window: the runs, the items of each run that has been opened, and whether
/// each item's file is still where the log expects it. Lives on the main actor; the log and the
/// disk are read elsewhere.
///
/// A read that fails is handed to `ActivityLogModel`, which closes the log and offers the ways out:
/// a log that cannot be read cannot be trusted to record a cleanup either.
@MainActor
@Observable
final class ActivityListModel {
    /// Every run in the log, newest first.
    private(set) var runs: [ActivityRun] = []

    /// False until the first read has finished, so the window can show a loading state.
    private(set) var hasLoaded = false

    /// The items of each run that has been expanded. A run's items are read when it is first opened.
    private(set) var changes: [ActivityRun.ID: [ActivityChange]] = [:]

    /// Whether each loaded item's file is still at its expected place, as of the last read.
    private(set) var presence: [ActivityChange.ID: ActivityChangePresence] = [:]

    private(set) var expanded: Set<ActivityRun.ID> = []

    /// Every loaded item by its identifier, so a selection is looked up without a search.
    private var changesByID: [ActivityChange.ID: ActivityChange] = [:]

    /// Counts full reads, so a slow one never overwrites a newer one.
    private var generation = 0

    /// Reads the runs again, and the items of every expanded run.
    func reload(from log: ActivityLog?, activity: ActivityLogModel) {
        generation += 1
        guard let log else {
            runs = []
            setChanges([:])
            presence = [:]
            return
        }
        let generation = generation
        let expandedAtStart = expanded
        Task {
            do throws(ActivityLogError) {
                let runs = try await log.runs()
                var changes: [ActivityRun.ID: [ActivityChange]] = [:]
                for run in runs where expandedAtStart.contains(run.id) {
                    changes[run.id] = try await log.changes(inRun: run.id)
                }
                let presence = await ActivityChange.presence(of: changes.values.flatMap { $0 })
                guard generation == self.generation else { return }
                let runIDs = Set(runs.map(\.id))
                self.runs = runs
                // Runs opened while this read was under way were read on their own; keep those items.
                let openedMeanwhile = self.changes.filter { runIDs.contains($0.key) && changes[$0.key] == nil }
                setChanges(changes.merging(openedMeanwhile) { fresh, _ in fresh })
                self.presence.merge(presence) { _, new in new }
                // Opening and closing done meanwhile stands. A run that was pruned can no longer be open.
                expanded.formIntersection(runIDs)
            } catch {
                guard generation == self.generation else { return }
                activity.readFailed(error)
            }
            hasLoaded = true
        }
    }

    func isExpanded(_ runID: ActivityRun.ID) -> Bool {
        expanded.contains(runID)
    }

    /// Opens or closes a run. Its items are read the first time it opens.
    func setExpanded(_ runID: ActivityRun.ID, _ isExpanded: Bool, log: ActivityLog?, activity: ActivityLogModel) {
        guard isExpanded else {
            expanded.remove(runID)
            return
        }
        expanded.insert(runID)
        guard changes[runID] == nil, let log else { return }
        let generation = generation
        Task {
            do throws(ActivityLogError) {
                let items = try await log.changes(inRun: runID)
                let itemPresence = await ActivityChange.presence(of: items)
                // A full read started meanwhile reads this run too, from a newer state of the log.
                guard generation == self.generation else { return }
                var updated = changes
                updated[runID] = items
                setChanges(updated)
                presence.merge(itemPresence) { _, new in new }
            } catch {
                guard generation == self.generation else { return }
                activity.readFailed(error)
            }
        }
    }

    /// The run a row belongs to, for the keys that open and close it.
    func runID(of row: ActivityRowID) -> ActivityRun.ID? {
        switch row {
        case .run(let id):
            id
        case .change(let changeID):
            changesByID[changeID]?.runID
        }
    }

    /// Where Finder can show the selected items: each one's expected place, when something is
    /// there or when that cannot be told (the Trash may not be looked into; Finder can still show it).
    func revealableURLs(for rows: Set<ActivityRowID>) -> [URL] {
        rows.compactMap { row -> URL? in
            guard case .change(let id) = row, let change = changesByID[id], let path = change.expectedPath else {
                return nil
            }
            switch presence[id] {
            case .present, .unknown:
                return URL(filePath: path)
            case .missing, nil:
                return nil
            }
        }
        .sorted { $0.path(percentEncoded: false) < $1.path(percentEncoded: false) }
    }

    private func setChanges(_ changes: [ActivityRun.ID: [ActivityChange]]) {
        self.changes = changes
        var byID: [ActivityChange.ID: ActivityChange] = [:]
        byID.reserveCapacity(changes.values.reduce(0) { $0 + $1.count })
        for change in changes.values.joined() {
            byID[change.id] = change
        }
        changesByID = byID
    }
}
