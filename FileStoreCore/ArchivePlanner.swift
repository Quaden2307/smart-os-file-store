import Foundation
import os

/// Plans Archive Old Downloads: the regular files at the top level of the folder that carry the
/// Never opened or Unused mark (`FileMarker`, with the same settings as the file list, so the list
/// and the action never disagree) move into the archive folder, "Old downloads", under their own
/// name. The folder is made by the first move.
///
/// When the archive already has the name, as the volume compares names: a file there with exactly
/// the same bytes means this copy goes to the Trash instead (`alreadyArchived`); anything else
/// means the file is filed under its name with its Date Added (`report 2025-01-01.pdf`), then
/// ` v2` and so on. Folders, packages, links and the files the shared rules keep out (hidden, the
/// archive itself, downloads in progress, the grace period, Kept) take no part. Files another action
/// would trash stay candidates: resolving overlap is Tidy Now's job.
public struct ArchivePlanner: Sendable {
    /// The rules every action shares, with the Kept list.
    public let eligibility: CandidateEligibility

    /// The thresholds behind the Never opened and Unused marks.
    public let settings: CleanupSettings

    public let hasher: ContentHasher

    /// Content hashes read earlier in this session, for the folder's own files only: read from and
    /// added to. The executor hashes both copies again before it trashes one.
    public let hashCache: ContentHashCache?

    static let logger = Logger(subsystem: "com.quaden2307.FileStoreCore", category: "ArchivePlanner")

    public init(
        eligibility: CandidateEligibility = CandidateEligibility(),
        settings: CleanupSettings = CleanupSettings(),
        hasher: ContentHasher = ContentHasher(),
        hashCache: ContentHashCache? = nil
    ) {
        self.eligibility = eligibility
        self.settings = settings
        self.hasher = hasher
        self.hashCache = hashCache
    }

    /// The archive folder inside `folderURL`.
    public static func archiveURL(in folderURL: URL) -> URL {
        folderURL.appending(path: CandidateEligibility.archiveFolderName, directoryHint: .isDirectory)
    }

    // MARK: - Pure functions

    /// The regular files directly inside `folderURL` that the shared rules allow at `now` and that
    /// are marked Never opened or Unused.
    public func candidates(in records: [FileRecord], folderURL: URL, now: Date) -> [FileRecord] {
        DuplicatePlanner.recordsDirectlyInside(folderURL, among: records).filter { record in
            guard record.kind == .file, eligibility.allows(record, now: now) else {
                return false
            }
            let marks = FileMarker.marks(for: record, now: now, settings: settings, eligibility: eligibility)
            return marks.contains(.neverOpened) || marks.contains(.unused)
        }
    }

    /// Builds the plan for `candidates` from what the archive holds. Pure: nothing here touches the
    /// disk.
    ///
    /// - Parameters:
    ///   - hashes: The content hashes of candidates whose name and size a regular file in the
    ///     archive has. A candidate missing from it is treated as different from that file.
    ///   - caseSensitive: Whether the volume tells names apart by letter case.
    ///   - timeZone: The time zone a Date Added is written in for a name that is taken.
    public static func makePlan(
        folderURL: URL,
        candidates: [FileRecord],
        archive: ArchiveListing,
        hashes: [FileRecord.ID: ContentHash] = [:],
        skippedItems: [CleanupPlan.SkippedItem] = [],
        caseSensitive: Bool,
        timeZone: TimeZone
    ) -> CleanupPlan {
        if let problem = archive.problem {
            return CleanupPlan(action: .archiveOldDownloads, folderURL: folderURL, changes: [], archiveProblem: problem)
        }
        func key(_ name: String) -> String {
            MessyNamePlanner.comparisonKey(name, caseSensitive: caseSensitive)
        }
        let archiveURL = archiveURL(in: folderURL)
        let entriesByKey = Dictionary(archive.entries.map { (key($0.name), $0) }, uniquingKeysWith: { first, _ in first })
        var taken = Set(entriesByKey.keys)
        var skippedItems = skippedItems
        let skippedURLs = Set(skippedItems.map(\.url))
        let remaining = candidates.filter { !skippedURLs.contains($0.url) }.sorted(by: nameOrder)

        // Own names first, so a file never loses its name to a dated one; then the dates.
        var changes: [ProposedChange] = []
        var needsDate: [FileRecord] = []
        for record in remaining {
            guard let reason = reason(for: record) else { continue }
            let name = record.displayName
            if let entry = entriesByKey[key(name)] {
                if let theirs = entry.contentHash, hashes[record.id] == theirs {
                    changes.append(ProposedChange(record: record, operation: .moveToTrash, reason: .alreadyArchived(copyNamed: entry.name)))
                } else {
                    needsDate.append(record)
                }
            } else if taken.insert(key(name)).inserted {
                changes.append(ProposedChange(record: record, operation: .move(to: archiveURL, name: name), reason: reason))
            } else {
                needsDate.append(record)
            }
        }
        for record in needsDate {
            guard let reason = reason(for: record),
                  let date = record.dateAdded ?? record.dateModified,
                  let name = FileNameRules.datedName(
                      record.displayName,
                      date: date,
                      timeZone: timeZone,
                      takenCount: taken.count,
                      isFree: { !taken.contains(key($0)) }
                  ) else {
                skippedItems.append(CleanupPlan.SkippedItem(url: record.url, reason: .invalidName))
                continue
            }
            taken.insert(key(name))
            changes.append(ProposedChange(record: record, operation: .move(to: archiveURL, name: name), reason: reason))
        }

        changes.sort { nameOrder($0.record, $1.record) }
        let sortedSkips = skippedItems.sorted {
            $0.url.lastPathComponent.localizedStandardCompare($1.url.lastPathComponent) == .orderedAscending
        }
        return CleanupPlan(action: .archiveOldDownloads, folderURL: folderURL, changes: changes, skippedItems: sortedSkips)
    }

    /// Why `record` is archived: when it was last opened, or, never opened, when it arrived.
    private static func reason(for record: FileRecord) -> ProposedChange.Reason? {
        if let lastOpened = record.lastOpened {
            return .notOpenedSince(lastOpened)
        }
        return record.dateAdded.map { .neverOpened(downloadedOn: $0) }
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
