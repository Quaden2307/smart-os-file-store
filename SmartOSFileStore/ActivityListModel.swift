import FileStoreCore
import Foundation
import Observation

/// A row of the Activity place: a run, or one item of a run.
enum ActivityRowID: Hashable {
    case run(ActivityRun.ID)
    case change(ActivityChange.ID)
}

/// Whether a row of the Activity place has an Undo button, and whether it works.
enum UndoAvailability: Equatable {
    /// No button: an undo's own rows, a change that changed nothing, a change already undone.
    case none
    /// Being checked; shown greyed out for that moment.
    case checking
    case available
    /// Shown greyed out, with why.
    case unavailable(reason: String)

    var isAvailable: Bool { self == .available }
}

/// State of the Activity place: the runs, the items of each run that is open, and whether each of
/// those items' files is still where the log expects it. Lives on the main actor, for as long as
/// the main window; the log and the disk are read elsewhere.
///
/// Everything here describes one opened log. When a different log is opened (a fresh one, or the
/// same file again after a failure), it starts over: run numbers begin again in a fresh log, so
/// nothing read from the old one may be kept. Opening a run reads its items, and their files, anew
/// every time; what was read before is shown until the new read is in.
///
/// A read that fails is handed to `ActivityLogModel`, which closes the log and offers the ways out:
/// a log that cannot be read cannot be trusted to record a cleanup either.
@MainActor
@Observable
final class ActivityListModel {
    /// Every run in the log, newest first.
    private(set) var runs: [ActivityRun] = []

    /// False until the current log's first read has finished, so the place can show a loading state.
    private(set) var hasLoaded = false

    /// The items of each run that has been opened, as last read.
    private(set) var changes: [ActivityRun.ID: [ActivityChange]] = [:]

    /// Whether each loaded item's file is still at its expected place, as of the last read.
    private(set) var presence: [ActivityChange.ID: ActivityChangePresence] = [:]

    /// Whether each loaded item can be undone now, as of the last read. Looks at the files with
    /// `lstat` only; the undo itself checks everything again, content included.
    private(set) var assessments: [ActivityChange.ID: UndoPlanner.Assessment] = [:]

    private(set) var expanded: Set<ActivityRun.ID> = []

    /// Every loaded item by its identifier, so a selection is looked up without a search.
    private var changesByID: [ActivityChange.ID: ActivityChange] = [:]

    /// Which opening of the log the state above was read from (`ActivityLogModel.openings`).
    private var loadedOpening: Int?

    /// Counts reads, so a slow one never overwrites a newer one.
    private var generation = 0

    /// Reads the runs again, and the items of every open run with their files.
    func reload(activity: ActivityLogModel) {
        generation += 1
        if loadedOpening != activity.openings {
            // Another log: nothing read from the last one may stay.
            loadedOpening = activity.openings
            runs = []
            expanded = []
            presence = [:]
            assessments = [:]
            setChanges([:])
            hasLoaded = false
        }
        guard let log = activity.log else {
            hasLoaded = false
            return
        }
        let generation = generation
        let openAtStart = expanded
        Task {
            do throws(ActivityLogError) {
                let runs = try await log.runs()
                var changes: [ActivityRun.ID: [ActivityChange]] = [:]
                for run in runs where openAtStart.contains(run.id) {
                    changes[run.id] = try await log.changes(inRun: run.id)
                }
                let looked = try await Self.look(at: changes, runs: runs, log: log, folders: activity.folders)
                guard generation == self.generation else { return }
                let runIDs = Set(runs.map(\.id))
                self.runs = runs
                // Opening and closing done meanwhile stands. A run that was pruned can no longer be open.
                expanded.formIntersection(runIDs)
                // What was read now replaces what was read before; runs that were not read keep theirs.
                let kept = self.changes.filter { runIDs.contains($0.key) }
                setChanges(kept.merging(changes) { _, fresh in fresh })
                self.presence.merge(looked.presence) { _, new in new }
                // Only open runs were looked at now; what was assessed before is out of date, so it
                // goes, and a closed run goes by its counts until it is opened again. A run opened
                // meanwhile keeps what its own read found: this read did not look at it.
                let openedMeanwhile = Set(expanded.subtracting(openAtStart).flatMap { self.changes[$0]?.map(\.id) ?? [] })
                self.assessments = self.assessments.filter { openedMeanwhile.contains($0.key) }
                    .merging(looked.assessments) { _, new in new }
                hasLoaded = true
            } catch {
                guard generation == self.generation else { return }
                activity.logFailed(error)
            }
        }
    }

    func isExpanded(_ runID: ActivityRun.ID) -> Bool {
        expanded.contains(runID)
    }

