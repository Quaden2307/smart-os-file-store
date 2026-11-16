import Foundation

/// Undo: reversing logged changes, through the same executor, journal and disk calls as a cleanup.
///
/// Every step is checked again right before anything moves, by the rules the planner used
/// (`UndoEvidence`: the recorded size, modification date and disk ID), and its content hash is read
/// when one was recorded. For a folder, the disk ID is checked on the folder and the size and last
/// change on what is inside it (`PackageContents`). The file goes back under its original name with the exclusive rename,
/// which refuses a taken name in the same step, so nothing is ever overwritten. Nothing is looked
/// for by name: a file that is not at the place the log recorded is not undone.
///
/// The grace period, the in-progress download rule and the archive rule do not apply. They decide
/// what a cleanup may pick; undo only reverses a change the log recorded (decision record 0008).
extension CleanupExecutor {
    /// Reverses the steps of `plan`, in plan order, and records the changes it refused as not undone.
    ///
    /// - Parameters:
    ///   - trash: Where the Trash is for the plan's folder. A put back only takes an item from there.
    ///   - onProgress: Called on the executing thread before the first step and after each one.
    ///   - beforeChange: Called on the executing thread once a step has passed its checks, right
    ///     before the move. Tests use it to change the folder at that very moment.
    /// - Returns: One result per step, in the order tried, then one per refused change. If the task
    ///   is cancelled, the steps not reached are not undone and `wasCancelled` is set. If the activity
    ///   log fails, the steps after the failure are left alone and `logFailure` is set.
    @concurrent
    public func undo(
        _ plan: UndoPlan,
        trash: TrashLocator = .system,
        onProgress: (@Sendable (UndoProgress) -> Void)? = nil,
        beforeChange: (@Sendable (UndoStep) -> Void)? = nil
    ) async -> UndoResult {
        let clock = ContinuousClock()
        let start = clock.now

        // A plan built elsewhere could list one change twice; it is looked at once.
        var seen: Set<ActivityChange.ID> = []
        let steps = plan.steps.filter { seen.insert($0.changeID).inserted }
        let refused = plan.refused.filter { seen.insert($0.change.id).inserted }
        let folder = UndoFolder(url: plan.folderURL)
        // The Trash is looked up once for the run, not once per file.
        let trash = trash.resolved(for: plan.folderURL)

        var journal = RunJournal(recorder: recorder)
        journal.beginUndo(plan, confirmedCount: steps.count + refused.count)
        var items: [UndoItemResult] = []
        items.reserveCapacity(steps.count + refused.count)
        var notTried: [UndoRunFinish.NotTried] = []
        var wasCancelled = false
        onProgress?(UndoProgress(itemsCompleted: 0, itemsTotal: steps.count))

        for (sequence, step) in steps.enumerated() {
            let item: UndoItemResult
            if journal.isStopped {
                item = UndoItemResult(step, outcome: .notUndone(.activityLogUnavailable))
            } else if wasCancelled || Task.isCancelled {
                wasCancelled = true
                item = UndoItemResult(step, outcome: .notUndone(.cancelled))
                notTried.append(UndoRunFinish.NotTried(sequence: sequence, item: item))
            } else {
                journal.startItem(sequence: sequence)
                let outcome = await undoStep(step, folder: folder, trash: trash, journal: &journal, beforeChange: beforeChange)
                item = UndoItemResult(step, outcome: outcome)
                if outcome == .notUndone(.cancelled) {
                    wasCancelled = true
                }
                journal.completeUndo(item)
            }
            items.append(item)
            Self.log(item)
            onProgress?(UndoProgress(itemsCompleted: items.count, itemsTotal: steps.count))
        }
        // The changes refused when the plan was made, recorded with the run's last write.
        for (offset, change) in refused.enumerated() {
            let item = UndoItemResult(change)
            items.append(item)
            notTried.append(UndoRunFinish.NotTried(sequence: steps.count + offset, item: item))
        }

        journal.finishUndo(wasCancelled: wasCancelled, notTried: notTried)
        let result = UndoResult(
            target: plan.target,
            undoneActionCode: plan.undoneActionCode,
            runID: journal.runID,
            items: items,
            wasCancelled: wasCancelled,
            logFailure: journal.failure
        )
        if let failure = journal.failure {
            Self.logger.error("The activity log failed during undo (\(String(describing: failure.error), privacy: .public)); undo stopped")
        }
        Self.logger.info(
            "Undid \(result.undone.count) of \(steps.count) changes (\(result.bytesTakenFromTrash) bytes out of the Trash), \(refused.count) refused when planned, cancelled: \(wasCancelled), in \((clock.now - start).milliseconds, format: .fixed(precision: 1)) ms"
        )
        return result
    }

