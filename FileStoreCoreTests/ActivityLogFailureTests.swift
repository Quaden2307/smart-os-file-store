import FileStoreCore
import Foundation
import Testing

/// When the activity log fails. A write that fails stops the run: no file is changed that could not
/// be recorded first, no file is handled twice, and a file that was changed is never lost track of.
/// A database that is damaged is found when it is opened, and can be set aside, never removed.
@Suite("Activity log failure")
struct ActivityLogFailureTests {
    private let scanner = FolderScanner()
    private let planner = DuplicatePlanner()
    private let now = Date(timeIntervalSince1970: 1_800_000_000)

    /// A folder with `a.txt` and three identical copies of it, and the plan to trash the copies.
    private func duplicates(in folder: URL) async throws -> CleanupPlan {
        try FileDates.writeSettled(
            ["a.txt": "same bytes", "a (1).txt": "same bytes", "a (2).txt": "same bytes", "a (3).txt": "same bytes"],
            in: folder
        )
        let records = try await scanner.scan(.temporary(folder)).records
        return try await planner.plan(records: records, in: .temporary(folder))
    }

    private func all(_ plan: CleanupPlan) -> Set<ProposedChange.ID> {
        Set(plan.changes.map(\.id))
    }

    private func outcomes(_ result: CleanupResult) -> [String: CleanupItemOutcome] {
        Dictionary(uniqueKeysWithValues: result.items.map { ($0.change.record.displayName, $0.outcome) })
    }

    private func isTrashed(_ outcome: CleanupItemOutcome?) -> Bool {
        if case .trashed = outcome {
            return true
        }
        return false
    }

    // MARK: - A write fails during a run

    @Test func aRunThatCannotBeOpenedInTheLogTouchesNothing() async throws {
        let temp = try TemporaryFolder.make()
        defer { temp.remove() }
        let plan = try await duplicates(in: temp.url)
        let before = DiskState.snapshot(of: temp.url)
        let spy = SpyRecorder(failing: SpyRecorder.Failure(kind: .beginRun, occurrence: 0))

        let result = await CleanupExecutor(recorder: spy).execute(plan: plan, confirmedChangeIDs: all(plan))

        #expect(result.items.count == 3)
        #expect(result.items.allSatisfy { $0.outcome == .skipped(.activityLogUnavailable) })
        #expect(result.logFailure == CleanupLogFailure(error: .writeFailed(code: 13), unrecordedChangeID: nil))
        #expect(result.trashedCount == 0)
        #expect(DiskState.snapshot(of: temp.url) == before)
        #expect(spy.callNames == [])
    }

    @Test func aStartedRowThatCannotBeWrittenLeavesItsFileAloneAndStopsTheRun() async throws {
        let temp = try TemporaryFolder.make()
        defer { temp.remove() }
        let plan = try await duplicates(in: temp.url)
        // The second file's started row fails.
        let spy = SpyRecorder(failing: SpyRecorder.Failure(kind: .recordIntent, occurrence: 1))

        let result = await CleanupExecutor(recorder: spy).execute(plan: plan, confirmedChangeIDs: all(plan))
        defer { TrashedFiles.remove(result) { _ in Data("same bytes".utf8) } }

        let outcomes = outcomes(result)
        #expect(isTrashed(outcomes["a (1).txt"]))
        #expect(outcomes["a (2).txt"] == .skipped(.activityLogUnavailable))
        #expect(outcomes["a (3).txt"] == .skipped(.activityLogUnavailable))
        // Nothing was started for the second file, so nothing is unaccounted for.
        #expect(result.logFailure == CleanupLogFailure(error: .writeFailed(code: 13), unrecordedChangeID: nil))
        #expect(DiskState.entryNames(in: temp.url) == ["a (2).txt", "a (3).txt", "a.txt"])
        #expect(DiskState.text(of: temp.url.appending(path: "a (2).txt")) == "same bytes")
        // The run stopped: no further row, and the run was not closed as if it had finished.
        #expect(spy.callNames == ["beginRun", "recordIntent a (1).txt", "recordResult a (1).txt"])
    }

