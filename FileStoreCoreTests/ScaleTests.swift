import FileStoreCore
import Foundation
import Synchronization
import Testing

/// Behaviour at the size of a real Downloads folder: thousands of small files and files of several
/// gigabytes. Correctness is asserted strictly. Time and memory have wide bounds that catch a
/// regression of an order of magnitude, and the measured values are recorded as warnings so they
/// show in the test log without failing anything. The large files are sparse: they cost no disk
/// space and read as zeros through the same code path as any file.
@Suite("Scale", .serialized, .timeLimit(.minutes(3)))
struct ScaleTests {
    private let scanner = FolderScanner()
    private let planner = DuplicatePlanner()

    private static let smallFileCount = 5_000
    private static let mebibyte: Int64 = 1 << 20
    private static let gibibyte: Int64 = 1 << 30
    private static let bigSize = 2 * gibibyte
    private static let uniqueBigSize = 3 * gibibyte

    // MARK: - Reporting

    /// Records a measurement in the test log. A warning never fails a test.
    private static func report(_ text: String) {
        Issue.record("SCALE \(text)", severity: .warning)
    }

    // MARK: - Tests

    @Test func scansAndPlansThousandsOfFilesWithFlatMemory() async throws {
        let temp = try TemporaryFolder.make()
        defer { temp.remove() }
        let clock = ContinuousClock()
        let setupStart = clock.now
        let smallTotal = try BulkFiles.writeSmallFiles(count: Self.smallFileCount, in: temp.url)
        try BulkFiles.writeSparseFile(temp.url.appending(path: "big-a.bin"), size: Self.bigSize)
        try BulkFiles.writeSparseFile(temp.url.appending(path: "big-b.bin"), size: Self.bigSize)
        try BulkFiles.writeSparseFile(temp.url.appending(path: "big-c.bin"), size: Self.uniqueBigSize)
        let setupTime = clock.now - setupStart

        // Scan
        let scanStart = clock.now
        let scan = try await scanner.scan(ScanLocation(folderURL: temp.url, source: .launchArgument))
        let scanTime = clock.now - scanStart
        #expect(scan.records.count == Self.smallFileCount + 3)
        #expect(scan.skippedItems.isEmpty)

        // Plan. The files were written moments ago, so the plan is made as if two hours had passed;
        // the production rule still runs. Memory is sampled from the progress callback, which is
        // the only place that runs while the hashing threads are busy.
        let first = Mutex<DuplicateScanProgress?>(nil)
        let peak = Mutex<UInt64>(0)
        let before = try #require(physicalFootprintInBytes())
        let planStart = clock.now
        let plan = try await planner.plan(records: scan.records, in: temp.url, now: Date(timeIntervalSinceNow: 2 * 3_600)) { progress in
            first.withLock { stored in
                if stored == nil {
                    stored = progress
                }
            }
            if let footprint = physicalFootprintInBytes() {
                peak.withLock { $0 = max($0, footprint) }
            }
        }
        let planTime = clock.now - planStart
        let after = try #require(physicalFootprintInBytes())

        let firstProgress = try #require(first.withLock { $0 })
        #expect(firstProgress.filesToHash == Self.smallFileCount + 2)
        // big-c has a size of its own, so it is never read.
        #expect(firstProgress.bytesToHash == smallTotal + 2 * Self.bigSize)

        #expect(plan.skippedItems.isEmpty)
        #expect(plan.duplicateGroups.count == Self.smallFileCount / 2 + 1)
        #expect(plan.changes.count == Self.smallFileCount / 2 + 1)
        let bigGroup = try #require(plan.duplicateGroups.first { $0.fileSizeInBytes == Self.bigSize })
        #expect(bigGroup.kept.displayName == "big-a.bin")
        #expect(bigGroup.duplicates.map(\.displayName) == ["big-b.bin"])
        #expect(plan.duplicateGroups.first?.kept.displayName == "big-a.bin", "the largest saving comes first")
        let mentioned = plan.duplicateGroups.flatMap { [$0.kept.displayName] + $0.duplicates.map(\.displayName) }
        #expect(!mentioned.contains("big-c.bin"))
        #expect(plan.changes.allSatisfy { $0.record.displayName != "big-c.bin" })

        let highest = max(peak.withLock { $0 }, after)
        let growth = highest > before ? highest - before : 0
        #expect(growth < UInt64(64 * Self.mebibyte), "footprint grew by \(Measured.mebibytes(growth)) while hashing \(firstProgress.bytesToHash) bytes")

        Self.report(
            "setup \(Measured.milliseconds(setupTime).formatted(.number.precision(.fractionLength(0)))) ms; "
                + "scan of \(scan.records.count) records \(Measured.milliseconds(scanTime).formatted(.number.precision(.fractionLength(1)))) ms; "
                + "plan hashing \(firstProgress.filesToHash) files, \(Measured.mebibytes(UInt64(firstProgress.bytesToHash))), "
                + "\(Measured.milliseconds(planTime).formatted(.number.precision(.fractionLength(0)))) ms; "
                + "footprint before \(Measured.mebibytes(before)), peak \(Measured.mebibytes(highest)), after \(Measured.mebibytes(after)), growth \(Measured.mebibytes(growth))"
        )
    }

