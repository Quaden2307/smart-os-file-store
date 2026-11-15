import FileStoreCore
import Foundation
import Testing

/// Undo on disk: each operation puts the very file back under its exact original path, never
/// overwrites anything, refuses a file it cannot prove is the one the change moved, and lowers the
/// totals by exactly what the change added, once. Trash items come from a stand-in Trash the test
/// controls, except in the one round trip through the real Trash.
@Suite("Undo executor")
struct UndoExecutorTests {
    private typealias Fixtures = UndoFixtures

    /// A temporary folder, a stand-in Trash and an empty log, removed afterwards.
    private func withSetup(_ body: (URL, FakeTrash, ActivityLog) async throws -> Void) async throws {
        let folder = try TemporaryFolder.make()
        defer { folder.remove() }
        let trash = try FakeTrash.make()
        defer { trash.remove() }
        let log = try await ActivityLog.open(.inMemory)
        try await body(folder.url, trash, log)
    }

    // MARK: - Each operation

    @Test func puttingBackFromTheTrashRestoresTheExactPathContentAndFile() async throws {
        try await withSetup { folder, trash, log in
            try Fixtures.write(["report (1).pdf": "report bytes"], in: folder)
            let original = folder.appending(path: "report (1).pdf")
            let before = try #require(Fixtures.snapshot(of: original))
            let (runID, trashURLs) = try await Fixtures.trashRun(["report (1).pdf"], in: folder, to: trash, log: log)
            #expect(try await log.totals() == ActivityTotals(bytesMovedToTrash: 12, filesCleaned: 1))

            let result = try await Fixtures.undo(.run(runID), in: folder, trash: trash.locator, log: log)

            #expect(result.undone.count == 1)
            #expect(result.notUndone.isEmpty)
            #expect(result.bytesTakenFromTrash == 12)
            #expect(Fixtures.snapshot(of: original) == before)
            #expect(DiskState.entryNames(in: folder) == ["report (1).pdf"])
            #expect(!DiskState.exists(try #require(trashURLs["report (1).pdf"])))
            // The change is marked undone, the undo is a run of its own, and the totals are back.
            let change = try await Fixtures.change(named: "report (1).pdf", inRun: runID, log: log)
            #expect(change.undoneAt != nil)
            #expect(change.expectedPath == change.originalPath)
            #expect(try await log.totals() == .zero)
            let undoRun = try #require(try await log.runs().first { $0.isUndo })
            #expect(undoRun.id == result.runID)
            #expect(undoRun.undoneAction == .findDuplicates)
            #expect(undoRun.state == .finished)
            #expect(undoRun.doneCount == 1)
            #expect(undoRun.bytesTakenFromTrash == 12)
            let undoRows = try await log.changes(inRun: undoRun.id)
            #expect(undoRows.map(\.outcome) == [.undone])
            #expect(undoRows.first?.undoesChangeID == change.id)
            #expect(undoRows.first?.operation == .putBackFromTrash)
            #expect(try await log.run(id: runID)?.undoneCount == 1)
        }
    }

    @Test func renamingBackGivesTheOldNameBack() async throws {
        try await withSetup { folder, trash, log in
            try Fixtures.write(["report (1).txt": "report"], in: folder)
            let original = folder.appending(path: "report (1).txt")
            let before = try #require(Fixtures.snapshot(of: original))
            let plan = try await RelocationPlans.rename([("report (1).txt", "report.txt")], in: folder)
            let cleanup = await CleanupExecutor(recorder: log).execute(plan: plan, confirmedChangeIDs: Set(plan.changes.map(\.id)))
            let runID = try #require(cleanup.runID)
            #expect(DiskState.entryNames(in: folder) == ["report.txt"])
            let change = try await Fixtures.change(named: "report (1).txt", inRun: runID, log: log)

            let result = try await Fixtures.undo(.change(change.id), in: folder, trash: trash.locator, log: log)

            #expect(result.undone.map(\.originalName) == ["report (1).txt"])
            #expect(DiskState.entryNames(in: folder) == ["report (1).txt"])
            #expect(Fixtures.snapshot(of: original) == before)
            #expect(try await log.totals() == .zero)
        }
    }

