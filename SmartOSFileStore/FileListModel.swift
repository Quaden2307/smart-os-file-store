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
    private(set) var records: [FileRecord] = []

    /// `records` in the table's current sort order. Re-sorted only when either input changes.
    private(set) var sortedRecords: [FileRecord] = []

    /// The rows the table shows: `sortedRecords` narrowed by `filter`.
    private(set) var visibleRecords: [FileRecord] = []

    /// Total size of `visibleRecords`, counted like `totalBytes`.
    private(set) var visibleBytes: Int64 = 0

    /// Each record's marks at the time of the latest scan. Records without marks have no entry.
    private(set) var marksByID: [FileRecord.ID: [FileMark]] = [:]

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

    private var scanTask: Task<Void, Never>?
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
        let marksByID: [FileRecord.ID: [FileMark]]
    }

    /// Starts a new scan, cancelling any that is still running.
    func refresh() {
        guard let location else { return }
        scanTask?.cancel()
        isLoading = true
        let scanner = scanner
        // Read again on every scan, so a threshold changed with `defaults write` applies on ⌘R.
        let settings = CleanupSettings.load(from: UserDefaults.standard)
        scanTask = Task {
            let outcome: Result<ScanOutcome, FolderScanError>
            do throws(FolderScanError) {
                let result = try await scanner.scan(location)
                let marksByID = await Self.marks(for: result.records, now: result.scannedAt, settings: settings)
                outcome = .success(ScanOutcome(result: result, marksByID: marksByID))
            } catch {
                outcome = .failure(error)
            }
            // A superseded scan must not overwrite the state of the one that replaced it.
            guard !Task.isCancelled else { return }
            apply(outcome)
        }
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
            marksByID = outcome.marksByID
            resort()
            logger.info(
                "Listed \(result.records.count) items, skipped \(result.skippedItems.count), marked \(self.marksByID.count); sorting and filtering on the main actor took \((clock.now - start).milliseconds, format: .fixed(precision: 1)) ms"
            )
        case .failure(let error):
            failure = ScanFailure(error)
            records = []
            sortedRecords = []
            visibleRecords = []
            visibleBytes = 0
            marksByID = [:]
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
    private nonisolated static func marks(for records: [FileRecord], now: Date, settings: CleanupSettings) async -> [FileRecord.ID: [FileMark]] {
        var marksByID: [FileRecord.ID: [FileMark]] = [:]
        for record in records {
            let marks = FileMarker.marks(for: record, now: now, settings: settings)
            if !marks.isEmpty {
                marksByID[record.id] = marks
            }
        }
        return marksByID
    }
}
