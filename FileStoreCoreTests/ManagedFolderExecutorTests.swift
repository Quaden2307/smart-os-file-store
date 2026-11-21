import FileStoreCore
import Foundation
import Testing

/// A plan and its run belong to exactly one managed folder. The executor is given the log itself
/// (as `any CleanupRecording`, so no test helper stands between), with two folders on its list, and
/// must leave everything outside the plan's folder alone: a file in the other managed folder, a
/// destination there, and a folder the log does not hold at all.
@Suite("Managed folder executor")
struct ManagedFolderExecutorTests {
    private func executor(_ home: ManagedHome) -> CleanupExecutor {
        CleanupExecutor(recorder: home.log as any CleanupRecording, receipts: .fixed([]))
    }

    private func execute(_ plan: CleanupPlan, _ home: ManagedHome) async -> CleanupResult {
        await executor(home).execute(plan: plan, confirmedChangeIDs: Set(plan.changes.map(\.id)))
    }

    @Test func aChangeWhoseFileLiesInAnotherManagedFolderIsRefusedAndNothingThereMoves() async throws {
        try await withTemporaryFolderAsync { root in
            let home = try await ManagedHome(root: root)
            try FileDates.writeSettled(["a (1).txt": "in downloads"], in: home.downloads.url)
            try FileDates.writeSettled(["b (1).txt": "same", "b (2).txt": "same", "c (1).txt": "other"], in: home.desktop.url)
            let desktopRecords = try await RelocationPlans.records(in: home.desktop.url)
            // Three plans made for Desktop, one per operation, each handed over as a plan for Downloads.
            let trash = try await DuplicatePlanner().plan(records: desktopRecords, in: home.desktop)
            #expect(trash.changes.count == 1)
            let rename = try await RelocationPlans.rename([("c (1).txt", "c.txt")], in: home.desktop.url)
            // The move names a destination inside Downloads, so that its file being elsewhere is what refuses it.
            let move = try await RelocationPlans.move([("c (1).txt", home.downloads.url.appending(path: "Old downloads"), "c.txt")], in: home.desktop.url)
            let before = DiskState.snapshot(of: home.desktop.url)
            let downloadsBefore = DiskState.snapshot(of: home.downloads.url)

            for plan in [trash, rename, move] {
                let result = await execute(plan.claimed(for: home.downloads), home)

                #expect(result.items.count == 1, "\(plan.action)")
                #expect(result.items.allSatisfy { $0.outcome == .skipped(.outsideFolder) }, "\(plan.action)")
                #expect(result.trashedCount == 0)
                // The run is Downloads' own, and says the change was refused.
                let runID = try #require(result.runID)
                let run = try #require(try await home.log.run(id: runID))
                #expect(run.folderID == home.downloads.id)
                #expect(run.doneCount == 0)
                #expect(run.skippedCount == 1)
            }
            #expect(DiskState.snapshot(of: home.desktop.url) == before)
            #expect(DiskState.snapshot(of: home.downloads.url) == downloadsBefore)
        }
    }

    @Test func aMoveWhoseDestinationIsInAnotherManagedFolderIsRefused() async throws {
        try await withTemporaryFolderAsync { root in
            let home = try await ManagedHome(root: root)
            try FileDates.writeSettled(["a (1).txt": "in downloads"], in: home.downloads.url)
            let move = try await RelocationPlans.move([("a (1).txt", home.desktop.url, "a.txt")], in: home.downloads.url)

            let result = await execute(move.claimed(for: home.downloads), home)

            #expect(try RelocationPlans.outcome(for: "a (1).txt", in: result) == .skipped(.destinationOutsideFolder))
            #expect(DiskState.entryNames(in: home.downloads.url) == ["a (1).txt"])
            #expect(DiskState.entryNames(in: home.desktop.url).isEmpty)
        }
    }

    @Test func eachRunIsRecordedInItsPlansFolder() async throws {
        try await withTemporaryFolderAsync { root in
            let home = try await ManagedHome(root: root)
            try FileDates.writeSettled(["a (1).txt": "a"], in: home.downloads.url)
            try FileDates.writeSettled(["b (1).txt": "b"], in: home.desktop.url)
            let inDownloads = try await RelocationPlans.rename([("a (1).txt", "a.txt")], in: home.downloads.url)
            let onDesktop = try await RelocationPlans.rename([("b (1).txt", "b.txt")], in: home.desktop.url)

            let first = await execute(inDownloads.claimed(for: home.downloads), home)
            let second = await execute(onDesktop.claimed(for: home.desktop), home)

            #expect(first.renamed.count == 1)
            #expect(second.renamed.count == 1)
            #expect(DiskState.entryNames(in: home.downloads.url) == ["a.txt"])
            #expect(DiskState.entryNames(in: home.desktop.url) == ["b.txt"])
            let runs = try await home.log.runs()
            #expect(Set(runs.map(\.folderID)) == [home.downloads.id, home.desktop.id])
            let firstRunID = try #require(first.runID)
            let secondRunID = try #require(second.runID)
            #expect(try await home.log.run(id: firstRunID)?.folderID == home.downloads.id)
            #expect(try await home.log.run(id: secondRunID)?.folderID == home.desktop.id)
        }
    }

