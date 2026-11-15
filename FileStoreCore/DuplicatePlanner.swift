import Foundation
import os
import Synchronization

/// Why a duplicate search produced no plan.
public enum DuplicatePlanError: Error, Sendable, Hashable {
    /// The task running the search was cancelled before it finished.
    case cancelled
}

/// Finds files with identical content and plans which copies to send to the Trash.
///
/// Grouping and the keep rule are pure functions over records and hashes, so they are tested
/// without a disk. Only `plan(records:in:now:onProgress:)` reads files, and it reads only:
/// nothing here moves, renames or removes anything.
public struct DuplicatePlanner: Sendable {
    /// Files hashed at the same time. Enough to keep an SSD busy without saturating it.
    public static let defaultMaxConcurrentHashes = 4

    public let hasher: ContentHasher
    public let maxConcurrentHashes: Int

    /// The rules every action shares, the grace period among them.
    public let eligibility: CandidateEligibility

    private static let logger = Logger(subsystem: "com.quaden2307.FileStoreCore", category: "DuplicatePlanner")

    public init(
        hasher: ContentHasher = ContentHasher(),
        maxConcurrentHashes: Int = Self.defaultMaxConcurrentHashes,
        eligibility: CandidateEligibility = CandidateEligibility()
    ) {
        self.hasher = hasher
        self.maxConcurrentHashes = max(1, maxConcurrentHashes)
        self.eligibility = eligibility
    }

    // MARK: - Pure functions

    /// The records that may take part at all: those the shared rules allow at `now` (see
    /// `CandidateEligibility.allows`: not hidden, not the archive, not still downloading, past the
    /// grace period), and of those only regular files with content. Folders, packages, symbolic
    /// links and empty files are never candidates. A file the user marked Kept takes part too, but
    /// only ever as the copy its group keeps (`makePlan`); it is never proposed.
    public func candidates(in records: [FileRecord], now: Date) -> [FileRecord] {
        records.filter { record in
            guard record.kind == .file, let size = record.sizeInBytes, size > 0 else { return false }
            switch eligibility.refusal(for: record, now: now) {
            case nil, .kept:
                return true
            case .excludedName, .downloadInProgress, .insideGracePeriod:
                return false
            }
        }
    }

    /// Groups of two or more records that share a size, smallest size first. Only these need
    /// hashing; a file with a unique size cannot have a duplicate.
    public static func sizeGroups(of records: [FileRecord]) -> [[FileRecord]] {
        var bySize: [Int64: [FileRecord]] = [:]
        for record in records {
            guard let size = record.sizeInBytes else { continue }
            bySize[size, default: []].append(record)
        }
        return bySize
            .sorted { $0.key < $1.key }
            .map(\.value)
            .filter { $0.count >= 2 }
    }

    /// The file to keep out of records with identical content: a name without a copy suffix
    /// first, then the oldest by Date Added (Date Modified when Date Added is missing; a file with
    /// neither date sorts last), then the name, so the answer never depends on input order.
    public static func keptFile(among records: [FileRecord]) -> FileRecord? {
        records.min(by: keepsBefore)
    }

