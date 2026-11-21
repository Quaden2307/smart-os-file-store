import Foundation

/// Plans Clear Failed Downloads: the partial downloads at the top level of the folder that stopped
/// and never finished, proposed for the Trash.
///
/// A partial download is a file ending in `.crdownload` (Chrome and others) or `.part` (Firefox and
/// others), or a folder ending in `.download` (Safari's, a package). It counts as failed once
/// nothing about it has changed for the grace period: for a file, its modification date (which
/// moves whenever it grows); for a folder, the newest date of anything inside it or of the folder
/// itself (`FileRecord.lastChange`). This is the one action that handles downloads in progress;
/// every other rule still applies: hidden items, the archive, links and Kept items never take part.
///
/// Pure: it reads only the records, the rules and the time it is given.
public struct FailedDownloadPlanner: Sendable {
    /// What a partial download must be on disk, decided by its name alone.
    public enum PartialShape: Sendable, Hashable {
        /// A regular file: `.crdownload` or `.part`.
        case file
        /// A folder, which macOS shows as a package where Safari's type is registered: `.download`.
        case folder
    }

    /// Extensions of a partial download that is a file. Compared case-insensitively.
    public static let partialFileExtensions: Set<String> = ["crdownload", "part"]

    /// The extension of a partial download that is a folder. Compared case-insensitively.
    public static let partialFolderExtension = "download"

    /// The rules every action shares, with the Kept list.
    public let eligibility: CandidateEligibility

    public init(eligibility: CandidateEligibility = CandidateEligibility()) {
        self.eligibility = eligibility
    }

    /// What an item called `name` must be to be a partial download, or nil when the name is not one.
    /// The extension is read by the same rule as `FileRecord.isInProgressDownload`, so `part`,
    /// `my.download.pdf` and `Downloads` are not partial downloads.
    public static func partialShape(ofName name: String) -> PartialShape? {
        let pathExtension = URL(filePath: name, directoryHint: .notDirectory).pathExtension.lowercased()
        if partialFileExtensions.contains(pathExtension) {
            return .file
        }
        if pathExtension == partialFolderExtension {
            return .folder
        }
        return nil
    }

    /// True when the scan's `kind` is what `shape` requires. A link never is.
    static func kind(_ kind: FileRecord.Kind, fits shape: PartialShape) -> Bool {
        switch (shape, kind) {
        case (.file, .file), (.folder, .folder), (.folder, .package):
            true
        case (.file, .folder), (.file, .package), (.file, .symlink), (.folder, .file), (.folder, .symlink):
            false
        }
    }

    /// The name the download would have had once finished: `movie.mp4` for `movie.mp4.crdownload`.
    static func finishedName(of name: String) -> String {
        URL(filePath: name, directoryHint: .notDirectory).deletingPathExtension().lastPathComponent
    }

    /// True when the plan at `now` would propose `record`: the file list's Failed download mark asks
    /// the same question, so the two never disagree.
    public func isCandidate(_ record: FileRecord, in folder: ManagedFolder, now: Date) -> Bool {
        // The scan's flag answers for almost every item at no cost: the file list asks this of all.
        guard record.isDownloading,
              let shape = Self.partialShape(ofName: record.displayName),
              Self.kind(record.kind, fits: shape) else {
            return false
        }
        // A folder whose contents were not read in full has no known last change.
        if shape == .folder, record.readContents == nil {
            return false
        }
        return eligibility.refusal(for: record, in: folder, now: now, downloads: .allowed) == nil
    }

    /// The plan for the records directly inside `folderURL`, from one scan of it, at `now`. Changes
    /// are in name order.
    /// A `.download` folder whose contents could not be read is reported as not checked; one too
    /// big to be a download is left out.
    public func plan(records: [FileRecord], in folder: ManagedFolder, now: Date = .now) -> CleanupPlan {
        let folderURL = folder.url
        // Only the folder's own items: never anything inside a folder in it, the archive's included.
        let records = DuplicatePlanner.recordsDirectlyInside(folderURL, among: records)
        let finished = Self.finishedItemNames(in: records)
        var changes: [ProposedChange] = []
        var skippedItems: [CleanupPlan.SkippedItem] = []
        for record in records {
            if isCandidate(record, in: folder, now: now), let stoppedOn = record.lastChange {
                let finishedFileName = finished[Self.finishedName(of: record.displayName).lowercased()]
                changes.append(
                    ProposedChange(
                        record: record,
                        operation: .moveToTrash,
                        reason: .failedDownload(stoppedOn: stoppedOn, finishedFileName: finishedFileName)
                    )
                )
            } else if let reason = unreadableReason(for: record, in: folder, now: now) {
                skippedItems.append(CleanupPlan.SkippedItem(url: record.url, reason: reason))
            }
        }
        changes.sort { Self.isOrderedBefore($0.record.displayName, $1.record.displayName) }
        skippedItems.sort { Self.isOrderedBefore($0.url.lastPathComponent, $1.url.lastPathComponent) }
        return CleanupPlan(action: .clearFailedDownloads, folder: folder, changes: changes, skippedItems: skippedItems)
    }

    // MARK: - Rules

    /// Why a `.download` folder that could be a candidate was not checked, or nil. The shared rules
    /// apply by the folder's own dates, the only ones known: a folder changed within the grace
    /// period may simply be downloading, and is left out without a word, like a fresh candidate.
    private func unreadableReason(for record: FileRecord, in folder: ManagedFolder, now: Date) -> CleanupSkipReason? {
        guard Self.partialShape(ofName: record.displayName) == .folder,
              Self.kind(record.kind, fits: .folder),
              case .failure(let failure) = record.packageContents,
              eligibility.refusal(for: record, in: folder, now: now, downloads: .allowed) == nil else {
            return nil
        }
        return CleanupSkipReason(packageFailure: failure)
    }

    /// The items a finished download could be, by their name in lower case: non-empty files and
    /// packages that are not themselves partial downloads. An empty file is left out: Firefox
    /// makes one under the final name when a download starts.
    private static func finishedItemNames(in records: [FileRecord]) -> [String: String] {
        var names: [String: String] = [:]
        for record in records.sorted(by: { isOrderedBefore($0.displayName, $1.displayName) }) {
            guard partialShape(ofName: record.displayName) == nil else { continue }
            switch record.kind {
            case .file:
                guard let size = record.sizeInBytes, size > 0 else { continue }
            case .package:
                break
            case .folder, .symlink:
                continue
            }
            let key = record.displayName.lowercased()
            if names[key] == nil {
                names[key] = record.displayName
            }
        }
        return names
    }

    private static func isOrderedBefore(_ first: String, _ second: String) -> Bool {
        first.localizedStandardCompare(second) == .orderedAscending
    }
}
