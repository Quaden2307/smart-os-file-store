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
    /// 10,000 unless `SMARTOS_BENCHMARK_FILES` says otherwise (`TEST_RUNNER_SMARTOS_BENCHMARK_FILES`
    /// on the xcodebuild command line), so the same benchmark runs at 50,000 too.
    private static let smallFileCount = ProcessInfo.processInfo.environment["SMARTOS_BENCHMARK_FILES"].flatMap { Int($0) } ?? 10_000
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

    /// Tidy Now on the same folder as above: one scan, then every planner together with a fresh
    /// content-hash cache each run, so Find Duplicates reads every candidate and the planners after
    /// it read from the cache. Memory is sampled on every progress report.
    @Test func tidyNowAtTenThousandFiles() async throws {
        let temp = try TemporaryFolder.make()
        defer { temp.remove() }
        _ = try BulkFiles.writeSmallFiles(count: Self.smallFileCount, in: temp.url)
        _ = try BulkFiles.addDownloadAttributes(count: Self.smallFileCount, in: temp.url)
        try BulkFiles.writeSparseFile(temp.url.appending(path: "big-a.bin"), size: Self.bigSize)
        try BulkFiles.writeSparseFile(temp.url.appending(path: "big-b.bin"), size: Self.bigSize)
        try BulkFiles.writeSparseFile(temp.url.appending(path: "big-c.bin"), size: Self.uniqueBigSize)
        let clock = ContinuousClock()
        let location = ScanLocation(folderURL: temp.url, source: .launchArgument)
        let later = Date(timeIntervalSinceNow: 2 * 3_600)
        let scan = try await FolderScanner().scan(location)
        let before = try #require(physicalFootprintInBytes())
        let peak = Mutex<UInt64>(before)
        var times: [Duration] = []
        for run in 0...Self.measuredRuns {
            let planner = TidyNowPlanner(
                eligibility: CandidateEligibility(),
                keptItems: KeptItems(),
                installers: .testing(),
                records: scan.records,
                folderURL: temp.url,
                now: later
            )
            let start = clock.now
            let plan = try await planner.plan { _ in
                if let footprint = physicalFootprintInBytes() {
                    peak.withLock { $0 = max($0, footprint) }
                }
            }
            let time = clock.now - start
            #expect(plan.outcomes.allSatisfy { $0.outcome != .failed })
            #expect(plan.plans.first { $0.action == .findDuplicates }?.duplicateGroups.count == Self.smallFileCount / 2 + 1)
            if run > 0 {
                times.append(time)
            }
        }
        let highest = peak.withLock { $0 }
        let growth = highest > before ? highest - before : 0
        Self.report("Tidy Now over \(Self.smallFileCount + 3) records: \(Self.summary(times)), median (min–max) of \(Self.measuredRuns) runs")
        Self.report("Tidy Now memory: footprint before \(Measured.mebibytes(before)), sampled peak \(Measured.mebibytes(highest)), growth \(Measured.mebibytes(growth))")
    }

    /// Undo of a run that moved 1,000 files to a fake Trash, with the activity log in a file as the
    /// app keeps it: the undo plan from the log and the disk, then every file put back. Three runs,
    /// each trashed again first; only the undo is timed.
    @Test func undoOfAThousandItemRun() async throws {
        let folder = try TemporaryFolder.make()
        defer { folder.remove() }
        let trash = try FakeTrash.make()
        defer { trash.remove() }
        let names = (0..<1_000).map { String(format: "file-%04d.txt", $0) }
        try UndoFixtures.write(Dictionary(uniqueKeysWithValues: names.map { ($0, "contents of \($0)") }), in: folder.url)
        try await withLogSandbox { sandbox in
            let log = try await ActivityLog.open(try sandbox.realLocation())
            let clock = ContinuousClock()
            var times: [Duration] = []
            for _ in 0..<3 {
                let (runID, _) = try await UndoFixtures.trashRun(names, in: folder.url, to: trash, log: log)
                let start = clock.now
                let result = try await UndoFixtures.undo(.run(runID), in: folder.url, trash: trash.locator, log: log)
                times.append(clock.now - start)
                #expect(result.undone.count == names.count)
            }
            try await log.close()
            Self.report("undo of a 1,000-item run: \(Self.summary(times)), median (min–max) of 3 runs")
        }
    }

    /// Remove Used Installers on 130 installers against 300 installed apps: the installed-apps
    /// index, the first search (every installer read, ten disk images attached two at a time),
    /// the second (everything from the cache, nothing attached), and the Installed marks.
    @Test func installerScanAtThreeHundredApps() async throws {
        let temp = try TemporaryFolder.make()
        defer { temp.remove() }
        let downloads = temp.url.appending(path: "Downloads", directoryHint: .isDirectory)
        let applications = temp.url.appending(path: "Applications", directoryHint: .isDirectory)
        let staging = temp.url.appending(path: "Staging", directoryHint: .isDirectory)
        for folder in [downloads, applications, staging] {
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        }
        let clock = ContinuousClock()
        let setupStart = clock.now
        for index in 0..<300 {
            try FakeDownloadsFolder.writeApp(at: applications.appending(path: "App\(index).app"), identifier: "com.example.App\(index)", version: "1.\(index)", build: "\(index)")
        }
        var installers: [URL] = []
        for index in 0..<100 {
            let app = staging.appending(path: "App\(index).app")
            try FakeDownloadsFolder.writeApp(at: app, identifier: "com.example.App\(index)", version: "1.\(index)", build: "\(index)")
            let zip = downloads.appending(path: "App\(index)-1.\(index).zip")
            try ZipTools.ditto(app, to: zip, keepParent: true)
            installers.append(zip)
        }
        for index in 100..<120 {
            let root = staging.appending(path: "root\(index)", directoryHint: .isDirectory)
            try FakeDownloadsFolder.writeApp(at: root.appending(path: "App\(index).app"), identifier: "com.example.App\(index)", version: "1.\(index)", build: "\(index)")
            let package = downloads.appending(path: "App\(index).pkg")
            try CommandLineTool.run("/usr/bin/pkgbuild", [
                "--quiet", "--root", root.path(percentEncoded: false), "--identifier", "com.example.App\(index).pkg",
                "--version", "1.\(index)", "--install-location", "/Applications", package.path(percentEncoded: false),
            ])
            installers.append(package)
        }
        for index in 120..<130 {
            let source = staging.appending(path: "image\(index)", directoryHint: .isDirectory)
            try FakeDownloadsFolder.writeApp(at: source.appending(path: "App\(index).app"), identifier: "com.example.App\(index)", version: "1.\(index)", build: "\(index)")
            let image = downloads.appending(path: "App\(index).dmg")
            try FakeDownloadsFolder.makeDiskImage(from: source, volumeName: "App\(index)", to: image, staging: staging)
            installers.append(image)
        }
        try FileDates.settle(installers)
        let setupTime = clock.now - setupStart

        let records = try await RelocationPlans.records(in: downloads)
        let mountFolder = try TemporaryFolder.make(prefix: "Mounts")
        defer { mountFolder.remove() }
        let log = try await ActivityLog.open(.inMemory)
        let mounts = DiskImageMounts(root: mountFolder.url.appending(path: "root", directoryHint: .isDirectory))
        #expect(await mounts.prepare())
        let sources = InstallerSources.testing(applications: [applications], cache: log, mounts: mounts)
        func plan() async throws -> CleanupPlan {
            try #require(try await CleanupPlanners.plan(
                .removeUsedInstallers, records: records, in: downloads, eligibility: CandidateEligibility(), keptItems: KeptItems(), installers: sources
            ))
        }

        var indexTimes: [Duration] = []
        for run in 0...Self.measuredRuns {
            let start = clock.now
            let index = await InstalledApps.read(folders: [applications])
            if run > 0 {
                indexTimes.append(clock.now - start)
            }
            #expect(index.count == 300)
        }

        let firstStart = clock.now
        let first = try await plan()
        let firstTime = clock.now - firstStart
        // Every zip and image is strong; the packages have no receipt and match by name.
        #expect(first.changes.count == 130)
        #expect(first.changes.filter(\.reason.isPossibleMatch).count == 20)
        try await log.storeInstallerFacts(first.installerFactsRead)

        var cachedTimes: [Duration] = []
        var markTimes: [Duration] = []
        for run in 0...Self.measuredRuns {
            let start = clock.now
            let again = try await plan()
            let planned = clock.now - start
            #expect(again.installerFactsRead.isEmpty)
            #expect(again.changes == first.changes)
            let marksStart = clock.now
            let marked = await InstallerPlanner.strongMatches(among: records, in: downloads, applicationFolders: [applications], cache: log, receipts: .fixed([]))
            let marksTime = clock.now - marksStart
            #expect(marked.count == 110)
            if run > 0 {
                cachedTimes.append(planned)
                markTimes.append(marksTime)
            }
        }

        #if DEBUG
        let configuration = "Debug"
        #else
        let configuration = "Release"
        #endif
        let date = Date.now.formatted(Date.ISO8601FormatStyle(timeZone: .current).year().month().day())
        Self.report("installer setup of 300 apps, 100 zips, 20 packages and 10 disk images: \(String(format: "%.0f", Measured.milliseconds(setupTime))) ms")
        Self.report("installed-apps index of 300 apps: \(Self.summary(indexTimes)), median (min–max) of \(Self.measuredRuns) runs")
        Self.report("first installer search, 130 read, 10 attached: \(String(format: "%.1f", Measured.milliseconds(firstTime))) ms, one run")
        Self.report("cached installer search, nothing attached: \(Self.summary(cachedTimes)), median (min–max) of \(Self.measuredRuns) runs")
        Self.report("Installed marks from the cache: \(Self.summary(markTimes)), median (min–max) of \(Self.measuredRuns) runs")
        Self.report(
            "installer row: | \(date) | \(Self.machineModel()) | \(ProcessInfo.processInfo.operatingSystemVersionString) | \(configuration) | <commit> | \(Self.summary(indexTimes)) | \(String(format: "%.1f ms", Measured.milliseconds(firstTime))) | \(Self.summary(cachedTimes)) | \(Self.summary(markTimes)) |"
        )
    }
}
