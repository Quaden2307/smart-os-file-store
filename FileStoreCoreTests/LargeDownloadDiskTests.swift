import FileStoreCore
import Foundation
import Testing

/// Review Large Downloads on real folders: the space on disk the scan reads, the plan the fake
/// Downloads folder gives, the run, the activity log and undo. The threshold is 1 MB so the files
/// stay small. Files go through the real Trash; `TrashedFiles` removes the test's own afterwards
/// when the runner may.
@Suite("Review Large Downloads on disk")
struct LargeDownloadDiskTests {
    private typealias Names = FakeDownloadsFolder.Names

    private static let settings = CleanupSettings(largeDownloadMegabytes: 1)

    /// 2 MB of real bytes: taken on disk, not a hole.
    private static let bigBytes = Data(repeating: 0x5A, count: 2_000_000)

    private func plan(_ folder: URL) async throws -> CleanupPlan {
        try #require(
            try await CleanupPlanners.plan(
                .reviewLargeDownloads,
                records: try await RelocationPlans.records(in: folder),
                in: folder,
                eligibility: CandidateEligibility(),
                keptItems: KeptItems(),
                installers: .testing(applications: []),
                settings: Self.settings
            )
        )
    }

    private func execute(_ plan: CleanupPlan, log: ActivityLog) async -> CleanupResult {
        await CleanupExecutor(recorder: log).execute(plan: plan, confirmedChangeIDs: Set(plan.changes.map(\.id)))
    }

    /// Writes `big.iso` (2 MB on disk) and `sparse.img` (600 MB long, nothing allocated), settled.
    private func writeFileAndSparseFile(in folder: URL) throws {
        try Self.bigBytes.write(to: folder.appending(path: "big.iso"))
        try BulkFiles.writeSparseFile(folder.appending(path: "sparse.img"), size: 600_000_000)
        try FileDates.settle([folder.appending(path: "big.iso"), folder.appending(path: "sparse.img")])
    }

    /// Writes the package `Big.app` holding two files of 700 KB each, settled.
    private func writePackage(in folder: URL) throws -> URL {
        let package = folder.appending(path: "Big.app", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: package, withIntermediateDirectories: false)
        let files = ["one.bin", "two.bin"].map { package.appending(path: $0) }
        for file in files {
            try Data(repeating: 0x33, count: 700_000).write(to: file)
        }
        try FileDates.settle(files + [package])
        return package
    }

    private func cleanUp(_ result: CleanupResult) {
        TrashedFiles.remove(result) { $0.lastPathComponent == "big.iso" ? Self.bigBytes : nil }
        TrashedFiles.removeFolders(result) { url in
            url.lastPathComponent == "Big.app"
                ? ["one.bin": Data(repeating: 0x33, count: 700_000), "two.bin": Data(repeating: 0x33, count: 700_000)]
                : nil
        }
    }

    // MARK: - The scan and the plan

    @Test func aSparseFileIsReportedAtItsRealSizeAndNotListed() async throws {
        try await withTemporaryFolderAsync { folder in
            try writeFileAndSparseFile(in: folder)
            let records = try await RelocationPlans.records(in: folder)
            let sparse = try RelocationPlans.record(named: "sparse.img", in: records)
            let big = try RelocationPlans.record(named: "big.iso", in: records)
            #expect(sparse.sizeInBytes == 600_000_000)
            #expect(try #require(sparse.allocatedSizeInBytes) < 1_000_000)
            #expect(try #require(big.allocatedSizeInBytes) >= 2_000_000)

            let plan = try await plan(folder)
            #expect(plan.changes.map(\.record.displayName) == ["big.iso"])
            #expect(plan.changes.first?.reason == .largeDownload(sizeOnDisk: big.allocatedSizeInBytes ?? 0, lastOpened: nil, opensRecorded: true))
            #expect(plan.changes.allSatisfy { $0.reason.isReviewOnly })
            #expect(plan.topLevelSizeOnDisk == (big.allocatedSizeInBytes ?? 0) + (sparse.allocatedSizeInBytes ?? 0))
        }
    }

    @Test func aPackageTotalsItsContents() async throws {
        try await withTemporaryFolderAsync { folder in
            _ = try writePackage(in: folder)
            let record = try RelocationPlans.record(named: "Big.app", in: try await RelocationPlans.records(in: folder))
            #expect(record.kind == .package)
            #expect(record.contentSizeInBytes == 1_400_000)
            #expect(try #require(record.allocatedSizeInBytes) >= 1_400_000)

            let plan = try await plan(folder)
            #expect(plan.changes.map(\.record.displayName) == ["Big.app"])
            #expect(plan.changes.first?.sizeInBytes == 1_400_000)
        }
    }

    @Test func theFakeFolderListsTheWrittenVideoAndNotTheSparseBackup() async throws {
        try await withFakeDownloadsFolder { fixture in
            let plan = try await plan(fixture.url)
            #expect(plan.changes.map(\.record.displayName) == [Names.bigVideo])
            #expect(plan.changes.allSatisfy { $0.reason.isReviewOnly })
            // The default threshold lists nothing there.
            let byDefault = try #require(
                try await CleanupPlanners.plan(
                    .reviewLargeDownloads,
                    records: try await RelocationPlans.records(in: fixture.url),
                    in: fixture.url,
                    eligibility: CandidateEligibility(),
                    keptItems: KeptItems(),
                    installers: .testing(applications: [])
                )
            )
            #expect(byDefault.isEmpty)
        }
    }

    // MARK: - The run, the log and undo

    @Test func trashingAFileIsLoggedAndPlanningAgainProposesNothing() async throws {
        try await withTemporaryFolderAsync { folder in
            try writeFileAndSparseFile(in: folder)
            let log = try await ActivityLog.open(.inMemory)
            let plan = try await plan(folder)
            let change = try #require(plan.changes.first)

            let result = await execute(plan, log: log)
            defer { cleanUp(result) }

            #expect(result.trashedCount == 1)
            #expect(DiskState.entryNames(in: folder) == ["sparse.img"])
            let runID = try #require(result.runID)
            #expect(try await log.run(id: runID)?.action == .reviewLargeDownloads)
            let rows = try await log.changes(inRun: runID)
            #expect(rows.count == 1)
            #expect(rows.first?.outcome == .trashed)
            #expect(rows.first?.reason == change.reason)
            #expect(rows.first?.originalPath == change.originalPath)
            #expect(rows.first?.sizeInBytes == 2_000_000)
            #expect(rows.first?.fileNumber != nil)
            #expect(try await log.totals() == ActivityTotals(bytesMovedToTrash: 2_000_000, filesCleaned: 1))

            #expect(try await self.plan(folder).isEmpty)
        }
    }

    @Test func undoingTheRunPutsTheFileAndThePackageBack() async throws {
        try await withTemporaryFolderAsync { folder in
            try writeFileAndSparseFile(in: folder)
            _ = try writePackage(in: folder)
            let log = try await ActivityLog.open(.inMemory)
            let plan = try await plan(folder)
            #expect(plan.changes.map(\.record.displayName) == ["big.iso", "Big.app"])

            let result = await execute(plan, log: log)
            defer { cleanUp(result) }
            #expect(result.trashedCount == 2)
            #expect(DiskState.entryNames(in: folder) == ["sparse.img"])
            let runID = try #require(result.runID)
            #expect(try await log.changes(inRun: runID).map(\.reason) == plan.changes.map(\.reason))

            let undo = try await UndoFixtures.undo(.run(runID), in: folder, trash: .system, log: log)

            #expect(Set(undo.undone.map(\.originalName)) == ["big.iso", "Big.app"])
            #expect(undo.notUndone.isEmpty)
            #expect(Set(DiskState.entryNames(in: folder)) == ["big.iso", "Big.app", "sparse.img"])
            #expect(try await log.totals() == .zero)
        }
    }

    @Test func itemsChangedSinceThePlanAreLeftAlone() async throws {
        try await withTemporaryFolderAsync { folder in
            try writeFileAndSparseFile(in: folder)
            let package = try writePackage(in: folder)
            let log = try await ActivityLog.open(.inMemory)
            let plan = try await plan(folder)
            // One byte more in the file; a new file inside the package, dated back like the rest.
            let handle = try FileHandle(forWritingTo: folder.appending(path: "big.iso"))
            try handle.seekToEnd()
            try handle.write(contentsOf: Data([1]))
            try handle.close()
            try FileDates.settle([folder.appending(path: "big.iso")])
            let added = package.appending(path: "three.bin")
            try Data("new".utf8).write(to: added)
            try FileDates.settle([added, package])

            let result = await execute(plan, log: log)

            #expect(result.trashedCount == 0)
            #expect(try RelocationPlans.outcome(for: "big.iso", in: result) == .skipped(.changedSinceScan))
            #expect(try RelocationPlans.outcome(for: "Big.app", in: result) == .skipped(.changedSinceScan))
            #expect(DiskState.entryNames(in: folder).count == 3)
        }
    }
}
