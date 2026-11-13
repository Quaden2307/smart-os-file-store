import Foundation
import os

/// Carries out the confirmed changes of a `CleanupPlan` by moving files to the Trash.
///
/// This is the only code in the engine that changes a user's disk, and its one means of removal is
/// `FileManager.trashItem`; nothing is ever deleted permanently. Each item is re-verified right
/// before it is moved: it is still a regular file directly inside the scanned folder, with the size
/// and modification date the scan saw and the content the plan grouped it by, and the group's kept
/// copy is still there with that same content. A file with the same identity as any kept copy is
/// refused, so whatever a plan or an interface sends, every group keeps at least one copy. Items
/// succeed, are skipped or fail one by one; the executor never throws.
public struct TrashExecutor: Sendable {
    /// Allowed difference between the scan's modification date and the one read back now. Two
    /// conversions of the same timestamp can differ by floating-point noise; a real change is
    /// caught by the content check regardless.
    public static let modificationDateTolerance: TimeInterval = 0.001

    public let hasher: ContentHasher

    /// A file modified more recently than this is still being written and is left alone.
    public let recentModificationWindow: TimeInterval

    private static let logger = Logger(subsystem: "com.quaden2307.FileStoreCore", category: "TrashExecutor")

    public init(
        hasher: ContentHasher = ContentHasher(),
        recentModificationWindow: TimeInterval = DuplicatePlanner.defaultRecentModificationWindow
    ) {
        self.hasher = hasher
        self.recentModificationWindow = recentModificationWindow
    }

    /// Moves the confirmed changes of `plan` to the Trash, in plan order.
    ///
    /// - Parameters:
    ///   - confirmedChangeIDs: The changes the user ticked. IDs that match nothing in the plan are
    ///     logged and ignored; nothing outside the plan is ever touched.
    ///   - now: The current time, for the "modified in the last few seconds" rule.
    ///   - onProgress: Called on the executing thread before the first item and after each one.
    /// - Returns: One result per confirmed change. If the task is cancelled, the items not yet
    ///   reached are reported as skipped and `wasCancelled` is set.
    @concurrent
    public func execute(
        plan: CleanupPlan,
        confirmedChangeIDs: Set<ProposedChange.ID>,
        now: Date = .now,
        onProgress: (@Sendable (CleanupExecutionProgress) -> Void)? = nil
    ) async -> CleanupResult {
        let clock = ContinuousClock()
        let start = clock.now

        // The checks in `process` are the duplicate action's. Another action must add its own
        // before it may use this executor; the switch is exhaustive on purpose.
        switch plan.action {
        case .findDuplicates:
            break
        }

        let confirmed = plan.changes.filter { confirmedChangeIDs.contains($0.id) }
        let unknown = confirmedChangeIDs.subtracting(plan.changes.map(\.id))
        if !unknown.isEmpty {
            Self.logger.error("Ignoring \(unknown.count) confirmed items that are not in the plan")
        }
        let context = PlanContext(plan: plan)

        var items: [CleanupItemResult] = []
        items.reserveCapacity(confirmed.count)
        var bytesFreed: Int64 = 0
        var wasCancelled = false
        onProgress?(CleanupExecutionProgress(itemsCompleted: 0, itemsTotal: confirmed.count, bytesFreed: 0))

        for change in confirmed {
            let outcome: CleanupItemOutcome
            if wasCancelled || Task.isCancelled {
                wasCancelled = true
                outcome = .skipped(.cancelled)
            } else {
                outcome = await process(change, context: context, now: now)
                if outcome == .skipped(.cancelled) {
                    wasCancelled = true
                }
            }
            if case .trashed = outcome {
                bytesFreed += change.sizeInBytes
            }
            items.append(CleanupItemResult(change: change, outcome: outcome))
            Self.log(change, outcome)
            onProgress?(
                CleanupExecutionProgress(itemsCompleted: items.count, itemsTotal: confirmed.count, bytesFreed: bytesFreed)
            )
        }

        let result = CleanupResult(action: plan.action, folderURL: plan.folderURL, items: items, wasCancelled: wasCancelled)
        let elapsed = clock.now - start
        let milliseconds = Double(elapsed.components.seconds) * 1_000
            + Double(elapsed.components.attoseconds) / 1e15
        Self.logger.info(
            "Trashed \(result.trashedCount) of \(confirmed.count) confirmed items (\(result.bytesFreed) bytes), \(result.skipped.count) skipped, \(result.failed.count) failed, cancelled: \(wasCancelled), in \(milliseconds, format: .fixed(precision: 1)) ms"
        )
        return result
    }

    // MARK: - One item