    /// The log takes no run for a folder it does not hold, so the run never opens and nothing changes.
    @Test func aFolderTheLogDoesNotHoldIsNeverCleaned() async throws {
        try await withTemporaryFolderAsync { root in
            let home = try await ManagedHome(root: root)
            let stranger = root.appending(path: "Stranger", directoryHint: .isDirectory)
            try FileManager.default.createDirectory(at: stranger, withIntermediateDirectories: false)
            try FileDates.writeSettled(["a (1).txt": "a"], in: stranger)
            let plan = try await RelocationPlans.rename([("a (1).txt", "a.txt")], in: stranger)
            #expect(try home.log.folderID(of: .downloads) != plan.folder.id)

            let result = await execute(plan, home)

            #expect(result.logFailure != nil)
            #expect(result.runID == nil)
            #expect(result.items.allSatisfy { $0.outcome == .skipped(.activityLogUnavailable) })
            #expect(DiskState.entryNames(in: stranger) == ["a (1).txt"])
            #expect(try await home.log.runs().isEmpty)
        }
    }

    /// One Tidy Now is one run in one folder. A plan for another folder among its plans is not
    /// carried out, and every change of it is reported.
    @Test func aTidyNowCarriesOutOnlyTheChangesOfItsOwnFolder() async throws {
        try await withTemporaryFolderAsync { root in
            let home = try await ManagedHome(root: root)
            try FileDates.writeSettled(["a (1).txt": "a"], in: home.downloads.url)
            try FileDates.writeSettled(["b (1).txt": "b"], in: home.desktop.url)
            let inDownloads = try await RelocationPlans.move(
                [("a (1).txt", home.downloads.url.appending(path: "Old downloads"), "a.txt")],
                in: home.downloads.url
            ).claimed(for: home.downloads)
            let onDesktop = try await RelocationPlans.rename([("b (1).txt", "b.txt")], in: home.desktop.url).claimed(for: home.desktop)
            let ids = Set((inDownloads.changes + onDesktop.changes).map(\.id))

            let result = await executor(home).executeTidyNow(plans: [onDesktop, inDownloads], confirmedChangeIDs: ids)

            // Moves are carried out before renames, so the run is the move's folder: Downloads.
            let runID = try #require(result.runID)
            let run = try #require(try await home.log.run(id: runID))
            #expect(run.folderID == home.downloads.id)
            #expect(run.confirmedCount == 2)
            #expect(run.doneCount == 1)
            #expect(run.skippedCount == 1)
            let moved = try #require(result.results.first { $0.action == .archiveOldDownloads })
            let renamed = try #require(result.results.first { $0.action == .fixMessyNames })
            #expect(moved.moved.count == 1)
            #expect(renamed.items.map(\.outcome) == [.skipped(.outsideFolder)])
            #expect(DiskState.entryNames(in: home.desktop.url) == ["b (1).txt"])
            #expect(DiskState.entryNames(in: home.downloads.url.appending(path: "Old downloads")) == ["a.txt"])
            #expect(try await home.log.changes(inRun: run.id).map(\.outcome).contains(.skipped(.outsideFolder)))
        }
    }

    /// A copy of a Desktop file in Downloads is not a duplicate of it: duplicates are found within
    /// one folder, and cleaning Desktop lists and changes nothing in Downloads.
    @Test func aCleanupInOneFolderNeverListsOrChangesAFileInAnother() async throws {
        try await withTemporaryFolderAsync { root in
            let home = try await ManagedHome(root: root)
            try FileDates.writeSettled(["report.pdf": "same", "report (1).pdf": "same"], in: home.desktop.url)
            try FileDates.writeSettled(["report (2).pdf": "same", "solo.txt": "solo"], in: home.downloads.url)
            let downloadsBefore = DiskState.snapshot(of: home.downloads.url)
            let desktopRecords = try await RelocationPlans.records(in: home.desktop.url)

            let plan = try await DuplicatePlanner().plan(records: desktopRecords, in: home.desktop)
            #expect(plan.changes.map(\.record.url.lastPathComponent) == ["report (1).pdf"])
            #expect(plan.changes.allSatisfy { $0.record.url.deletingLastPathComponent().standardizedFileURL == home.desktop.url.standardizedFileURL })

            let result = await execute(plan, home)
            #expect(result.trashedCount == 1)
            #expect(DiskState.entryNames(in: home.desktop.url) == ["report.pdf"])
            #expect(DiskState.snapshot(of: home.downloads.url) == downloadsBefore)
        }
    }
}
