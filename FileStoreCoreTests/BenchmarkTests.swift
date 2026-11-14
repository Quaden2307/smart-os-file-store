import Darwin
import FileStoreCore
import Foundation
import Synchronization
import Testing

/// How long the engine takes on a large folder: 10,000 small files carrying the attributes a real
/// download has, and three sparse files of several gigabytes. It times the scan with and without
/// reading those attributes, the marks, and the duplicate plan, reports memory, and asserts only
/// that the answers are right; there are no time limits to pass. Results go to the test log as
/// warnings starting `BENCHMARK`, and are copied by hand into docs/benchmarks.md.
///
/// It is not part of the normal test run: the default test plan leaves it out, and the `Benchmark`
/// test plan runs it alone (see README.md for the command). That plan also sets
/// `SMARTOS_RUN_BENCHMARK`, so a run that bypasses the plans (`-only-testing:FileStoreCoreTests`,
/// say) reports it as skipped instead of spending a minute on it.
@Suite(
    "Benchmark",
    .serialized,
    .timeLimit(.minutes(10)),
    .enabled(if: ProcessInfo.processInfo.environment["SMARTOS_RUN_BENCHMARK"] == "1", "runs from the Benchmark test plan only")
)
struct BenchmarkTests {
    private static let smallFileCount = 10_000
    private static let gibibyte: Int64 = 1 << 30
    private static let bigSize = 2 * gibibyte
    private static let uniqueBigSize = 3 * gibibyte
    /// Measured runs after one warm-up run.
    private static let measuredRuns = 5

    /// Median, minimum and maximum in milliseconds, as "median (min–max) ms".
    private static func summary(_ durations: [Duration]) -> String {
        let values = durations.map(Measured.milliseconds).sorted()
        guard let lowest = values.first, let highest = values.last else { return "no runs" }
        let median = values[values.count / 2]
        return String(format: "%.1f ms (%.1f–%.1f)", median, lowest, highest)
    }

    private static func machineModel() -> String {
        var size = 0
        guard sysctlbyname("hw.model", nil, &size, nil, 0) == 0, size > 0 else { return "unknown" }
        var model = [UInt8](repeating: 0, count: size)
        guard sysctlbyname("hw.model", &model, &size, nil, 0) == 0 else { return "unknown" }
        return String(decoding: model.prefix { $0 != 0 }, as: UTF8.self)
    }

    private static func report(_ text: String) {
        Issue.record("BENCHMARK \(text)", severity: .warning)
    }