    @Test func movingBackPutsTheFileInItsFolderUnderItsNameAndLeavesTheMadeFolder() async throws {
        try await withSetup { folder, trash, log in
            try Fixtures.write(["setup.zip": "zip bytes"], in: folder)
            let original = folder.appending(path: "setup.zip")
            let before = try #require(Fixtures.snapshot(of: original))
            let archive = folder.appending(path: "Old downloads", directoryHint: .isDirectory)
            let plan = try await RelocationPlans.move([("setup.zip", archive, "setup.zip")], in: folder)
            let cleanup = await CleanupExecutor(recorder: log).execute(plan: plan, confirmedChangeIDs: Set(plan.changes.map(\.id)))
            let runID = try #require(cleanup.runID)
            #expect(DiskState.entryNames(in: archive) == ["setup.zip"])

            let result = try await Fixtures.undo(.run(runID), in: folder, trash: trash.locator, log: log)

            #expect(result.undone.count == 1)
            #expect(Fixtures.snapshot(of: original) == before)
            // The folder the move made stays: removing it would be a deletion.
            #expect(DiskState.entryNames(in: folder) == ["Old downloads", "setup.zip"])
            #expect(DiskState.entryNames(in: archive) == [])
        }
    }

    // MARK: - Never overwriting

    @Test func anOriginalNameThatIsTakenIsNeverOverwritten() async throws {
        try await withSetup { folder, trash, log in
            try Fixtures.write(["a.txt": "trashed"], in: folder)
            let (runID, trashURLs) = try await Fixtures.trashRun(["a.txt"], in: folder, to: trash, log: log)
            try Data("new file".utf8).write(to: folder.appending(path: "a.txt"))

            let plan = try await UndoPlanner(trash: trash.locator).plan(.run(runID), log: log, folderURL: folder)
            #expect(plan.steps.isEmpty)
            #expect(plan.refused.map(\.refusal) == [.originalNameTaken(name: "a.txt")])
            let result = await CleanupExecutor(recorder: log).undo(plan, trash: trash.locator)

            #expect(result.undone.isEmpty)
            #expect(try Fixtures.outcome(for: "a.txt", in: result) == .notUndone(.originalNameTaken(name: "a.txt")))
            #expect(DiskState.text(of: folder.appending(path: "a.txt")) == "new file")
            #expect(DiskState.text(of: try #require(trashURLs["a.txt"])) == "trashed")
            #expect(try await log.totals() == ActivityTotals(bytesMovedToTrash: 7, filesCleaned: 1))
        }
    }

    @Test func aFileThatTakesTheOriginalNameAtTheLastMomentIsNotOverwritten() async throws {
        try await withSetup { folder, trash, log in
            try Fixtures.write(["a.txt": "trashed"], in: folder)
            let (runID, trashURLs) = try await Fixtures.trashRun(["a.txt"], in: folder, to: trash, log: log)
            let original = folder.appending(path: "a.txt")

            // Free when planned and checked; taken an instant before the move.
            let result = try await Fixtures.undo(.run(runID), in: folder, trash: trash.locator, log: log) { _ in
                try? Data("raced in".utf8).write(to: original)
            }

            #expect(try Fixtures.outcome(for: "a.txt", in: result) == .notUndone(.originalNameTaken(name: "a.txt")))
            #expect(DiskState.text(of: original) == "raced in")
            #expect(DiskState.text(of: try #require(trashURLs["a.txt"])) == "trashed")
            let change = try await Fixtures.change(named: "a.txt", inRun: runID, log: log)
            #expect(change.undoneAt == nil)
        }
    }

    // MARK: - Proving it is the same file

