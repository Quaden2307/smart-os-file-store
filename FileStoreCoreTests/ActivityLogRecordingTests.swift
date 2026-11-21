import FileStoreCore
import Foundation
import Synchronization
import Testing

/// What the executor leaves in the activity log: one run per confirmed cleanup and one row per
/// item, whatever happened to it, with the running totals. The executor here is the real one, on
/// small temporary folders, writing to a real log.
@Suite("Activity log recording")
struct ActivityLogRecordingTests {
    private let scanner = FolderScanner()
    private let planner = DuplicatePlanner()

    private func duplicatePlan(_ folder: URL) async throws -> CleanupPlan {
        let records = try await scanner.scan(.temporary(folder)).records
        return try await planner.plan(records: records, in: .temporary(folder))
    }

    private func change(named name: String, in changes: [ActivityChange]) throws -> ActivityChange {
        try #require(changes.first { URL(filePath: $0.originalPath).lastPathComponent == name }, "no row for \(name)")
    }

    private func all(_ plan: CleanupPlan) -> Set<ProposedChange.ID> {
        Set(plan.changes.map(\.id))
    }

    // MARK: - One row per item

    @Test func trashedSkippedAndFailedItemsEachGetARow() async throws {
        let temp = try TemporaryFolder.make()
        defer { temp.remove() }
        try FileDates.writeSettled(
            ["a.txt": "same bytes", "a (1).txt": "same bytes", "a (2).txt": "same bytes", "a (3).txt": "same bytes"],
            in: temp.url
        )
        let plan = try await duplicatePlan(temp.url)
        #expect(plan.changes.count == 3)
        // After the plan: one copy is locked, and one is rewritten with other bytes of another length.
        let lockedPath = temp.url.appending(path: "a (2).txt").path(percentEncoded: false)
        try FileManager.default.setAttributes([.immutable: true], ofItemAtPath: lockedPath)
        defer { try? FileManager.default.setAttributes([.immutable: false], ofItemAtPath: lockedPath) }
        try Data("rewritten since the scan".utf8).write(to: temp.url.appending(path: "a (3).txt"))
        let log = try await ActivityLog.open(.inMemory)
        let before = Date.now

        let result = await CleanupExecutor(recorder: log).execute(plan: plan, confirmedChangeIDs: all(plan))
        defer { TrashedFiles.remove(result) { _ in Data("same bytes".utf8) } }

        let runs = try await log.runs()
        let run = try #require(runs.first)
        #expect(runs.count == 1)
        #expect(run.action == .findDuplicates)
        #expect(run.state == .finished)
        #expect(canonicalPath(URL(filePath: run.folderPath)) == canonicalPath(temp.url))
        #expect(run.confirmedCount == 3)
        #expect(run.doneCount == 1)
        #expect(run.skippedCount == 1)
        #expect(run.failedCount == 1)
        #expect(run.bytesMovedToTrash == 10)
        #expect(run.startedAt >= before.addingTimeInterval(-1))
        #expect(try #require(run.finishedAt) >= run.startedAt)

        let changes = try await log.changes(inRun: run.id)
        #expect(changes.map(\.sequence) == [0, 1, 2])
        #expect(changes.allSatisfy { $0.runID == run.id && $0.operation == .moveToTrash && $0.undoneAt == nil })
        #expect(changes.allSatisfy { $0.reason == .sameContent(asFileNamed: "a.txt") })

        let trashed = try change(named: "a (1).txt", in: changes)
        let planned = try #require(plan.changes.first { $0.record.displayName == "a (1).txt" })
        let group = try #require(plan.duplicateGroups.first)
        #expect(trashed.outcome == .trashed)
        #expect(trashed.isDone)
        #expect(trashed.originalPath == planned.originalPath)
        #expect(trashed.sizeInBytes == 10)
        #expect(trashed.dateModified == planned.dateModified)
        #expect(trashed.contentHash == group.contentHash)
        #expect(trashed.attemptedAt >= before.addingTimeInterval(-1))
        // Where the file went, as the system reported it, which is what an undo will need.
        guard case .trashed(let trashURL?) = try RelocationPlans.outcome(for: "a (1).txt", in: result) else {
            Issue.record("the Trash did not report where the file went")
            return
        }
        #expect(trashed.resultingPath == trashURL.path(percentEncoded: false))
        #expect(trashed.expectedPath == trashed.resultingPath)

        let failed = try change(named: "a (2).txt", in: changes)
        #expect(failed.outcome == .failed(.fileIsLocked))
        #expect(!failed.isDone)
        #expect(failed.resultingPath == nil)
        #expect(failed.expectedPath == failed.originalPath)

        let skipped = try change(named: "a (3).txt", in: changes)
        #expect(skipped.outcome == .skipped(.changedSinceScan))
        #expect(skipped.contentHash == nil)

        #expect(try await log.totals() == ActivityTotals(bytesMovedToTrash: 10, filesCleaned: 1))
    }