    /// Opens or closes a run. Opening reads its items and their files again, so where each file is
    /// now is what Reveal in Finder goes by; what was read before shows meanwhile. Closing keeps it.
    func setExpanded(_ runID: ActivityRun.ID, _ isExpanded: Bool, activity: ActivityLogModel) {
        guard isExpanded else {
            expanded.remove(runID)
            return
        }
        expanded.insert(runID)
        guard let log = activity.log else { return }
        let generation = generation
        Task {
            do throws(ActivityLogError) {
                let items = try await log.changes(inRun: runID)
                let runs = runs.filter { $0.id == runID }
                let looked = try await Self.look(at: [runID: items], runs: runs, log: log, folders: activity.folders)
                // A full read started meanwhile reads this run too, from a newer state of the log.
                guard generation == self.generation else { return }
                var updated = changes
                updated[runID] = items
                setChanges(updated)
                presence.merge(looked.presence) { _, new in new }
                assessments.merge(looked.assessments) { _, new in new }
            } catch {
                guard generation == self.generation else { return }
                activity.logFailed(error)
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
    /// there or when that cannot be told (Finder may still be able to show it).
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

    // MARK: - Undo

    /// Whether `run`'s Undo button works. Known from its counts alone until its items are loaded;
    /// then by what each item's check found.
    func undoAvailability(for run: ActivityRun) -> UndoAvailability {
        guard !run.isUndo else {
            return .none
        }
        guard run.doneCount > 0 else {
            return .unavailable(reason: String(localized: "Nothing changed, so there is nothing to undo."))
        }
        guard run.hasChangesLeftToUndo else {
            return .unavailable(reason: String(localized: "Already undone"))
        }
        // Only an open run's items were looked at with the latest read.
        guard expanded.contains(run.id), let items = changes[run.id] else {
            return .available
        }
        let assessed = items.compactMap { assessments[$0.id] }
        if assessed.contains(where: { $0.refusal == nil }) {
            return .available
        }
        // Not yet checked since they were read: the run's counts say there is something left.
        if assessed.count < items.count {
            return .checking
        }
        return .unavailable(reason: String(localized: "None of its files can be put back"))
    }

    /// Whether `change`'s Undo button works. No button for what there is nothing to undo about.
    func undoAvailability(for change: ActivityChange, in run: ActivityRun) -> UndoAvailability {
        guard !run.isUndo, change.undoneAt == nil else {
            return .none
        }
        switch change.outcome {
        case .skipped, .failed, .undone, .notUndone, .unrecognized:
            return .none
        case .started, .trashed, .renamed, .moved:
            break
        }
        switch assessments[change.id] {
        case .undoable:
            return .available
        case .notUndoable(let refusal):
            return .unavailable(reason: refusal.localizedDescription(for: change.undoOperation))
        case nil:
            return .checking
        }
    }

    /// What to undo for the selection: one run or one item whose Undo button works. Nil otherwise.
    func undoTarget(for rows: Set<ActivityRowID>) -> UndoTarget? {
        guard rows.count == 1, let row = rows.first else {
            return nil
        }
        switch row {
        case .run(let runID):
            guard let run = runs.first(where: { $0.id == runID }), undoAvailability(for: run).isAvailable else {
                return nil
            }
            return .run(runID)
        case .change(let changeID):
            guard let change = changesByID[changeID],
                  let run = runs.first(where: { $0.id == change.runID }),
                  undoAvailability(for: change, in: run).isAvailable else {
                return nil
            }
            return .change(changeID)
        }
    }

    /// What one look at the disk says about loaded changes: whether each file is at its expected
    /// place, and whether each change can be undone.
    private struct Look: Sendable {
        var presence: [ActivityChange.ID: ActivityChangePresence] = [:]
        var assessments: [ActivityChange.ID: UndoPlanner.Assessment] = [:]
    }

    /// Looks at each change's places once, off the main actor, for both answers. Each run is
    /// judged in its own folder, wherever that is now, and with that folder's Trash; a run whose
    /// folder cannot be found cannot be undone.
    @concurrent
    private static func look(
        at changes: [ActivityRun.ID: [ActivityChange]],
        runs: [ActivityRun],
        log: ActivityLog,
        folders: FolderRegistry
    ) async throws(ActivityLogError) -> Look {
        var look = Look()
        // Each folder, and its Trash, is looked up once, not once per run or change.
        var planners: [ManagedFolder.ID?: (folder: ManagedFolder?, planner: UndoPlanner)] = [:]
        for run in runs {
            guard let items = changes[run.id], !items.isEmpty else { continue }
            let found: (folder: ManagedFolder?, planner: UndoPlanner)
            if let known = planners[run.folderID] {
                found = known
            } else {
                let folder = try await UndoPlanner.folder(of: run, log: log, folders: folders)
                found = (folder, UndoPlanner(trash: folder.map { TrashLocator.system.resolved(for: $0.url) } ?? .system))
                planners[run.folderID] = found
            }
            let observations = await found.planner.observe(items, folder: found.folder)
            for change in items {
                let observation = observations[change.id]
                look.assessments[change.id] = found.planner.assess(change, in: run, observation: observation, folder: found.folder)
                look.presence[change.id] = presence(of: change, in: observation)
            }
        }
        return look
    }

    /// Whether the change's file is at its expected place, from the look `observe` took at both places.
    nonisolated private static func presence(of change: ActivityChange, in observation: UndoObservation?) -> ActivityChangePresence {
        let place: UndoObservation.Place? = switch change.expectedPath {
        case nil:
            .nothing
        case change.resultingPath:
            observation?.currentPlace
        default:
            observation?.originalPlace
        }
        switch place {
        case .item:
            return .present
        case .nothing:
            return .missing
        case .unreadable, nil:
            return .unknown
        }
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
