import FileStoreCore
import Foundation
import Testing

/// The executor's last look at the Kept list: a file marked Kept after its plan was made is never
/// changed, whatever the operation, and a Kept list that cannot be read stops the run.
@Suite("Executor and Kept files")
struct KeptExecutorTests {
    @Test func aDuplicateMarkedKeptAfterPlanningIsNotTrashed() async throws {
        let temp = try TemporaryFolder.make()
        defer { temp.remove() }
        try FileDates.writeSettled(["report.pdf": "quarterly report body", "report (1).pdf": "quarterly report body"], in: temp.url)
        let records = try await RelocationPlans.records(in: temp.url)
        let log = try await ActivityLog.open(.inMemory)
        let plan = try #require(
            try await CleanupPlanners.plan(.findDuplicates, records: records, in: temp.url, eligibility: CandidateEligibility(), keptItems: KeptItems(), installers: .testing())
        )
        let copy = try #require(plan.changes.first)
        #expect(copy.record.displayName == "report (1).pdf")

        try await log.keep([copy.record])
        let result = await CleanupExecutor(recorder: log).execute(plan: plan, confirmedChangeIDs: [copy.id])

        #expect(try RelocationPlans.outcome(for: "report (1).pdf", in: result) == .skipped(.markedKept))
        #expect(result.trashedCount == 0)
        #expect(result.logFailure == nil)
        #expect(DiskState.exists(temp.url.appending(path: "report (1).pdf")))
        // The activity log says why it was left alone.
        let runID = try #require(result.runID)
        #expect(try await log.changes(inRun: runID).map(\.outcome) == [.skipped(.markedKept)])
    }

    @Test func aFileMarkedKeptAfterPlanningIsNotRenamedOrMoved() async throws {
        let temp = try TemporaryFolder.make()
        defer { temp.remove() }
        try FileDates.writeSettled(["manual (2).pdf": "manual", "old-receipt.pdf": "receipt", "budget copy.xlsx": "budget"], in: temp.url)
        let archive = temp.url.appending(path: "Old downloads", directoryHint: .isDirectory)
        let rename = try await RelocationPlans.rename([("manual (2).pdf", "manual.pdf"), ("budget copy.xlsx", "budget.xlsx")], in: temp.url)
        let move = try await RelocationPlans.move([("old-receipt.pdf", archive, "old-receipt.pdf")], in: temp.url)
        let log = try await ActivityLog.open(.inMemory)
        let manual = try #require(rename.changes.first { $0.record.displayName == "manual (2).pdf" })
        let receipt = try #require(move.changes.first)

        try await log.keep([manual.record, receipt.record])
        let executor = CleanupExecutor(recorder: log)
        let renamed = await executor.execute(plan: rename, confirmedChangeIDs: Set(rename.changes.map(\.id)))
        let moved = await executor.execute(plan: move, confirmedChangeIDs: [receipt.id])

        #expect(try RelocationPlans.outcome(for: "manual (2).pdf", in: renamed) == .skipped(.markedKept))
        #expect(try RelocationPlans.outcome(for: "old-receipt.pdf", in: moved) == .skipped(.markedKept))
        #expect(DiskState.exists(temp.url.appending(path: "manual (2).pdf")))
        #expect(DiskState.exists(temp.url.appending(path: "old-receipt.pdf")))
        #expect(!DiskState.exists(archive))
        // A file that is not Kept is renamed as usual.
        #expect(try RelocationPlans.outcome(for: "budget copy.xlsx", in: renamed) == .renamed(
            from: temp.url.appending(path: "budget copy.xlsx"),
            to: temp.url.appending(path: "budget.xlsx")
        ))
    }

    @Test func noStartedRowIsWrittenForAKeptFileAndTheRunGoesOn() async throws {
        let temp = try TemporaryFolder.make()
        defer { temp.remove() }
        try FileDates.writeSettled(["a (1).txt": "a", "b (1).txt": "b"], in: temp.url)
        let plan = try await RelocationPlans.rename([("a (1).txt", "a.txt"), ("b (1).txt", "b.txt")], in: temp.url)
        let log = try await ActivityLog.open(.inMemory)
        try await log.keep([try #require(plan.changes.first).record])
        let recorder = SpyRecorder(forwardingTo: log)

        let result = await CleanupExecutor(recorder: recorder).execute(plan: plan, confirmedChangeIDs: Set(plan.changes.map(\.id)))

        // The Kept check and the started row are one step: the Kept file got only its result row.
        #expect(recorder.callNames == [
            "beginRun", "recordResult a (1).txt", "recordIntent b (1).txt", "recordResult b (1).txt", "finishRun",
        ])
        #expect(result.items.map(\.outcome) == [
            .skipped(.markedKept),
            .renamed(from: temp.url.appending(path: "b (1).txt"), to: temp.url.appending(path: "b.txt")),
        ])
        #expect(result.logFailure == nil)
        #expect(DiskState.exists(temp.url.appending(path: "a (1).txt")))
    }

    @Test func theKeptCheckAlsoComparesThePathTheChangeActsOn() async throws {
        let temp = try TemporaryFolder.make()
        defer { temp.remove() }
        try FileDates.writeSettled(["a (1).txt": "a"], in: temp.url)
        let plan = try await RelocationPlans.rename([("a (1).txt", "a.txt")], in: temp.url)
        let change = try #require(plan.changes.first)
        let log = try await ActivityLog.open(.inMemory)
        // An entry made without an identity, at the path the executor acts on rather than the
        // plan's spelling of it, as on a volume that gives items no lasting numbers.
        let actedOn = FileRecord(
            url: temp.url.appending(path: "a (1).txt"),
            displayName: "a (1).txt",
            kind: .file,
            localizedTypeDescription: nil,
            contentType: nil,
            sizeInBytes: 1,
            dateAdded: nil,
            dateModified: nil,
            isDownloading: false
        )
        try await log.keep([actedOn])
        let runID = try log.beginRun(CleanupRunStart(action: .fixMessyNames, folderURL: temp.url, confirmedCount: 1, startedAt: .now))

        let decision = try log.recordIntent(
            CleanupChangeIntent(
                runID: runID,
                sequence: 0,
                change: change,
                contentHash: nil,
                keptProbe: KeptItemProbe(identity: nil, paths: ["/elsewhere/a (1).txt", actedOn.keptItemPath]),
                attemptedAt: .now
            )
        )

        #expect(decision == .markedKept)
    }
}