    @Test func aResultThatCannotBeWrittenKeepsTheStartedRowAndStopsTheRun() async throws {
        let temp = try TemporaryFolder.make()
        defer { temp.remove() }
        let plan = try await duplicates(in: temp.url)
        let log = try await ActivityLog.open(.inMemory, now: now)
        // The first file is moved, and then its result cannot be written.
        let spy = SpyRecorder(failing: SpyRecorder.Failure(kind: .recordResult, occurrence: 0), forwardingTo: log)

        let result = await CleanupExecutor(recorder: spy).execute(plan: plan, confirmedChangeIDs: all(plan))
        defer { TrashedFiles.remove(result) { _ in Data("same bytes".utf8) } }

        // The caller is told the truth about the file: it is in the Trash.
        let outcomes = outcomes(result)
        let first = try #require(plan.changes.first { $0.record.displayName == "a (1).txt" })
        #expect(isTrashed(outcomes["a (1).txt"]))
        #expect(outcomes["a (2).txt"] == .skipped(.activityLogUnavailable))
        #expect(outcomes["a (3).txt"] == .skipped(.activityLogUnavailable))
        #expect(result.logFailure == CleanupLogFailure(error: .writeFailed(code: 13), unrecordedChangeID: first.id))
        #expect(DiskState.entryNames(in: temp.url) == ["a (2).txt", "a (3).txt", "a.txt"])

        // The log has not lost track of it: its row says the change was started, and where from.
        let run = try #require(try await log.runs().first)
        #expect(run.state == .running)
        #expect(run.doneCount == 0)
        let changes = try await log.changes(inRun: run.id)
        #expect(changes.map(\.outcome) == [.started])
        #expect(changes.first?.originalPath == first.originalPath)
        #expect(changes.first?.contentHash == plan.duplicateGroups.first?.contentHash)
        #expect(try await log.totals() == .zero)

        // The same plan again, with a log that works: the file that was moved is not handled a
        // second time, and the two that were left alone are now moved and recorded.
        let again = await CleanupExecutor(recorder: log).execute(plan: plan, confirmedChangeIDs: all(plan))
        defer { TrashedFiles.remove(again) { _ in Data("same bytes".utf8) } }
        let outcomesAgain = self.outcomes(again)
        #expect(outcomesAgain["a (1).txt"] == .skipped(.notFound))
        #expect(isTrashed(outcomesAgain["a (2).txt"]))
        #expect(isTrashed(outcomesAgain["a (3).txt"]))
        #expect(again.logFailure == nil)
        #expect(DiskState.entryNames(in: temp.url) == ["a.txt"])
        #expect(try await log.totals() == ActivityTotals(bytesMovedToTrash: 20, filesCleaned: 2))
    }

    @Test func aMoveWhoseStartedRowFailsMakesNoFolderAndMovesNothing() async throws {
        let temp = try TemporaryFolder.make()
        defer { temp.remove() }
        try FileDates.writeSettled(["a.txt": "mine", "b.txt": "also mine"], in: temp.url)
        let archive = temp.url.appending(path: "Old downloads", directoryHint: .isDirectory)
        let plan = try await RelocationPlans.move([("a.txt", archive, "a.txt"), ("b.txt", archive, "b.txt")], in: temp.url)
        let before = DiskState.snapshot(of: temp.url)
        let spy = SpyRecorder(failing: SpyRecorder.Failure(kind: .recordIntent, occurrence: 0))

        let result = await CleanupExecutor(recorder: spy).execute(plan: plan, confirmedChangeIDs: all(plan))

        #expect(result.items.map(\.outcome) == [.skipped(.activityLogUnavailable), .skipped(.activityLogUnavailable)])
        #expect(result.items.allSatisfy { $0.createdFolders.isEmpty })
        #expect(!DiskState.exists(archive))
        #expect(DiskState.snapshot(of: temp.url) == before)
        #expect(result.logFailure?.unrecordedChangeID == nil)
    }

