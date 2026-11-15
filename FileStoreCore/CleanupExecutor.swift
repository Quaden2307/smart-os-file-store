import Foundation
import os

/// Carries out the confirmed changes of a `CleanupPlan`: moves to the Trash, renames and moves.
///
/// This is the engine's one executor, and only it calls `DiskChange`, the one place that changes a
/// user's disk. Nothing is ever deleted permanently and nothing is ever overwritten. A plan may
/// only use the operation its action allows (`CleanupAction.allows`), and each item is checked
/// again right before it changes, by its operation's rules: the duplicate checks for the Trash
/// (`CleanupExecutor+Duplicates`), the relocation checks for renames and moves
/// (`CleanupExecutor+Relocation`). Items succeed, are skipped or fail one by one; the executor
/// never throws.
///
/// Every run is written to the activity log as it happens, and there is no executor without one:
/// a row that says a change was started goes in before the change, and is completed right after
/// it. If the log cannot be written the run stops there, with the file untouched.
public struct CleanupExecutor: Sendable {
    /// Allowed difference between the scan's modification date and the one read back now. Two
    /// conversions of the same timestamp can differ by floating-point noise; a real change is
    /// caught by the content check regardless.
    public static let modificationDateTolerance: TimeInterval = 0.001

    public let hasher: ContentHasher

    /// The rules every action shares. The grace period is checked again on dates read from disk.
    public let eligibility: CandidateEligibility

    /// Where every run is written down: the activity log.
    public let recorder: any CleanupRecording

    static let logger = Logger(subsystem: "com.quaden2307.FileStoreCore", category: "CleanupExecutor")

    public init(
        recorder: any CleanupRecording,
        hasher: ContentHasher = ContentHasher(),
        eligibility: CandidateEligibility = CandidateEligibility()
    ) {
        self.recorder = recorder
        self.hasher = hasher
        self.eligibility = eligibility
    }