    @Test func renamedAndMovedItemsEachGetARowWithWhereTheyWent() async throws {
        let temp = try TemporaryFolder.make()
        defer { temp.remove() }
        try FileDates.writeSettled(["invoice (1).pdf": "invoice", "old.txt": "old", "taken (1).txt": "mine", "taken.txt": "theirs"], in: temp.url)
        let log = try await ActivityLog.open(.inMemory)
        let executor = CleanupExecutor(recorder: log)

        let renames = try await RelocationPlans.rename([("invoice (1).pdf", "invoice.pdf"), ("taken (1).txt", "taken.txt")], in: temp.url)
        let renameResult = await executor.execute(plan: renames, confirmedChangeIDs: all(renames))
        let archive = temp.url.appending(path: "Old downloads", directoryHint: .isDirectory).appending(path: "2024", directoryHint: .isDirectory)
        let moves = try await RelocationPlans.move([("old.txt", archive, "old.txt")], in: temp.url)
        let moveResult = await executor.execute(plan: moves, confirmedChangeIDs: all(moves))

        // Newest first.
        let runs = try await log.runs()
        #expect(runs.map(\.action) == [.archiveOldDownloads, .fixMessyNames])
        let moveRun = try #require(runs.first)
        let renameRun = try #require(runs.last)
        #expect(renameRun.doneCount == 1)
        #expect(renameRun.skippedCount == 1)
        #expect(renameRun.bytesMovedToTrash == 0)
        #expect(moveRun.doneCount == 1)

        let renamed = try change(named: "invoice (1).pdf", in: try await log.changes(inRun: renameRun.id))
        guard case .renamed(_, let newURL) = try RelocationPlans.outcome(for: "invoice (1).pdf", in: renameResult) else {
            Issue.record("the rename did not happen")
            return
        }
        #expect(renamed.operation == .rename)
        #expect(renamed.reason == .messyName(MessyNameFix(fixes: [])))
        #expect(renamed.outcome == .renamed)
        #expect(renamed.resultingPath == newURL.path(percentEncoded: false))
        #expect(renamed.contentHash == nil)
        #expect(renamed.createdFolders == [])

        // A rename refused by the volume, after its row was started: the row says why, and still
        // names where the file was to go.
        let refused = try change(named: "taken (1).txt", in: try await log.changes(inRun: renameRun.id))
        #expect(refused.outcome == .skipped(.destinationExists(name: "taken.txt")))
        #expect(refused.resultingPath == renames.changes.last?.destinationPath)
        #expect(refused.expectedPath == refused.originalPath)

        let moved = try change(named: "old.txt", in: try await log.changes(inRun: moveRun.id))
        let movedItem = try RelocationPlans.item(for: "old.txt", in: moveResult)
        guard case .moved(_, let movedURL) = movedItem.outcome else {
            Issue.record("the move did not happen")
            return
        }
        #expect(moved.operation == .move)
        #expect(moved.reason == RelocationPlans.archiveReason)
        #expect(moved.outcome == .moved)
        #expect(moved.resultingPath == movedURL.path(percentEncoded: false))
        // Both folders were made for this move, and an undo will have to know.
        #expect(moved.createdFolders == movedItem.createdFolders.map { $0.path(percentEncoded: false) })
        #expect(moved.createdFolders.count == 2)

        // Renames and moves clean files without moving a byte to the Trash.
        #expect(try await log.totals() == ActivityTotals(bytesMovedToTrash: 0, filesCleaned: 2))
    }