    /// The move happens and makes two folders, and then its result cannot be written. The log still
    /// names the folders, from the row written before anything was made, so they are not lost track of.
    @Test func aMoveWhoseResultCannotBeWrittenStillNamesTheFoldersItWasToMake() async throws {
        let temp = try TemporaryFolder.make()
        defer { temp.remove() }
        try FileDates.writeSettled(["old.txt": "old"], in: temp.url)
        let archive = temp.url.appending(path: "Old downloads", directoryHint: .isDirectory)
        let year = archive.appending(path: "2024", directoryHint: .isDirectory)
        let plan = try await RelocationPlans.move([("old.txt", year, "old.txt")], in: temp.url)
        let log = try await ActivityLog.open(.inMemory, now: now)
        let spy = SpyRecorder(failing: SpyRecorder.Failure(kind: .recordResult, occurrence: 0), forwardingTo: log)

        let result = await CleanupExecutor(recorder: spy).execute(plan: plan, confirmedChangeIDs: all(plan))

        let item = try RelocationPlans.item(for: "old.txt", in: result)
        guard case .moved = item.outcome else {
            Issue.record("expected the move to happen, got \(item.outcome)")
            return
        }
        #expect(DiskState.isFolder(year))
        let run = try #require(try await log.runs().first)
        let row = try #require(try await log.changes(inRun: run.id).first)
        #expect(row.outcome == .started)
        let planned = [archive, year].map { $0.path(percentEncoded: false) }
        #expect(row.createdFolders.map { canonicalPath(URL(filePath: $0)) } == planned.map { canonicalPath(URL(filePath: $0)) })
        #expect(item.createdFolders.map { canonicalPath($0) } == planned.map { canonicalPath(URL(filePath: $0)) })
    }

    @Test func aRenameWhoseResultCannotBeWrittenIsReportedAsDone() async throws {
        let temp = try TemporaryFolder.make()
        defer { temp.remove() }
        try FileDates.writeSettled(["invoice (1).pdf": "invoice", "notes (1).txt": "notes"], in: temp.url)
        let plan = try await RelocationPlans.rename([("invoice (1).pdf", "invoice.pdf"), ("notes (1).txt", "notes.txt")], in: temp.url)
        let spy = SpyRecorder(failing: SpyRecorder.Failure(kind: .recordResult, occurrence: 0, error: .inconsistent))

        let result = await CleanupExecutor(recorder: spy).execute(plan: plan, confirmedChangeIDs: all(plan))

        #expect(result.renamed.map(\.change.record.displayName) == ["invoice (1).pdf"])
        #expect(try RelocationPlans.outcome(for: "notes (1).txt", in: result) == .skipped(.activityLogUnavailable))
        #expect(result.logFailure == CleanupLogFailure(error: .inconsistent, unrecordedChangeID: plan.changes.first?.id))
        #expect(DiskState.entryNames(in: temp.url) == ["invoice.pdf", "notes (1).txt"])
    }

    @Test func aRunThatCannotBeClosedInTheLogIsReported() async throws {
        let temp = try TemporaryFolder.make()
        defer { temp.remove() }
        let plan = try await duplicates(in: temp.url)
        let spy = SpyRecorder(failing: SpyRecorder.Failure(kind: .finishRun, occurrence: 0))

        let result = await CleanupExecutor(recorder: spy).execute(plan: plan, confirmedChangeIDs: all(plan))
        defer { TrashedFiles.remove(result) { _ in Data("same bytes".utf8) } }

        // Every file was moved and recorded; only the run's last line is missing.
        #expect(result.trashedCount == 3)
        #expect(result.logFailure == CleanupLogFailure(error: .writeFailed(code: 13), unrecordedChangeID: nil))
        #expect(spy.results.count == 3)
    }

