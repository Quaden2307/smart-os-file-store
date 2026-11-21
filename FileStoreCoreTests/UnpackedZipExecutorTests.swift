import FileStoreCore
import Foundation
import Testing

/// Remove Unpacked Zips carried out: through the real Trash, since `trashItem` puts things only
/// there, with `TrashedFiles` removing the test's own zips afterwards when the runner may. Each zip
/// is checked again right before it moves, and so is the copy it was unpacked to, which is never
/// touched.
@Suite("Unpacked zip executor")
struct UnpackedZipExecutorTests {
    private typealias Zips = UnpackedZips

    private func withZips(_ body: (URL, UnpackedZips.Contents, ActivityLog) async throws -> Void) async throws {
        try await withTemporaryFolderAsync { folder in
            let contents = try Zips.write(in: folder)
            let log = try await ActivityLog.open(.inMemory)
            try await body(folder, contents, log)
        }
    }

    private func plan(_ folder: URL, now: Date = .now) async throws -> CleanupPlan {
        try #require(try await Zips.plan(folder, now: now))
    }

    private func execute(_ plan: CleanupPlan, recorder: any CleanupRecording, beforeChange: (@Sendable (ProposedChange) -> Void)? = nil) async -> CleanupResult {
        await CleanupExecutor(recorder: testRecorder(recorder)).execute(
            plan: plan,
            confirmedChangeIDs: Set(plan.changes.map(\.id)),
            beforeChange: beforeChange
        )
    }

    /// Removes from the Trash whatever of this test's the run put there, and nothing else.
    private func cleanUp(_ result: CleanupResult, _ contents: UnpackedZips.Contents) {
        TrashedFiles.remove(result) { contents.zipData(at: $0) }
    }

    private func outcome(_ name: String, in result: CleanupResult) throws -> CleanupItemOutcome {
        try RelocationPlans.outcome(for: name, in: result)
    }

    /// The copies, exactly as written: what no run may ever change.
    private func expectCopiesUntouched(in folder: URL, _ contents: UnpackedZips.Contents) {
        let project = folder.appending(path: Zips.project)
        #expect(DiskState.text(of: project.appending(path: Zips.readme)) == contents.readme)
        #expect(DiskState.text(of: project.appending(path: "\(Zips.source)/\(Zips.main)")) == contents.main)
        #expect(DiskState.text(of: folder.appending(path: Zips.contract)) == contents.contract)
    }

    private func changeOf(_ name: String, in plan: CleanupPlan) throws -> ProposedChange {
        try #require(plan.changes.first { $0.record.displayName == name })
    }

    // MARK: - The run

    @Test func bothGoToTheTrashAndTheLogSaysEnoughToUndoThem() async throws {
        try await withZips { folder, contents, log in
            let plan = try await plan(folder)
            #expect(Zips.proposals(plan) == ["\(Zips.contractZip) → \(Zips.contract)", "\(Zips.projectZip) → \(Zips.project)"])

            let result = await execute(plan, recorder: log)
            defer { cleanUp(result, contents) }

            #expect(result.trashedCount == 2)
            #expect(result.action == .removeUnpackedZips)
            let expectedBytes = Int64(contents.zips.values.reduce(0) { $0 + $1.count })
            #expect(result.bytesFreed == expectedBytes)
            #expect(Set(DiskState.entryNames(in: folder)) == [Zips.project, Zips.contract])
            expectCopiesUntouched(in: folder, contents)

            let runID = try #require(result.runID)
            #expect(try await log.run(id: runID)?.action == .removeUnpackedZips)
            let rows = try await log.changes(inRun: runID)
            #expect(rows.map { URL(filePath: $0.originalPath).lastPathComponent } == [Zips.contractZip, Zips.projectZip])
            #expect(rows.map(\.outcome) == [.trashed, .trashed])
            #expect(rows.map(\.reason) == [.unpackedZip(unpackedTo: Zips.contract), .unpackedZip(unpackedTo: Zips.project)])
            #expect(rows.map(\.isFolder) == [false, false])
            #expect(rows.allSatisfy { $0.fileNumber != nil && $0.contentHash == nil })
            #expect(rows.allSatisfy { !$0.originalPath.hasSuffix("/") && $0.resultingPath?.hasSuffix("/") == false })
            for (row, change) in zip(rows, plan.changes) {
                #expect(row.sizeInBytes == change.sizeInBytes)
                #expect(row.dateModified == change.dateModified)
            }
            #expect(try await log.totals() == ActivityTotals(bytesMovedToTrash: expectedBytes, filesCleaned: 2))
        }
    }

