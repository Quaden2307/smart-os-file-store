import Foundation
import os

/// Plans Fix Messy Names: a clean name (`MessyNameCleaner`) for each regular file at the top level
/// of the folder whose name has copy numbers or leftover junk, never one that is taken.
///
/// - When the clean name is free, it is proposed. When several files want it, the oldest gets it.
/// - When a file with identical content has it, nothing is proposed: that is a duplicate, which
///   Find Duplicates handles.
/// - Otherwise the file's date is added, `report 2026-11-13.pdf`, then ` v2`, ` v3` and so on until
///   the name is free. A file with no date, or whose dated name would be too long, is listed as not
///   checked (`invalidName`) rather than dropped without a word.
///
/// Names are compared the way the volume compares them: in any letter case unless the volume is
/// case-sensitive, and in any Unicode form, as APFS does. Every name in the scan counts as taken,
/// and so does every name the plan gives, so no two changes share a destination and none relies on
/// another file being renamed first. Folders, packages, links and the files the shared rules keep
/// out (hidden, the archive, downloads in progress, the grace period, Kept) are never proposed.
public struct MessyNamePlanner: Sendable {
    /// A file that could be renamed, and its clean name.
    public struct Candidate: Sendable, Hashable {
        public let record: FileRecord
        public let cleaned: MessyNameCleaner.Cleaned

        public init(record: FileRecord, cleaned: MessyNameCleaner.Cleaned) {
            self.record = record
            self.cleaned = cleaned
        }
    }

    /// The rules every action shares, with the Kept list.
    public let eligibility: CandidateEligibility

    public let hasher: ContentHasher

    private static let logger = Logger(subsystem: "com.quaden2307.FileStoreCore", category: "MessyNamePlanner")

    public init(eligibility: CandidateEligibility = CandidateEligibility(), hasher: ContentHasher = ContentHasher()) {
        self.eligibility = eligibility
        self.hasher = hasher
    }

    // MARK: - Pure functions

    /// The regular files directly inside `folderURL` that the shared rules allow at `now` and whose
    /// names the cleaner changes.
    public func candidates(in records: [FileRecord], folderURL: URL, now: Date) -> [Candidate] {
        DuplicatePlanner.recordsDirectlyInside(folderURL, among: records).compactMap { record in
            guard record.kind == .file, eligibility.allows(record, now: now),
                  let cleaned = MessyNameCleaner.clean(record.displayName) else {
                return nil
            }
            return Candidate(record: record, cleaned: cleaned)
        }
    }

    /// `name` as the volume compares it: folded to one letter case unless the volume is
    /// case-sensitive. Swift compares strings in any Unicode form already.
    public static func comparisonKey(_ name: String, caseSensitive: Bool) -> String {
        caseSensitive ? name : name.folding(options: .caseInsensitive, locale: nil)
    }

    /// Builds the plan. Pure: nothing here touches the disk.
    ///
    /// - Parameters:
    ///   - records: The whole scan: every name in it is taken.
    ///   - identicalTakers: Candidates whose clean name belongs to a file with identical content.
    ///   - skippedItems: Candidates that could not be compared with the file that has their clean name.
    ///   - caseSensitive: Whether the volume tells names apart by letter case.
    ///   - timeZone: The time zone the added date is written in.
    public static func makePlan(
        folderURL: URL,
        records: [FileRecord],
        candidates: [Candidate],
        identicalTakers: Set<FileRecord.ID> = [],
        skippedItems: [CleanupPlan.SkippedItem] = [],
        caseSensitive: Bool,
        timeZone: TimeZone
    ) -> CleanupPlan {
        func key(_ name: String) -> String {
            comparisonKey(name, caseSensitive: caseSensitive)
        }
        var taken = Set(records.map { key($0.displayName) })
        var skippedItems = skippedItems
        let skippedURLs = Set(skippedItems.map(\.url))
        let remaining = candidates
            .filter { !identicalTakers.contains($0.record.id) && !skippedURLs.contains($0.record.url) }
            .sorted { isOlder($0.record, $1.record) }

        // Clean names first, oldest first, so a later file never takes one from an older file.
        var changes: [ProposedChange] = []
        var needsDate: [Candidate] = []
        for candidate in remaining {
            if taken.insert(key(candidate.cleaned.name)).inserted {
                changes.append(change(candidate, to: candidate.cleaned.name, takenName: nil))
            } else {
                needsDate.append(candidate)
            }
        }

        // Then the date, and a number if that is taken too.
        for candidate in needsDate {
            if let name = datedName(for: candidate, timeZone: timeZone, takenCount: taken.count, isFree: { !taken.contains(key($0)) }) {
                taken.insert(key(name))
                changes.append(change(candidate, to: name, takenName: candidate.cleaned.name))
            } else {
                skippedItems.append(CleanupPlan.SkippedItem(url: candidate.record.url, reason: .invalidName))
            }
        }

        changes.sort { nameOrder($0.record, $1.record) }
        let sortedSkips = skippedItems.sorted {
            $0.url.lastPathComponent.localizedStandardCompare($1.url.lastPathComponent) == .orderedAscending
        }
        return CleanupPlan(action: .fixMessyNames, folderURL: folderURL, changes: changes, skippedItems: sortedSkips)
    }