    @Test func aClosedLogStopsTheRunBeforeAnyFileIsTouched() async throws {
        let temp = try TemporaryFolder.make()
        defer { temp.remove() }
        let plan = try await duplicates(in: temp.url)
        let before = DiskState.snapshot(of: temp.url)
        let log = try await ActivityLog.open(.inMemory, now: now)
        try await log.close()

        let result = await CleanupExecutor(recorder: log).execute(plan: plan, confirmedChangeIDs: all(plan))

        #expect(result.items.allSatisfy { $0.outcome == .skipped(.activityLogUnavailable) })
        guard case .writeFailed = result.logFailure?.error else {
            Issue.record("expected a failed write, got \(String(describing: result.logFailure))")
            return
        }
        #expect(DiskState.snapshot(of: temp.url) == before)
    }

    /// The real database, held locked by another connection the way a second copy of the app in
    /// the middle of a write would hold it.
    @Test func aDatabaseLockedByAnotherConnectionFailsTheWrite() async throws {
        try await withLogSandbox { sandbox in
            let location = try sandbox.realLocation()
            let databaseURL = try #require(location.databaseURL)
            let log = try await ActivityLog.open(location, now: now)
            let other = try RawDatabase(databaseURL)
            try other.execute("BEGIN EXCLUSIVE")
            let start = CleanupRunStart(action: .findDuplicates, folder: log.downloads(at: LogSamples.folderURL), confirmedCount: 1, startedAt: now)

            do {
                _ = try log.beginRun(start)
                Issue.record("a write went through a locked database")
            } catch ActivityLogError.writeFailed {
                // After waiting for the lock, a typed failure the executor stops on.
            }

            // Once the other connection lets go, the log works again and holds nothing half-written.
            try other.execute("COMMIT")
            #expect(try await log.runs().isEmpty)
            _ = try log.beginRun(start)
            #expect(try await log.runs().count == 1)
        }
    }

    // MARK: - A database that is damaged

