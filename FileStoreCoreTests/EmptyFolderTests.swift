import Darwin
import FileStoreCore
import Foundation
import Testing

/// Remove Empty Folders on real folders: what the scan reads as empty, what the planner proposes and
/// leaves out, the recheck right before the Trash, the activity log and undo. Folders go through the
/// real Trash; `TrashedFiles` removes the test's own afterwards when the runner may.
@Suite("Remove Empty Folders")
struct EmptyFolderTests {
    private typealias Names = FakeDownloadsFolder.Names

    private static let dsStore = Data("\0\0\0\u{1}Bud1".utf8)

    private func plan(_ folder: URL, keptItems: KeptItems = KeptItems()) async throws -> CleanupPlan {
        try #require(
            try await CleanupPlanners.plan(
                .removeEmptyFolders,
                records: try await RelocationPlans.records(in: folder),
                in: .temporary(folder),
                eligibility: CandidateEligibility(),
                keptItems: keptItems,
                installers: .testing(applications: [])
            )
        )
    }

    private func execute(_ plan: CleanupPlan, log: ActivityLog) async -> CleanupResult {
        await CleanupExecutor(recorder: log).execute(plan: plan, confirmedChangeIDs: Set(plan.changes.map(\.id)))
    }

    private func cleanUp(_ result: CleanupResult) {
        TrashedFiles.removeFolders(result) { url in
            switch url.lastPathComponent {
            case "Empty": [:]
            case "OnlyDS": [".DS_Store": Self.dsStore]
            default: nil
            }
        }
    }

    /// Makes the folders at `paths` (relative to `folder`, parents first) and the files in `files`,
    /// then settles everything, deepest first, so that no folder is new.
    private func make(_ paths: [String], files: [String: Data] = [:], in folder: URL) throws {
        for path in paths {
            try FileManager.default.createDirectory(at: folder.appending(path: path, directoryHint: .isDirectory), withIntermediateDirectories: false)
        }
        for (path, data) in files {
            try data.write(to: folder.appending(path: path))
        }
        let all = (paths + files.keys).sorted { $0.split(separator: "/").count > $1.split(separator: "/").count }
        try FileDates.settle(all.map { folder.appending(path: $0) })
    }

    private func names(_ plan: CleanupPlan) -> [String] {
        plan.changes.map(\.record.displayName)
    }

    // MARK: - What counts as empty

    @Test func emptyFoldersAreProposedTickedAndEverythingElseIsNot() async throws {
        try await withTemporaryFolderAsync { folder in
            // Empty folders nested one level deeper than the reader goes.
            let deep = (1...PackageContents.maximumDepth).map { level in "TooDeep/" + (1...level).map { "d\($0)" }.joined(separator: "/") }
            try make(
                ["Empty", "OnlyDS", "Nested", "Nested/a", "Nested/a/b", "Nested/c", "Deep", "Deep/a", "Deep/a/b",
                 "Old downloads", "Empty.app", "WithLink", "TooDeep"] + deep,
                files: ["OnlyDS/.DS_Store": Self.dsStore, "Nested/a/.DS_Store": Self.dsStore, "Nested/.localized": Data(),
                        "Deep/a/b/notes.txt": Data("one deep file".utf8), "file.txt": Data("x".utf8)],
                in: folder
            )
            // A link to an empty folder, and a folder holding only a link.
            try FileManager.default.createSymbolicLink(atPath: folder.appending(path: "link").path(percentEncoded: false), withDestinationPath: "Empty")
            try FileManager.default.createSymbolicLink(atPath: folder.appending(path: "WithLink/to-empty").path(percentEncoded: false), withDestinationPath: "../Empty")
            try FileDates.settle([folder.appending(path: "link"), folder.appending(path: "WithLink/to-empty"), folder.appending(path: "WithLink")])

            let plan = try await plan(folder)

            #expect(names(plan) == ["Empty", "Nested", "OnlyDS"])
            #expect(plan.changes.allSatisfy { $0.reason == .emptyFolder && $0.operation == .moveToTrash })
            // Ticked by default: not a review list, and not a possible match.
            #expect(plan.changes.allSatisfy { !$0.reason.isReviewOnly && !$0.reason.isPossibleMatch })
            // Too deep to read in full is not empty, and not reported as unreadable either.
            #expect(plan.skippedItems.isEmpty)
        }
    }

    @Test func aFolderTheAppCannotReadIsNotEmptyAndIsListedAsNotChecked() async throws {
        try await withTemporaryFolderAsync { folder in
            // And a folder holding a file beside an unreadable folder: simply not empty.
            try make(["Private", "Project", "Project/a-private"], files: ["Project/README.md": Data("read me".utf8)], in: folder)
            let privatePaths = ["Private", "Project/a-private"].map { folder.appending(path: $0).path(percentEncoded: false) }
            for path in privatePaths {
                #expect(chmod(path, 0) == 0)
            }
            defer {
                for path in privatePaths {
                    _ = chmod(path, 0o755)
                }
            }

            let plan = try await plan(folder)

            #expect(plan.isEmpty)
            #expect(plan.skippedItems.map(\.url.lastPathComponent) == ["Private"])
            #expect(plan.skippedItems.map(\.reason) == [.accessDenied])
        }
    }

    @Test func newAndKeptFoldersAreLeftOut() async throws {
        try await withTemporaryFolderAsync { folder in
            try make(["Kept"], in: folder)
            try FileManager.default.createDirectory(at: folder.appending(path: "Fresh", directoryHint: .isDirectory), withIntermediateDirectories: false)
            let records = try await RelocationPlans.records(in: folder)
            let kept = try RelocationPlans.record(named: "Kept", in: records)

            let unkept = try await plan(folder)
            #expect(names(unkept) == ["Kept"])
            let keptList = KeptItems([KeptItem(identity: kept.persistentIdentity, path: kept.keptItemPath, keptAt: .now)])
            #expect(try await plan(folder, keptItems: keptList).isEmpty)
        }
    }

    @Test func theFakeFolderGivesItsTwoEmptyFolders() async throws {
        try await withFakeDownloadsFolder { fixture in
            let plan = try await plan(fixture.url)
            #expect(names(plan) == [Names.emptyFolder, Names.dsStoreFolder])
        }
    }

    // MARK: - The run, the recheck, the log and undo

    @Test func trashingIsLoggedAndPlanningAgainProposesNothing() async throws {
        try await withTemporaryFolderAsync { folder in
            try make(["Empty", "OnlyDS"], files: ["OnlyDS/.DS_Store": Self.dsStore], in: folder)
            let log = try await ActivityLog.open(.inMemory)
            let plan = try await plan(folder)
            #expect(names(plan) == ["Empty", "OnlyDS"])

            let result = await execute(plan, log: log)
            defer { cleanUp(result) }

            #expect(result.trashedCount == 2)
            #expect(DiskState.entryNames(in: folder).isEmpty)
            let runID = try #require(result.runID)
            #expect(try await log.run(id: runID)?.action == .removeEmptyFolders)
            let rows = try await log.changes(inRun: runID)
            #expect(rows.map(\.outcome) == [.trashed, .trashed])
            #expect(rows.allSatisfy { $0.reason == .emptyFolder && $0.fileNumber != nil })
            #expect(rows.map(\.originalPath) == plan.changes.map(\.originalPath))

            #expect(try await self.plan(folder).isEmpty)
        }
    }

    @Test func undoingTheRunPutsTheFoldersBack() async throws {
        try await withTemporaryFolderAsync { folder in
            try make(["Empty", "OnlyDS"], files: ["OnlyDS/.DS_Store": Self.dsStore], in: folder)
            let log = try await ActivityLog.open(.inMemory)
            let result = await execute(try await plan(folder), log: log)
            defer { cleanUp(result) }
            #expect(result.trashedCount == 2)
            let runID = try #require(result.runID)

            let undo = try await UndoFixtures.undo(.run(runID), in: folder, trash: .system, log: log)

            #expect(Set(undo.undone.map(\.originalName)) == ["Empty", "OnlyDS"])
            #expect(undo.notUndone.isEmpty)
            #expect(Set(DiskState.entryNames(in: folder)) == ["Empty", "OnlyDS"])
            #expect(DiskState.entryNames(in: folder.appending(path: "OnlyDS")) == [".DS_Store"])
        }
    }

    @Test func aFileAddedBetweenPlanAndExecuteKeepsTheFolder() async throws {
        try await withTemporaryFolderAsync { folder in
            try make(["Empty", "Nested", "Nested/a"], in: folder)
            let log = try await ActivityLog.open(.inMemory)
            let plan = try await plan(folder)
            #expect(names(plan) == ["Empty", "Nested"])
            // Files arrive, one at the top of a folder, one deep inside the other, dated back.
            let top = folder.appending(path: "Empty/new.txt")
            let deep = folder.appending(path: "Nested/a/new.txt")
            try Data("new".utf8).write(to: top)
            try Data("new".utf8).write(to: deep)
            try FileDates.settle([top, deep])

            let result = await execute(plan, log: log)

            #expect(result.trashedCount == 0)
            #expect(try RelocationPlans.outcome(for: "Empty", in: result) == .skipped(.changedSinceScan))
            #expect(try RelocationPlans.outcome(for: "Nested", in: result) == .skipped(.changedSinceScan))
            #expect(DiskState.exists(top) && DiskState.exists(deep))
        }
    }
}