    /// One item, checked from the cheapest test to the dearest. The first failing check decides.
    private func process(_ change: ProposedChange, context: PlanContext, now: Date) async -> CleanupItemOutcome {
        guard let folderIdentity = context.folderIdentity else {
            return .skipped(.folderUnavailable)
        }
        switch change.operation {
        case .moveToTrash:
            break
        }

        // Membership: the plan's own data must propose exactly this change.
        let recordURL = change.record.url.standardizedFileURL
        guard let group = context.groupsByDuplicateURL[recordURL],
              group.fileSizeInBytes > 0,
              change.sizeInBytes == group.fileSizeInBytes else {
            return .skipped(.notInPlan)
        }
        if context.keptURLs.contains(recordURL) {
            return .skipped(.keptFile)
        }

        // Containment: act on `<folder>/<name>`, never on the plan's spelling of the path.
        guard let itemURL = Self.urlInsideFolder(recordURL, folderURL: context.folderURL, folderIdentity: folderIdentity),
              let keptURL = Self.urlInsideFolder(
                  group.kept.url.standardizedFileURL,
                  folderURL: context.folderURL,
                  folderIdentity: folderIdentity
              ) else {
            return .skipped(.outsideFolder)
        }
        let keptName = group.kept.displayName

        // The item as it is now.
        let status: FileStatus
        do throws(FileStatus.Failure) {
            status = try FileStatus.of(path: itemURL.path(percentEncoded: false))
        } catch {
            return .skipped(CleanupSkipReason(statusFailure: error))
        }
        guard status.isRegularFile, !status.isSymbolicLink else {
            return .skipped(.notARegularFile)
        }
        if status.isDataless {
            return .skipped(.notDownloaded)
        }
        if context.keptIdentities.contains(status.identity) {
            return .skipped(.keptFile)
        }

        // The kept copy must be there, and must not be this very file under another name.
        guard let keptStatus = try? FileStatus.of(path: keptURL.path(percentEncoded: false)),
              keptStatus.isRegularFile else {
            return .skipped(.keptFileMissing(name: keptName))
        }
        if keptStatus.identity == status.identity {
            return .skipped(.keptFile)
        }

        // Scope rules the planner applied; a plan built elsewhere must not get round them.
        if FileRecord.isInProgressDownload(itemURL) || status.isHidden || itemURL.lastPathComponent.hasPrefix(".") {
            return .skipped(.notInPlan)
        }
        guard status.sizeInBytes == change.sizeInBytes,
              let scannedDate = change.dateModified,
              abs(status.modificationDate.timeIntervalSince(scannedDate)) <= Self.modificationDateTolerance,
              now.timeIntervalSince(status.modificationDate) >= recentModificationWindow else {
            return .skipped(.changedSinceScan)
        }
        if status.isUserImmutable || status.isSystemImmutable {
            return .failed(.fileIsLocked)
        }

        // Content: the item still is a copy, and the kept file still holds the same bytes.
        do throws(ContentHashError) {
            let hash = try await hasher.hash(contentsOf: itemURL, expectedSizeInBytes: change.sizeInBytes)
            guard hash == group.contentHash else {
                return .skipped(.changedSinceScan)
            }
        } catch {
            guard let reason = CleanupSkipReason(hashError: error) else {
                return .skipped(.cancelled)
            }
            return .skipped(reason)
        }
        do throws(ContentHashError) {
            let keptHash = try await hasher.hash(contentsOf: keptURL, expectedSizeInBytes: group.fileSizeInBytes)
            guard keptHash == group.contentHash else {
                return .skipped(.keptFileNotVerified(name: keptName))
            }
        } catch {
            switch error {
            case .cancelled:
                return .skipped(.cancelled)
            case .fileNotFound:
                return .skipped(.keptFileMissing(name: keptName))
            case .accessDenied, .notARegularFile, .changedSinceScan, .notDownloaded, .readFailed:
                return .skipped(.keptFileNotVerified(name: keptName))
            }
        }

        if Task.isCancelled {
            return .skipped(.cancelled)
        }

        // Last look, after the reads and right before the move: the path must still hold the very
        // file that was just hashed, not something put in its place meanwhile.
        guard let finalStatus = try? FileStatus.of(path: itemURL.path(percentEncoded: false)),
              finalStatus.identity == status.identity,
              finalStatus.isRegularFile,
              finalStatus.sizeInBytes == status.sizeInBytes,
              finalStatus.modificationDate == status.modificationDate else {
            return .skipped(.changedSinceScan)
        }
        return Self.trash(itemURL)
    }

