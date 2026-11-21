import Foundation
import os

/// Plans Review Near-Duplicates: the regular files at the top level of the folder whose cleaned names
/// (`MessyNameCleaner`) are equal, extension included, but whose content differs, such as
/// `report.pdf` and `report (1).pdf` with different bytes.
///
/// It is a review list. Every file shown is a proposed move to the Trash that the preview leaves
/// unticked (`ProposedChange.Reason.isReviewOnly`), and no file is chosen to stay. Files with
/// identical content are duplicates, Find Duplicates' business: a group shows one file of each
/// distinct content and notes its identical copies, and a group with one distinct content is no
/// group. Folders, packages, links and the files the shared rules keep out (hidden, the archive,
/// downloads in progress, the grace period, Kept) take no part.
public struct NearDuplicatePlanner: Sendable {
    /// The rules every action shares, with the Kept list.
    public let eligibility: CandidateEligibility

    public let hasher: ContentHasher

    /// Hashes already read this session; a file whose hash is in it is not read again.
    public let hashCache: ContentHashCache

    private static let logger = Logger(subsystem: "com.quaden2307.FileStoreCore", category: "NearDuplicatePlanner")

    public init(
        eligibility: CandidateEligibility = CandidateEligibility(),
        hasher: ContentHasher = ContentHasher(),
        hashCache: ContentHashCache = ContentHashCache()
    ) {
        self.eligibility = eligibility
        self.hasher = hasher
        self.hashCache = hashCache
    }

    // MARK: - Pure functions

    /// The regular files directly inside `folderURL` that the shared rules allow at `now`.
    public func candidates(in records: [FileRecord], folder: ManagedFolder, now: Date) -> [FileRecord] {
        DuplicatePlanner.recordsDirectlyInside(folder.url, among: records).filter { record in
            record.kind == .file && eligibility.allows(record, in: folder, now: now)
        }
    }

    /// `name` cleaned, as the volume compares it: the key files are grouped by.
    public static func nameKey(_ name: String, caseSensitive: Bool) -> String {
        MessyNamePlanner.comparisonKey(MessyNameCleaner.clean(name)?.name ?? name, caseSensitive: caseSensitive)
    }

    /// Groups of two or more records whose cleaned names are equal, in name order within each group.
    /// Only these are hashed; a file whose cleaned name no other file has cannot be in a group.
    public static func nameGroups(of records: [FileRecord], caseSensitive: Bool) -> [[FileRecord]] {
        Dictionary(grouping: records) { nameKey($0.displayName, caseSensitive: caseSensitive) }
            .values
            .filter { $0.count >= 2 }
            .map { $0.sorted(by: nameOrder) }
            .sorted { lhs, rhs in
                guard let left = lhs.first, let right = rhs.first else { return lhs.count < rhs.count }
                return nameOrder(left, right)
            }
    }

    /// Builds the plan from name groups whose hashes are known. A record missing from `hashes` takes
    /// no part (the driver lists it as not checked). Pure: nothing here touches the disk.
    public static func makePlan(
        folder: ManagedFolder,
        nameGroups: [[FileRecord]],
        hashes: [FileRecord.ID: ContentHash],
        skippedItems: [CleanupPlan.SkippedItem] = []
    ) -> CleanupPlan {
        var groups: [NearDuplicateGroup] = []
        for nameGroup in nameGroups {
            var byHash: [ContentHash: [FileRecord]] = [:]
            for record in nameGroup {
                guard let hash = hashes[record.id] else { continue }
                byHash[hash, default: []].append(record)
            }
            guard byHash.count >= 2 else { continue }
            let members = byHash.compactMap { hash, records -> NearDuplicateGroup.Member? in
                // The file Find Duplicates would keep stands for its identical copies.
                guard let shown = DuplicatePlanner.keptFile(among: records) else { return nil }
                return NearDuplicateGroup.Member(
                    record: shown,
                    contentHash: hash,
                    identicalCopies: records.filter { $0.id != shown.id }.sorted(by: nameOrder)
                )
            }
            .sorted { nameOrder($0.record, $1.record) }
            guard let first = members.first?.record.displayName else { continue }
            groups.append(NearDuplicateGroup(cleanedName: MessyNameCleaner.clean(first)?.name ?? first, members: members))
        }

        let changes = groups.flatMap { group in
            group.members.map { member in
                let other = group.members.first { $0.id != member.id } ?? member
                return ProposedChange(
                    record: member.record,
                    operation: .moveToTrash,
                    reason: .nearDuplicate(sameNameAs: other.record.displayName)
                )
            }
        }
        let sortedSkips = skippedItems.sorted {
            $0.url.lastPathComponent.localizedStandardCompare($1.url.lastPathComponent) == .orderedAscending
        }
        return CleanupPlan(
            action: .reviewNearDuplicates,
            folder: folder,
            changes: changes,
            nearDuplicateGroups: groups,
            skippedItems: sortedSkips
        )
    }

