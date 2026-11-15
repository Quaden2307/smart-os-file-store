import Foundation

/// Works out what undoing a logged change, or a whole run, would do, and for each change whether
/// it can be undone now and why not.
///
/// The deciding is pure (`plan`, `assess`): it takes the log's rows and what was seen on disk.
/// Looking at the disk (`observe`) reads names and `lstat` only, never content, so the Activity
/// place can ask for every item it shows. The executor checks everything again right before it
/// moves a file, the content hash included.
public struct UndoPlanner: Sendable {
    /// Whether one change can be undone now.
    public enum Assessment: Sendable, Hashable {
        case undoable(UndoStep)
        case notUndoable(UndoRefusal)

        public var refusal: UndoRefusal? {
            if case .notUndoable(let refusal) = self {
                return refusal
            }
            return nil
        }
    }

    public let trash: TrashLocator

    public init(trash: TrashLocator = .system) {
        self.trash = trash
    }

    // MARK: - Deciding

    /// The plan for `target`, from the log's rows and what `observe` saw.
    ///
    /// - Parameters:
    ///   - run: The run the target belongs to.
    ///   - changes: The target's changes: every change of the run, or the one change.
    ///   - folderURL: The folder the app looks after now. A run made in another folder is not undone.
    public func plan(
        target: UndoTarget,
        run: ActivityRun,
        changes: [ActivityChange],
        observations: [ActivityChange.ID: UndoObservation],
        folderURL: URL
    ) -> UndoPlan {
        var steps: [UndoStep] = []
        var refused: [UndoPlan.Refused] = []
        let planner = UndoPlanner(trash: trash.resolved(for: folderURL))
        for change in changes {
            switch planner.assess(change, in: run, observation: observations[change.id], folderURL: folderURL) {
            case .undoable(let step):
                steps.append(step)
            case .notUndoable(let refusal):
                // A whole run leaves out what there is nothing to say about: changes that changed
                // nothing, changes already undone, and the rows of an undo.
                if case .run = target, [.nothingChanged, .alreadyUndone, .isAnUndo].contains(refusal) {
                    continue
                }
                refused.append(UndoPlan.Refused(change: change, refusal: refusal))
            }
        }
        // The reverse of the order the run made them in.
        steps.sort { ($0.sequence, $0.changeID) > ($1.sequence, $1.changeID) }
        refused.sort { ($0.change.sequence, $0.change.id) > ($1.change.sequence, $1.change.id) }
        return UndoPlan(target: target, folderURL: folderURL, undoneActionCode: run.actionCode, steps: steps, refused: refused)
    }

    /// Whether `change` can be undone, by the log and by what was seen. The first rule that fails decides.
    public func assess(
        _ change: ActivityChange,
        in run: ActivityRun,
        observation: UndoObservation?,
        folderURL: URL
    ) -> Assessment {
        let operation: UndoStep.Operation
        let currentPath: String
        switch evaluate(change, in: run, folderURL: folderURL) {
        case .reversed(let reversal, let path):
            (operation, currentPath) = (reversal, path)
        case .refused(let refusal):
            return .notUndoable(refusal)
        }
        guard let observation else {
            return .notUndoable(.cannotBeChecked)
        }
        guard observation.folderIsReachable else {
            return .notUndoable(.folderUnavailable)
        }
        guard observation.originalIsInFolder else {
            return .notUndoable(.notWhereRecorded)
        }
        let evidence = change.undoEvidence
        let current: UndoItemFacts
        switch observation.currentPlace {
        case .nothing:
            return .notUndoable(.missing)
        case .unreadable:
            return .notUndoable(.accessDenied)
        case .item(let facts):
            if let refusal = evidence.refusal(for: facts) {
                return .notUndoable(refusal)
            }
            current = facts
        }
        let originalName = UndoPaths.name(of: change.originalPath) ?? change.originalPath
        switch observation.originalPlace {
        case .nothing:
            break
        case .item(let facts) where operation == .renameBack && facts.fileNumber == current.fileNumber:
            // The file itself, found under its old name: a rename that changed only the letter case
            // or the Unicode form, which the volume treats as one name. The exclusive rename decides.
            break
        case .item:
            return .notUndoable(.originalNameTaken(name: originalName))
        case .unreadable:
            return .notUndoable(.accessDenied)
        }
        return .undoable(
            UndoStep(
                changeID: change.id,
                runID: change.runID,
                sequence: change.sequence,
                operation: operation,
                currentPath: currentPath,
                originalPath: change.originalPath,
                evidence: evidence
            )
        )
    }

    /// What the log alone says about a change.
    private enum Verdict {
        /// How the change is reversed, and where the change put the file.
        case reversed(UndoStep.Operation, currentPath: String)
        case refused(UndoRefusal)
    }