    // MARK: - Order of writes

    @Test func theStartedRowIsInTheLogBeforeTheFileChanges() async throws {
        let temp = try TemporaryFolder.make()
        defer { temp.remove() }
        try FileDates.writeSettled(["a.txt": "same bytes", "a (1).txt": "same bytes"], in: temp.url)
        let plan = try await duplicatePlan(temp.url)
        let log = try await ActivityLog.open(.inMemory)
        let spy = SpyRecorder(forwardingTo: log)
        let duplicate = temp.url.appending(path: "a (1).txt")
        let seenAtTheChange = ConcurrentLog<[String]>()
        let fileWasStillThere = ConcurrentLog<Bool>()

        let result = await CleanupExecutor(recorder: spy).execute(
            plan: plan,
            confirmedChangeIDs: all(plan),
            beforeChange: { _ in
                seenAtTheChange.append(spy.callNames)
                fileWasStillThere.append(DiskState.exists(duplicate))
            }
        )
        defer { TrashedFiles.remove(result) { _ in Data("same bytes".utf8) } }

        #expect(seenAtTheChange.values == [["beginRun", "recordIntent a (1).txt"]])
        #expect(fileWasStillThere.values == [true])
        #expect(spy.callNames == ["beginRun", "recordIntent a (1).txt", "recordResult a (1).txt", "finishRun"])
        #expect(!DiskState.exists(duplicate))
        #expect(result.logFailure == nil)
    }

    @Test func aMovesStartedRowNamesTheFoldersItIsAboutToMake() async throws {
        let temp = try TemporaryFolder.make()
        defer { temp.remove() }
        try FileDates.writeSettled(["a.txt": "a", "b.txt": "b"], in: temp.url)
        let archive = temp.url.appending(path: "Old downloads", directoryHint: .isDirectory)
        let year = archive.appending(path: "2024", directoryHint: .isDirectory)
        let plan = try await RelocationPlans.move([("a.txt", year, "a.txt"), ("b.txt", year, "b.txt")], in: temp.url)
        let spy = SpyRecorder()
        let foldersAtTheChange = ConcurrentLog<Bool>()

        _ = await CleanupExecutor(recorder: spy).execute(
            plan: plan,
            confirmedChangeIDs: all(plan),
            beforeChange: { _ in foldersAtTheChange.append(DiskState.exists(archive)) }
        )

        let intents = spy.calls.compactMap { call -> CleanupChangeIntent? in
            if case .recordIntent(let intent) = call {
                return intent
            }
            return nil
        }
        // The first move makes both folders; they were named before either existed. The second
        // finds them made and has none to make.
        #expect(intents.map { $0.foldersToMake.map(canonicalPath) } == [[archive, year].map(canonicalPath), []])
        #expect(foldersAtTheChange.values == [false, true])
    }