    // MARK: - One step

    /// Where a step's file is now: in the Trash, named by its path, or in a folder held open.
    private enum UndoSource {
        case trash(path: String)
        case folder(DirectoryHandle, name: String, path: String)

        var path: String {
            switch self {
            case .trash(let path), .folder(_, _, let path):
                path
            }
        }

        /// The item there, as it is now. A link is described itself.
        func status() throws(FileStatus.Failure) -> FileStatus {
            switch self {
            case .trash(let path):
                try FileStatus.of(path: path)
            case .folder(let handle, let name, _):
                try handle.status(of: name)
            }
        }

        /// What is inside the folder there, as it is now. A link is never followed. Read with the
        /// largest limits any action reads with, so a package reads back as it was read before it
        /// moved, and a smaller folder reads the same under either.
        func contents() -> Result<PackageContents, PackageContents.Failure> {
            switch self {
            case .trash(let path):
                PackageContents.read(atPath: path, limits: .package)
            case .folder(let handle, let name, _):
                PackageContents.read(named: name, in: handle, limits: .package)
            }
        }
    }

    /// One step, from the cheapest check to the dearest. The first failing check decides.
    private func undoStep(
        _ step: UndoStep,
        folder: UndoFolder,
        trash: TrashLocator,
        journal: inout RunJournal,
        beforeChange: (@Sendable (UndoStep) -> Void)?
    ) async -> UndoItemOutcome {
        // The folder itself, again for every step: nothing goes back into a different folder.
        guard let handle = folder.handle, folder.isStillTheSame() else {
            return .notUndone(.folderUnavailable)
        }
        // The original place: one visible name directly inside this very folder, however the scan
        // spelled its path. Only that name is used from here on, inside the folder's handle.
        let folderPath = folder.url.path(percentEncoded: false)
        guard UndoPaths.isItemDirectlyIn(step.originalPath, folderIdentity: folder.identity),
              let originalName = UndoPaths.name(of: step.originalPath) else {
            return .notUndone(.notWhereRecorded)
        }

        // The source: only where the log says the change put the file.
        let source: UndoSource
        switch step.operation {
        case .putBackFromTrash:
            guard trash.holds(step.currentPath, for: folder.url) else {
                return .notUndone(.notWhereRecorded)
            }
            source = .trash(path: step.currentPath)
        case .renameBack:
            guard UndoPaths.isDirectlyInside(step.currentPath, folderPath: folderPath), let name = UndoPaths.name(of: step.currentPath) else {
                return .notUndone(.notWhereRecorded)
            }
            source = .folder(handle, name: name, path: step.currentPath)
        case .moveBack:
            guard let folderNames = UndoPaths.folderNames(from: folderPath, toItemAt: step.currentPath),
                  let name = UndoPaths.name(of: step.currentPath) else {
                return .notUndone(.notWhereRecorded)
            }
            // Each folder on the way opened inside the one before, never through a link or onto another disk.
            var parent = handle
            for folderName in folderNames {
                switch Self.step(into: folderName, from: parent, device: folder.identity.device) {
                case .opened(let child):
                    parent = child
                case .missing:
                    return .notUndone(.missing)
                case .refused(.failed(.accessDenied)):
                    return .notUndone(.accessDenied)
                case .refused:
                    return .notUndone(.notWhereRecorded)
                }
            }
            source = .folder(parent, name: name, path: step.currentPath)
        }

        // The item there now, checked against what the log recorded.
        let status: FileStatus
        do throws(FileStatus.Failure) {
            status = try source.status()
        } catch {
            return .notUndone(Self.refusal(statusFailure: error))
        }
        if let refusal = step.evidence.refusal(for: UndoItemFacts(status)) {
            return .notUndone(refusal)
        }
        // The flags every change respects: a placeholder, a hidden file or a locked file stays put.
        if let flagged = Self.flagOutcome(status) {
            return Self.undoOutcome(flagged)
        }
        // For a folder, what is inside it, read now and again at the last look.
        var folderContents: Result<PackageContents, PackageContents.Failure>?
        if step.evidence.isFolder {
            let contents = source.contents()
            if let refusal = Self.folderContentRefusal(step, folderStatus: status, contents: contents) {
                return .notUndone(refusal)
            }
            folderContents = contents
        } else if let refusal = await contentRefusal(step, at: source.path) {
            return .notUndone(refusal)
        }

        // Nothing may have the original name. The exclusive rename asks again, in the same step as it moves.
        do throws(FileStatus.Failure) {
            let taker = try handle.status(of: originalName)
            // For a rename back, the file itself may answer to its old name: a rename that changed
            // only the letter case or the Unicode form, which the volume treats as one name. The
            // exclusive rename then decides, as for any rename (record 0005).
            if step.operation != .renameBack || taker.identity != status.identity {
                return .notUndone(.originalNameTaken(name: originalName))
            }
        } catch .notFound {
            // Free.
        } catch {
            return .notUndone(Self.refusal(statusFailure: error))
        }

        // The activity log first: a row that says this change is being undone, with the disk ID just
        // read. Without the row there is no permit, and no move.
        let permit: ChangePermit
        switch journal.intendUndo(step, fileNumber: UInt64(status.identity.inode)) {
        case .permitted(let granted):
            permit = granted
        case .alreadyUndone:
            return .notUndone(.alreadyUndone)
        case .notAsRecorded:
            return .notUndone(.notWhereRecorded)
        case .stopped:
            return .notUndone(.activityLogUnavailable)
        }

        // Last look, after the reads and right before the move: the very item checked above.
        if let refusal = Self.undoLastLookRefusal(try? source.status(), checked: status, isFolder: step.evidence.isFolder) {
            return refusal
        }
        // A folder's contents can change without its own date: they must still be the ones checked.
        if let folderContents, source.contents() != folderContents {
            return .notUndone(.changed)
        }
        if Task.isCancelled {
            return .notUndone(.cancelled)
        }
        // A move back gives the file its Date Added from before the move, which the move kept.
        var addedTime: timespec?
        if step.operation == .moveBack, case .folder(let parent, let name, _) = source {
            addedTime = try? FileStatus.addedTime(path: name, relativeTo: parent.descriptor)
        }
        beforeChange?(step)

        let failure = switch source {
        case .trash(let path):
            DiskChange.putBackFromTrash(path, to: originalName, in: handle, permit: permit)
        case .folder(let parent, let name, _):
            DiskChange.renameWithoutReplacing(name, in: parent, to: originalName, in: handle, permit: permit)
        }
        if let failure {
            return Self.undoOutcome(Self.outcome(changeFailure: failure, name: originalName))
        }
        if let addedTime, let failure = DiskChange.setDateAdded(of: originalName, in: handle, to: addedTime, permit: permit) {
            Self.logger.error("Could not set a file's Date Added back after undo: \(String(cString: strerror(failure)), privacy: .public)")
        }
        return .undone(to: URL(filePath: step.originalPath))
    }

