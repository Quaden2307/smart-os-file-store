import FileStoreCore
import Foundation
import Observation
import os

/// Window state for the file list. Lives on the main actor; the scan itself runs elsewhere.
@MainActor
@Observable
final class FileListModel {
    /// The folder being scanned, or nil when it could not be resolved (see `failure`).
    private(set) var location: ScanLocation?

    /// The rules every cleanup action shares, resolved once from the same launch arguments as the
    /// folder, so the search and the executor use the same grace period.
    let eligibility: CandidateEligibility

    /// Records from the latest successful scan, in file-system order.
    private(set) var records: [FileRecord] = [] {
        didSet { recordsByID = Dictionary(records.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first }) }
    }

    /// `records` by their ID, so a selection is looked up without going through every record.
    private var recordsByID: [FileRecord.ID: FileRecord] = [:]

    /// `records` in the table's current sort order. Re-sorted only when either input changes.
    private(set) var sortedRecords: [FileRecord] = []

    /// The rows the table shows: `sortedRecords` narrowed by `filter`.
    private(set) var visibleRecords: [FileRecord] = []

    /// Total size of `visibleRecords`, counted like `totalBytes`.
    private(set) var visibleBytes: Int64 = 0

    /// Each record's marks at the time of the latest scan, with Kept as the Kept list now has it.
    /// Records without marks have no entry.
    private(set) var marksByID: [FileRecord.ID: [FileMark]] = [:]

    /// The Kept list as last read from the activity log. Empty until the log has been read.
    private(set) var keptItems = KeptItems()

    /// Items the last scan saw but could not read.
    private(set) var skippedItems: [FolderScanResult.SkippedItem] = []

    /// Total size of every item with a size; folders and packages count as zero. Kept in step with `records`.
    private(set) var totalBytes: Int64 = 0

    /// Why the folder cannot be shown, or nil when all is well.
    private(set) var failure: ScanFailure?

    /// True while a scan is running.
    private(set) var isLoading = false

    /// False until the first scan has finished (or failed), so the window can show a loading state.
    private(set) var hasLoadedOnce = false

    /// Increases each time the listing is replaced, after a successful or a failed scan, so views
    /// can react once per scan instead of comparing thousands of records.
    private(set) var scanGeneration = 0

    /// The table's sort order. Default: newest Date Added first.
    var sortOrder: [KeyPathComparator<FileRecord>] = FileListSort.newestFirst {
        didSet { resort() }
    }

    /// Which rows the table shows. Kept across refreshes.
    var filter: FileListFilter = .all {
        didSet { refilter() }
    }

    var itemCount: Int { records.count }

    var visibleCount: Int { visibleRecords.count }

    /// True when the folder was scanned successfully and holds nothing visible.
    var isEmpty: Bool { hasLoadedOnce && failure == nil && records.isEmpty }

    /// True when a refresh can do something: the location resolved.
    var canRefresh: Bool { location != nil }

    /// True when the rows on screen are a complete, current listing: loaded without error and no
    /// scan in flight. Cleanup actions work on those rows, so they wait for this.
    var isSettled: Bool { hasLoadedOnce && failure == nil && !isLoading }

    /// True while the Kept list is being changed or read back. A search started now could miss the
    /// change, so Find Duplicates waits for this.
    var isChangingKept: Bool { pendingKeptOperations > 0 }

    /// True when the Kept list can be changed: the log is open and the folder is known.
    var canChangeKept: Bool { activity?.log != nil && location != nil }

    private var scanTask: Task<Void, Never>?

    /// The activity log's state, which holds the Kept list. Set once, when the window appears.
    private var activity: ActivityLogModel?

    /// The latest Kept operation. Each new one waits for it, so changes and reads of the list happen
    /// in the order they were asked for and results never land out of order.
    private var keptChain: Task<Void, Never>?
    private var pendingKeptOperations = 0

    /// Works the marks out again after the Kept list changed between scans.
    private var marksTask: Task<Void, Never>?

    /// Increases each time marks are worked out again between scans, so the window can drop
    /// selected rows the filter now hides.
    private(set) var marksRevision = 0

    /// The time and settings the latest scan's marks were worked out with.
    private var markInputs: (now: Date, settings: CleanupSettings)?
    private let scanner = FolderScanner()
    private let logger = Logger(subsystem: "com.quaden2307.SmartOSFileStore", category: "FileList")

    init(
        arguments: [String] = ProcessInfo.processInfo.arguments,
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) {
        eligibility = CandidateEligibility.resolve(arguments: arguments)
        do throws(ScanLocationError) {
            location = try ScanLocation.resolve(arguments: arguments, environment: environment)
        } catch {
            failure = ScanFailure(error)
            hasLoadedOnce = true
            logger.error("Scan location could not be resolved: \(String(describing: error), privacy: .private)")
        }
    }

    /// A finished scan and the marks worked out from it.
    private struct ScanOutcome: Sendable {
        let result: FolderScanResult
        let settings: CleanupSettings
        /// The Kept list the marks were worked out with.
        let keptItems: KeptItems
        let marksByID: [FileRecord.ID: [FileMark]]
    }

    /// Connects the list to the activity log's state, where the Kept list is read and changed.
    func connect(to activity: ActivityLogModel) {
        self.activity = activity
    }

    /// Starts a new scan, cancelling any that is still running. Once it has finished, the Kept list
    /// is read again, which drops the entries of items that no longer exist.
    func refresh() {
        guard let location else { return }
        scanTask?.cancel()
        isLoading = true
        let scanner = scanner
        // Read again on every scan, so a threshold changed with `defaults write` applies on ⌘R.
        let settings = CleanupSettings.load(from: UserDefaults.standard)
        let keptItems = keptItems
        scanTask = Task {
            let outcome: Result<ScanOutcome, FolderScanError>
            do throws(FolderScanError) {
                let result = try await scanner.scan(location)
                let marksByID = await Self.marks(for: result.records, now: result.scannedAt, settings: settings, keptItems: keptItems)
                outcome = .success(ScanOutcome(result: result, settings: settings, keptItems: keptItems, marksByID: marksByID))
            } catch {
                outcome = .failure(error)
            }
            // A superseded scan must not overwrite the state of the one that replaced it.
            guard !Task.isCancelled else { return }
            apply(outcome)
            if case .success = outcome {
                reloadKeptItems()
            }
        }
    }

    // MARK: - Kept

    /// What Keep This File would do for the listed items in `ids`: stop keeping them when every one
    /// is Kept, otherwise keep them. Nil when `ids` names no listed item.
    func keepToggle(for ids: Set<FileRecord.ID>) -> KeepToggle? {
        let selected = records(for: ids)
        guard !selected.isEmpty else { return nil }
        return selected.allSatisfy(keptItems.contains) ? .stopKeeping : .keep
    }

    /// Keeps the listed items in `ids`, or stops keeping them when every one is already Kept.
    func toggleKept(_ ids: Set<FileRecord.ID>) {
        let selected = records(for: ids)
        switch keepToggle(for: ids) {
        case .keep:
            let toKeep = selected.filter { !keptItems.contains($0) }
            enqueueKeptOperation(keeping: toKeep) { log throws(ActivityLogError) in try await log.keep(toKeep) }
        case .stopKeeping:
            enqueueKeptOperation { log throws(ActivityLogError) in try await log.stopKeeping(selected) }
        case nil:
            break
        }
    }

    /// Marks `records` Kept: the preview's Keep This File, for files it took out of its plan. Only
    /// items in the listing are marked. `onFinish` hears whether the list could be changed.
    func keep(_ records: [FileRecord], onFinish: @escaping @MainActor (Bool) -> Void) {
        let toKeep = records.filter { recordsByID[$0.id] != nil }
        enqueueKeptOperation(keeping: toKeep, onFinish: onFinish) { log throws(ActivityLogError) in try await log.keep(toKeep) }
    }

    /// Empties the Kept list. The window asks first.
    func stopKeepingAll() {
        enqueueKeptOperation { log throws(ActivityLogError) in try await log.stopKeepingAll() }
    }

    /// Reads the Kept list again: after a scan, when the log has opened or been replaced, and after
    /// the preview has marked files Kept.
    func reloadKeptItems() {
        enqueueKeptOperation { _ in }
    }

    /// Runs `operation` on the open log once every earlier Kept operation has finished, then reads
    /// the list back. A failure is the log's, and is reported as one, unless that log has been
    /// replaced meanwhile. `onFinish` hears whether the operation itself was carried out.
    ///
    /// - Parameter keeping: The items `operation` marks Kept. One that does not read as Kept
    ///   afterwards was changed on disk since the scan (saved as a new copy, say), so it is marked
    ///   by what is there now; the list is scanned again to show it.
    private func enqueueKeptOperation(
        keeping: [FileRecord] = [],
        onFinish: (@MainActor (Bool) -> Void)? = nil,
        _ operation: @escaping @Sendable (ActivityLog) async throws(ActivityLogError) -> Void
    ) {
        guard let activity, let log = activity.log, let folderURL = location?.folderURL else {
            onFinish?(false)
            return
        }
        let opening = activity.openings
        let previous = keptChain
        pendingKeptOperations += 1
        keptChain = Task {
            await previous?.value
            var changed = false
            do throws(ActivityLogError) {
                try await operation(log)
                changed = true
                let kept = try await log.keptItems(forFolder: folderURL)
                apply(kept)
                if keeping.contains(where: { !kept.contains($0) }) {
                    refresh()
                }
            } catch {
                logger.error("The Kept list could not be used: \(String(describing: error), privacy: .public)")
                // A log closed and replaced meanwhile is not the one on screen now.
                if activity.openings == opening {
                    activity.logFailed(error)
                }
            }
            pendingKeptOperations -= 1
            onFinish?(changed)
        }
    }

    private func apply(_ keptItems: KeptItems) {
        guard keptItems != self.keptItems else { return }
        self.keptItems = keptItems
        remark()
    }

    /// Works the marks out again for the records on screen, off the main actor, with the Kept list
    /// as it is now. A later scan or change replaces the result before it lands.
    private func remark() {
        guard let markInputs else { return }
        marksTask?.cancel()
        let records = records
        let keptItems = keptItems
        marksTask = Task {
            let marksByID = await Self.marks(for: records, now: markInputs.now, settings: markInputs.settings, keptItems: keptItems)
            guard !Task.isCancelled else { return }
            self.marksByID = marksByID
            refilter()
            marksRevision += 1
        }
    }

    private func records(for ids: Set<FileRecord.ID>) -> [FileRecord] {
        ids.compactMap { recordsByID[$0] }
    }

    private func apply(_ outcome: Result<ScanOutcome, FolderScanError>) {
        switch outcome {
        case .failure(.cancelled):
            // Only a superseded scan reports this, and the scan that replaced it owns the state.
            return
        case .success(let outcome):
            let clock = ContinuousClock()
            let start = clock.now
            let result = outcome.result
            failure = nil
            records = result.records
            skippedItems = result.skippedItems
            totalBytes = result.records.reduce(0) { $0 + ($1.sizeInBytes ?? 0) }
            marksTask?.cancel()
            marksByID = outcome.marksByID
            markInputs = (now: result.scannedAt, settings: outcome.settings)
            resort()
            // The Kept list changed while the scan ran: its marks were worked out with the old one.
            if outcome.keptItems != keptItems {
                remark()
            }
            logger.info(
                "Listed \(result.records.count) items, skipped \(result.skippedItems.count), marked \(self.marksByID.count); sorting and filtering on the main actor took \((clock.now - start).milliseconds, format: .fixed(precision: 1)) ms"
            )
        case .failure(let error):
            failure = ScanFailure(error)
            records = []
            sortedRecords = []
            visibleRecords = []
            visibleBytes = 0
            marksTask?.cancel()
            marksByID = [:]
            markInputs = nil
            skippedItems = []
            totalBytes = 0
            logger.error("Scan failed: \(String(describing: error), privacy: .private)")
        }
        isLoading = false
        hasLoadedOnce = true
        scanGeneration += 1
    }

    /// The marks `record` carried at the latest scan, in display order.
    func marks(for record: FileRecord) -> [FileMark] {
        marksByID[record.id] ?? []
    }

    /// Where each of the rows was downloaded from, for those that recorded an address, in the
    /// table's display order: what Copy Download Source copies.
    func downloadAddresses(for ids: Set<FileRecord.ID>) -> [String] {
        guard !ids.isEmpty else { return [] }
        return visibleRecords.filter { ids.contains($0.id) }.compactMap(\.downloadSource?.fileAddress)
    }

    private func resort() {
        sortedRecords = FileListSort.sorted(records, using: sortOrder)
        refilter()
    }

    private func refilter() {
        switch filter {
        case .all:
            visibleRecords = sortedRecords
            visibleBytes = totalBytes
        case .marked(let mark):
            visibleRecords = sortedRecords.filter { marks(for: $0).contains(mark) }
            visibleBytes = visibleRecords.reduce(0) { $0 + ($1.sizeInBytes ?? 0) }
        }
    }

    /// Each record's marks, worked out off the main actor so a large folder never holds up the window.
    /// Built with a loop rather than `Dictionary(uniqueKeysWithValues:)`, which traps on a repeated
    /// key; a listing never repeats a URL, but a crash is not the way to find out.
    @concurrent
    private nonisolated static func marks(
        for records: [FileRecord],
        now: Date,
        settings: CleanupSettings,
        keptItems: KeptItems
    ) async -> [FileRecord.ID: [FileMark]] {
        var marksByID: [FileRecord.ID: [FileMark]] = [:]
        for record in records {
            let marks = FileMarker.marks(for: record, now: now, settings: settings, keptItems: keptItems)
            if !marks.isEmpty {
                marksByID[record.id] = marks
            }
        }
        return marksByID
    }
}

/// What Keep This File does for a selection.
enum KeepToggle: Equatable {
    /// Some of the items are not Kept yet: keep them.
    case keep
    /// Every item is Kept: stop keeping them.
    case stopKeeping

    /// The menu item's title.
    var title: String {
        switch self {
        case .keep:
            String(localized: "Keep This File")
        case .stopKeeping:
            String(localized: "Stop Keeping")
        }
    }
}
