import FileStoreCore
import Foundation
import Testing

/// Undo of a `.download` folder that went to the Trash, with a stand-in Trash the test controls:
/// the folder is proved by its disk ID and what is inside it, never hashed, and one whose contents
/// changed in the Trash stays there.
@Suite("Failed download undo")
struct FailedDownloadUndoTests {
    private typealias Fixtures = UndoFixtures
    private typealias Partials = FailedDownloads

    private func withSetup(_ body: (URL, FakeTrash, FailedDownloads.Contents, ActivityLog) async throws -> Void) async throws {
        let folder = try TemporaryFolder.make()
        defer { folder.remove() }
        let trash = try FakeTrash.make()
        defer { trash.remove() }
        let contents = try Partials.write(in: folder.url)
        let log = try await ActivityLog.open(.inMemory)
        try await body(folder.url, trash, contents, log)
    }

    @Test func aFolderComesBackWithEverythingInIt() async throws {
        try await withSetup { folder, trash, contents, log in
            let package = folder.appending(path: Partials.safari)
            let inode = try #require(DiskState.inode(of: package))
            let (runID, _) = try await Fixtures.failedDownloadRun([Partials.safari, Partials.chrome], in: folder, to: trash, log: log)
            let rows = try await log.changes(inRun: runID)
            #expect(rows.map(\.isFolder) == [true, false])
            // A folder is never hashed: its row holds no hash, so neither undo nor the reconciler reads one.
            #expect(rows.allSatisfy { $0.contentHash == nil && $0.undoEvidence.contentHash == nil })
            #expect(rows.first?.undoEvidence.isFolder == true)

            let result = try await Fixtures.undo(.run(runID), in: folder, trash: trash.locator, log: log)

            #expect(Set(result.undone.map(\.originalName)) == [Partials.safari, Partials.chrome])
            #expect(DiskState.inode(of: package) == inode)
            #expect(Set(DiskState.entryNames(in: package)) == [Partials.safariContent, Partials.safariInfo])
            #expect(DiskState.text(of: package.appending(path: Partials.safariInfo)) == contents.safariInfo)
            #expect(try await log.totals() == .zero)
            // The undo row knows it put back a folder.
            let undoRun = try #require(try await log.runs().first { $0.isUndo })
            #expect(try await log.changes(inRun: undoRun.id).map(\.isFolder) == [false, true])
        }
    }

    @Test func aFolderWhoseContentsChangedInTheTrashStaysThere() async throws {
        try await withSetup { folder, trash, _, log in
            let (runID, trashURLs) = try await Fixtures.failedDownloadRun([Partials.safari], in: folder, to: trash, log: log)
            let trashed = try #require(trashURLs[Partials.safari])
            // Something wrote to the file inside, keeping the folder's own date and disk ID.
            let inside = trashed.appending(path: Partials.safariContent)
            try Data("rewritten".utf8).write(to: inside)

            // Activity looks only at the folder, so it still offers the undo…
            let change = try await Fixtures.change(named: Partials.safari, inRun: runID, log: log)
            let observations = await UndoPlanner(trash: trash.locator).observe([change], folderURL: folder)
            let run = try #require(try await log.run(id: runID))
            let assessment = UndoPlanner(trash: trash.locator).assess(change, in: run, observation: observations[change.id], folderURL: folder)
            #expect(assessment.refusal == nil)

            // …and the executor, which reads inside, refuses it.
            let result = try await Fixtures.undo(.run(runID), in: folder, trash: trash.locator, log: log)

            #expect(try Fixtures.outcome(for: Partials.safari, in: result) == .notUndone(.changed))
            #expect(DiskState.exists(trashed))
            #expect(!DiskState.exists(folder.appending(path: Partials.safari)))
        }
    }

    @Test func aFileWhereTheFolderWasIsNotPutBack() async throws {
        try await withSetup { folder, trash, _, log in
            let (runID, trashURLs) = try await Fixtures.failedDownloadRun([Partials.safari], in: folder, to: trash, log: log)
            let trashed = try #require(trashURLs[Partials.safari])
            try FileManager.default.removeItem(at: trashed)
            try Data("a file now".utf8).write(to: trashed)

            let result = try await Fixtures.undo(.run(runID), in: folder, trash: trash.locator, log: log)

            #expect(try Fixtures.outcome(for: Partials.safari, in: result) == .notUndone(.replaced))
            #expect(!DiskState.exists(folder.appending(path: Partials.safari)))
        }
    }

    @Test func aFolderPutBackBeforeACrashIsSettledAtTheNextLaunch() async throws {
        let folder = try TemporaryFolder.make()
        defer { folder.remove() }
        let trash = try FakeTrash.make()
        defer { trash.remove() }
        try Partials.write(in: folder.url)
        try await withLogSandbox { sandbox in
            let location = try sandbox.realLocation()
            let log = try await ActivityLog.open(location)
            let (runID, _) = try await Fixtures.failedDownloadRun([Partials.safari], in: folder.url, to: trash, log: log)

            // The folder moves back, then the row that says so cannot be written.
            let spy = SpyRecorder(failing: SpyRecorder.Failure(kind: .recordUndoResult, occurrence: 0), forwardingTo: log)
            let crashed = try await Fixtures.undo(.run(runID), in: folder.url, trash: trash.locator, log: log, recorder: spy)
            #expect(Fixtures.isUndone(try Fixtures.outcome(for: Partials.safari, in: crashed)))
            #expect(crashed.logFailure != nil)
            try await log.close()

            let reopened = try await ActivityLog.open(location)
            let settled = try await UndoReconciler().reconcile(reopened)

            #expect(settled == UndoReconciler.Result(undone: 1, notUndone: 0))
            #expect(try await Fixtures.change(named: Partials.safari, inRun: runID, log: reopened).undoneAt != nil)
            #expect(try await reopened.totals() == .zero)
        }
    }

    @Test func aFolderRecordedWithoutADiskIDCannotBeChecked() {
        let evidence = UndoEvidence(sizeInBytes: 40, dateModified: .now, fileNumber: nil, contentHash: nil, isFolder: true)
        let folder = UndoItemFacts(isRegularFile: false, sizeInBytes: 96, dateModified: .now, fileNumber: 7, isDataless: false, isDirectory: true)
        #expect(evidence.refusal(for: folder) == .cannotBeChecked)
        let numbered = UndoEvidence(sizeInBytes: 40, dateModified: .now, fileNumber: 7, contentHash: nil, isFolder: true)
        #expect(numbered.refusal(for: folder) == nil)
        let file = UndoItemFacts(isRegularFile: true, sizeInBytes: 40, dateModified: .now, fileNumber: 7, isDataless: false)
        #expect(numbered.refusal(for: file) == .replaced)
        let other = UndoItemFacts(isRegularFile: false, sizeInBytes: 96, dateModified: .now, fileNumber: 8, isDataless: false, isDirectory: true)
        #expect(numbered.refusal(for: other) == .replaced)
        // A file's evidence never accepts a folder.
        let fileEvidence = UndoEvidence(sizeInBytes: 96, dateModified: folder.dateModified, fileNumber: 7, contentHash: nil)
        #expect(fileEvidence.refusal(for: folder) == .replaced)
    }
}