    /// Carries out the confirmed changes of `plan`, in plan order.
    ///
    /// - Parameters:
    ///   - confirmedChangeIDs: The changes the user ticked. IDs that match nothing in the plan are
    ///     logged and ignored; nothing outside the plan is ever touched.
    ///   - now: The current time, for the grace period.
    ///   - onProgress: Called on the executing thread before the first item and after each one.
    ///   - beforeChange: Called on the executing thread once an item has passed its checks,
    ///     immediately before its first change on disk: the change itself, or making a folder for a
    ///     move. It runs inside the gap those checks leave, so it must be quick. The activity log
    ///     has recorded the change as started by then. Tests use it to change the folder at that
    ///     very moment.
    /// - Returns: One result per confirmed change. If the task is cancelled, the items not yet
    ///   reached are reported as skipped and `wasCancelled` is set. If the activity log fails, the
    ///   items after the failure are reported as skipped and `logFailure` is set.
    @concurrent
    public func execute(
        plan: CleanupPlan,
        confirmedChangeIDs: Set<ProposedChange.ID>,
        now: Date = .now,
        onProgress: (@Sendable (CleanupExecutionProgress) -> Void)? = nil,
        beforeChange: (@Sendable (ProposedChange) -> Void)? = nil
    ) async -> CleanupResult {
        let clock = ContinuousClock()
        let start = clock.now

        // A plan built elsewhere could list one file twice; it is looked at once.
        var seen: Set<ProposedChange.ID> = []
        let confirmed = plan.changes.filter { confirmedChangeIDs.contains($0.id) && seen.insert($0.id).inserted }
        let unknown = confirmedChangeIDs.subtracting(plan.changes.map(\.id))
        if !unknown.isEmpty {
            Self.logger.error("Ignoring \(unknown.count) confirmed items that are not in the plan")
        }
        let context = PlanContext(plan: plan)
        // Renames and moves look up every name through one handle on the folder, opened only when
        // the plan has some and only if it is the folder the plan names.
        let folder = confirmed.contains { $0.operation != .moveToTrash } ? context.openFolder() : nil

        var items: [CleanupItemResult] = []
        items.reserveCapacity(confirmed.count)
        var bytesFreed: Int64 = 0
        var wasCancelled = false
        var verifiedKept: [URL: VerifiedFile] = [:]
        // The run is opened in the activity log before anything is looked at. If that fails, the
        // journal is stopped from the start and every item below is left alone.
        var journal = RunJournal(recorder: recorder)
        journal.begin(action: plan.action, folderURL: plan.folderURL, confirmedCount: confirmed.count)
        var notReached: [CleanupRunFinish.NotReached] = []
        onProgress?(CleanupExecutionProgress(itemsCompleted: 0, itemsTotal: confirmed.count, bytesFreed: 0))

        for (sequence, change) in confirmed.enumerated() {
            let item: CleanupItemResult
            if journal.isStopped {
                // The log failed. Nothing more is changed, and nothing more is written.
                item = CleanupItemResult(change: change, outcome: .skipped(.activityLogUnavailable))
            } else if wasCancelled || Task.isCancelled {
                wasCancelled = true
                item = CleanupItemResult(change: change, outcome: .skipped(.cancelled))
                // Never attempted, so not written one by one: the run's last write records them all.
                notReached.append(CleanupRunFinish.NotReached(sequence: sequence, change: change))
            } else {
                journal.startItem(sequence: sequence)
                item = await process(
                    change,
                    context: context,
                    folder: folder,
                    now: now,
                    verifiedKept: &verifiedKept,
                    journal: &journal,
                    beforeChange: beforeChange
                )
                if item.outcome == .skipped(.cancelled) {
                    wasCancelled = true
                }
                // The item's row, right after the attempt and before anything else is looked at.
                journal.complete(item)
            }
            if item.isTrashed {
                bytesFreed += change.sizeInBytes
            }
            items.append(item)
            Self.log(item)
            onProgress?(
                CleanupExecutionProgress(itemsCompleted: items.count, itemsTotal: confirmed.count, bytesFreed: bytesFreed)
            )
        }

        journal.finish(wasCancelled: wasCancelled, notReached: notReached)
        let result = CleanupResult(
            action: plan.action,
            folderURL: plan.folderURL,
            items: items,
            wasCancelled: wasCancelled,
            logFailure: journal.failure
        )
        if let failure = journal.failure {
            Self.logger.error(
                "The activity log failed (\(String(describing: failure.error), privacy: .public)); the run stopped. Change left unrecorded: \(failure.unrecordedChangeID != nil)"
            )
        }
        Self.logger.info(
            "Trashed \(result.trashedCount), renamed \(result.renamed.count), moved \(result.moved.count) of \(confirmed.count) confirmed items (\(result.bytesFreed) bytes freed), \(result.skipped.count) skipped, \(result.failed.count) failed, cancelled: \(wasCancelled), in \((clock.now - start).milliseconds, format: .fixed(precision: 1)) ms"
        )
        return result
    }

    // MARK: - One item