    /// Builds the plan from records whose hashes are known. Records missing from `hashes` are
    /// ignored. Pure: nothing here touches the disk.
    ///
    /// A file in `keptItems` is never proposed. When a group has one, that copy is the one kept,
    /// whatever its name; with several, the keep rule picks among them. A group in which every copy
    /// is Kept proposes nothing and is left out.
    public static func makePlan(
        folderURL: URL,
        records: [FileRecord],
        hashes: [FileRecord.ID: ContentHash],
        keptItems: KeptItems,
        skippedItems: [CleanupPlan.SkippedItem] = []
    ) -> CleanupPlan {
        var byHash: [ContentHash: [FileRecord]] = [:]
        for record in records {
            guard let hash = hashes[record.id] else { continue }
            byHash[hash, default: []].append(record)
        }

        var groups: [DuplicateGroup] = []
        for (hash, members) in byHash where members.count >= 2 {
            let markedKept = members.filter(keptItems.contains)
            guard let kept = keptFile(among: markedKept.isEmpty ? members : markedKept) else { continue }
            let duplicates = members
                .filter { $0.id != kept.id && !keptItems.contains($0) }
                .sorted(by: nameOrder)
            guard !duplicates.isEmpty else { continue }
            groups.append(
                DuplicateGroup(
                    contentHash: hash,
                    kept: kept,
                    duplicates: duplicates,
                    fileSizeInBytes: kept.sizeInBytes ?? 0
                )
            )
        }
        groups.sort { lhs, rhs in
            if lhs.reclaimableBytes != rhs.reclaimableBytes {
                return lhs.reclaimableBytes > rhs.reclaimableBytes
            }
            return nameOrder(lhs.kept, rhs.kept)
        }

        let changes = groups.flatMap { group in
            group.duplicates.map { duplicate in
                ProposedChange(
                    record: duplicate,
                    operation: .moveToTrash,
                    reason: .sameContent(asFileNamed: group.kept.displayName)
                )
            }
        }
        let sortedSkips = skippedItems.sorted {
            $0.url.path(percentEncoded: false) < $1.url.path(percentEncoded: false)
        }
        return CleanupPlan(
            action: .findDuplicates,
            folderURL: folderURL,
            changes: changes,
            duplicateGroups: groups,
            skippedItems: sortedSkips
        )
    }

    // MARK: - Driver

    /// Plans the duplicates among `records`, which should come from one scan of `folderURL`.
    ///
    /// Candidates are grouped by size, files sharing a size are hashed a few at a time, and the
    /// pure functions above turn the hashes into a plan. A file that cannot be hashed is reported
    /// in `skippedItems`; it never fails the search.
    ///
    /// - Parameter onProgress: Called from hashing threads, at most every 100 ms plus once at the
    ///   end. It must return quickly.
    /// - Throws: `.cancelled` when the task is cancelled.
    @concurrent
    public func plan(
        records: [FileRecord],
        in folderURL: URL,
        now: Date = .now,
        onProgress: (@Sendable (DuplicateScanProgress) -> Void)? = nil
    ) async throws(DuplicatePlanError) -> CleanupPlan {
        let clock = ContinuousClock()
        let start = clock.now

        try Self.throwIfCancelled()

        let candidates = Self.distinctFiles(candidates(in: Self.recordsDirectlyInside(folderURL, among: records), now: now))
        let toHash = Self.sizeGroups(of: candidates).flatMap { $0 }
        let bytesToHash = toHash.reduce(Int64(0)) { $0 + ($1.sizeInBytes ?? 0) }
        let tracker = ProgressTracker(filesToHash: toHash.count, bytesToHash: bytesToHash, onProgress: onProgress)
        tracker.emitNow()
        Self.logger.info(
            "\(candidates.count) of \(records.count) records are candidates; hashing \(toHash.count) files sharing a size, \(bytesToHash) bytes"
        )

        let hasher = hasher
        let width = maxConcurrentHashes
        let (hashes, skippedItems, sawCancelledHash) = await withTaskGroup(
            of: HashOutcome.self,
            returning: ([FileRecord.ID: ContentHash], [CleanupPlan.SkippedItem], Bool).self
        ) { group in
            var hashes: [FileRecord.ID: ContentHash] = [:]
            var skippedItems: [CleanupPlan.SkippedItem] = []
            var sawCancelledHash = false
            func collect(_ outcome: HashOutcome) {
                switch outcome {
                case .hashed(let id, let hash):
                    hashes[id] = hash
                case .skipped(let item):
                    skippedItems.append(item)
                case .cancelled:
                    sawCancelledHash = true
                }
            }

            var running = 0
            for record in toHash {
                if Task.isCancelled {
                    group.cancelAll()
                    break
                }
                if running >= width, let outcome = await group.next() {
                    running -= 1
                    collect(outcome)
                }
                group.addTask {
                    await Self.hashOne(record, hasher: hasher, tracker: tracker)
                }
                running += 1
            }
            while let outcome = await group.next() {
                collect(outcome)
            }
            return (hashes, skippedItems, sawCancelledHash)
        }

        // A hash stops early only when its task was cancelled, normally because this whole search
        // was. If only a hashing task was cancelled, the plan would be missing a file without
        // saying so, so the search reports cancelled rather than returning an incomplete plan.
        if sawCancelledHash {
            throw .cancelled
        }
        try Self.throwIfCancelled()
        tracker.emitNow()

        // A Kept file that could not be read is left out of the plan altogether, not listed as
        // unchecked: no plan ever names a Kept file except as the copy a group keeps.
        let keptURLs = Set(toHash.filter(eligibility.keptItems.contains).map(\.url))
        let plan = Self.makePlan(
            folderURL: folderURL,
            records: toHash,
            hashes: hashes,
            keptItems: eligibility.keptItems,
            skippedItems: skippedItems.filter { !keptURLs.contains($0.url) }
        )

        Self.logger.info(
            "Planned \(plan.duplicateGroups.count) duplicate groups, \(plan.changes.count) changes, \(plan.skippedItems.count) skipped, in \((clock.now - start).milliseconds, format: .fixed(precision: 1)) ms"
        )
        return plan
    }