    @Test func aTrashItemThatIsMissingChangedOrReplacedIsLeftWhereItIs() async throws {
        try await withSetup { folder, trash, log in
            let names = ["copied.txt", "edited.txt", "fine.txt", "gone.txt", "grown.txt"]
            try Fixtures.write(Dictionary(uniqueKeysWithValues: names.map { ($0, "content of \($0)") }), in: folder)
            let (runID, trashURLs) = try await Fixtures.trashRun(names, in: folder, to: trash, log: log)
            func inTrash(_ name: String) throws -> URL { try #require(trashURLs[name]) }

            // Emptied from the Trash.
            try FileManager.default.removeItem(at: try inTrash("gone.txt"))
            // Grown.
            let grown = try FileHandle(forWritingTo: try inTrash("grown.txt"))
            try grown.seekToEnd()
            try grown.write(contentsOf: Data(" and more".utf8))
            try grown.close()
            // Edited in place to other bytes of the same size, with its modification date set back.
            let edited = try inTrash("edited.txt")
            let editedDate = try #require(try FileManager.default.attributesOfItem(atPath: edited.path(percentEncoded: false))[.modificationDate] as? Date)
            try Data("CONTENT OF EDITED.TXT".utf8).write(to: edited)
            try FileDates.set(edited, to: editedDate)
            // Replaced by a copy: the same bytes and date, but another file.
            let copied = try inTrash("copied.txt")
            let copiedDate = try #require(try FileManager.default.attributesOfItem(atPath: copied.path(percentEncoded: false))[.modificationDate] as? Date)
            let copy = folder.appending(path: "copy")
            try FileManager.default.copyItem(at: copied, to: copy)
            try FileManager.default.removeItem(at: copied)
            try FileManager.default.moveItem(at: copy, to: copied)
            try FileDates.set(copied, to: copiedDate)

            let result = try await Fixtures.undo(.run(runID), in: folder, trash: trash.locator, log: log)

            #expect(Fixtures.isUndone(try Fixtures.outcome(for: "fine.txt", in: result)))
            #expect(try Fixtures.outcome(for: "gone.txt", in: result) == .notUndone(.missing))
            #expect(try Fixtures.outcome(for: "grown.txt", in: result) == .notUndone(.changed))
            #expect(try Fixtures.outcome(for: "copied.txt", in: result) == .notUndone(.replaced))
            // Only the content shows the edit, and only the executor reads content.
            #expect(try Fixtures.outcome(for: "edited.txt", in: result) == .notUndone(.changed))
            #expect(DiskState.entryNames(in: folder) == ["fine.txt"])
            #expect(DiskState.entryNames(in: trash.url) == ["copied.txt", "edited.txt", "grown.txt"])
            // Only the one put back lowers the totals.
            let fineSize = Int64("content of fine.txt".utf8.count)
            let trashedBytes = names.reduce(Int64(0)) { $0 + Int64("content of \($1)".utf8.count) }
            #expect(try await log.totals() == ActivityTotals(bytesMovedToTrash: trashedBytes - fineSize, filesCleaned: 4))
        }
    }

    @Test func aRenamedFileEditedAfterTheRenameIsNotUndone() async throws {
        try await withSetup { folder, trash, log in
            try Fixtures.write(["notes (1).txt": "notes"], in: folder)
            let plan = try await RelocationPlans.rename([("notes (1).txt", "notes.txt")], in: folder)
            let cleanup = await CleanupExecutor(recorder: log).execute(plan: plan, confirmedChangeIDs: Set(plan.changes.map(\.id)))
            let runID = try #require(cleanup.runID)
            try Data("notes, edited".utf8).write(to: folder.appending(path: "notes.txt"))

            let result = try await Fixtures.undo(.run(runID), in: folder, trash: trash.locator, log: log)

            #expect(try Fixtures.outcome(for: "notes (1).txt", in: result) == .notUndone(.changed))
            #expect(DiskState.entryNames(in: folder) == ["notes.txt"])
            #expect(DiskState.text(of: folder.appending(path: "notes.txt")) == "notes, edited")
        }
    }

    // MARK: - Whole runs

    @Test func aWholeRunIsUndoneInReverseOrderAndABlockedChangeDoesNotStopTheRest() async throws {
        try await withSetup { folder, trash, log in
            try Fixtures.write(["1.txt": "one", "2.txt": "two", "3.txt": "three"], in: folder)
            let (runID, trashURLs) = try await Fixtures.trashRun(["1.txt", "2.txt", "3.txt"], in: folder, to: trash, log: log)
            try Data("taken".utf8).write(to: folder.appending(path: "2.txt"))
            let order = ConcurrentLog<String>()

            let result = try await Fixtures.undo(.run(runID), in: folder, trash: trash.locator, log: log) { step in
                order.append(step.originalName)
            }

            #expect(order.values == ["3.txt", "1.txt"])
            #expect(result.undone.map(\.originalName) == ["3.txt", "1.txt"])
            #expect(try Fixtures.outcome(for: "2.txt", in: result) == .notUndone(.originalNameTaken(name: "2.txt")))
            #expect(DiskState.text(of: folder.appending(path: "1.txt")) == "one")
            #expect(DiskState.text(of: folder.appending(path: "2.txt")) == "taken")
            #expect(DiskState.text(of: folder.appending(path: "3.txt")) == "three")
            #expect(DiskState.text(of: try #require(trashURLs["2.txt"])) == "two")
            let undoRunID = try #require(result.runID)
            let undoRun = try #require(try await log.run(id: undoRunID))
            #expect(undoRun.confirmedCount == 3)
            #expect(undoRun.doneCount == 2)
            #expect(undoRun.skippedCount == 1)
            #expect(try await log.run(id: runID)?.undoneCount == 2)
        }
    }

    @Test func undoingTwiceDoesNothingTheSecondTime() async throws {
        try await withSetup { folder, trash, log in
            try Fixtures.write(["a.txt": "ten bytes!", "b.txt": "twenty bytes, not 10"], in: folder)
            let (runID, trashURLs) = try await Fixtures.trashRun(["a.txt", "b.txt"], in: folder, to: trash, log: log)
            #expect(try await log.totals() == ActivityTotals(bytesMovedToTrash: 30, filesCleaned: 2))
            let firstPlan = try await UndoPlanner(trash: trash.locator).plan(.run(runID), log: log, folderURL: folder)
            let first = await CleanupExecutor(recorder: log).undo(firstPlan, trash: trash.locator)
            #expect(first.undone.count == 2)
            #expect(try await log.totals() == .zero)
            let afterFirst = DiskState.snapshot(of: folder)

            // Planned again: nothing left, and each change says why.
            let again = try await UndoPlanner(trash: trash.locator).plan(.run(runID), log: log, folderURL: folder)
            #expect(again.steps.isEmpty)
            #expect(again.refused.isEmpty)
            let change = try await Fixtures.change(named: "a.txt", inRun: runID, log: log)
            let one = try await UndoPlanner(trash: trash.locator).plan(.change(change.id), log: log, folderURL: folder)
            #expect(one.refused.map(\.refusal) == [.alreadyUndone])

            // The old plan carried out again: the files are not in the Trash any more.
            let stale = await CleanupExecutor(recorder: log).undo(firstPlan, trash: trash.locator)
            #expect(stale.undone.isEmpty)
            #expect(DiskState.snapshot(of: folder) == afterFirst)

            // Even with the very file back where the change put it, the log says it is undone.
            let a = folder.appending(path: "a.txt")
            _ = try trash.take(a, as: try #require(trashURLs["a.txt"]).lastPathComponent)
            let staleAgain = await CleanupExecutor(recorder: log).undo(firstPlan, trash: trash.locator)
            #expect(try Fixtures.outcome(for: "a.txt", in: staleAgain) == .notUndone(.alreadyUndone))
            #expect(!DiskState.exists(a))
            #expect(try await log.totals() == .zero)
            #expect(try await log.run(id: runID)?.undoneCount == 2)
        }
    }

    // MARK: - The log and cancellation

    @Test func withoutAStartedRowNothingMoves() async throws {
        try await withSetup { folder, trash, log in
            try Fixtures.write(["a.txt": "trashed"], in: folder)
            let (runID, trashURLs) = try await Fixtures.trashRun(["a.txt"], in: folder, to: trash, log: log)
            let spy = SpyRecorder(failing: SpyRecorder.Failure(kind: .recordUndoIntent, occurrence: 0), forwardingTo: log)

            let result = try await Fixtures.undo(.run(runID), in: folder, trash: trash.locator, log: log, recorder: spy)

            #expect(try Fixtures.outcome(for: "a.txt", in: result) == .notUndone(.activityLogUnavailable))
            #expect(result.logFailure == CleanupLogFailure(error: .writeFailed(code: 13), unrecordedChangeID: nil))
            #expect(DiskState.entryNames(in: folder) == [])
            #expect(DiskState.text(of: try #require(trashURLs["a.txt"])) == "trashed")
            #expect(spy.callNames == ["beginUndoRun"])
        }
    }

    @Test func cancellingStopsBetweenChanges() async throws {
        try await withSetup { folder, trash, log in
            try Fixtures.write(["1.txt": "one", "2.txt": "two"], in: folder)
            let (runID, _) = try await Fixtures.trashRun(["1.txt", "2.txt"], in: folder, to: trash, log: log)
            let plan = try await UndoPlanner(trash: trash.locator).plan(.run(runID), log: log, folderURL: folder)
            let locator = trash.locator

            // Cancelled from inside the undo's own task, so the test's task is left alone.
            let task = Task {
                await CleanupExecutor(recorder: log).undo(plan, trash: locator) { progress in
                    if progress.itemsCompleted == 1 {
                        withUnsafeCurrentTask { $0?.cancel() }
                    }
                }
            }
            let result = await task.value

            #expect(result.wasCancelled)
            #expect(result.undone.map(\.originalName) == ["2.txt"])
            #expect(try Fixtures.outcome(for: "1.txt", in: result) == .notUndone(.cancelled))
            #expect(DiskState.entryNames(in: folder) == ["2.txt"])
            let undoRunID = try #require(result.runID)
            let undoRun = try #require(try await log.run(id: undoRunID))
            #expect(undoRun.state == .cancelled)
            #expect(try await log.changes(inRun: undoRun.id).map(\.outcome) == [.undone, .notUndone(.cancelled)])
        }
    }

    // MARK: - The real Trash

    @Test func aFileTrashedForRealComesBackOutOfTheRealTrash() async throws {
        let folder = try TemporaryFolder.make()
        defer { folder.remove() }
        let log = try await ActivityLog.open(.inMemory)
        let marker = "undo round trip \(UUID().uuidString)"
        try Fixtures.write(["a.txt": marker, "a (1).txt": marker], in: folder.url)
        let records = try await RelocationPlans.records(in: folder.url)
        let plan = try await DuplicatePlanner().plan(records: records, in: folder.url)
        let cleanup = await CleanupExecutor(recorder: log).execute(plan: plan, confirmedChangeIDs: Set(plan.changes.map(\.id)))
        // Whatever happens next, nothing of this test's is left in the user's Trash: the removal
        // only acts on a file still there with the test's own bytes.
        defer { TrashedFiles.remove(cleanup) { _ in Data(marker.utf8) } }
        #expect(cleanup.trashedCount == 1)
        let runID = try #require(cleanup.runID)

        let result = try await Fixtures.undo(.run(runID), in: folder.url, trash: .system, log: log)

        #expect(result.undone.map(\.originalName) == ["a (1).txt"])
        #expect(DiskState.entryNames(in: folder.url) == ["a (1).txt", "a.txt"])
        #expect(DiskState.text(of: folder.url.appending(path: "a (1).txt")) == marker)
        #expect(try await log.totals() == .zero)
    }

    @Test func everyChangeRecordsTheFilesDiskID() async throws {
        try await withSetup { folder, _, log in
            try Fixtures.write(["a (1).txt": "a", "b.zip": "b"], in: folder)
            let renamedInode = try #require(DiskState.inode(of: folder.appending(path: "a (1).txt")))
            let movedInode = try #require(DiskState.inode(of: folder.appending(path: "b.zip")))
            let rename = try await RelocationPlans.rename([("a (1).txt", "a.txt")], in: folder)
            let renamed = await CleanupExecutor(recorder: log).execute(plan: rename, confirmedChangeIDs: Set(rename.changes.map(\.id)))
            let renameRun = try #require(renamed.runID)
            let archive = folder.appending(path: "Old downloads", directoryHint: .isDirectory)
            let move = try await RelocationPlans.move([("b.zip", archive, "b.zip")], in: folder)
            let moved = await CleanupExecutor(recorder: log).execute(plan: move, confirmedChangeIDs: Set(move.changes.map(\.id)))
            let moveRun = try #require(moved.runID)

            #expect(try await log.changes(inRun: renameRun).map(\.fileNumber) == [renamedInode])
            #expect(try await log.changes(inRun: moveRun).map(\.fileNumber) == [movedInode])
        }
    }

    // MARK: - Review follow-ups

    @Test func aRenameOfTheLetterCaseOnlyIsUndone() async throws {
        try await withSetup { folder, trash, log in
            try Fixtures.write(["Report.txt": "report"], in: folder)
            let before = try #require(Fixtures.snapshot(of: folder.appending(path: "Report.txt")))
            let plan = try await RelocationPlans.rename([("Report.txt", "report.txt")], in: folder)
            let cleanup = await CleanupExecutor(recorder: log).execute(plan: plan, confirmedChangeIDs: Set(plan.changes.map(\.id)))
            let runID = try #require(cleanup.runID)
            #expect(DiskState.entryNames(in: folder) == ["report.txt"])

            // The old name answers with the file itself on a case-insensitive volume: not a taker.
            let result = try await Fixtures.undo(.run(runID), in: folder, trash: trash.locator, log: log)

            #expect(result.undone.map(\.originalName) == ["Report.txt"])
            #expect(DiskState.entryNames(in: folder) == ["Report.txt"])
            #expect(Fixtures.snapshot(of: folder.appending(path: "Report.txt")) == before)
        }
    }

    @Test func aFileHiddenSinceItWasRenamedIsNotUndone() async throws {
        try await withSetup { folder, trash, log in
            try Fixtures.write(["notes (1).txt": "notes"], in: folder)
            let plan = try await RelocationPlans.rename([("notes (1).txt", "notes.txt")], in: folder)
            let cleanup = await CleanupExecutor(recorder: log).execute(plan: plan, confirmedChangeIDs: Set(plan.changes.map(\.id)))
            let runID = try #require(cleanup.runID)
            let renamed = folder.appending(path: "notes.txt")
            #expect(chflags(renamed.path(percentEncoded: false), UInt32(UF_HIDDEN)) == 0)

            let result = try await Fixtures.undo(.run(runID), in: folder, trash: trash.locator, log: log)

            #expect(try Fixtures.outcome(for: "notes (1).txt", in: result) == .notUndone(.hidden))
            #expect(DiskState.entryNames(in: folder) == ["notes.txt"])
        }
    }

    @Test func aStepThatIsNotTheChangeAsLoggedMovesNothing() async throws {
        try await withSetup { folder, trash, log in
            try Fixtures.write(["a.txt": "same size", "b.txt": "same size"], in: folder)
            let (runID, trashURLs) = try await Fixtures.trashRun(["a.txt", "b.txt"], in: folder, to: trash, log: log)
            let plan = try await UndoPlanner(trash: trash.locator).plan(.run(runID), log: log, folderURL: folder)
            let a = try #require(plan.steps.first { $0.originalName == "a.txt" })
            let b = try #require(plan.steps.first { $0.originalName == "b.txt" })
            // A plan built elsewhere: a's change, but b's file in the Trash, with b's own evidence,
            // which b's file passes on disk.
            let forged = UndoStep(
                changeID: a.changeID,
                runID: a.runID,
                sequence: a.sequence,
                operation: .putBackFromTrash,
                currentPath: b.currentPath,
                originalPath: a.originalPath,
                evidence: b.evidence
            )
            let forgedPlan = UndoPlan(target: .change(a.changeID), folderURL: folder, undoneActionCode: plan.undoneActionCode, steps: [forged], refused: [])

            let result = await CleanupExecutor(recorder: log).undo(forgedPlan, trash: trash.locator)

            #expect(try Fixtures.outcome(for: "a.txt", in: result) == .notUndone(.notWhereRecorded))
            #expect(DiskState.entryNames(in: folder) == [])
            #expect(DiskState.exists(try #require(trashURLs["b.txt"])))
            #expect(try await log.totals() == ActivityTotals(bytesMovedToTrash: 18, filesCleaned: 2))
        }
    }

    @Test func aTargetTheLogNoLongerHoldsHasNothingToUndo() async throws {
        try await withSetup { folder, trash, log in
            let planner = UndoPlanner(trash: trash.locator)
            for target in [UndoTarget.run(999), .change(999)] {
                let plan = try await planner.plan(target, log: log, folderURL: folder)
                #expect(plan.steps.isEmpty)
                #expect(plan.refused.isEmpty)
            }
        }
    }

    @Test func everyRefusalReadsBackAsWritten() async throws {
        let log = try await ActivityLog.open(.inMemory)
        let runID = try LogSamples.writeRun(to: log, startedAt: Fixtures.now, count: 1)
        let change = try #require(try await log.changes(inRun: runID).first)
        // Exhaustive on purpose: a new refusal does not compile here until it is listed below.
        func listed(_ refusal: UndoRefusal) {
            switch refusal {
            case .alreadyUndone, .nothingChanged, .interrupted, .isAnUndo, .unknownToThisVersion, .otherFolder,
                 .folderUnavailable, .trashLocationUnknown, .notWhereRecorded, .missing, .replaced, .changed,
                 .cannotBeChecked, .originalNameTaken, .notDownloaded, .hidden, .accessDenied, .cancelled,
                 .activityLogUnavailable:
                break
            }
        }
        let refusals: [UndoRefusal] = [
            .alreadyUndone, .nothingChanged, .interrupted, .isAnUndo, .unknownToThisVersion, .otherFolder,
            .folderUnavailable, .trashLocationUnknown, .notWhereRecorded, .missing, .replaced, .changed,
            .cannotBeChecked, .originalNameTaken(name: "résumé – final ✓.pdf"), .notDownloaded, .hidden, .accessDenied,
            .cancelled, .activityLogUnavailable,
        ]
        refusals.forEach(listed)
        let undoRunID = try log.beginUndoRun(
            UndoRunStart(target: .run(runID), folderURL: LogSamples.folderURL, undoneActionCode: "findDuplicates", confirmedCount: refusals.count, startedAt: Fixtures.now)
        )
        for (sequence, refusal) in refusals.enumerated() {
            let item = UndoItemResult(
                changeID: change.id,
                operation: .putBackFromTrash,
                originalPath: change.originalPath,
                currentPath: change.resultingPath,
                sizeInBytes: change.sizeInBytes,
                outcome: .notUndone(refusal)
            )
            try log.recordUndoResult(UndoChangeResult(runID: undoRunID, rowID: nil, sequence: sequence, item: item, attemptedAt: Fixtures.now))
        }

        #expect(try await log.changes(inRun: undoRunID).map(\.outcome) == refusals.map { .notUndone($0) })
    }
}