    /// The URL to act on for `standardizedURL`: the plan's folder plus the item's own name, once the
    /// item's parent has been confirmed to be that folder. `standardizedFileURL` removes `..`
    /// lexically while the kernel follows symbolic links first, so the plan's spelling is never
    /// handed to the file system; only `<folder>/<name>` is.
    private static func urlInsideFolder(_ standardizedURL: URL, folderURL: URL, folderIdentity: FileIdentity) -> URL? {
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

    /// The one place in the engine that removes anything from a folder, and it deletes nothing:
    /// the file goes to the Trash, from where the user can put it back.
    private static func trash(_ url: URL) -> CleanupItemOutcome {
        var trashURL: NSURL?
        do {
            try autoreleasepool {
                try FileManager.default.trashItem(at: url, resultingItemURL: &trashURL)
            }
        } catch {
            return outcome(trashError: error)
        }
        return .trashed(trashURL: trashURL.map { $0 as URL })
    }

    private static func outcome(trashError error: any Error) -> CleanupItemOutcome {
        if let cocoaError = error as? CocoaError {
            switch cocoaError.code {
            case .fileNoSuchFile, .fileReadNoSuchFile:
                return .skipped(.notFound)
            case .fileWriteNoPermission, .fileReadNoPermission:
                return .failed(.accessDenied)
            case .fileWriteVolumeReadOnly:
                return .failed(.volumeReadOnly)
            case .featureUnsupported:
                return .failed(.trashUnavailable)
            default:
                break
            }
            if let posixError = cocoaError.underlying as? POSIXError, let mapped = outcome(posixError: posixError) {
                return mapped
            }
        }
        if let posixError = error as? POSIXError, let mapped = outcome(posixError: posixError) {
            return mapped
        }
        let nsError = error as NSError
        return .failed(.other(domain: nsError.domain, code: nsError.code, description: error.localizedDescription))
    }

    private static func outcome(posixError error: POSIXError) -> CleanupItemOutcome? {
        switch error.code {
        case .ENOENT:
            .skipped(.notFound)
        case .EPERM, .EACCES:
            .failed(.accessDenied)
        case .EROFS:
            .failed(.volumeReadOnly)
        default:
            nil
        }
    }

    private static func log(_ change: ProposedChange, _ outcome: CleanupItemOutcome) {
        let path = change.record.url.path(percentEncoded: false)
        switch outcome {
        case .trashed(let trashURL):
            let destination = trashURL?.path(percentEncoded: false) ?? "an unreported location"
            logger.info("Trashed \(path, privacy: .private) to \(destination, privacy: .private)")
        case .skipped(let reason):
            logger.notice("Skipped \(path, privacy: .private): \(reason.logDescription, privacy: .public)")
        case .failed(let error):
            logger.error("Could not trash \(path, privacy: .private): \(error.logDescription, privacy: .public)")
        }
    }
}

/// What the executor needs from the plan, looked up once: the folder's identity, the kept files'
/// URLs and identities, and each duplicate's group.
private struct PlanContext: Sendable {
    let folderURL: URL

    /// Nil when the folder cannot be read or is not a folder; nothing is moved then.
    let folderIdentity: FileIdentity?

    /// Standardized URLs of every group's kept file.
    let keptURLs: Set<URL>

    /// Identities of every kept file that exists, read through the plan's own spelling of its path:
    /// whatever a plan names as kept must never be moved.
    let keptIdentities: Set<FileIdentity>

    /// Each duplicate's group, by standardized URL.
    let groupsByDuplicateURL: [URL: DuplicateGroup]

    init(plan: CleanupPlan) {
        folderURL = plan.folderURL
        let folderStatus = try? FileStatus.of(path: plan.folderURL.path(percentEncoded: false), followingLinks: true)
        folderIdentity = folderStatus?.isDirectory == true ? folderStatus?.identity : nil

        var keptURLs: Set<URL> = []
        var keptIdentities: Set<FileIdentity> = []
        var groups: [URL: DuplicateGroup] = [:]
        for group in plan.duplicateGroups {
            let keptURL = group.kept.url.standardizedFileURL
            keptURLs.insert(keptURL)
            if let status = try? FileStatus.of(path: keptURL.path(percentEncoded: false)) {
                keptIdentities.insert(status.identity)
            }
            for duplicate in group.duplicates {
                // A URL listed in two groups is checked against the first group's kept file; the
                // second group's kept file is protected through `keptURLs` and `keptIdentities`.
                let url = duplicate.url.standardizedFileURL
                if groups[url] == nil {
                    groups[url] = group
                }
            }
        }
        self.keptURLs = keptURLs
        self.keptIdentities = keptIdentities
        self.groupsByDuplicateURL = groups
    }
}

extension CleanupSkipReason {
    fileprivate init(statusFailure: FileStatus.Failure) {
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
        case .unreadable:
            "unreadable"
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
        case .other(let domain, let code, _):
            "\(domain) \(code)"
        }
    }
}
