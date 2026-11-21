import FileStoreCore
import Foundation
import Testing

/// Undo puts a file back into the folder its run was made in, found by the run's own folder ID:
/// not the folder on screen, and whatever has happened to the list since. When that folder is gone,
/// or is no longer where the run saw it, undo refuses and nothing moves.
@Suite("Managed folder undo")
struct ManagedFolderUndoTests {
    private typealias Fixtures = UndoFixtures

    private func withSetup(_ body: (ManagedHome, FakeTrash) async throws -> Void) async throws {
        let root = try TemporaryFolder.make()
        defer { root.remove() }
        let trash = try FakeTrash.make()
        defer { trash.remove() }
        try await body(try await ManagedHome(root: root.url), trash)
    }

    /// The executor with the log itself, so no test helper stands between.
    private func undo(_ plan: UndoPlan, _ home: ManagedHome, _ trash: FakeTrash) async -> UndoResult {
        await CleanupExecutor(recorder: home.log as any CleanupRecording).undo(plan, trash: trash.locator)
    }

    @Test func undoPutsTheFileBackIntoItsRunsFolderWhateverTheListIsNow() async throws {
        try await withSetup { home, trash in
            try Fixtures.write(["note.txt": "desktop note"], in: home.desktop.url)
            try Fixtures.write(["other.txt": "downloads file"], in: home.downloads.url)
            let (runID, trashURLs) = try await Fixtures.trashRun(["note.txt"], in: home.desktop.url, to: trash, log: home.log, managedFolder: home.desktop)
            #expect(try await home.log.run(id: runID)?.folderID == home.desktop.id)

            // The list changes: Desktop is taken off it, and a folder of the user's own is added.
            try await home.registry.remove(home.desktop, from: home.log)
            _ = try await home.addCustomFolder(named: "Projects")
            #expect(try await home.registry.folders(in: home.log).map(\.kind) == [.downloads, .custom])
            let downloadsBefore = DiskState.snapshot(of: home.downloads.url)

            let plan = try await UndoPlanner(trash: trash.locator).plan(.run(runID), log: home.log, folders: home.registry)
            #expect(plan.folderID == home.desktop.id)
            expectSameFolder(plan.folderURL, home.desktop.url)
            #expect(plan.refused.isEmpty)
            #expect(plan.steps.count == 1)
            let result = await undo(plan, home, trash)

            #expect(result.undone.count == 1)
            #expect(result.notUndone.isEmpty)
            #expect(DiskState.text(of: home.desktop.url.appending(path: "note.txt")) == "desktop note")
            let trashed = try #require(trashURLs["note.txt"])
            #expect(!DiskState.exists(trashed))
            #expect(DiskState.snapshot(of: home.downloads.url) == downloadsBefore)
            #expect(DiskState.entryNames(in: home.home.appending(path: "Projects")).isEmpty)
            // The undo is a run of the same folder.
            let undoRunID = try #require(result.runID)
            #expect(try await home.log.run(id: undoRunID)?.folderID == home.desktop.id)
        }
    }

    @Test func whenTheRunsFolderIsGoneUndoRefusesAndNothingMoves() async throws {
        try await withSetup { home, trash in
            try Fixtures.write(["note.txt": "desktop note"], in: home.desktop.url)
            let (runID, trashURLs) = try await Fixtures.trashRun(["note.txt"], in: home.desktop.url, to: trash, log: home.log, managedFolder: home.desktop)
            let trashed = try #require(trashURLs["note.txt"])
            try FileManager.default.removeItem(at: home.desktop.url)

            let plan = try await UndoPlanner(trash: trash.locator).plan(.run(runID), log: home.log, folders: home.registry)
            #expect(plan.steps.isEmpty)
            #expect(plan.refused.map(\.refusal) == [.folderUnavailable])
            #expect(plan.folderID == home.desktop.id)
            let result = await undo(plan, home, trash)

            #expect(result.undone.isEmpty)
            #expect(result.notUndone.map(\.outcome) == [.notUndone(.folderUnavailable)])
            #expect(DiskState.text(of: trashed) == "desktop note")
            // The folder is not made again, and the file is put nowhere else.
            #expect(!DiskState.exists(home.desktop.url))
            #expect(DiskState.entryNames(in: home.downloads.url).isEmpty)
            #expect(try await Fixtures.change(named: "note.txt", inRun: runID, log: home.log).undoneAt == nil)
        }
    }