    // MARK: - Driver

    /// Plans the renames for `records`, from one scan of `folderURL`, at `now`. Reads only: the
    /// volume's letter-case rule, and the content of a candidate and of the file that has its clean
    /// name when the two are the same size, to tell a duplicate from a different file.
    ///
    /// - Throws: `.cancelled` when the task is cancelled.
    @concurrent
    public func plan(
        records: [FileRecord],
        in folderURL: URL,
        now: Date = .now,
        timeZone: TimeZone = .current
    ) async throws(CleanupPlanningError) -> CleanupPlan {
        let candidates = candidates(in: records, folderURL: folderURL, now: now)
        // Unknown counts as not case-sensitive: more names clash, never fewer.
        let values = try? folderURL.resourceValues(forKeys: [.volumeSupportsCaseSensitiveNamesKey])
        let caseSensitive = values?.volumeSupportsCaseSensitiveNames ?? false

        let byName = Dictionary(
            records.map { (Self.comparisonKey($0.displayName, caseSensitive: caseSensitive), $0) },
            uniquingKeysWith: { first, _ in first }
        )

        var hashes: [URL: Result<ContentHash, ContentHashError>] = [:]
        var identical: Set<FileRecord.ID> = []
        var skippedItems: [CleanupPlan.SkippedItem] = []
        for candidate in candidates {
            guard let taker = byName[Self.comparisonKey(candidate.cleaned.name, caseSensitive: caseSensitive)],
                  taker.kind == .file,
                  let size = candidate.record.sizeInBytes, size > 0, taker.sizeInBytes == size else {
                continue
            }
            do throws(ContentHashError) {
                let mine = try await hash(candidate.record, cache: &hashes)
                let theirs = try await hash(taker, cache: &hashes)
                if mine == theirs {
                    identical.insert(candidate.record.id)
                }
            } catch {
                guard let reason = CleanupSkipReason(hashError: error) else {
                    throw .cancelled
                }
                skippedItems.append(CleanupPlan.SkippedItem(url: candidate.record.url, reason: reason))
            }
        }
        if Task.isCancelled {
            throw .cancelled
        }

        let plan = Self.makePlan(
            folderURL: folderURL,
            records: records,
            candidates: candidates,
            identicalTakers: identical,
            skippedItems: skippedItems,
            caseSensitive: caseSensitive,
            timeZone: timeZone
        )
        Self.logger.info(
            "\(candidates.count) messy names; \(identical.count) duplicates left to Find Duplicates, \(plan.changes.count) renames, \(plan.skippedItems.count) skipped"
        )
        return plan
    }

    // MARK: - Helpers

    /// The first free name of `<clean stem> YYYY-MM-DD<ext>`, then ` v2`, ` v3`…, or nil when the file
    /// has no date or the name would be too long. One more try than names taken always finds a free one.
    private static func datedName(for candidate: Candidate, timeZone: TimeZone, takenCount: Int, isFree: (String) -> Bool) -> String? {
        guard let date = candidate.record.dateAdded ?? candidate.record.dateModified else {
            return nil
        }
        let (stem, pathExtension) = MessyNameCleaner.parts(of: candidate.cleaned.name)
        let dated = "\(stem) \(date.formatted(Date.ISO8601FormatStyle(timeZone: timeZone).year().month().day().dateSeparator(.dash)))"
        for number in 1...(takenCount + 1) {
            let name = (number == 1 ? dated : "\(dated) v\(number)") + pathExtension
            guard FileNameRules.isAllowedFileName(name, maximumLength: FileNameRules.defaultMaximumLength) else {
                return nil
            }
            if isFree(name) {
                return name
            }
        }
        return nil
    }

    /// A file's hash, or why it could not be read, each read at most once per plan.
    private func hash(
        _ record: FileRecord,
        cache: inout [URL: Result<ContentHash, ContentHashError>]
    ) async throws(ContentHashError) -> ContentHash {
        if let known = cache[record.url] {
            return try known.get()
        }
        do throws(ContentHashError) {
            let hash = try await hasher.hash(contentsOf: record.url, expectedSizeInBytes: record.sizeInBytes)
            cache[record.url] = .success(hash)
            return hash
        } catch {
            if error != .cancelled {
                cache[record.url] = .failure(error)
            }
            throw error
        }
    }

    private static func change(_ candidate: Candidate, to name: String, takenName: String?) -> ProposedChange {
        ProposedChange(
            record: candidate.record,
            operation: .rename(to: name),
            reason: .messyName(MessyNameFix(fixes: candidate.cleaned.fixes, takenName: takenName))
        )
    }

    /// Oldest by Date Added (Date Modified when it is missing; a file with neither sorts last), then
    /// by name, so the answer never depends on input order.
    private static func isOlder(_ lhs: FileRecord, _ rhs: FileRecord) -> Bool {
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
            true
        case .orderedDescending:
            false
        case .orderedSame:
            lhs.url.path(percentEncoded: false) < rhs.url.path(percentEncoded: false)
        }
    }
}