    /// One item: the folder, the action's operation, then the operation's own checks.
    private func process(
        _ change: ProposedChange,
        context: PlanContext,
        folder: DirectoryHandle?,
        now: Date,
        verifiedKept: inout [URL: VerifiedFile],
        journal: inout RunJournal,
        beforeChange: (@Sendable (ProposedChange) -> Void)?
    ) async -> CleanupItemResult {
        // The folder itself is checked again for every item: it can be renamed, removed or replaced
        // while earlier items are being changed, and nothing may be changed in a different folder.
        guard let folderIdentity = context.folderIdentity,
              let folderNow = try? FileStatus.of(path: context.folderURL.path(percentEncoded: false), followingLinks: true),
              folderNow.isDirectory,
              folderNow.identity == folderIdentity else {
            return CleanupItemResult(change: change, outcome: .skipped(.folderUnavailable))
        }
        // Whatever else a plan lists, it may only use the operation its action allows.
        guard context.action.allows(change.operation) else {
            return CleanupItemResult(change: change, outcome: .skipped(.notInPlan))
        }

        switch change.operation {
        case .moveToTrash:
            // The Trash checks are the duplicate action's. Another action that trashes must add
            // its own before it may use this executor; the switch is exhaustive on purpose.
            switch context.action {
            case .findDuplicates:
                let outcome = await trashDuplicate(
                    change,
                    context: context,
                    folderIdentity: folderIdentity,
                    now: now,
                    verifiedKept: &verifiedKept,
                    journal: &journal,
                    beforeChange: beforeChange
                )
                return CleanupItemResult(change: change, outcome: outcome)
            case .fixMessyNames, .archiveOldDownloads:
                return CleanupItemResult(change: change, outcome: .skipped(.notInPlan))
            }
        case .rename(to: let newName):
            guard let folder else {
                return CleanupItemResult(change: change, outcome: .skipped(.folderUnavailable))
            }
            return relocate(
                change,
                to: Relocation(folderNames: [], name: newName),
                folder: folder,
                context: context,
                folderIdentity: folderIdentity,
                now: now,
                journal: &journal,
                beforeChange: beforeChange
            )
        case .move(to: let destination, name: let name):
            guard let folder else {
                return CleanupItemResult(change: change, outcome: .skipped(.folderUnavailable))
            }
            guard let folderNames = FileNameRules.folderNames(from: context.folderURL, to: destination) else {
                return CleanupItemResult(change: change, outcome: .skipped(.destinationOutsideFolder))
            }
            return relocate(
                change,
                to: Relocation(folderNames: folderNames, name: name),
                folder: folder,
                context: context,
                folderIdentity: folderIdentity,
                now: now,
                journal: &journal,
                beforeChange: beforeChange
            )
        }
    }

    // MARK: - Shared checks

    /// The rules every action shares, on what the disk says about the item now rather than on the
    /// scan's record, so a plan built elsewhere cannot get round them: not hidden, past the grace
    /// period by the Date Added read now, the size and modification date the scan saw, and not
    /// locked. A file put here since the scan, under the same name and with an old modification
    /// date, is as new as a freshly written one.
    ///
    /// - Parameter readDateAdded: Reads the item's Date Added from disk, only if it is needed.
    /// - Returns: Nil when the item may go on to its operation's own checks, otherwise why not.
    func sharedRefusal(
        _ status: FileStatus,
        itemURL: URL,
        change: ProposedChange,
        now: Date,
        readDateAdded: () throws(FileStatus.Failure) -> Date?
    ) -> CleanupItemOutcome? {
        if status.isHidden {
            return .skipped(.notInPlan)
        }
        let dateAdded: Date?
        do throws(FileStatus.Failure) {
            dateAdded = try readDateAdded()
        } catch {
            return .skipped(CleanupSkipReason(statusFailure: error))
        }
        switch eligibility.refusal(
            name: itemURL.lastPathComponent,
            isDownloading: FileRecord.isInProgressDownload(itemURL),
            dateAdded: dateAdded,
            dateModified: status.modificationDate,
            now: now
        ) {
        case nil:
            break
        case .excludedName, .downloadInProgress:
            return .skipped(.notInPlan)
        case .insideGracePeriod:
            return .skipped(.changedSinceScan)
        }
        guard status.sizeInBytes == change.sizeInBytes,
              let scannedDate = change.dateModified,
              abs(status.modificationDate.timeIntervalSince(scannedDate)) <= Self.modificationDateTolerance else {
            return .skipped(.changedSinceScan)
        }
        if status.isUserImmutable || status.isSystemImmutable {
            return .failed(.fileIsLocked)
        }
        return nil
    }