    /// The rules the log alone can answer: how the change is reversed, or why it cannot be.
    private func evaluate(_ change: ActivityChange, in run: ActivityRun, folderURL: URL) -> Verdict {
        if run.isUndo || change.undoesChangeID != nil {
            return .refused(.isAnUndo)
        }
        if change.undoneAt != nil {
            return .refused(.alreadyUndone)
        }
        let operation: UndoStep.Operation
        switch (change.operation, change.outcome) {
        case (_, .started):
            return .refused(.interrupted)
        case (_, .skipped), (_, .failed):
            return .refused(.nothingChanged)
        case (.moveToTrash, .trashed):
            operation = .putBackFromTrash
        case (.rename, .renamed):
            operation = .renameBack
        case (.move, .moved):
            operation = .moveBack
        case (_, .undone), (_, .notUndone):
            return .refused(.isAnUndo)
        case (nil, _), (_, .unrecognized), (.moveToTrash, _), (.rename, _), (.move, _), (.putBackFromTrash, _):
            return .refused(.unknownToThisVersion)
        }
        // Only the folder the app looks after, and only one visible name in it. That the file was
        // directly inside that folder is for the observation to say: the scan may spell the folder
        // another way than the run does.
        let folderPath = folderURL.path(percentEncoded: false)
        guard UndoPaths.components(of: run.folderPath) == UndoPaths.components(of: folderPath) else {
            return .refused(.otherFolder)
        }
        guard let originalName = UndoPaths.name(of: change.originalPath), UndoPaths.isSingleName(originalName) else {
            return .refused(.notWhereRecorded)
        }
        // Where the change put it: the Trash, or a name or folder inside the scanned folder. The
        // executor wrote these with the run's own spelling of the folder.
        guard let currentPath = change.resultingPath else {
            return .refused(operation == .putBackFromTrash ? .trashLocationUnknown : .notWhereRecorded)
        }
        let isWhereRecorded = switch operation {
        case .putBackFromTrash:
            trash.holds(currentPath, for: folderURL)
        case .renameBack:
            UndoPaths.isDirectlyInside(currentPath, folderPath: folderPath)
        case .moveBack:
            UndoPaths.folderNames(from: folderPath, toItemAt: currentPath) != nil
        }
        guard isWhereRecorded else {
            return .refused(.notWhereRecorded)
        }
        return .reversed(operation, currentPath: currentPath)
    }

    // MARK: - Looking

    /// Looks, right now, at each change's current and original places. Reads `lstat` only.
    @concurrent
    public func observe(_ changes: [ActivityChange], folderURL: URL) async -> [ActivityChange.ID: UndoObservation] {
        let folder = try? FileStatus.of(path: folderURL.path(percentEncoded: false), followingLinks: true)
        let folderIdentity = folder?.isDirectory == true ? folder?.identity : nil
        var result: [ActivityChange.ID: UndoObservation] = [:]
        result.reserveCapacity(changes.count)
        // The changes of a run share one folder; each folder spelling is looked at once.
        var isTheFolder: [String: Bool] = [:]
        for change in changes {
            var originalIsInFolder = false
            if let folderIdentity, let name = UndoPaths.name(of: change.originalPath), UndoPaths.isSingleName(name) {
                let parent = UndoPaths.parent(of: change.originalPath)
                if let known = isTheFolder[parent] {
                    originalIsInFolder = known
                } else {
                    originalIsInFolder = UndoPaths.isItemDirectlyIn(change.originalPath, folderIdentity: folderIdentity)
                    isTheFolder[parent] = originalIsInFolder
                }
            }
            result[change.id] = UndoObservation(
                currentPlace: UndoObservation.place(at: change.resultingPath),
                originalPlace: UndoObservation.place(at: change.originalPath),
                folderIsReachable: folderIdentity != nil,
                originalIsInFolder: originalIsInFolder
            )
        }
        return result
    }

    /// The plan for `target`, read from `log` and the disk now. A target the log no longer holds
    /// (its run was pruned) gives a plan with nothing in it: there is nothing left to undo.
    ///
    /// - Throws: When the log cannot be read.
    @concurrent
    public func plan(_ target: UndoTarget, log: ActivityLog, folderURL: URL) async throws(ActivityLogError) -> UndoPlan {
        let nothing = UndoPlan(target: target, folderURL: folderURL, undoneActionCode: "", steps: [], refused: [])
        let run: ActivityRun
        let changes: [ActivityChange]
        switch target {
        case .run(let runID):
            guard let found = try await log.run(id: runID) else {
                return nothing
            }
            run = found
            changes = try await log.changes(inRun: runID)
        case .change(let changeID):
            guard let change = try await log.change(id: changeID), let found = try await log.run(id: change.runID) else {
                return nothing
            }
            run = found
            changes = [change]
        }
        let observations = await observe(changes, folderURL: folderURL)
        return plan(target: target, run: run, changes: changes, observations: observations, folderURL: folderURL)
    }
}

extension ActivityChange {
    /// What the log recorded to prove that a file found later is this change's file.
    public var undoEvidence: UndoEvidence {
        UndoEvidence(sizeInBytes: sizeInBytes, dateModified: dateModified, fileNumber: fileNumber, contentHash: contentHash)
    }
}