    // MARK: - Driver

    /// Plans the review list for `records`, from one scan of `folderURL`, at `now`. Reads only: the
    /// volume's letter-case rule, and the content of the files in a name group, each at most once,
    /// and not at all when this session's cache already has its hash.
    ///
    /// - Throws: `.cancelled` when the task is cancelled.
    @concurrent
    public func plan(
        records: [FileRecord],
        in folder: ManagedFolder,
        now: Date = .now
    ) async throws(CleanupPlanningError) -> CleanupPlan {
        let folderURL = folder.url
        // Unknown counts as not case-sensitive: more names match, so more files are shown, never fewer.
        let values = try? folderURL.resourceValues(forKeys: [.volumeSupportsCaseSensitiveNamesKey])
        let caseSensitive = values?.volumeSupportsCaseSensitiveNames ?? false
        let groups = Self.nameGroups(
            of: DuplicatePlanner.distinctFiles(candidates(in: records, folder: folder, now: now)),
            caseSensitive: caseSensitive
        )

        var hashes: [FileRecord.ID: ContentHash] = [:]
        var skippedItems: [CleanupPlan.SkippedItem] = []
        var hashedCount = 0
        // shortcut: one file at a time and no progress count, as Fix Messy Names; read in parallel with
        // progress like Find Duplicates if large same-named downloads make this slow in practice.
        for record in groups.joined() {
            if Task.isCancelled {
                throw .cancelled
            }
            if let known = hashCache.hash(for: record) {
                hashes[record.id] = known
                continue
            }
            do throws(ContentHashError) {
                if record.isDataless {
                    throw .notDownloaded(record.url)
                }
                let hash = try await hasher.hash(contentsOf: record.url, expectedSizeInBytes: record.sizeInBytes)
                hashes[record.id] = hash
                hashCache.store(hash, for: record)
                hashedCount += 1
            } catch {
                guard let reason = CleanupSkipReason(hashError: error) else {
                    throw .cancelled
                }
                skippedItems.append(CleanupPlan.SkippedItem(url: record.url, reason: reason))
            }
        }
        if Task.isCancelled {
            throw .cancelled
        }

        let plan = Self.makePlan(folder: folder, nameGroups: groups, hashes: hashes, skippedItems: skippedItems)
        Self.logger.info(
            "\(groups.count) name groups; read \(hashedCount) files; \(plan.nearDuplicateGroups.count) near-duplicate groups, \(plan.changes.count) files, \(plan.skippedItems.count) skipped"
        )
        return plan
    }

    // MARK: - Helpers

    /// Finder-like name order, with the path as a last resort so the order is total.
    private static func nameOrder(_ lhs: FileRecord, _ rhs: FileRecord) -> Bool {
        switch lhs.displayName.localizedStandardCompare(rhs.displayName) {
        case .orderedAscending:
            true
        case .orderedDescending:
            false
        case .orderedSame:
            lhs.url.path(percentEncoded: false) < rhs.url.path(percentEncoded: false)
        }
    }
}
