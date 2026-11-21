import FileStoreCore
import Foundation
import Testing

/// Review Near-Duplicates on real folders: the plan the fake Downloads folder gives, the guarantee
/// that a group always keeps a file, the activity log, undo, and the session's hash cache. Files
/// go through the real Trash, since `trashItem` puts them only there; `TrashedFiles` removes the
/// test's own afterwards when the runner may.
@Suite("Review Near-Duplicates on disk")
struct NearDuplicateDiskTests {
    private typealias Names = FakeDownloadsFolder.Names

    private func plan(_ folder: URL, hashCache: ContentHashCache = ContentHashCache()) async throws -> CleanupPlan {
        try #require(
            try await CleanupPlanners.plan(
                .reviewNearDuplicates,
                records: try await RelocationPlans.records(in: folder),
                in: .temporary(folder),
                eligibility: CandidateEligibility(),
                keptItems: KeptItems(),
                installers: .testing(applications: []),
                hashCache: hashCache
            )
        )
    }

    private func execute(_ plan: CleanupPlan, log: ActivityLog, only names: Set<String>? = nil) async -> CleanupResult {
        let ids = plan.changes.filter { names?.contains($0.record.displayName) ?? true }.map(\.id)
        return await CleanupExecutor(recorder: log).execute(plan: plan, confirmedChangeIDs: Set(ids))
    }

    /// Removes from the Trash whatever of `files` the run put there.
    private func cleanUp(_ result: CleanupResult, _ files: [String: String]) {
        TrashedFiles.remove(result) { files[$0.lastPathComponent].map { Data($0.utf8) } }
    }

    private static let pair = ["notes.txt": "draft one", "notes (1).txt": "draft two, edited"]

    // MARK: - The plan

    @Test func theFakeFolderGivesTheNotesPairAndNotTheIdenticalReports() async throws {
        try await withFakeDownloadsFolder { fixture in
            let plan = try await plan(fixture.url)

            // The notes, invoice and agenda pairs: same cleaned name, different bytes.
            #expect(plan.nearDuplicateGroups.map(\.cleanedName) == [Names.agendaClean, Names.invoice, Names.notes])
            let notes = try #require(plan.nearDuplicateGroups.first { $0.cleanedName == Names.notes })
            #expect(notes.members.map(\.record.displayName) == [Names.notesEdited, Names.notes])
            #expect(notes.members.allSatisfy { $0.identicalCopies.isEmpty })
            // The report copies all hold the same bytes: duplicates, Find Duplicates' business.
            let shown = plan.nearDuplicateGroups.flatMap { $0.members.flatMap { [$0.record] + $0.identicalCopies } }
            #expect(!shown.contains { $0.displayName.hasPrefix("report") })
            // Different extensions never match.
            #expect(!shown.contains { $0.displayName.hasPrefix("todo") })
            // Nothing is preselected and nothing is chosen to stay.
            #expect(plan.changes.allSatisfy { $0.reason.isReviewOnly })
            #expect(plan.duplicateGroups.isEmpty)
            #expect(Set(plan.changes.map(\.id)) == Set(plan.nearDuplicateGroups.flatMap { $0.members.map(\.id) }))
            let edited = try #require(plan.changes.first { $0.record.displayName == Names.notesEdited })
            #expect(edited.reason == .nearDuplicate(sameNameAs: Names.notes))
        }
    }

    // MARK: - A group always keeps a file

    @Test func aConfirmationOfEveryFileInAGroupLeavesOne() async throws {
        try await withTemporaryFolderAsync { folder in
            let files = Self.pair.merging(["memo.txt": "one", "memo (1).txt": "two two", "memo (2).txt": "three three three"]) { $1 }
            try FileDates.writeSettled(files, in: folder)
            let log = try await ActivityLog.open(.inMemory)
            let plan = try await plan(folder)
            #expect(plan.nearDuplicateGroups.count == 2)

            // What the preview never sends: every file of every group.
            let result = await execute(plan, log: log)
            defer { cleanUp(result, files) }

            #expect(result.trashedCount == 3)
            // Written in name order, so the newest of each group is the one spared.
            #expect(try RelocationPlans.outcome(for: "notes.txt", in: result) == .skipped(.lastInGroup))
            #expect(try RelocationPlans.outcome(for: "memo.txt", in: result) == .skipped(.lastInGroup))
            #expect(Set(DiskState.entryNames(in: folder)) == ["notes.txt", "memo.txt"])
        }
    }

    @Test func theLastFileLeftInTheFolderIsNotMoved() async throws {
        try await withTemporaryFolderAsync { folder in
            try FileDates.writeSettled(Self.pair, in: folder)
            let log = try await ActivityLog.open(.inMemory)
            let plan = try await plan(folder)
            // The partner went after the plan was made (the test's own file).
            try FileManager.default.removeItem(at: folder.appending(path: "notes.txt"))

            let result = await execute(plan, log: log, only: ["notes (1).txt"])
            defer { cleanUp(result, Self.pair) }

            #expect(try RelocationPlans.outcome(for: "notes (1).txt", in: result) == .skipped(.lastInGroup))
            #expect(DiskState.entryNames(in: folder) == ["notes (1).txt"])
        }
    }

    @Test func aPartnerReplacedByAnotherFileDoesNotCountAsTheOneThatStays() async throws {
        try await withTemporaryFolderAsync { folder in
            try FileDates.writeSettled(Self.pair, in: folder)
            let log = try await ActivityLog.open(.inMemory)
            let plan = try await plan(folder)
            // Something else now has the partner's name.
            let partner = folder.appending(path: "notes.txt")
            try FileManager.default.removeItem(at: partner)
            try Data("an unrelated file".utf8).write(to: partner)
            try FileDates.set(partner, to: Date(timeIntervalSinceNow: -FileDates.settledAge))

            let result = await execute(plan, log: log, only: ["notes (1).txt"])
            defer { cleanUp(result, Self.pair) }

            #expect(try RelocationPlans.outcome(for: "notes (1).txt", in: result) == .skipped(.lastInGroup))
            #expect(DiskState.entryNames(in: folder).count == 2)
        }
    }

    @Test func aCraftedGroupOfUnrelatedNamesMovesNothing() async throws {
        try await withTemporaryFolderAsync { folder in
            let files = ["alpha.txt": "one", "beta.txt": "two two"]
            try FileDates.writeSettled(files, in: folder)
            let log = try await ActivityLog.open(.inMemory)
            let records = try await RelocationPlans.records(in: folder)
            let alpha = try RelocationPlans.record(named: "alpha.txt", in: records)
            let beta = try RelocationPlans.record(named: "beta.txt", in: records)
            let hash = ContentHash(bytes: Array(repeating: 1, count: 32))
            let other = ContentHash(bytes: Array(repeating: 2, count: 32))
            let plan = CleanupPlan(
                action: .reviewNearDuplicates,
                folder: log.downloads(at: folder),
                changes: [ProposedChange(record: alpha, operation: .moveToTrash, reason: .nearDuplicate(sameNameAs: "beta.txt"))],
                nearDuplicateGroups: [
                    NearDuplicateGroup(cleanedName: "alpha.txt", members: [
                        NearDuplicateGroup.Member(record: alpha, contentHash: hash),
                        NearDuplicateGroup.Member(record: beta, contentHash: other),
                    ]),
                ]
            )

            let result = await execute(plan, log: log)
            defer { cleanUp(result, files) }

            #expect(try RelocationPlans.outcome(for: "alpha.txt", in: result) == .skipped(.lastInGroup))
            #expect(DiskState.entryNames(in: folder).count == 2)
        }
    }

    @Test func aFileThatChangedSinceThePlanStays() async throws {
        try await withTemporaryFolderAsync { folder in
            try FileDates.writeSettled(Self.pair, in: folder)
            let log = try await ActivityLog.open(.inMemory)
            let plan = try await plan(folder)
            let edited = folder.appending(path: "notes (1).txt")
            try Data("draft two, edited again".utf8).write(to: edited)

            let result = await execute(plan, log: log, only: ["notes (1).txt"])

            #expect(try RelocationPlans.outcome(for: "notes (1).txt", in: result) == .skipped(.changedSinceScan))
            #expect(DiskState.entryNames(in: folder).count == 2)
        }
    }

    // MARK: - The run, the log and undo

    @Test func movingOneFileIsLoggedAndPlanningAgainProposesNothing() async throws {
        try await withTemporaryFolderAsync { folder in
            try FileDates.writeSettled(Self.pair, in: folder)
            let log = try await ActivityLog.open(.inMemory)
            let plan = try await plan(folder)
            let change = try #require(plan.changes.first { $0.record.displayName == "notes (1).txt" })

            let result = await execute(plan, log: log, only: ["notes (1).txt"])
            defer { cleanUp(result, Self.pair) }

            #expect(result.trashedCount == 1)
            #expect(result.action == .reviewNearDuplicates)
            #expect(DiskState.entryNames(in: folder) == ["notes.txt"])
            let runID = try #require(result.runID)
            #expect(try await log.run(id: runID)?.action == .reviewNearDuplicates)
            let rows = try await log.changes(inRun: runID)
            #expect(rows.count == 1)
            #expect(rows.first?.outcome == .trashed)
            #expect(rows.first?.reason == .nearDuplicate(sameNameAs: "notes.txt"))
            #expect(rows.first?.originalPath == change.originalPath)
            #expect(rows.first?.sizeInBytes == change.sizeInBytes)
            #expect(rows.first?.fileNumber != nil)
            #expect(rows.first?.contentHash == nil)
            #expect(try await log.totals() == ActivityTotals(bytesMovedToTrash: change.sizeInBytes, filesCleaned: 1))

            // One file left: no group.
            #expect(try await self.plan(folder).isEmpty)
        }
    }

    @Test func undoingTheRunPutsTheFileBack() async throws {
        try await withTemporaryFolderAsync { folder in
            try FileDates.writeSettled(Self.pair, in: folder)
            let log = try await ActivityLog.open(.inMemory)
            let result = await execute(try await plan(folder), log: log, only: ["notes (1).txt"])
            defer { cleanUp(result, Self.pair) }
            #expect(result.trashedCount == 1)
            let runID = try #require(result.runID)

            let undo = try await UndoFixtures.undo(.run(runID), in: folder, trash: .system, log: log)

            #expect(undo.undone.map(\.originalName) == ["notes (1).txt"])
            #expect(undo.notUndone.isEmpty)
            #expect(Set(DiskState.entryNames(in: folder)) == Set(Self.pair.keys))
            #expect(DiskState.text(of: folder.appending(path: "notes (1).txt")) == Self.pair["notes (1).txt"])
            #expect(try await log.changes(inRun: runID).allSatisfy { $0.undoneAt != nil })
            #expect(try await log.totals() == .zero)
        }
    }

    // MARK: - Hashes read once a session

    @Test func hashesAlreadyReadThisSessionAreNotReadAgain() async throws {
        try await withTemporaryFolderAsync { folder in
            try FileDates.writeSettled(Self.pair, in: folder)
            let cache = ContentHashCache()

            #expect(try await plan(folder, hashCache: cache).nearDuplicateGroups.count == 1)
            #expect(cache.count == 2)

            // A cache that says both hold the same bytes is believed, so the files were not read.
            let lying = ContentHashCache()
            let same = ContentHash(bytes: Array(repeating: 7, count: 32))
            for record in try await RelocationPlans.records(in: folder) {
                lying.store(same, for: record)
            }
            #expect(try await plan(folder, hashCache: lying).isEmpty)
        }
    }

    @Test func aCachedHashIsIgnoredOnceTheFileChanged() async throws {
        try await withTemporaryFolderAsync { folder in
            try FileDates.writeSettled(Self.pair, in: folder)
            let cache = ContentHashCache()
            let same = ContentHash(bytes: Array(repeating: 7, count: 32))
            for record in try await RelocationPlans.records(in: folder) {
                cache.store(same, for: record)
            }
            try Data("draft two, edited again".utf8).write(to: folder.appending(path: "notes (1).txt"))
            try FileDates.set(folder.appending(path: "notes (1).txt"), to: Date(timeIntervalSinceNow: -FileDates.settledAge))

            #expect(try await plan(folder, hashCache: cache).nearDuplicateGroups.count == 1)
        }
    }

    @Test func theCacheKeepsOnlyTheFilesOfAFoldersLatestScanAndLeavesOtherFoldersAlone() async throws {
        try await withTemporaryFolderAsync { root in
            let folder = root.appending(path: "Downloads", directoryHint: .isDirectory)
            let other = root.appending(path: "Desktop", directoryHint: .isDirectory)
            for url in [folder, other] {
                try FileManager.default.createDirectory(at: url, withIntermediateDirectories: false)
                try FileDates.writeSettled(Self.pair, in: url)
            }
            let cache = ContentHashCache()
            let records = try await RelocationPlans.records(in: folder)
            let otherRecords = try await RelocationPlans.records(in: other)
            let same = ContentHash(bytes: Array(repeating: 7, count: 32))
            for record in records + otherRecords {
                cache.store(same, for: record)
            }
            let remaining = try #require(records.first)
            cache.keepOnly([remaining], in: .temporary(folder))
            // One folder's scan says nothing about another folder's files.
            #expect(cache.count == 1 + otherRecords.count)
            #expect(cache.hash(for: remaining) == same)
            #expect(otherRecords.allSatisfy { cache.hash(for: $0) == same })
            cache.keepOnly([], in: .temporary(other))
            #expect(cache.count == 1)
        }
    }

    @Test func findDuplicatesLeavesItsHashesForTheSession() async throws {
        try await withFakeDownloadsFolder { fixture in
            let cache = ContentHashCache()
            _ = try await CleanupPlanners.plan(
                .findDuplicates,
                records: try await RelocationPlans.records(in: fixture.url),
                in: .temporary(fixture.url),
                eligibility: CandidateEligibility(),
                keptItems: KeptItems(),
                installers: .testing(applications: []),
                hashCache: cache
            )
            #expect(cache.count > 0)
        }
    }
}
