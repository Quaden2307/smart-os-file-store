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

    /// Records from the latest successful scan, in file-system order.
    private(set) var records: [FileRecord] = []

    /// `records` in the table's current sort order. Re-sorted only when either input changes.
    private(set) var sortedRecords: [FileRecord] = []

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
    var sortOrder: [KeyPathComparator<FileRecord>] = [KeyPathComparator(\.dateAdded, order: .reverse)] {
        didSet { resort() }
    }

    var itemCount: Int { records.count }

    /// True when the folder was scanned successfully and holds nothing visible.
    var isEmpty: Bool { hasLoadedOnce && failure == nil && records.isEmpty }

    /// True when a refresh can do something: the location resolved.
    var canRefresh: Bool { location != nil }

    private var scanTask: Task<Void, Never>?
    private let scanner = FolderScanner()
    private let logger = Logger(subsystem: "com.quaden2307.SmartOSFileStore", category: "FileList")

    init(
        arguments: [String] = ProcessInfo.processInfo.arguments,
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) {
        do throws(ScanLocationError) {
            location = try ScanLocation.resolve(arguments: arguments, environment: environment)
        } catch {
            failure = ScanFailure(error)
            hasLoadedOnce = true
            logger.error("Scan location could not be resolved: \(String(describing: error), privacy: .private)")
        }
    }

    /// Starts a new scan, cancelling any that is still running.
    func refresh() {
        guard let location else { return }
        scanTask?.cancel()
        isLoading = true
        let scanner = scanner
        scanTask = Task {
            let outcome: Result<FolderScanResult, FolderScanError>
            do throws(FolderScanError) {
                outcome = .success(try await scanner.scan(location))
            } catch {
                outcome = .failure(error)
            }
            // A superseded scan must not overwrite the state of the one that replaced it.
            guard !Task.isCancelled else { return }
            apply(outcome)
        }
    }

    private func apply(_ outcome: Result<FolderScanResult, FolderScanError>) {
        switch outcome {
        case .failure(.cancelled):
            // Only a superseded scan reports this, and the scan that replaced it owns the state.
            return
        case .success(let result):
            failure = nil
            records = result.records
            skippedItems = result.skippedItems
            totalBytes = result.records.reduce(0) { $0 + ($1.sizeInBytes ?? 0) }
            resort()
            logger.info("Listed \(result.records.count) items, skipped \(result.skippedItems.count)")
        case .failure(let error):
            failure = ScanFailure(error)
            records = []
            sortedRecords = []
            skippedItems = []
            totalBytes = 0
            logger.error("Scan failed: \(String(describing: error), privacy: .private)")
        }
        isLoading = false
        hasLoadedOnce = true
        scanGeneration += 1
    }

    private func resort() {
        sortedRecords = records.sorted(using: sortOrder)
    }
}