    // MARK: - Helpers

    /// The records that sit directly inside `folderURL`. The scanner lists only those, so for its
    /// records this changes nothing; a record built elsewhere must not widen the search to a file
    /// outside the folder. (Hidden names are the shared rules' business; see `candidates`.)
    static func recordsDirectlyInside(_ folderURL: URL, among records: [FileRecord]) -> [FileRecord] {
        let folder = folderURL.standardizedFileURL
        let folderComponents = folder.pathComponents
        // A directory listing spells its entries with symbolic links resolved (`/private/var/…` for
        // a folder given as `/var/…`), so the folder's resolved spelling is accepted as well. Only a
        // record that matches neither is resolved itself.
        let resolvedFolderComponents = folder.resolvingSymlinksInPath().pathComponents
        return records.filter { record in
            let standardized = record.url.standardizedFileURL
            let parentComponents = Array(standardized.pathComponents.dropLast())
            if parentComponents == folderComponents || parentComponents == resolvedFolderComponents {
                return true
            }
            return standardized.deletingLastPathComponent().resolvingSymlinksInPath().pathComponents
                == resolvedFolderComponents
        }
    }

    /// One record per file on disk. Two names for one file (hard links) hold the same bytes by
    /// definition: they are not duplicates of each other and moving one would free nothing, so the
    /// name the keep rule prefers stands for them all. A record whose file cannot be read now is
    /// kept, so that the hash step reports it.
    static func distinctFiles(_ records: [FileRecord]) -> [FileRecord] {
        var chosen: [FileIdentity: FileRecord] = [:]
        var identities: [FileIdentity] = []
        var unidentified: [FileRecord] = []
        for record in records {
            guard let status = try? FileStatus.of(path: record.url.path(percentEncoded: false)) else {
                unidentified.append(record)
                continue
            }
            if let current = chosen[status.identity] {
                if keepsBefore(record, current) {
                    chosen[status.identity] = record
                }
            } else {
                chosen[status.identity] = record
                identities.append(status.identity)
            }
        }
        return identities.compactMap { chosen[$0] } + unidentified
    }

    private enum HashOutcome: Sendable {
        case hashed(FileRecord.ID, ContentHash)
        case skipped(CleanupPlan.SkippedItem)
        case cancelled
    }

    private static func hashOne(
        _ record: FileRecord,
        hasher: ContentHasher,
        tracker: ProgressTracker
    ) async -> HashOutcome {
        let bytesSeen = ByteCount()
        let expectedBytes = record.sizeInBytes ?? 0
        do throws(ContentHashError) {
            let hash = try await hasher.hash(contentsOf: record.url, expectedSizeInBytes: record.sizeInBytes) { count in
                bytesSeen.add(count)
                tracker.addBytes(count)
            }
            tracker.fileFinished(unaccountedBytes: expectedBytes - bytesSeen.total)
            return .hashed(record.id, hash)
        } catch {
            guard let reason = CleanupSkipReason(hashError: error) else {
                return .cancelled
            }
            tracker.fileFinished(unaccountedBytes: expectedBytes - bytesSeen.total)
            return .skipped(CleanupPlan.SkippedItem(url: record.url, reason: reason))
        }
    }