    /// A different folder made where a custom folder used to be is not that folder: the bookmark
    /// alone would take it for the one; what the folder is on its volume says otherwise.
    @Test func aNewFolderAtTheOldPlaceOfACustomFolderIsNotUndoneInto() async throws {
        try await withSetup { home, trash in
            let projects = try await home.addCustomFolder(named: "Projects")
            try Fixtures.write(["plan.txt": "the plan"], in: projects.url)
            let (runID, trashURLs) = try await Fixtures.trashRun(["plan.txt"], in: projects.url, to: trash, log: home.log, managedFolder: projects)
            try FileManager.default.removeItem(at: projects.url)
            try FileManager.default.createDirectory(at: projects.url, withIntermediateDirectories: false)

            let plan = try await UndoPlanner(trash: trash.locator).plan(.run(runID), log: home.log, folders: home.registry)
            #expect(plan.steps.isEmpty)
            #expect(plan.refused.map(\.refusal) == [.folderUnavailable])
            _ = await undo(plan, home, trash)

            let trashed = try #require(trashURLs["plan.txt"])
            #expect(DiskState.entryNames(in: projects.url).isEmpty)
            #expect(DiskState.text(of: trashed) == "the plan")
        }
    }

    /// The log holds each file's whole path, so a folder that has moved since the run is found (its
    /// bookmark follows it) and left alone.
    @Test func whenACustomFolderHasMovedSinceUndoRefuses() async throws {
        try await withSetup { home, trash in
            let projects = try await home.addCustomFolder(named: "Projects")
            try Fixtures.write(["plan.txt": "the plan"], in: projects.url)
            let (runID, trashURLs) = try await Fixtures.trashRun(["plan.txt"], in: projects.url, to: trash, log: home.log, managedFolder: projects)
            let moved = home.home.appending(path: "Old projects", directoryHint: .isDirectory)
            try FileManager.default.moveItem(at: projects.url, to: moved)
            // The folder is still the managed one, at its new place.
            let found = try #require(try await home.registry.folder(id: projects.id, in: home.log))
            expectSameFolder(found.url, moved)

            let plan = try await UndoPlanner(trash: trash.locator).plan(.run(runID), log: home.log, folders: home.registry)
            #expect(plan.steps.isEmpty)
            #expect(plan.refused.map(\.refusal) == [.otherFolder])
            _ = await undo(plan, home, trash)

            #expect(DiskState.entryNames(in: moved).isEmpty)
            let trashed = try #require(trashURLs["plan.txt"])
            #expect(!DiskState.exists(projects.url))
            #expect(DiskState.text(of: trashed) == "the plan")
        }
    }

    /// The planner asks the registry for the run's folder; a folder handed to it that is not the
    /// run's is another folder, even at the same path.
    @Test func aFolderThatIsNotTheRunsOwnIsRefused() async throws {
        try await withSetup { home, trash in
            try Fixtures.write(["note.txt": "desktop note"], in: home.desktop.url)
            let (runID, _) = try await Fixtures.trashRun(["note.txt"], in: home.desktop.url, to: trash, log: home.log, managedFolder: home.desktop)
            let run = try #require(try await home.log.run(id: runID))
            let changes = try await home.log.changes(inRun: runID)
            let planner = UndoPlanner(trash: trash.locator)

            for folder in [home.downloads, ManagedFolder(kind: .desktop, url: home.desktop.url)] {
                let observations = await planner.observe(changes, folder: folder)
                let plan = planner.plan(target: .run(runID), run: run, changes: changes, observations: observations, folder: folder)
                #expect(plan.steps.isEmpty)
                #expect(plan.refused.map(\.refusal) == [.otherFolder])
            }
            let observations = await planner.observe(changes, folder: nil)
            let plan = planner.plan(target: .run(runID), run: run, changes: changes, observations: observations, folder: nil)
            #expect(plan.refused.map(\.refusal) == [.folderUnavailable])
        }
    }

