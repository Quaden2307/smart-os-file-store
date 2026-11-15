import FileStoreCore
import Foundation
import Testing

/// A crash between the move back and the row that records it. The log, written to a file, is opened
/// again as the next launch would, and the reconciler settles what it finds: the change is marked
/// undone and the totals go down once when the file is back, and the change stays undoable when it
/// is not. Running it twice changes nothing.
@Suite("Undo reconcile")
struct UndoReconcileTests {
    private typealias Fixtures = UndoFixtures

    private func withSetup(_ body: (URL, FakeTrash, LogSandbox) async throws -> Void) async throws {
        let folder = try TemporaryFolder.make()
        defer { folder.remove() }
        let trash = try FakeTrash.make()
        defer { trash.remove() }
        try await withLogSandbox { sandbox in
            try await body(folder.url, trash, sandbox)
        }
    }

    @Test func aMoveBackThatHappenedIsRecordedAtTheNextLaunch() async throws {
        try await withSetup { folder, trash, sandbox in
            let location = try sandbox.realLocation()
            let log = try await ActivityLog.open(location)
            try Fixtures.write(["a.txt": "ten bytes!"], in: folder)
            let (runID, _) = try await Fixtures.trashRun(["a.txt"], in: folder, to: trash, log: log)
            #expect(try await log.totals() == ActivityTotals(bytesMovedToTrash: 10, filesCleaned: 1))

            // The file moves back, then the row that says so cannot be written: as if the app stopped there.
            let spy = SpyRecorder(failing: SpyRecorder.Failure(kind: .recordUndoResult, occurrence: 0), forwardingTo: log)
            let crashed = try await Fixtures.undo(.run(runID), in: folder, trash: trash.locator, log: log, recorder: spy)
            #expect(Fixtures.isUndone(try Fixtures.outcome(for: "a.txt", in: crashed)))
            #expect(crashed.logFailure != nil)
            #expect(DiskState.text(of: folder.appending(path: "a.txt")) == "ten bytes!")
            try await log.close()

            let reopened = try await ActivityLog.open(location)
            let undoRunID = try #require(crashed.runID)
            #expect(try await reopened.run(id: undoRunID)?.state == .interrupted)
            #expect(try await reopened.changes(inRun: undoRunID).map(\.outcome) == [.started])
            #expect(try await Fixtures.change(named: "a.txt", inRun: runID, log: reopened).undoneAt == nil)
            #expect(try await reopened.totals() == ActivityTotals(bytesMovedToTrash: 10, filesCleaned: 1))

            let settled = try await UndoReconciler().reconcile(reopened)

            #expect(settled == UndoReconciler.Result(undone: 1, notUndone: 0))
            #expect(try await reopened.changes(inRun: undoRunID).map(\.outcome) == [.undone])
            #expect(try await Fixtures.change(named: "a.txt", inRun: runID, log: reopened).undoneAt != nil)
            #expect(try await reopened.totals() == .zero)
            #expect(try await reopened.run(id: undoRunID)?.bytesTakenFromTrash == 10)

            // A second time finds nothing, and lowers nothing again.
            #expect(try await UndoReconciler().reconcile(reopened) == UndoReconciler.Result(undone: 0, notUndone: 0))
            #expect(try await reopened.totals() == .zero)
        }
    }

    @Test func aMoveBackThatNeverHappenedLeavesTheChangeUndoable() async throws {
        try await withSetup { folder, trash, sandbox in
            let location = try sandbox.realLocation()
            let log = try await ActivityLog.open(location)
            try Fixtures.write(["a.txt": "ten bytes!"], in: folder)
            let (runID, trashURLs) = try await Fixtures.trashRun(["a.txt"], in: folder, to: trash, log: log)
            let plan = try await UndoPlanner(trash: trash.locator).plan(.run(runID), log: log, folderURL: folder)
            let step = try #require(plan.steps.first)

            // The started row goes in, then the app stops before the move.
            let undoRunID = try log.beginUndoRun(
                UndoRunStart(target: plan.target, folderURL: folder, undoneActionCode: plan.undoneActionCode, confirmedCount: 1, startedAt: Fixtures.now)
            )
            let trashURL = try #require(trashURLs["a.txt"])
            let fileNumber = try #require(DiskState.inode(of: trashURL))
            let decision = try log.recordUndoIntent(UndoChangeIntent(runID: undoRunID, sequence: 0, step: step, fileNumber: fileNumber, attemptedAt: Fixtures.now))
            guard case .recorded = decision else {
                Issue.record("the started row was refused: \(decision)")
                return
            }
            try await log.close()

            let reopened = try await ActivityLog.open(location)
            let settled = try await UndoReconciler().reconcile(reopened)

            #expect(settled == UndoReconciler.Result(undone: 0, notUndone: 1))
            #expect(try await reopened.changes(inRun: undoRunID).map(\.outcome) == [.notUndone(.interrupted)])
            #expect(try await Fixtures.change(named: "a.txt", inRun: runID, log: reopened).undoneAt == nil)
            #expect(try await reopened.totals() == ActivityTotals(bytesMovedToTrash: 10, filesCleaned: 1))

            // The change can still be undone, and is.
            let result = try await Fixtures.undo(.run(runID), in: folder, trash: trash.locator, log: reopened)
            #expect(result.undone.map(\.originalName) == ["a.txt"])
            #expect(try await reopened.totals() == .zero)
        }
    }
}