    /// The last look, after the reads and right before the change: `current` must still be the
    /// very file checked as `checked`, not something put in its place meanwhile, and its flags must
    /// still allow the change. Nil when it may go ahead.
    static func lastLookRefusal(_ current: FileStatus?, checked: FileStatus) -> CleanupItemOutcome? {
        guard let current,
              current.identity == checked.identity,
              current.isRegularFile,
              current.sizeInBytes == checked.sizeInBytes,
              current.modificationDate == checked.modificationDate else {
            return .skipped(.changedSinceScan)
        }
        return flagOutcome(current)
    }

    /// Flags the file system can change at any moment, checked on the status read right before
    /// the change: a placeholder, a hidden file or a locked file is never changed.
    private static func flagOutcome(_ status: FileStatus) -> CleanupItemOutcome? {
        if status.isDataless {
            return .skipped(.notDownloaded)
        }
        if status.isHidden {
            return .skipped(.notInPlan)
        }
        if status.isUserImmutable || status.isSystemImmutable {
            return .failed(.fileIsLocked)
        }
        return nil
    }

    /// The URL to act on for `standardizedURL`: the plan's folder plus the item's own name, once the
    /// item's parent has been confirmed to be that folder. `standardizedFileURL` removes `..`
    /// lexically while the kernel follows symbolic links first, so the plan's spelling is never
    /// handed to the file system; only `<folder>/<name>` is.
    static func urlInsideFolder(_ standardizedURL: URL, folderURL: URL, folderIdentity: FileIdentity) -> URL? {
        let name = standardizedURL.lastPathComponent
        guard !name.isEmpty, name != ".", name != "..", name != "/" else {
            return nil
        }
        let parentPath = standardizedURL.deletingLastPathComponent().path(percentEncoded: false)
        guard let parent = try? FileStatus.of(path: parentPath, followingLinks: true),
              parent.isDirectory,
              parent.identity == folderIdentity else {
            return nil
        }
        return folderURL.appending(path: name)
    }

    // MARK: - Logging

    private static func log(_ item: CleanupItemResult) {
        let path = item.change.record.url.path(percentEncoded: false)
        for folder in item.createdFolders {
            logger.info("Made folder \(folder.path(percentEncoded: false), privacy: .private) for a move")
        }
        switch item.outcome {
        case .trashed(let trashURL):
            let destination = trashURL?.path(percentEncoded: false) ?? "an unreported location"
            logger.info("Trashed \(path, privacy: .private) to \(destination, privacy: .private)")
        case .renamed(_, let newURL):
            logger.info("Renamed \(path, privacy: .private) to \(newURL.path(percentEncoded: false), privacy: .private)")
        case .moved(_, let newURL):
            logger.info("Moved \(path, privacy: .private) to \(newURL.path(percentEncoded: false), privacy: .private)")
        case .skipped(let reason):
            logger.notice("Skipped \(path, privacy: .private): \(reason.logDescription, privacy: .public)")
        case .failed(let error):
            logger.error(
                "Could not \(item.change.operation.logVerb, privacy: .public) \(path, privacy: .private): \(error.logDescription, privacy: .public)"
            )
        }
    }
}

/// The executor's name until it learnt to rename and move. Find Duplicates' tests still use it.
public typealias TrashExecutor = CleanupExecutor

/// What the executor needs from the plan, looked up once: the folder's identity, the kept files'
/// URLs and identities, and each duplicate's group.
struct PlanContext: Sendable {
    let action: CleanupAction

    let folderURL: URL

    /// Nil when the folder cannot be read or is not a folder; nothing is changed then.
    let folderIdentity: FileIdentity?

    /// Every group's kept file, by the plan's own URL value.
    let keptURLs: Set<URL>

    /// Identities of every kept file that exists, read through the plan's own spelling of its path:
    /// whatever a plan names as kept must never be moved.
    let keptIdentities: Set<FileIdentity>