    private static func keepsBefore(_ lhs: FileRecord, _ rhs: FileRecord) -> Bool {
        let lhsSuffixed = FileNameCopySuffix.hasCopySuffix(lhs.displayName)
        let rhsSuffixed = FileNameCopySuffix.hasCopySuffix(rhs.displayName)
        if lhsSuffixed != rhsSuffixed {
            return !lhsSuffixed
        }
        let lhsDate = lhs.dateAdded ?? lhs.dateModified ?? .distantFuture
        let rhsDate = rhs.dateAdded ?? rhs.dateModified ?? .distantFuture
        if lhsDate != rhsDate {
            return lhsDate < rhsDate
        }
        return nameOrder(lhs, rhs)
    }

    /// Finder-like name order, with the path as a last resort so the order is total.
    private static func nameOrder(_ lhs: FileRecord, _ rhs: FileRecord) -> Bool {
        switch lhs.displayName.localizedStandardCompare(rhs.displayName) {
        case .orderedAscending:
            return true
        case .orderedDescending:
            return false
        case .orderedSame:
            return lhs.url.path(percentEncoded: false) < rhs.url.path(percentEncoded: false)
        }
    }

    /// Typed-throws stand-in for `Task.checkCancellation()`, which throws `CancellationError`.
    private static func throwIfCancelled() throws(DuplicatePlanError) {
        if Task.isCancelled {
            throw .cancelled
        }
    }
}

/// Bytes one hashing task has reported so far.
private final class ByteCount: Sendable {
    private let value = Mutex<Int64>(0)

    func add(_ count: Int) {
        value.withLock { $0 += Int64(count) }
    }

    var total: Int64 {
        value.withLock { $0 }
    }
}

/// Collects progress from every hashing task and forwards it, rate-limited, to the caller.
private final class ProgressTracker: Sendable {
    private struct State {
        var filesHashed = 0
        var bytesHashed: Int64 = 0
        var lastEmit: ContinuousClock.Instant?
    }

    /// Updates closer together than this are dropped, except the forced first and last ones.
    static let minimumInterval: Duration = .milliseconds(100)

    private let filesToHash: Int
    private let bytesToHash: Int64
    private let onProgress: (@Sendable (DuplicateScanProgress) -> Void)?
    private let state = Mutex(State())
    private let clock = ContinuousClock()

    init(filesToHash: Int, bytesToHash: Int64, onProgress: (@Sendable (DuplicateScanProgress) -> Void)?) {
        self.filesToHash = filesToHash
        self.bytesToHash = bytesToHash
        self.onProgress = onProgress
    }

    func addBytes(_ count: Int) {
        update(force: false) { $0.bytesHashed += Int64(count) }
    }

    /// Counts a finished file. `unaccountedBytes` are bytes that were never read, for example
    /// because the file had to be skipped, so the totals still line up at the end.
    func fileFinished(unaccountedBytes: Int64) {
        update(force: false) {
            $0.filesHashed += 1
            $0.bytesHashed += max(0, unaccountedBytes)
        }
    }

    func emitNow() {
        update(force: true) { _ in }
    }

    /// The callback runs under the lock on purpose: progress values then reach the caller in the
    /// order they were produced, and the callback is documented as quick.
    private func update(force: Bool, _ change: (inout State) -> Void) {
        guard let onProgress else { return }
        state.withLock { state in
            change(&state)
            let now = clock.now
            if !force, let last = state.lastEmit, now - last < Self.minimumInterval {
                return
            }
            state.lastEmit = now
            onProgress(
                DuplicateScanProgress(
                    filesHashed: state.filesHashed,
                    filesToHash: filesToHash,
                    bytesHashed: state.bytesHashed,
                    bytesToHash: bytesToHash
                )
            )
        }
    }
}