    @Test func anItemRefusedBeforeItsChangeGetsItsOnlyRowRightAfter() async throws {
        let temp = try TemporaryFolder.make()
        defer { temp.remove() }
        try FileDates.writeSettled(["a.txt": "same bytes", "a (1).txt": "same bytes", "a (2).txt": "same bytes"], in: temp.url)
        let plan = try await duplicatePlan(temp.url)
        try FileManager.default.removeItem(at: temp.url.appending(path: "a (1).txt"))
        let spy = SpyRecorder()

        let result = await CleanupExecutor(recorder: spy).execute(plan: plan, confirmedChangeIDs: all(plan))
        defer { TrashedFiles.remove(result) { _ in Data("same bytes".utf8) } }

        // The missing file never got a started row; its one row came before the next file was looked at.
        #expect(spy.callNames == ["beginRun", "recordResult a (1).txt", "recordIntent a (2).txt", "recordResult a (2).txt", "finishRun"])
        #expect(spy.results.first?.changeID == nil)
        #expect(spy.results.first?.item.outcome == .skipped(.notFound))
        #expect(spy.results.last?.changeID != nil)
    }

    // MARK: - Totals

    @Test func totalsAddUpAcrossRunsAndCountOnlyWhatWasDone() async throws {
        let log = try await ActivityLog.open(.inMemory)
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        try LogSamples.writeRun(to: log, startedAt: now, count: 2, size: 1_000)
        try LogSamples.writeRun(to: log, startedAt: now.addingTimeInterval(60), count: 3, size: 10)
        // A run in which nothing was done adds nothing.
        let runID = try log.beginRun(CleanupRunStart(action: .findDuplicates, folder: log.downloads(at: LogSamples.folderURL), confirmedCount: 2, startedAt: now))
        let skipped = CleanupItemResult(change: LogSamples.trashChange("gone.pdf", size: 999), outcome: .skipped(.notFound))
        let failed = CleanupItemResult(change: LogSamples.trashChange("locked.pdf", size: 999), outcome: .failed(.fileIsLocked))
        try log.recordResult(CleanupChangeResult(runID: runID, changeID: nil, sequence: 0, item: skipped, attemptedAt: now))
        try log.recordResult(CleanupChangeResult(runID: runID, changeID: nil, sequence: 1, item: failed, attemptedAt: now))
        try log.finishRun(CleanupRunFinish(runID: runID, finishedAt: now, wasCancelled: false, notReached: []))

        #expect(try await log.totals() == ActivityTotals(bytesMovedToTrash: 2_030, filesCleaned: 5))
        let run = try #require(try await log.runs().first { $0.id == runID })
        #expect(run.doneCount == 0)
        #expect(run.skippedCount == 1)
        #expect(run.failedCount == 1)
        #expect(run.bytesMovedToTrash == 0)
    }

    @Test func aResultIsNeverCountedTwice() async throws {
        let log = try await ActivityLog.open(.inMemory)
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let runID = try log.beginRun(CleanupRunStart(action: .findDuplicates, folder: log.downloads(at: LogSamples.folderURL), confirmedCount: 1, startedAt: now))
        let change = LogSamples.trashChange("report (1).pdf", size: 700)
        let changeID = try log.recordedIntent(CleanupChangeIntent(runID: runID, sequence: 0, change: change, contentHash: nil, attemptedAt: now))
        let result = CleanupChangeResult(runID: runID, changeID: changeID, sequence: 0, item: LogSamples.trashed(change), attemptedAt: now)
        try log.recordResult(result)

        // The same row completed again would count the file twice; the log refuses, and nothing moves.
        #expect(throws: ActivityLogError.inconsistent) {
            try log.recordResult(result)
        }