    @Test func cancelStopsAMultiGigabyteSearchPromptly() async throws {
        let temp = try TemporaryFolder.make()
        defer { temp.remove() }
        try BulkFiles.writeSparseFile(temp.url.appending(path: "big-a.bin"), size: Self.bigSize)
        try BulkFiles.writeSparseFile(temp.url.appending(path: "big-b.bin"), size: Self.bigSize)
        let records = try await scanner.scan(ScanLocation(folderURL: temp.url, source: .launchArgument)).records
        #expect(records.count == 2)
        let clock = ContinuousClock()
        let planner = planner
        let folder = temp.url
        // The callback runs on a hashing thread, inside a child of the search's task; cancelling the
        // current task there would stop one hash only. The search task itself is cancelled instead,
        // once it is known: the callback before the handle is set simply waits for the next one.
        let searchTask = Mutex<Task<CleanupPlan, any Error>?>(nil)
        let cancelledAt = Mutex<ContinuousClock.Instant?>(nil)

        let task = Task<CleanupPlan, any Error> {
            try await planner.plan(records: records, in: folder, now: Date(timeIntervalSinceNow: 2 * 3_600)) { progress in
                guard progress.bytesHashed > 64 * Self.mebibyte else { return }
                searchTask.withLock { task in
                    guard let task else { return }
                    cancelledAt.withLock { instant in
                        if instant == nil {
                            instant = clock.now
                            task.cancel()
                        }
                    }
                }
            }
        }
        searchTask.withLock { $0 = task }
        let outcome = await task.result
        let returnedAt = clock.now

        let instant = try #require(cancelledAt.withLock { $0 })
        let latency = returnedAt - instant
        switch outcome {
        case .success:
            Issue.record("expected the search to report cancellation, got a plan")
        case .failure(let error):
            #expect(error as? DuplicatePlanError == .cancelled)
        }
        #expect(latency < .seconds(2), "the search took \(Measured.milliseconds(latency)) ms to stop after cancel")
        Self.report("search of two \(Measured.mebibytes(UInt64(Self.bigSize))) files stopped \(Measured.milliseconds(latency).formatted(.number.precision(.fractionLength(1)))) ms after cancel")
    }

    @Test func cancelStopsAMultiGigabyteHashPromptly() async throws {
        let temp = try TemporaryFolder.make()
        defer { temp.remove() }
        let url = temp.url.appending(path: "big.bin")
        try BulkFiles.writeSparseFile(url, size: Self.bigSize)
        let clock = ContinuousClock()
        let hasher = ContentHasher()
        let chunks = Mutex(0)
        let cancelledAt = Mutex<ContinuousClock.Instant?>(nil)

        // The callback runs inside the hashing task, so cancelling the current task is exact.
        let task = Task<ContentHash, any Error> {
            try await hasher.hash(contentsOf: url, expectedSizeInBytes: Self.bigSize) { _ in
                let count = chunks.withLock { count -> Int in
                    count += 1
                    return count
                }
                if count == 64 {
                    cancelledAt.withLock { $0 = clock.now }
                    withUnsafeCurrentTask { $0?.cancel() }
                }
            }
        }
        let outcome = await task.result
        let returnedAt = clock.now

        let instant = try #require(cancelledAt.withLock { $0 })
        let latency = returnedAt - instant
        switch outcome {
        case .success:
            Issue.record("expected the hash to report cancellation, got a hash")
        case .failure(let error):
            #expect(error as? ContentHashError == .cancelled)
        }
        #expect(chunks.withLock { $0 } <= 65, "hashing went on after cancel")
        #expect(latency < .seconds(2), "the hash took \(Measured.milliseconds(latency)) ms to stop after cancel")
        Self.report("hash of a \(Measured.mebibytes(UInt64(Self.bigSize))) file stopped \(Measured.milliseconds(latency).formatted(.number.precision(.fractionLength(2)))) ms after cancel, after \(chunks.withLock { $0 }) chunks")
    }