    /// Each duplicate's group, by the plan's own URL value.
    let groupsByDuplicateURL: [URL: DuplicateGroup]

    init(plan: CleanupPlan) {
        action = plan.action
        folderURL = plan.folderURL
        let folderStatus = try? FileStatus.of(path: plan.folderURL.path(percentEncoded: false), followingLinks: true)
        folderIdentity = folderStatus?.isDirectory == true ? folderStatus?.identity : nil

        var keptURLs: Set<URL> = []
        var keptIdentities: Set<FileIdentity> = []
        var groups: [URL: DuplicateGroup] = [:]
        for group in plan.duplicateGroups {
            keptURLs.insert(group.kept.url)
            if let status = try? FileStatus.of(path: group.kept.url.standardizedFileURL.path(percentEncoded: false)) {
                keptIdentities.insert(status.identity)
            }
            for duplicate in group.duplicates {
                // A URL listed in two groups is checked against the first group's kept file; the
                // second group's kept file is protected through `keptURLs` and `keptIdentities`.
                if groups[duplicate.url] == nil {
                    groups[duplicate.url] = group
                }
            }
        }
        self.keptURLs = keptURLs
        self.keptIdentities = keptIdentities
        self.groupsByDuplicateURL = groups
    }

    /// A handle on the plan's folder, or nil when it cannot be opened or is no longer the folder
    /// whose identity was read above.
    func openFolder() -> DirectoryHandle? {
        guard let folderIdentity,
              let handle = try? DirectoryHandle.open(path: folderURL.path(percentEncoded: false)),
              let status = try? handle.status(),
              status.isDirectory,
              status.identity == folderIdentity else {
            return nil
        }
        return handle
    }
}

extension CleanupSkipReason {
    init(statusFailure: FileStatus.Failure) {
        switch statusFailure {
        case .notFound:
            self = .notFound
        case .accessDenied:
            self = .accessDenied
        case .other(let reason):
            self = .unreadable(reason: reason)
        }
    }

    /// A description without names or paths, which stay private in logs.
    fileprivate var logDescription: String {
        switch self {
        case .changedSinceScan:
            "changed since scan"
        case .notFound:
            "not found"
        case .accessDenied:
            "access denied"
        case .notDownloaded:
            "not downloaded"
        case .notARegularFile:
            "not a regular file"
        case .unreadable(let reason):
            "unreadable: \(reason)"
        case .keptFile:
            "is a kept file"
        case .notInPlan:
            "not in plan"
        case .outsideFolder:
            "outside the folder"
        case .folderUnavailable:
            "folder unavailable"
        case .keptFileMissing:
            "kept file missing"
        case .keptFileNotVerified:
            "kept file not verified"
        case .cancelled:
            "cancelled"
        case .destinationExists:
            "destination name taken"
        case .invalidName:
            "invalid name"
        case .destinationOutsideFolder:
            "destination outside the folder"
        case .destinationNotAFolder:
            "destination is not a folder"
        case .destinationHidden:
            "destination folder is hidden"
        case .activityLogUnavailable:
            "activity log unavailable"
        }
    }
}

extension CleanupExecutionError {
    /// A description without the system's text, which can name the file.
    fileprivate var logDescription: String {
        switch self {
        case .fileIsLocked:
            "file is locked"
        case .accessDenied:
            "access denied"
        case .volumeReadOnly:
            "volume is read-only"
        case .trashUnavailable:
            "no Trash on the volume"
        case .renameUnsupported:
            "no exclusive rename on the volume"
        case .other(let domain, let code, _):
            "\(domain) \(code)"
        }
    }
}

extension ProposedChange.Operation {
    /// The verb for a log line, without the names the operation carries.
    fileprivate var logVerb: String {
        switch self {
        case .moveToTrash:
            "trash"
        case .rename:
            "rename"
        case .move:
            "move"
        }
    }
}