        #expect(try await log.totals() == ActivityTotals(bytesMovedToTrash: 700, filesCleaned: 1))
        #expect(try await log.runs().first?.doneCount == 1)
        #expect(try await log.changes(inRun: runID).count == 1)
    }

    // MARK: - Runs that did not simply finish

    @Test func aCancelledRunRecordsTheItemsItNeverReached() async throws {
        let temp = try TemporaryFolder.make()
        defer { temp.remove() }
        try FileDates.writeSettled(
            ["a.txt": "same bytes", "a (1).txt": "same bytes", "a (2).txt": "same bytes", "a (3).txt": "same bytes"],
            in: temp.url
        )
        let plan = try await duplicatePlan(temp.url)
        let log = try await ActivityLog.open(.inMemory)
        let executor = CleanupExecutor(recorder: log)
        let confirmed = all(plan)

        // A child task, cancelled from inside once the first item is done: cancelling the test's own
        // task would skip the test.
        let task = Task {
            await executor.execute(plan: plan, confirmedChangeIDs: confirmed, onProgress: { progress in
                if progress.itemsCompleted == 1 {
                    withUnsafeCurrentTask { $0?.cancel() }
                }
            })
        }
        let result = await task.value
        defer { TrashedFiles.remove(result) { _ in Data("same bytes".utf8) } }

        #expect(result.wasCancelled)
        #expect(result.trashedCount == 1)
        let run = try #require(try await log.runs().first)
        #expect(run.state == .cancelled)
        #expect(run.finishedAt != nil)
        #expect(run.confirmedCount == 3)
        #expect(run.doneCount == 1)
        #expect(run.skippedCount == 2)
        #expect(run.doneCount + run.skippedCount + run.failedCount == run.confirmedCount)
        let changes = try await log.changes(inRun: run.id)
        #expect(changes.map(\.sequence) == [0, 1, 2])
        #expect(changes.map(\.outcome) == [.trashed, .skipped(.cancelled), .skipped(.cancelled)])
    }

    @Test func aRunLeftRunningIsFoundInterruptedWhenTheLogIsNextOpened() async throws {
        try await withLogSandbox { sandbox in
            let location = try sandbox.realLocation()
            let now = Date(timeIntervalSince1970: 1_800_000_000)
            let log = try await ActivityLog.open(location, now: now)
            // What a copy of the app that stopped in the middle of a change leaves behind: an open
            // run and a row that says the change was started.
            let runID = try log.beginRun(
                CleanupRunStart(action: .findDuplicates, folder: log.downloads(at: LogSamples.folderURL), confirmedCount: 2, startedAt: now)
            )
            let change = LogSamples.trashChange("report (1).pdf")
            _ = try log.recordedIntent(CleanupChangeIntent(runID: runID, sequence: 0, change: change, contentHash: nil, attemptedAt: now))
            #expect(try await log.runs().first?.state == .running)
            try await log.close()

            let reopened = try await ActivityLog.open(location, now: now.addingTimeInterval(3_600))

            let run = try #require(try await reopened.runs().first)
            #expect(run.state == .interrupted)
            #expect(run.finishedAt == nil)
            #expect(run.doneCount == 0)
            let changes = try await reopened.changes(inRun: runID)
            #expect(changes.map(\.outcome) == [.started])
            #expect(changes.first?.isDone == false)
            // Nobody knows whether the file went, so nothing was counted.
            #expect(try await reopened.totals() == .zero)
        }
    }

    // MARK: - What is stored comes back as it went in

    @Test func everyReasonSkipAndFailureComesBackAsItWentIn() async throws {
        let log = try await ActivityLog.open(.inMemory)
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let skips: [CleanupSkipReason] = [
            .changedSinceScan, .notFound, .accessDenied, .notDownloaded, .notARegularFile,
            .unreadable(reason: "Input/output error"), .keptFile, .notInPlan, .markedKept, .outsideFolder, .folderUnavailable,
            .keptFileMissing(name: "kept – ✓.pdf"), .keptFileNotVerified(name: "kept.pdf"), .lastInGroup,
            .archivedCopyMissing(name: "old – ✓.pdf"), .archivedCopyNotVerified(name: "old.pdf"), .cancelled,
            .destinationExists(name: "taken.txt"), .invalidName, .destinationOutsideFolder, .destinationNotAFolder,
            .destinationHidden, .activityLogUnavailable,
            .zipUnlistable(.damaged), .zipUnlistable(.encryptedListing), .zipUnlistable(.tooManyEntries),
            .zipUnlistable(.nameTooLong), .zipUnlistable(.unreadableNames),
            .unpackedCopyMissing(name: "project – ✓"), .unpackedCopyNotVerified(name: "contract.docx"),
            .unpackedCopyRecentlyChanged(name: "photos 2"),
            .diskImageInUse, .installedAppMissing(name: "Some App – ✓"), .installedAppChanged(name: "SomeApp"),
        ] + InstallerFacts.Problem.allCases.map(CleanupSkipReason.installerUnreadable)
        let failures: [CleanupExecutionError] = [
            .fileIsLocked, .accessDenied, .volumeReadOnly, .trashUnavailable, .renameUnsupported,
            .other(domain: "NSCocoaErrorDomain", code: 513, description: "You don’t have permission."),
        ]
        let archive = LogSamples.folderURL.appending(path: "Old downloads", directoryHint: .isDirectory)
        let done: [CleanupItemResult] = [
            LogSamples.trashed(LogSamples.trashChange("trashed.pdf", keptName: "résumé – final ✓.pdf")),
            // The Trash does not always say where a file went.
            CleanupItemResult(change: LogSamples.trashChange("trashed-nowhere.pdf"), outcome: .trashed(trashURL: nil)),
            CleanupItemResult(
                change: ProposedChange(record: LogSamples.record(named: "messy (1).pdf"), operation: .rename(to: "messy.pdf"), reason: .messyName(MessyNameFix(fixes: []))),
                outcome: .renamed(from: LogSamples.folderURL.appending(path: "messy (1).pdf"), to: LogSamples.folderURL.appending(path: "messy.pdf"))
            ),
            CleanupItemResult(
                change: ProposedChange(record: LogSamples.record(named: "old.pdf"), operation: .move(to: archive, name: "old.pdf"), reason: .notOpenedSince(Date(timeIntervalSince1970: 1_738_400_400.5))),
                outcome: .moved(from: LogSamples.folderURL.appending(path: "old.pdf"), to: archive.appending(path: "old.pdf")),
                createdFolders: [archive]
            ),
            LogSamples.trashed(
                ProposedChange(record: LogSamples.record(named: "project.zip"), operation: .moveToTrash, reason: .unpackedZip(unpackedTo: "project 2"))
            ),
            LogSamples.trashed(
                ProposedChange(record: LogSamples.record(named: "notes (1).txt"), operation: .moveToTrash, reason: .nearDuplicate(sameNameAs: "notes – ✓.txt"))
            ),
            LogSamples.trashed(
                ProposedChange(record: LogSamples.record(named: "manual.pdf"), operation: .moveToTrash, reason: .alreadyArchived(copyNamed: "manual – ✓.pdf"))
            ),
            CleanupItemResult(
                change: ProposedChange(record: LogSamples.record(named: "never.pdf"), operation: .move(to: archive, name: "never 2025-01-01.pdf"), reason: .neverOpened(downloadedOn: Date(timeIntervalSince1970: 1_735_722_000.123456))),
                outcome: .moved(from: LogSamples.folderURL.appending(path: "never.pdf"), to: archive.appending(path: "never 2025-01-01.pdf"))
            ),
            // Every value the evidence carries, with a name and path that JSON must escape.
            LogSamples.trashed(
                ProposedChange(
                    record: LogSamples.record(named: "SomeApp-2.1.dmg"),
                    operation: .moveToTrash,
                    reason: .usedInstaller(UsedInstallerEvidence(
                        strength: .strong,
                        name: "Some \"App\" – ✓",
                        version: "2.1",
                        installedAppPath: "/Applications/Some \"App\" – ✓.app",
                        bundleIdentifier: "com.example.SomeApp",
                        otherMatches: 1
                    ))
                )
            ),
            LogSamples.trashed(
                ProposedChange(
                    record: LogSamples.record(named: "Driver.pkg"),
                    operation: .moveToTrash,
                    reason: .usedInstaller(UsedInstallerEvidence(
                        strength: .possible,
                        name: "com.example.driver.pkg",
                        version: nil,
                        installedAppPath: nil,
                        bundleIdentifier: nil,
                        receiptIdentifiers: ["com.example.driver.pkg", "com.example.helper.pkg"]
                    ))
                )
            ),
        ]
        var items = done
        items += skips.enumerated().map { index, reason in
            CleanupItemResult(change: LogSamples.trashChange("skipped-\(index).pdf"), outcome: .skipped(reason))
        }
        items += failures.enumerated().map { index, error in
            CleanupItemResult(change: LogSamples.trashChange("failed-\(index).pdf"), outcome: .failed(error))
        }
        let runID = try log.beginRun(
            CleanupRunStart(action: .findDuplicates, folder: log.downloads(at: LogSamples.folderURL), confirmedCount: items.count, startedAt: now)
        )
        for (sequence, item) in items.enumerated() {
            try log.recordResult(CleanupChangeResult(runID: runID, changeID: nil, sequence: sequence, item: item, attemptedAt: now))
        }

        let changes = try await log.changes(inRun: runID)

        #expect(changes.count == items.count)
        let expectedOutcomes: [ActivityChange.Outcome] = [.trashed, .trashed, .renamed, .moved, .trashed, .trashed, .trashed, .moved, .trashed, .trashed]
            + skips.map { .skipped($0) }
            + failures.map { .failed($0) }
        #expect(changes.map(\.outcome) == expectedOutcomes)
        #expect(changes.map(\.reason) == items.map { Optional($0.change.reason) })
        let expectedOperations: [ActivityChange.Operation?] = [.moveToTrash, .moveToTrash, .rename, .move, .moveToTrash, .moveToTrash, .moveToTrash, .move, .moveToTrash, .moveToTrash]
            + Array(repeating: .moveToTrash, count: skips.count + failures.count)
        #expect(changes.map(\.operation) == expectedOperations)
        #expect(changes.map(\.originalPath) == items.map(\.change.originalPath))
        #expect(changes[0].resultingPath == "/Users/someone/.Trash/trashed.pdf")
        #expect(changes[1].resultingPath == nil)
        #expect(changes[1].expectedPath == nil)
        #expect(changes[2].resultingPath == "/Users/someone/Downloads/messy.pdf")
        #expect(changes[3].resultingPath == "/Users/someone/Downloads/Old downloads/old.pdf")
        #expect(changes[3].createdFolders == [archive.path(percentEncoded: false)])
        #expect(changes.allSatisfy { $0.attemptedAt == now })
    }

    @Test func aModificationDateComesBackBitForBit() async throws {
        let log = try await ActivityLog.open(.inMemory)
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        // Dates as `lstat` gives them, with nanoseconds no decimal text would carry exactly.
        let dates: [Date?] = [
            Date(timeIntervalSince1970: 1_731_600_000 + 123_456_789.0 / 1_000_000_000),
            Date(timeIntervalSince1970: 1_717_232_400.999_999_9),
            Date(timeIntervalSinceReferenceDate: 0.1 + 0.2),
            Date(timeIntervalSince1970: -86_400.5),
            nil,
        ]
        let runID = try log.beginRun(
            CleanupRunStart(action: .findDuplicates, folder: log.downloads(at: LogSamples.folderURL), confirmedCount: dates.count, startedAt: now)
        )
        for (sequence, date) in dates.enumerated() {
            let change = ProposedChange(
                record: LogSamples.record(named: "file-\(sequence).pdf", modified: date),
                operation: .moveToTrash,
                reason: .sameContent(asFileNamed: "kept.pdf")
            )
            try log.recordResult(
                CleanupChangeResult(runID: runID, changeID: nil, sequence: sequence, item: LogSamples.trashed(change), attemptedAt: now)
            )
        }

        let stored = try await log.changes(inRun: runID).map(\.dateModified)

        #expect(stored == dates)
        #expect(stored.map { $0?.timeIntervalSinceReferenceDate.bitPattern } == dates.map { $0?.timeIntervalSinceReferenceDate.bitPattern })
    }
}