    @Test func runningItAgainRightAfterProposesNothing() async throws {
        try await withZips { folder, contents, log in
            let result = await execute(try await plan(folder), recorder: log)
            defer { cleanUp(result, contents) }
            #expect(result.trashedCount == 2)

            let again = try await plan(folder)
            #expect(again.isEmpty)
            #expect(again.skippedItems.isEmpty)
        }
    }

    @Test func theStartedRowIsWrittenBeforeTheZipMovesAndTheCopyIsThere() async throws {
        try await withZips { folder, contents, log in
            let plan = try await plan(folder)
            let spy = SpyRecorder(forwardingTo: log)
            let seen = ConcurrentLog<String>()

            let result = await execute(plan, recorder: spy) { change in
                guard case .unpackedZip(let copy) = change.reason else { return }
                let zipThere = DiskState.exists(folder.appending(path: change.record.displayName))
                let copyThere = DiskState.exists(folder.appending(path: copy))
                seen.append("\(spy.callNames.last ?? "") zip: \(zipThere) copy: \(copyThere)")
            }
            defer { cleanUp(result, contents) }

            #expect(seen.values == [
                "recordIntent \(Zips.contractZip) zip: true copy: true",
                "recordIntent \(Zips.projectZip) zip: true copy: true",
            ])
            #expect(result.trashedCount == 2)
        }
    }

    // MARK: - The copy changed after the plan

    @Test func theUnpackedItemRemovedBetweenPlanAndExecuteLeavesItsZipAlone() async throws {
        try await withZips { folder, contents, log in
            let plan = try await plan(folder)
            try FileManager.default.removeItem(at: folder.appending(path: Zips.project))

            let result = await execute(plan, recorder: log)
            defer { cleanUp(result, contents) }

            #expect(try outcome(Zips.projectZip, in: result) == .skipped(.unpackedCopyMissing(name: Zips.project)))
            #expect(try outcome(Zips.contractZip, in: result).isTrashed)
            #expect(DiskState.exists(folder.appending(path: Zips.projectZip)))
        }
    }

    @Test func aCopyThatNoLongerHoldsEverythingLeavesItsZipAlone() async throws {
        try await withZips { folder, contents, log in
            let plan = try await plan(folder)
            // A file inside removed; the one-file copy put back moments ago, identical but new.
            try FileManager.default.removeItem(at: folder.appending(path: "\(Zips.project)/\(Zips.source)/\(Zips.main)"))
            let contract = folder.appending(path: Zips.contract)
            try FileManager.default.removeItem(at: contract)
            try Data(contents.contract.utf8).write(to: contract)

            let result = await execute(plan, recorder: log)
            defer { cleanUp(result, contents) }

            #expect(try outcome(Zips.projectZip, in: result) == .skipped(.unpackedCopyNotVerified(name: Zips.project)))
            // Put back moments ago, it may still be unpacking: the hour holds the zip back.
            #expect(try outcome(Zips.contractZip, in: result) == .skipped(.unpackedCopyRecentlyChanged(name: Zips.contract)))
            #expect(result.trashedCount == 0)
        }
    }

    @Test func openingTheCopyInFinderDoesNotHoldTheZipBack() async throws {
        try await withZips { folder, contents, log in
            let plan = try await plan(folder)
            // Finder writes a .DS_Store into a folder it shows, which moves the folder's own date.
            try Data("Bud1".utf8).write(to: folder.appending(path: "\(Zips.project)/.DS_Store"))

            let result = await execute(plan, recorder: log)
            defer { cleanUp(result, contents) }

            #expect(try outcome(Zips.projectZip, in: result).isTrashed)
            #expect(try outcome(Zips.contractZip, in: result).isTrashed)
        }
    }

    @Test func aCopyHiddenOrResizedAfterThePlanLeavesItsZipAlone() async throws {
        try await withZips { folder, contents, log in
            let plan = try await plan(folder)
            var project = folder.appending(path: Zips.project, directoryHint: .isDirectory)
            var hidden = URLResourceValues()
            hidden.isHidden = true
            try project.setResourceValues(hidden)
            let contract = folder.appending(path: Zips.contract)
            try Data((contents.contract + " amended").utf8).write(to: contract)
            try FileDates.set(contract, to: Date(timeIntervalSinceNow: -FileDates.settledAge))

            let result = await execute(plan, recorder: log)
            defer { cleanUp(result, contents) }

            #expect(try outcome(Zips.projectZip, in: result) == .skipped(.unpackedCopyNotVerified(name: Zips.project)))
            #expect(try outcome(Zips.contractZip, in: result) == .skipped(.unpackedCopyNotVerified(name: Zips.contract)))
        }
    }

    @Test func aCopyHiddenWhileTheRowIsWrittenIsCaughtByTheLastLook() async throws {
        try await withZips { folder, contents, log in
            let plan = try await plan(folder)
            let spy = SpyRecorder(forwardingTo: log) { intent in
                guard intent.change.record.displayName == Zips.projectZip else { return }
                var project = folder.appending(path: Zips.project, directoryHint: .isDirectory)
                var hidden = URLResourceValues()
                hidden.isHidden = true
                try? project.setResourceValues(hidden)
            }

            let result = await execute(plan, recorder: spy)
            defer { cleanUp(result, contents) }

            #expect(try outcome(Zips.projectZip, in: result) == .skipped(.unpackedCopyNotVerified(name: Zips.project)))
            #expect(try outcome(Zips.contractZip, in: result).isTrashed)
        }
    }

    @Test func aChangeWhileTheRowIsWrittenIsCaughtByTheLastLook() async throws {
        try await withZips { folder, contents, log in
            let plan = try await plan(folder)
            // Inside the started row's write: after the checks, before the last look.
            let spy = SpyRecorder(forwardingTo: log) { intent in
                switch intent.change.record.displayName {
                case Zips.contractZip:
                    // The copy, the only evidence, cut short.
                    try? Data("cut".utf8).write(to: folder.appending(path: Zips.contract))
                default:
                    // The zip itself, touched.
                    try? FileDates.set(folder.appending(path: Zips.projectZip), to: Date(timeIntervalSinceNow: -3 * 60 * 60))
                }
            }

            let result = await execute(plan, recorder: spy)
            defer { cleanUp(result, contents) }

            #expect(try outcome(Zips.contractZip, in: result) == .skipped(.unpackedCopyNotVerified(name: Zips.contract)))
            #expect(try outcome(Zips.projectZip, in: result) == .skipped(.changedSinceScan))
            #expect(result.trashedCount == 0)
            let runID = try #require(result.runID)
            #expect(try await log.changes(inRun: runID).map(\.outcome) == [
                .skipped(.unpackedCopyNotVerified(name: Zips.contract)),
                .skipped(.changedSinceScan),
            ])
        }
    }

    // MARK: - The zip changed after the plan

    @Test func aZipRemovedOrRewrittenIsLeftAlone() async throws {
        try await withZips { folder, contents, log in
            let plan = try await plan(folder)
            try FileManager.default.removeItem(at: folder.appending(path: Zips.contractZip))
            let projectZip = folder.appending(path: Zips.projectZip)
            try Data("a different archive".utf8).write(to: projectZip)
            try FileDates.set(projectZip, to: Date(timeIntervalSinceNow: -FileDates.settledAge))

            let result = await execute(plan, recorder: log)
            defer { cleanUp(result, contents) }

            #expect(try outcome(Zips.contractZip, in: result) == .skipped(.notFound))
            #expect(try outcome(Zips.projectZip, in: result) == .skipped(.changedSinceScan))
        }
    }

    @Test func aZipKeptAfterThePlanOrLockedStays() async throws {
        try await withZips { folder, contents, log in
            var projectZip = folder.appending(path: Zips.projectZip)
            try setLocked(&projectZip, true)
            defer { try? setLocked(&projectZip, false) }
            let plan = try await plan(folder)
            try await log.keep([try changeOf(Zips.contractZip, in: plan).record])

            let result = await execute(plan, recorder: log)
            defer { cleanUp(result, contents) }

            #expect(try outcome(Zips.contractZip, in: result) == .skipped(.markedKept))
            #expect(try outcome(Zips.projectZip, in: result) == .failed(.fileIsLocked))
            #expect(result.trashedCount == 0)
        }
    }

    @Test func aZipReplacedByALinkIsLeftAlone() async throws {
        try await withZips { folder, contents, log in
            let plan = try await plan(folder)
            let zip = folder.appending(path: Zips.contractZip)
            try FileManager.default.removeItem(at: zip)
            try FileManager.default.createSymbolicLink(at: zip, withDestinationURL: folder.appending(path: Zips.projectZip))

            let result = await execute(plan, recorder: log)
            defer { cleanUp(result, contents) }

            #expect(try outcome(Zips.contractZip, in: result) == .skipped(.notARegularFile))
            #expect(DiskState.isSymbolicLink(zip))
        }
    }

    // MARK: - Plans built elsewhere

    @Test func aPlanCannotTrashAnythingButAZipItProvesUnpacked() async throws {
        try await withZips { folder, contents, log in
            let records = try await RelocationPlans.records(in: folder)
            func record(_ name: String) throws -> FileRecord {
                try RelocationPlans.record(named: name, in: records)
            }
            func change(_ name: String, _ reason: ProposedChange.Reason) throws -> ProposedChange {
                ProposedChange(record: try record(name), operation: .moveToTrash, reason: reason)
            }
            let plan = CleanupPlan(
                action: .removeUnpackedZips,
                folder: log.downloads(at: folder),
                changes: [
                    // Not a zip, whatever the reason says.
                    try change(Zips.contract, .unpackedZip(unpackedTo: Zips.project)),
                    // A zip with another action's reason.
                    try change(Zips.projectZip, .sameContent(asFileNamed: Zips.contractZip)),
                    // Copies the zip's own listing does not lead to: another item, the zip itself, paths.
                    try change(Zips.contractZip, .unpackedZip(unpackedTo: Zips.project)),
                ]
            )
            let itself = CleanupPlan(
                action: .removeUnpackedZips,
                folder: log.downloads(at: folder),
                changes: [try change(Zips.contractZip, .unpackedZip(unpackedTo: Zips.contractZip))]
            )
            let path = CleanupPlan(
                action: .removeUnpackedZips,
                folder: log.downloads(at: folder),
                changes: [try change(Zips.projectZip, .unpackedZip(unpackedTo: "\(Zips.project)/\(Zips.source)"))]
            )
            // A `/` joined with a combining mark is one Swift character, and still a `/` to the system.
            let fusedSlash = CleanupPlan(
                action: .removeUnpackedZips,
                folder: log.downloads(at: folder),
                changes: [try change(Zips.projectZip, .unpackedZip(unpackedTo: "\(Zips.project)/\u{301}\(Zips.source)"))]
            )

            var results: [CleanupResult] = []
            for plan in [plan, itself, path, fusedSlash] {
                results.append(await execute(plan, recorder: log))
            }
            defer { results.forEach { cleanUp($0, contents) } }

            #expect(results.flatMap(\.items).map(\.outcome) == Array(repeating: .skipped(.notInPlan), count: 6))
            #expect(Set(DiskState.entryNames(in: folder)) == [Zips.project, Zips.projectZip, Zips.contract, Zips.contractZip])
        }
    }

    // MARK: - Undo

    @Test func undoingTheRunPutsBothBackFromTheRealTrash() async throws {
        try await withZips { folder, contents, log in
            let result = await execute(try await plan(folder), recorder: log)
            defer { cleanUp(result, contents) }
            #expect(result.trashedCount == 2)
            let runID = try #require(result.runID)

            let undo = try await UndoFixtures.undo(.run(runID), in: folder, trash: .system, log: log)

            #expect(Set(undo.undone.map(\.originalName)) == [Zips.projectZip, Zips.contractZip])
            #expect(undo.notUndone.isEmpty)
            #expect(undo.bytesTakenFromTrash == result.bytesFreed)
            for (name, data) in contents.zips {
                #expect((try? Data(contentsOf: folder.appending(path: name))) == data, "\(name)")
            }
            expectCopiesUntouched(in: folder, contents)
            #expect(try await log.changes(inRun: runID).allSatisfy { $0.undoneAt != nil })
            #expect(try await log.totals() == .zero)
            // Put back just now, they are inside the grace period again, and unpacked zips once it
            // has passed.
            #expect(try await plan(folder).isEmpty)
            let later = try await plan(folder, now: Date(timeIntervalSinceNow: 2 * 60 * 60))
            #expect(Zips.proposals(later) == ["\(Zips.contractZip) → \(Zips.contract)", "\(Zips.projectZip) → \(Zips.project)"])
        }
    }

    private func setLocked(_ url: inout URL, _ locked: Bool) throws {
        var values = URLResourceValues()
        values.isUserImmutable = locked
        try url.setResourceValues(values)
    }
}

private extension CleanupItemOutcome {
    var isTrashed: Bool {
        if case .trashed = self {
            return true
        }
        return false
    }
}