    /// The content check, when the change recorded a hash. Nil when it passes. When macOS keeps the
    /// Trash's content from the app, a recorded disk ID, already matched, stands in for the hash; with
    /// no disk ID the file cannot be shown to be the same one.
    private func contentRefusal(_ step: UndoStep, at path: String) async -> UndoRefusal? {
        guard let expected = step.evidence.contentHash else {
            return nil
        }
        do throws(ContentHashError) {
            let hash = try await hasher.hash(contentsOf: URL(filePath: path), expectedSizeInBytes: step.evidence.sizeInBytes)
            return hash == expected ? nil : .changed
        } catch {
            switch error {
            case .cancelled:
                return .cancelled
            case .accessDenied:
                guard step.operation == .putBackFromTrash else {
                    return .accessDenied
                }
                return step.evidence.fileNumber == nil ? .cannotBeChecked : nil
            case .fileNotFound:
                return .missing
            case .notARegularFile:
                return .replaced
            case .changedSinceScan:
                return .changed
            case .notDownloaded:
                return .notDownloaded
            case .readFailed:
                return .cannotBeChecked
            }
        }
    }

    /// The contents check for a folder: what is inside it now must add up to the size and last
    /// change the log recorded, which the folder's own `lstat` cannot show. Nil when it passes.
    /// When macOS keeps the Trash's content from the app, the recorded disk ID, already matched,
    /// stands in for the contents, as it does for a hash.
    private static func folderContentRefusal(
        _ step: UndoStep,
        folderStatus: FileStatus,
        contents: Result<PackageContents, PackageContents.Failure>
    ) -> UndoRefusal? {
        switch contents {
        case .success(let contents):
            guard let recorded = step.evidence.dateModified,
                  contents.totalSizeInBytes == step.evidence.sizeInBytes,
                  abs(contents.lastChange(ofFolderModifiedAt: folderStatus.modificationDate).timeIntervalSince(recorded))
                      <= modificationDateTolerance else {
                return .changed
            }
            return nil
        case .failure(.accessDenied):
            guard step.operation == .putBackFromTrash else {
                return .accessDenied
            }
            return step.evidence.fileNumber == nil ? .cannotBeChecked : nil
        case .failure(.notDownloaded):
            return .notDownloaded
        case .failure(.tooManyItems):
            return .changed
        case .failure(.cancelled):
            return .cancelled
        case .failure(.unreadable):
            return .cannotBeChecked
        }
    }