    @Test func scanAndDuplicatePlanAtTenThousandFiles() async throws {
        let temp = try TemporaryFolder.make()
        defer { temp.remove() }
        let clock = ContinuousClock()
        let setupStart = clock.now
        let smallTotal = try BulkFiles.writeSmallFiles(count: Self.smallFileCount, in: temp.url)
        let openedCount = try BulkFiles.addDownloadAttributes(count: Self.smallFileCount, in: temp.url)
        try BulkFiles.writeSparseFile(temp.url.appending(path: "big-a.bin"), size: Self.bigSize)
        try BulkFiles.writeSparseFile(temp.url.appending(path: "big-b.bin"), size: Self.bigSize)
        try BulkFiles.writeSparseFile(temp.url.appending(path: "big-c.bin"), size: Self.uniqueBigSize)
        let setupTime = clock.now - setupStart

        let scanner = FolderScanner()
        // The scan as it was before last opened and download sources were read.
        let listingScanner = FolderScanner(metadataReader: NoMetadataReader())
        let planner = DuplicatePlanner()
        let settings = CleanupSettings()
        let location = ScanLocation(folderURL: temp.url, source: .launchArgument)
        // The files were written moments ago, so plans are made as if two hours had passed; the
        // production rules still run.
        let later = Date(timeIntervalSinceNow: 2 * 3_600)
        let before = try #require(physicalFootprintInBytes())
        let peak = Mutex<UInt64>(before)
        var listingTimes: [Duration] = []
        var scanTimes: [Duration] = []
        var markTimes: [Duration] = []
        var sortTimes: [Duration] = []
        var keyedSortTimes: [Duration] = []
        var planTimes: [Duration] = []
        var bytesHashed: Int64 = 0

        for run in 0...Self.measuredRuns {
            let listingStart = clock.now
            let listing = try await listingScanner.scan(location)
            let listingTime = clock.now - listingStart
            #expect(listing.records.count == Self.smallFileCount + 3)
            #expect(listing.records.allSatisfy { $0.lastOpened == nil && $0.downloadSource == nil })

            let scanStart = clock.now
            let scan = try await scanner.scan(location)
            let scanTime = clock.now - scanStart
            if let footprint = physicalFootprintInBytes() {
                peak.withLock { $0 = max($0, footprint) }
            }
            #expect(scan.records.count == Self.smallFileCount + 3)
            #expect(scan.skippedItems.isEmpty)
            let sourced = scan.records.filter {
                $0.downloadSource?.addresses == BulkFiles.downloadSources && $0.downloadSource?.downloadingApp == BulkFiles.downloadingApp
            }
            #expect(sourced.count == Self.smallFileCount)
            #expect(scan.records.count { $0.lastOpened == BulkFiles.lastOpened } == openedCount)

            // Every file is fresh, so the only mark is Unused, on the files last opened in 2025.
            let marksStart = clock.now
            let marks = scan.records.map { FileMarker.marks(for: $0, now: later, settings: settings) }
            let marksTime = clock.now - marksStart
            #expect(marks.count { $0 == [.unused] } == openedCount)
            #expect(marks.count { !$0.isEmpty } == openedCount)

            // What the app's table does on the main actor after each scan: its default sort, newest
            // Date Added first, the general way and the keyed way the app uses.
            let sortStart = clock.now
            let sorted = scan.records.sorted(using: [KeyPathComparator(\FileRecord.dateAdded, order: .reverse)])
            let sortTime = clock.now - sortStart
            let keyedSortStart = clock.now
            let keyedSorted = FileRecordSorting.sorted(scan.records, by: [.value(\.dateAdded, order: .reverse)])
            let keyedSortTime = clock.now - keyedSortStart
            #expect(keyedSorted.map(\.url) == sorted.map(\.url))

            let total = Mutex<Int64>(0)
            let planStart = clock.now
            // Progress arrives at most ten times a second while files are hashed: the memory sample.
            let plan = try await planner.plan(records: scan.records, in: temp.url, now: later) { progress in
                total.withLock { $0 = progress.bytesToHash }
                if let footprint = physicalFootprintInBytes() {
                    peak.withLock { $0 = max($0, footprint) }
                }
            }
            let planTime = clock.now - planStart
            if let footprint = physicalFootprintInBytes() {
                peak.withLock { $0 = max($0, footprint) }
            }
            #expect(plan.duplicateGroups.count == Self.smallFileCount / 2 + 1)
            #expect(plan.skippedItems.isEmpty)
            bytesHashed = total.withLock { $0 }

            // Run 0 warms the caches and is not counted.
            if run > 0 {
                listingTimes.append(listingTime)
                scanTimes.append(scanTime)
                markTimes.append(marksTime)
                sortTimes.append(sortTime)
                keyedSortTimes.append(keyedSortTime)
                planTimes.append(planTime)
            }
        }
        #expect(bytesHashed == smallTotal + 2 * Self.bigSize)

        let highest = peak.withLock { $0 }
        let growth = highest > before ? highest - before : 0
        let lifetime = lifetimePeakFootprintInBytes().map(Measured.mebibytes) ?? "unknown"
        #if DEBUG
        let configuration = "Debug"
        #else
        let configuration = "Release"
        #endif
        let model = Self.machineModel()
        let system = ProcessInfo.processInfo.operatingSystemVersionString
        let date = Date.now.formatted(Date.ISO8601FormatStyle(timeZone: .current).year().month().day())

        Self.report("setup of \(Self.smallFileCount + 3) files with their attributes: \(String(format: "%.0f", Measured.milliseconds(setupTime))) ms")
        Self.report("scan of \(Self.smallFileCount + 3) records without metadata: \(Self.summary(listingTimes)), median (min–max) of \(Self.measuredRuns) runs")
        Self.report("scan of \(Self.smallFileCount + 3) records with metadata: \(Self.summary(scanTimes)), median (min–max) of \(Self.measuredRuns) runs")
        Self.report("marks for \(Self.smallFileCount + 3) records: \(Self.summary(markTimes)), median (min–max) of \(Self.measuredRuns) runs")
        Self.report("sort of \(Self.smallFileCount + 3) records by Date Added with sorted(using:): \(Self.summary(sortTimes)), median (min–max) of \(Self.measuredRuns) runs")
        Self.report("sort of \(Self.smallFileCount + 3) records by Date Added with FileRecordSorting: \(Self.summary(keyedSortTimes)), median (min–max) of \(Self.measuredRuns) runs")
        Self.report("duplicate plan hashing \(Self.smallFileCount + 2) files, \(Measured.mebibytes(UInt64(bytesHashed))): \(Self.summary(planTimes)), median (min–max) of \(Self.measuredRuns) runs")
        Self.report("memory: footprint before \(Measured.mebibytes(before)), sampled peak \(Measured.mebibytes(highest)), growth \(Measured.mebibytes(growth)), process lifetime peak \(lifetime)")
        Self.report(
            "row: | \(date) | \(model) | \(system) | \(configuration) | <commit> | \(Self.summary(listingTimes)) | \(Self.summary(scanTimes)) | \(Self.summary(markTimes)) | \(Self.summary(sortTimes)) | \(Self.summary(keyedSortTimes)) | \(Self.summary(planTimes)) | \(Measured.mebibytes(highest)) (+\(Measured.mebibytes(growth))) | \(lifetime) |"
        )
    }
}