    /// Remove Unpacked Zips on a real zip of 50,051 entries (50 folders of 1,000 files), made with
    /// Info-ZIP, beside the folder it was made from: its listing is read and every entry found on
    /// disk well within the budget, with memory that does not grow with what is read.
    @Test func aZipOfFiftyThousandFilesIsCheckedWithinTheBudget() async throws {
        let temp = try TemporaryFolder.make()
        defer { temp.remove() }
        let clock = ContinuousClock()
        let setupStart = clock.now
        let big = temp.url.appending(path: "big", directoryHint: .isDirectory)
        // Every file dated two hours back, as an unpacked copy's files carry the zip's old dates:
        // one written in the last hour could still be being unpacked.
        let settled = Date(timeIntervalSinceNow: -FileDates.settledAge)
        for folderIndex in 0..<50 {
            let folder = big.appending(path: String(format: "d%02d", folderIndex), directoryHint: .isDirectory)
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            for fileIndex in 0..<1_000 {
                let file = folder.appending(path: String(format: "f%04d.txt", fileIndex))
                try Data(repeating: 0x61, count: fileIndex % 7).write(to: file)
                try FileDates.set(file, to: settled)
            }
        }
        let zip = temp.url.appending(path: "big.zip")
        try ZipTools.zip(["big"], in: temp.url, to: zip)
        try FileDates.settle([big, zip])
        let setupTime = clock.now - setupStart
        let records = try await scanner.scan(ScanLocation(folderURL: temp.url, source: .launchArgument)).records
        #expect(records.count == 2)

        let before = try #require(physicalFootprintInBytes())
        let listStart = clock.now
        let listing = try await ZipListing.read(at: zip)
        let listTime = clock.now - listStart
        #expect(listing.entries.count == 50_051)

        let planStart = clock.now
        let plan = try #require(
            try await CleanupPlanners.plan(.removeUnpackedZips, records: records, in: temp.url, eligibility: CandidateEligibility(), keptItems: KeptItems(), installers: .testing())
        )
        let planTime = clock.now - planStart
        let after = try #require(physicalFootprintInBytes())

        #expect(UnpackedZips.proposals(plan) == ["big.zip → big"])
        #expect(planTime < .seconds(10), "planning took \(Measured.milliseconds(planTime)) ms")
        let growth = after > before ? after - before : 0
        #expect(growth < UInt64(256 * Self.mebibyte), "footprint grew by \(Measured.mebibytes(growth))")
        Self.report(
            "zip of \(listing.entries.count) entries: setup \(Measured.milliseconds(setupTime).formatted(.number.precision(.fractionLength(0)))) ms; "
                + "listing \(Measured.milliseconds(listTime).formatted(.number.precision(.fractionLength(1)))) ms; "
                + "plan with every entry found \(Measured.milliseconds(planTime).formatted(.number.precision(.fractionLength(1)))) ms; "
                + "footprint before \(Measured.mebibytes(before)), after \(Measured.mebibytes(after))"
        )
    }

    /// The activity log stays small: ten thousand changes, written the way the executor writes them
    /// (a started row, then its result, each handed to the disk), take well under 10 MB. Paths are
    /// as long as real downloads' are, and every row carries a content hash, as a duplicate's does.
    @Test func tenThousandLoggedChangesStayUnderTenMegabytes() async throws {
        try await withLogSandbox { sandbox in
            let location = try sandbox.realLocation()
            let databaseURL = try #require(location.databaseURL)
            let log = try await ActivityLog.open(location)
            let count = 10_000
            let limit: Int64 = 10 * 1_000_000
            let largestWhileWriting = Mutex<Int64>(0)
            let clock = ContinuousClock()
            let start = clock.now

            let runID = try LogSamples.writeRun(
                to: log,
                startedAt: .now,
                count: count,
                size: 2_500_000,
                namePrefix: "Quarterly report – final version for review"
            ) { written in
                // The write-ahead file grows between checkpoints, so the size is watched on the way.
                if written.isMultiple(of: 250) {
                    let size = FileFacts.databaseSize(at: databaseURL)
                    largestWhileWriting.withLock { $0 = max($0, size) }
                }
            }

            let elapsed = clock.now - start
            let size = FileFacts.databaseSize(at: databaseURL)
            let largest = max(size, largestWhileWriting.withLock { $0 })
            #expect(try await log.changes(inRun: runID).count == count)
            #expect(try await log.totals() == ActivityTotals(bytesMovedToTrash: 2_500_000 * Int64(count), filesCleaned: count))
            #expect(size < limit, "\(size) bytes for \(count) changes")
            #expect(largest < limit, "\(largest) bytes at the largest, write-ahead file included")
            let megabytes = { (bytes: Int64) in (Double(bytes) / 1_000_000).formatted(.number.precision(.fractionLength(2))) }
            Self.report("activity log with \(count) changes: \(megabytes(size)) MB on disk (\(size / Int64(count)) bytes per change), \(megabytes(largest)) MB at the largest while writing, written in \(Measured.milliseconds(elapsed).formatted(.number.precision(.fractionLength(0)))) ms")
        }
    }
}
