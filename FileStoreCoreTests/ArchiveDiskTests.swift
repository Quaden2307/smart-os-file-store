import Darwin
import FileStoreCore
import Foundation
import Testing

/// Archive Old Downloads on real folders: what the fake Downloads folder gives, the archive folder
/// made once, metadata kept through the move and back, an archive that is not a folder, identical
/// and different files already archived, idempotence, the log and undo. Files trashed because the
/// archive has a copy go through the real Trash; `TrashedFiles` removes the test's own afterwards.
@Suite("Archive Old Downloads on disk")
struct ArchiveDiskTests {
    private typealias Names = FakeDownloadsFolder.Names

    /// A date well past every threshold: 2025-01-01 09:00 UTC.
    private static let oldDate = Date(timeIntervalSince1970: 1_735_722_000)

    private func plan(_ folder: URL) async throws -> CleanupPlan {
        try #require(
            try await CleanupPlanners.plan(
                .archiveOldDownloads,
                records: try await RelocationPlans.records(in: folder),
                in: folder,
                eligibility: CandidateEligibility(),
                keptItems: KeptItems(),
                installers: .testing(applications: [])
            )
        )
    }

    private func executeAll(_ plan: CleanupPlan, log: ActivityLog) async -> CleanupResult {
        await CleanupExecutor(recorder: log).execute(plan: plan, confirmedChangeIDs: Set(plan.changes.map(\.id)))
    }

    /// Writes `files` and dates them back to `oldDate`, never opened.
    private func writeOld(_ files: [String: String], in folder: URL) throws {
        for (name, text) in files.sorted(by: { $0.key < $1.key }) {
            let url = folder.appending(path: name)
            try Data(text.utf8).write(to: url)
            try FileDates.set(url, to: Self.oldDate)
        }
    }

    /// What a move must keep: the dates, the last-opened date, where it came from.
    private struct Metadata: Equatable {
        let dateAdded: Date?
        let dateModified: Date?
        let lastOpened: Date?
        let whereFroms: [String]?
        let quarantine: String?
        let inode: UInt64?

        init(_ url: URL) {
            // A fresh URL each time, so no resource value comes from a cache.
            let values = try? URL(filePath: url.path(percentEncoded: false)).resourceValues(forKeys: [.addedToDirectoryDateKey, .contentModificationDateKey])
            dateAdded = values?.addedToDirectoryDate
            dateModified = values?.contentModificationDate
            lastOpened = ExtendedAttributes.lastUsedDate(of: url)
            whereFroms = ExtendedAttributes.whereFroms(of: url)
            quarantine = ExtendedAttributes.quarantine(of: url)
            inode = DiskState.inode(of: url)
        }
    }

    // MARK: - The plan

    @Test func theFakeFoldersOldFilesAreProposedAndTheFreshOnesAreNot() async throws {
        try await withFakeDownloadsFolder { fixture in
            let plan = try await plan(fixture.url)
            let archive = ArchivePlanner.archiveURL(in: fixture.url)
            #expect(plan.changes.map(\.record.displayName) == [Names.oldManual, Names.oldReceipt])
            #expect(plan.changes.map(\.operation) == [.move(to: archive, name: Names.oldManual), .move(to: archive, name: Names.oldReceipt)])
            #expect(plan.changes.map(\.reason) == [
                .neverOpened(downloadedOn: FakeDownloadsFolder.oldManualDate),
                .notOpenedSince(FakeDownloadsFolder.oldReceiptLastOpened),
            ])
            // Old but opened yesterday: not unused.
            #expect(!plan.changes.contains { $0.record.displayName == Names.taxForm })
            #expect(plan.archiveProblem == nil)
            #expect(plan.skippedItems.isEmpty)
        }
    }

    // MARK: - Moving, the log, idempotence and undo

    @Test func archivingMakesTheFolderOnceKeepsMetadataAndUndoPutsEverythingBack() async throws {
        try await withTemporaryFolderAsync { folder in
            let files = ["a.pdf": "first", "b.pdf": "second"]
            try writeOld(files, in: folder)
            let a = folder.appending(path: "a.pdf")
            try ExtendedAttributes.setLastUsedDate(Self.oldDate.addingTimeInterval(86_400), on: a)
            try ExtendedAttributes.setWhereFroms(["https://example.com/a.pdf"], on: a)
            try ExtendedAttributes.setQuarantine(ExtendedAttributes.quarantineValue(app: "Safari", downloadedAt: Self.oldDate), on: a)
            let before = Dictionary(uniqueKeysWithValues: files.keys.map { ($0, Metadata(folder.appending(path: $0))) })
            let log = try await ActivityLog.open(.inMemory)
            let archive = ArchivePlanner.archiveURL(in: folder)

            let result = await executeAll(try await plan(folder), log: log)

            #expect(result.moved.count == 2)
            #expect(result.trashedCount == 0)
            #expect(result.items.flatMap(\.createdFolders).map(\.lastPathComponent) == [CandidateEligibility.archiveFolderName])
            #expect(DiskState.entryNames(in: folder) == [CandidateEligibility.archiveFolderName])
            #expect(Set(DiskState.entryNames(in: archive)) == Set(files.keys))
            for name in files.keys {
                #expect(Metadata(archive.appending(path: name)) == before[name], "\(name)")
            }

            // The log: the run, one moved row per file with its reason and where it went.
            let runID = try #require(result.runID)
            #expect(try await log.run(id: runID)?.action == .archiveOldDownloads)
            let rows = try await log.changes(inRun: runID)
            #expect(rows.map(\.outcome) == [.moved, .moved])
            #expect(rows.map(\.operation) == [.move, .move])
            #expect(rows.first?.reason == .notOpenedSince(Self.oldDate.addingTimeInterval(86_400)))
            #expect(rows.last?.reason == .neverOpened(downloadedOn: Self.oldDate))
            #expect(rows.map { $0.resultingPath.map { URL(filePath: $0).lastPathComponent } } == ["a.pdf", "b.pdf"])
            #expect(rows.first?.createdFolders.count == 1)
            #expect(try await log.totals().bytesMovedToTrash == 0)

            // Idempotent: the archived files are not proposed again, by this or any other action.
            #expect(try await plan(folder).isEmpty)
            let records = try await RelocationPlans.records(in: folder)
            for action in CleanupAction.allCases where CleanupPlanners.hasPlanner(action) {
                let other = try #require(
                    try await CleanupPlanners.plan(action, records: records, in: folder, eligibility: CandidateEligibility(), keptItems: KeptItems(), installers: .testing(applications: []))
                )
                #expect(other.isEmpty, "\(action)")
                #expect(other.skippedItems.isEmpty, "\(action)")
            }

            // Undo: every file back as it was, the empty archive folder left in place.
            let undo = try await UndoFixtures.undo(.run(runID), in: folder, trash: .system, log: log)
            #expect(Set(undo.undone.map(\.originalName)) == Set(files.keys))
            #expect(undo.notUndone.isEmpty)
            #expect(Set(DiskState.entryNames(in: folder)) == Set(files.keys).union([CandidateEligibility.archiveFolderName]))
            #expect(DiskState.entryNames(in: archive).isEmpty)
            for name in files.keys {
                #expect(Metadata(folder.appending(path: name)) == before[name], "\(name)")
            }
            #expect(try await log.changes(inRun: runID).allSatisfy { $0.undoneAt != nil })
            // Back where they were and as old as they were: proposed again.
            #expect(try await plan(folder).changes.count == 2)
        }
    }

    @Test func anExistingArchiveFolderIsUsedAndNoFolderIsMade() async throws {
        try await withTemporaryFolderAsync { folder in
            try writeOld(["a.pdf": "first"], in: folder)
            let archive = ArchivePlanner.archiveURL(in: folder)
            try FileManager.default.createDirectory(at: archive, withIntermediateDirectories: false)
            let log = try await ActivityLog.open(.inMemory)
            let result = await executeAll(try await plan(folder), log: log)
            #expect(result.moved.count == 1)
            #expect(result.items.flatMap(\.createdFolders).isEmpty)
            #expect(DiskState.entryNames(in: archive) == ["a.pdf"])
        }
    }

    // MARK: - Names taken in the archive

    @Test func aDifferentFileWithTheNameGetsTheDateAndAnIdenticalOneSendsThisCopyToTheTrash() async throws {
        try await withTemporaryFolderAsync { folder in
            let files = ["manual.pdf": "the manual", "report.pdf": "this year's report"]
            try writeOld(files, in: folder)
            let archive = ArchivePlanner.archiveURL(in: folder)
            try FileManager.default.createDirectory(at: archive, withIntermediateDirectories: false)
            try Data("the manual".utf8).write(to: archive.appending(path: "manual.pdf"))
            try Data("last year's report".utf8).write(to: archive.appending(path: "Report.pdf"))
            let log = try await ActivityLog.open(.inMemory)
            let utc = TimeZone(identifier: "UTC") ?? .gmt

            let plan = try await ArchivePlanner().plan(records: try await RelocationPlans.records(in: folder), in: folder, timeZone: utc)
            #expect(plan.changes.map(\.operation) == [.moveToTrash, .move(to: archive, name: "report 2025-01-01.pdf")])
            #expect(plan.changes.first?.reason == .alreadyArchived(copyNamed: "manual.pdf"))

            let result = await executeAll(plan, log: log)
            defer { TrashedFiles.remove(result) { files[$0.lastPathComponent].map { Data($0.utf8) } } }
            #expect(result.trashedCount == 1)
            #expect(result.moved.count == 1)
            #expect(DiskState.entryNames(in: folder) == [CandidateEligibility.archiveFolderName])
            #expect(Set(DiskState.entryNames(in: archive)) == ["manual.pdf", "Report.pdf", "report 2025-01-01.pdf"])
            #expect(DiskState.text(of: archive.appending(path: "manual.pdf")) == "the manual")
            let runID = try #require(result.runID)
            let trashed = try await UndoFixtures.change(named: "manual.pdf", inRun: runID, log: log)
            #expect(trashed.outcome == .trashed)
            #expect(trashed.contentHash != nil)

            // Undo puts the trashed copy back as well as the moved file.
            let undo = try await UndoFixtures.undo(.run(runID), in: folder, trash: .system, log: log)
            #expect(Set(undo.undone.map(\.originalName)) == Set(files.keys))
            #expect(DiskState.text(of: folder.appending(path: "manual.pdf")) == "the manual")
            #expect(DiskState.text(of: folder.appending(path: "report.pdf")) == "this year's report")
        }
    }

    /// A plan that names a copy in the archive is carried out only while the copy is there, identical.
    @Test func aChangedOrMissingArchivedCopyLeavesTheFileAlone() async throws {
        try await withTemporaryFolderAsync { folder in
            try writeOld(["manual.pdf": "the manual", "guide.pdf": "the guide"], in: folder)
            let archive = ArchivePlanner.archiveURL(in: folder)
            try FileManager.default.createDirectory(at: archive, withIntermediateDirectories: false)
            try Data("the manual".utf8).write(to: archive.appending(path: "manual.pdf"))
            try Data("the guide".utf8).write(to: archive.appending(path: "guide.pdf"))
            let plan = try await plan(folder)
            #expect(plan.changes.allSatisfy { $0.operation == .moveToTrash })

            // Same size, other bytes; and gone.
            try Data("THE MANUAL".utf8).write(to: archive.appending(path: "manual.pdf"))
            try FileManager.default.removeItem(at: archive.appending(path: "guide.pdf"))
            let before = DiskState.snapshot(of: folder)
            let result = await executeAll(plan, log: try await ActivityLog.open(.inMemory))
            #expect(try RelocationPlans.outcome(for: "manual.pdf", in: result) == .skipped(.archivedCopyNotVerified(name: "manual.pdf")))
            #expect(try RelocationPlans.outcome(for: "guide.pdf", in: result) == .skipped(.archivedCopyMissing(name: "guide.pdf")))
            #expect(DiskState.snapshot(of: folder) == before)

            // A Trash change of this action without an archived copy named is not in any plan.
            let crafted = CleanupPlan(
                action: .archiveOldDownloads,
                folderURL: folder,
                changes: [ProposedChange(record: try #require(plan.changes.first?.record), operation: .moveToTrash, reason: RelocationPlans.archiveReason)]
            )
            let craftedResult = await executeAll(crafted, log: try await ActivityLog.open(.inMemory))
            #expect(craftedResult.items.map(\.outcome) == [.skipped(.notInPlan)])
        }
    }

    // MARK: - An archive that is not a folder

    @Test(arguments: [false, true])
    func anArchiveNameThatIsNotAFolderStopsTheAction(isLink: Bool) async throws {
        try await withTemporaryFolderAsync { folder in
            try writeOld(["a.pdf": "first"], in: folder)
            let archive = ArchivePlanner.archiveURL(in: folder)
            let elsewhere = try TemporaryFolder.make()
            defer { elsewhere.remove() }
            if isLink {
                try FileManager.default.createSymbolicLink(at: archive, withDestinationURL: elsewhere.url)
            } else {
                try Data("not a folder".utf8).write(to: archive)
            }
            let before = DiskState.snapshot(of: folder)

            let plan = try await plan(folder)
            #expect(plan.isEmpty)
            #expect(plan.archiveProblem == (isLink ? .symbolicLink : .notAFolder))
            #expect(DiskState.snapshot(of: folder) == before)
            #expect(DiskState.entryNames(in: elsewhere.url).isEmpty)
        }
    }

    /// The archive became a file or a link after the plan was made: each move is refused before
    /// anything changes.
    @Test(arguments: [false, true])
    func anArchiveThatStopsBeingAFolderAfterPlanningChangesNothing(isLink: Bool) async throws {
        try await withTemporaryFolderAsync { folder in
            try writeOld(["a.pdf": "first", "b.pdf": "second"], in: folder)
            let plan = try await plan(folder)
            #expect(plan.changes.count == 2)
            let archive = ArchivePlanner.archiveURL(in: folder)
            let elsewhere = try TemporaryFolder.make()
            defer { elsewhere.remove() }
            if isLink {
                try FileManager.default.createSymbolicLink(at: archive, withDestinationURL: elsewhere.url)
            } else {
                try Data("not a folder".utf8).write(to: archive)
            }
            let before = DiskState.snapshot(of: folder)

            let result = await executeAll(plan, log: try await ActivityLog.open(.inMemory))
            let expected: CleanupItemOutcome = .skipped(isLink ? .destinationOutsideFolder : .destinationNotAFolder)
            #expect(result.items.map(\.outcome) == [expected, expected])
            #expect(DiskState.snapshot(of: folder) == before)
            #expect(DiskState.entryNames(in: elsewhere.url).isEmpty)
        }
    }
}

/// The archive folder and everything in it, out of bounds for the scanner, the shared rules and
/// every planner, even when its contents are handed to a planner as records.
@Suite("The archive is out of bounds")
struct ArchiveOutOfBoundsTests {
    private static func isInArchive(_ url: URL) -> Bool {
        let name = CandidateEligibility.archiveFolderName
        return url.lastPathComponent == name || url.deletingLastPathComponent().lastPathComponent == name
    }

    @Test func theScannerListsTheArchiveAsAFolderAndNothingInIt() async throws {
        try await withFakeDownloadsFolder { fixture in
            let records = try await RelocationPlans.records(in: fixture.url)
            let archive = try RelocationPlans.record(named: CandidateEligibility.archiveFolderName, in: records)
            #expect(archive.kind == .folder)
            #expect(!records.contains { $0.url.deletingLastPathComponent().lastPathComponent == CandidateEligibility.archiveFolderName })
            #expect(CandidateEligibility().refusal(for: archive, now: .now) == .excludedName)
            #expect(FileMarker.marks(for: archive, now: .now, settings: CleanupSettings()).isEmpty)
        }
    }

    /// The archive holds a copy of every item at the top of the fake folder, dated old enough for
    /// every action, and the planner is given their records too. It names none of them.
    @Test(arguments: PlannersRespectKeptTests.plannedActions)
    func noPlannerNamesTheArchiveOrAnythingInIt(action: CleanupAction) async throws {
        try await withFakeDownloadsFolder { fixture in
            let archive = ArchivePlanner.archiveURL(in: fixture.url)
            var copies: [URL] = []
            for record in try await RelocationPlans.records(in: fixture.url)
            where record.kind != .symlink && record.displayName != CandidateEligibility.archiveFolderName {
                let copy = archive.appending(path: record.displayName)
                guard !FileManager.default.fileExists(atPath: copy.path(percentEncoded: false)) else { continue }
                // A file's bytes only, so no lock flag comes along; a folder as it is.
                if record.kind == .file {
                    try Data(contentsOf: record.url).write(to: copy)
                } else {
                    try FileManager.default.copyItem(at: record.url, to: copy)
                }
                copies.append(copy)
            }
            try FileDates.settle(copies, base: Date(timeIntervalSince1970: 1_735_722_000))
            let records = try await RelocationPlans.records(in: fixture.url) + (try await RelocationPlans.records(in: archive))

            let plan = try #require(
                try await CleanupPlanners.plan(action, records: records, in: fixture.url, eligibility: CandidateEligibility(), keptItems: KeptItems(), installers: .testing(applications: [fixture.applicationsURL]))
            )
            let named = plan.changes.map(\.id) + plan.skippedItems.map(\.url)
                + plan.duplicateGroups.flatMap { [$0.kept.url] + $0.duplicates.map(\.url) }
                + plan.nearDuplicateGroups.flatMap { $0.members.flatMap { [$0.record.url] + $0.identicalCopies.map(\.url) } }
            #expect(!named.isEmpty, "the planner proposed nothing, so this test proves nothing")
            #expect(named.filter(Self.isInArchive).isEmpty, "\(named.filter(Self.isInArchive))")
        }
    }
}