    /// `current` must still be the very item checked as `checked`, unchanged, and with flags that
    /// allow the move: a regular file, or for a folder change, a folder. Nil when the move may go ahead.
    private static func undoLastLookRefusal(_ current: FileStatus?, checked: FileStatus, isFolder: Bool) -> UndoItemOutcome? {
        guard let current else {
            return .notUndone(.missing)
        }
        guard current.identity == checked.identity, isExpectedKind(current, isFolder: isFolder) else {
            return .notUndone(.replaced)
        }
        guard current.sizeInBytes == checked.sizeInBytes, current.modificationDate == checked.modificationDate else {
            return .notUndone(.changed)
        }
        return flagOutcome(current).map(undoOutcome)
    }

    /// An outcome of the checks undo shares with renames and moves (the flags, the rename's own
    /// failures), in undo's words.
    private static func undoOutcome(_ outcome: CleanupItemOutcome) -> UndoItemOutcome {
        switch outcome {
        case .failed(let error):
            .failed(error)
        case .skipped(.destinationExists(let name)):
            .notUndone(.originalNameTaken(name: name))
        case .skipped(.notFound):
            .notUndone(.missing)
        case .skipped(.notDownloaded):
            .notUndone(.notDownloaded)
        case .skipped(.notInPlan):
            // What the flag check says of a file hidden by flag.
            .notUndone(.hidden)
        case .skipped(.destinationOutsideFolder), .skipped(.invalidName):
            .notUndone(.notWhereRecorded)
        case .skipped, .trashed, .renamed, .moved:
            .notUndone(.cannotBeChecked)
        }
    }

    private static func refusal(statusFailure: FileStatus.Failure) -> UndoRefusal {
        switch statusFailure {
        case .notFound:
            .missing
        case .accessDenied:
            .accessDenied
        case .other:
            .cannotBeChecked
        }
    }

    // MARK: - Logging

    private static func log(_ item: UndoItemResult) {
        let path = item.currentPath ?? item.originalPath
        switch item.outcome {
        case .undone(let url):
            logger.info("Undid a change: \(path, privacy: .private) is back at \(url.path(percentEncoded: false), privacy: .private)")
        case .notUndone(let refusal):
            logger.notice("Did not undo the change to \(item.originalPath, privacy: .private): \(refusal.logDescription, privacy: .public)")
        case .failed(let error):
            logger.error("Could not undo the change to \(item.originalPath, privacy: .private): \(String(describing: error.logCode.code), privacy: .public)")
        }
    }
}

/// The scanned folder, opened once for an undo, with the identity it had then.
private struct UndoFolder {
    let url: URL
    let handle: DirectoryHandle?
    let identity: FileIdentity

    init(url: URL) {
        self.url = url
        let handle = try? DirectoryHandle.open(path: url.path(percentEncoded: false))
        let status = try? handle?.status()
        if let handle, let status, status.isDirectory {
            self.handle = handle
            self.identity = status.identity
        } else {
            self.handle = nil
            self.identity = FileIdentity(device: 0, inode: 0)
        }
    }

    /// True while the folder's path still leads to the folder opened: it can be renamed, removed or
    /// replaced while earlier steps are undone.
    func isStillTheSame() -> Bool {
        guard handle != nil, let now = try? FileStatus.of(path: url.path(percentEncoded: false), followingLinks: true) else {
            return false
        }
        return now.isDirectory && now.identity == identity
    }
}

extension UndoRefusal {
    /// A description without names or paths, which stay private in logs.
    fileprivate var logDescription: String {
        logCode.code
    }
}