    /// Whatever plan it is handed, the log lets a change be undone only by a run of the change's
    /// own folder.
    @Test func theLogRefusesAnUndoRecordedInAnotherFolder() async throws {
        try await withSetup { home, trash in
            try Fixtures.write(["note.txt": "desktop note"], in: home.desktop.url)
            let (runID, trashURLs) = try await Fixtures.trashRun(["note.txt"], in: home.desktop.url, to: trash, log: home.log, managedFolder: home.desktop)
            let plan = try await UndoPlanner(trash: trash.locator).plan(.run(runID), log: home.log, folders: home.registry)
            let step = try #require(plan.steps.first)
            // The same steps, in a plan that says they belong to Downloads.
            let forged = UndoPlan(target: plan.target, folderID: home.downloads.id, folderURL: plan.folderURL, undoneActionCode: plan.undoneActionCode, steps: [step], refused: [])

            let result = await undo(forged, home, trash)

            #expect(result.undone.isEmpty)
            #expect(result.notUndone.count == 1)
            let trashed = try #require(trashURLs["note.txt"])
            #expect(DiskState.entryNames(in: home.desktop.url).isEmpty)
            #expect(DiskState.text(of: trashed) == "desktop note")
            #expect(try await Fixtures.change(named: "note.txt", inRun: runID, log: home.log).undoneAt == nil)
        }
    }

    /// An undo a crash interrupted is settled in its own folder. While that folder cannot be found
    /// the row says nothing either way and waits for a launch that finds it.
    @Test func anInterruptedUndoWaitsWhileItsFolderCannotBeFound() async throws {
        let root = try TemporaryFolder.make()
        defer { root.remove() }
        let trash = try FakeTrash.make()
        defer { trash.remove() }
        try await withLogSandbox { sandbox in
            let location = try sandbox.realLocation()
            let home = try await ManagedHome(root: root.url, location: location)
            try Fixtures.write(["note.txt": "desktop note"], in: home.desktop.url)
            let (runID, _) = try await Fixtures.trashRun(["note.txt"], in: home.desktop.url, to: trash, log: home.log, managedFolder: home.desktop)
            let plan = try await UndoPlanner(trash: trash.locator).plan(.run(runID), log: home.log, folders: home.registry)
            // The file moves back, then the row that says so cannot be written: as if the app stopped there.
            let spy = SpyRecorder(failing: SpyRecorder.Failure(kind: .recordUndoResult, occurrence: 0), forwardingTo: home.log)
            let crashed = await CleanupExecutor(recorder: spy).undo(plan, trash: trash.locator)
            #expect(crashed.logFailure != nil)
            let undoRunID = try #require(crashed.runID)
            try await home.log.close()

            let reopened = try await ActivityLog.open(location)
            #expect(try await reopened.changes(inRun: undoRunID).map(\.outcome) == [.started])
            // A launch whose home has no Desktop: the folder cannot be found.
            let elsewhere = FolderRegistry(
                override: FolderOverride(source: .scanFolderArgument, folderURL: home.downloads.url),
                rules: home.registry.rules
            )
            #expect(try await UndoReconciler().reconcile(reopened, folders: elsewhere) == UndoReconciler.Result(undone: 0, notUndone: 0))
            #expect(try await reopened.changes(inRun: undoRunID).map(\.outcome) == [.started])

            // The next launch finds it, and the file is where it was.
            #expect(try await UndoReconciler().reconcile(reopened, folders: home.registry) == UndoReconciler.Result(undone: 1, notUndone: 0))
            #expect(try await reopened.changes(inRun: undoRunID).map(\.outcome) == [.undone])
            #expect(try await Fixtures.change(named: "note.txt", inRun: runID, log: reopened).undoneAt != nil)
            try await reopened.close()
        }
    }
}