    @Test func aFileThatIsNotADatabaseIsFoundDamagedWhenOpened() async throws {
        try await withLogSandbox { sandbox in
            let location = try sandbox.realLocation()
            let databaseURL = try #require(location.databaseURL)
            try FileManager.default.createDirectory(at: databaseURL.deletingLastPathComponent(), withIntermediateDirectories: true)
            try Data(repeating: 0x5A, count: 8_192).write(to: databaseURL)

            await #expect(throws: ActivityLogError.damaged) {
                _ = try await ActivityLog.open(location, now: now)
            }
        }
    }

    @Test func aDatabaseWithADamagedPageIsFoundDamagedWhenOpened() async throws {
        try await withLogSandbox { sandbox in
            let location = try sandbox.realLocation()
            let databaseURL = try #require(location.databaseURL)
            let log = try await ActivityLog.open(location, now: now)
            try LogSamples.writeRun(to: log, startedAt: now, count: 400)
            try await log.close()
            // The file's first page, with its header, is left as it is; a stretch of the rows'
            // pages further in is overwritten, as a failing disk might leave it.
            let size = FileFacts.size(of: databaseURL)
            #expect(size > 40_960)
            let handle = try FileHandle(forUpdating: databaseURL)
            try handle.seek(toOffset: 16_384)
            try handle.write(contentsOf: Data(repeating: 0xFF, count: 16_384))
            try handle.close()

            await #expect(throws: ActivityLogError.damaged) {
                _ = try await ActivityLog.open(location, now: now)
            }
        }
    }

    @Test func startingAFreshLogKeepsTheDamagedFileBesideIt() async throws {
        try await withLogSandbox { sandbox in
            let location = try sandbox.realLocation()
            let databaseURL = try #require(location.databaseURL)
            let folder = databaseURL.deletingLastPathComponent()
            let damaged = Data(repeating: 0x5A, count: 8_192)
            let sideFile = Data("what a write-ahead file held".utf8)
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            try damaged.write(to: databaseURL)
            await #expect(throws: ActivityLogError.damaged) {
                _ = try await ActivityLog.open(location, now: now)
            }
            // A write-ahead file beside it, as a database that was in use leaves one. Written after
            // the failed attempt to open, since SQLite itself clears away one it cannot use.
            try sideFile.write(to: URL(filePath: databaseURL.path(percentEncoded: false) + "-wal"))

            let fresh = try await ActivityLog.startFresh(at: location, now: now)

            // The damaged file and its side file are kept, byte for byte, under a new name.
            let setAside = try #require(fresh.setAsideURL)
            #expect(setAside.lastPathComponent.hasPrefix("FileStore.damaged-"))
            #expect(setAside.lastPathComponent.hasSuffix(".sqlite"))
            #expect(canonicalPath(setAside.deletingLastPathComponent()) == canonicalPath(folder))
            #expect(try Data(contentsOf: setAside) == damaged)
            #expect(try Data(contentsOf: URL(filePath: setAside.path(percentEncoded: false) + "-wal")) == sideFile)
            // The fresh log works, starts empty, and is private like any other.
            #expect(try await fresh.log.runs().isEmpty)
            #expect(try await fresh.log.totals() == .zero)
            try LogSamples.writeRun(to: fresh.log, startedAt: now, count: 1)
            #expect(try await fresh.log.totals().filesCleaned == 1)
            #expect(FileFacts.permissions(of: databaseURL) == 0o600)

            // A second damaged database in the same second gets a name of its own; the first stays.
            try await fresh.log.close()
            let secondDamaged = Data(repeating: 0x33, count: 4_096)
            for suffix in ["", "-wal", "-shm"] {
                try? FileManager.default.removeItem(at: URL(filePath: databaseURL.path(percentEncoded: false) + suffix))
            }
            try secondDamaged.write(to: databaseURL)
            let again = try await ActivityLog.startFresh(at: location, now: now)
            let secondAside = try #require(again.setAsideURL)
            #expect(secondAside != setAside)
            #expect(try Data(contentsOf: secondAside) == secondDamaged)
            #expect(try Data(contentsOf: setAside) == damaged)
        }
    }

    /// The database cannot be renamed (it is locked), after its write-ahead file already was. The
    /// write-ahead file goes back beside it, so the database still opens with its latest rows.
    @Test func aDatabaseThatCannotBeSetAsideKeepsItsSideFiles() async throws {
        try await withLogSandbox { sandbox in
            let location = try sandbox.realLocation()
            let databaseURL = try #require(location.databaseURL)
            let folder = databaseURL.deletingLastPathComponent()
            let walURL = URL(filePath: databaseURL.path(percentEncoded: false) + "-wal")
            let sideFile = Data("what a write-ahead file held".utf8)
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            try Data(repeating: 0x5A, count: 4_096).write(to: databaseURL)
            try sideFile.write(to: walURL)
            try FileManager.default.setAttributes([.immutable: true], ofItemAtPath: databaseURL.path(percentEncoded: false))
            defer { try? FileManager.default.setAttributes([.immutable: false], ofItemAtPath: databaseURL.path(percentEncoded: false)) }

            do {
                _ = try await ActivityLog.setAsideDatabase(at: location, now: now)
                Issue.record("a locked database was set aside")
            } catch ActivityLogError.unreadable {
                // Refused, with everything where it was.
            }

            #expect(try Data(contentsOf: walURL) == sideFile)
            #expect(DiskState.entryNames(in: folder) == ["FileStore.sqlite", "FileStore.sqlite-wal"])
        }
    }

    @Test func startingAFreshLogWhereThereIsNoneJustMakesOne() async throws {
        try await withLogSandbox { sandbox in
            let location = try sandbox.realLocation()

            let fresh = try await ActivityLog.startFresh(at: location, now: now)

            #expect(fresh.setAsideURL == nil)
            #expect(try await fresh.log.runs().isEmpty)
            #expect(try sandbox.applicationSupportContents().filter { $0.contains("damaged") } == [])
        }
    }
}
