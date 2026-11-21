import Darwin
import FileStoreCore
import Foundation
import Testing

/// Fix Messy Names on real folders: the plan the fake Downloads folder gives, the renames carried
/// out, a destination that appears in the meantime, the activity log and undo.
@Suite("Fix Messy Names on disk")
struct MessyNameDiskTests {
    private typealias Names = FakeDownloadsFolder.Names

    private func plan(_ records: [FileRecord], in folder: URL) async throws -> CleanupPlan {
        try #require(
            try await CleanupPlanners.plan(
                .fixMessyNames,
                records: records,
                in: .temporary(folder),
                eligibility: CandidateEligibility(),
                keptItems: KeptItems(),
                installers: .testing(applications: [])
            )
        )
    }

    private func renames(_ plan: CleanupPlan) -> [String: String] {
        var renames: [String: String] = [:]
        for change in plan.changes {
            if case .rename(to: let newName) = change.operation {
                renames[change.record.displayName] = newName
            }
        }
        return renames
    }

    /// `name` with the record's Date Added, as the planner writes it in this Mac's time zone.
    private func dated(_ stem: String, _ pathExtension: String, from record: FileRecord) throws -> String {
        let date = try #require(record.dateAdded)
        let style = Date.ISO8601FormatStyle(timeZone: .current).year().month().day().dateSeparator(.dash)
        return "\(stem) \(date.formatted(style))\(pathExtension)"
    }

    @Test func theFakeFolderGivesTheExpectedPlan() async throws {
        try await withFakeDownloadsFolder { fixture in
            let records = try await RelocationPlans.records(in: fixture.url)
            func record(_ name: String) throws -> FileRecord { try RelocationPlans.record(named: name, in: records) }

            let plan = try await plan(records, in: fixture.url)

            let expected = [
                Names.numberedName: "manual.pdf",
                Names.copyWordName: "budget.xlsx",
                Names.percentEncodedName: "file name with junk.txt",
                Names.queryLeftoverName: "brochure.pdf",
                Names.doubledExtensionName: "slides.pdf",
                Names.agendaNumbered: Names.agendaClean,
                Names.agendaCopyWord: try dated("agenda", ".docx", from: try record(Names.agendaCopyWord)),
                Names.invoiceCopy: try dated("invoice", ".pdf", from: try record(Names.invoiceCopy)),
                Names.notesEdited: try dated("notes", ".txt", from: try record(Names.notesEdited)),
            ]
            #expect(renames(plan) == expected)
            // The report copies and the receipt copy are duplicates of the file with their clean
            // name, which Find Duplicates handles.
            #expect(plan.skippedItems.isEmpty)
            let invoice = try #require(plan.changes.first { $0.record.displayName == Names.invoiceCopy })
            #expect(invoice.reason == .messyName(MessyNameFix(fixes: [.removedCopySuffix(" (1)")], takenName: Names.invoice)))
        }
    }

    @Test func renamingEverythingThenPlanningAgainProposesNothingAndUndoPutsEveryNameBack() async throws {
        try await withFakeDownloadsFolder { fixture in
            let trash = try FakeTrash.make()
            defer { trash.remove() }
            let log = try await ActivityLog.open(.inMemory)
            let before = DiskState.snapshot(of: fixture.url)
            let plan = try await plan(try await RelocationPlans.records(in: fixture.url), in: fixture.url)

            let result = await CleanupExecutor(recorder: log).execute(plan: plan, confirmedChangeIDs: Set(plan.changes.map(\.id)))

            #expect(result.renamed.count == plan.changes.count)
            #expect(result.leftAlone.isEmpty)
            let names = Set(DiskState.entryNames(in: fixture.url))
            for (_, newName) in renames(plan) {
                #expect(names.contains(newName), "\(newName) should exist")
            }
            // Idempotent: nothing is left to clean.
            let recordsAfter = try await RelocationPlans.records(in: fixture.url)
            let again = try await self.plan(recordsAfter, in: fixture.url)
            #expect(again.isEmpty, "\(renames(again))")

            // The log has every change, with enough to undo it.
            let runID = try #require(result.runID)
            let rows = try await log.changes(inRun: runID)
            #expect(rows.count == plan.changes.count)
            for change in plan.changes {
                let row = try #require(rows.first { $0.originalPath == change.originalPath })
                #expect(row.operation == .rename)
                #expect(row.outcome == .renamed)
                #expect(row.reason == change.reason)
                let resultingPath = try #require(row.resultingPath)
                let destinationPath = try #require(change.destinationPath)
                // The log spells the temporary folder /var, the plan /private/var: the same place.
                #expect(URL(filePath: resultingPath).resolvingSymlinksInPath() == URL(filePath: destinationPath).resolvingSymlinksInPath())
            }
            let runs = try await log.runs()
            #expect(runs.first?.action == .fixMessyNames)

            let undo = try await UndoFixtures.undo(.run(runID), in: fixture.url, trash: trash.locator, log: log)
            #expect(undo.undone.count == plan.changes.count)
            #expect(undo.notUndone.isEmpty)
            #expect(DiskState.snapshot(of: fixture.url) == before)
        }
    }

    @Test func aDestinationThatAppearsAfterThePlanIsNeverOverwrittenOrSwappedForAnotherName() async throws {
        let temp = try TemporaryFolder.make()
        defer { temp.remove() }
        try FileDates.writeSettled(["report (1).txt": "mine", "manual (2).txt": "manual"], in: temp.url)
        let log = try await ActivityLog.open(.inMemory)
        let plan = try await plan(try await RelocationPlans.records(in: temp.url), in: temp.url)
        #expect(renames(plan) == ["report (1).txt": "report.txt", "manual (2).txt": "manual.txt"])

        // One appears before the run starts, the other at the very last moment.
        try "early".write(to: temp.url.appending(path: "manual.txt"), atomically: false, encoding: .utf8)
        let lateURL = temp.url.appending(path: "report.txt")
        let result = await CleanupExecutor(recorder: log).execute(
            plan: plan,
            confirmedChangeIDs: Set(plan.changes.map(\.id)),
            beforeChange: { change in
                if change.record.displayName == "report (1).txt" {
                    try? "late".write(to: lateURL, atomically: false, encoding: .utf8)
                }
            }
        )

        #expect(try RelocationPlans.outcome(for: "report (1).txt", in: result) == .skipped(.destinationExists(name: "report.txt")))
        #expect(try RelocationPlans.outcome(for: "manual (2).txt", in: result) == .skipped(.destinationExists(name: "manual.txt")))
        #expect(Set(DiskState.entryNames(in: temp.url)) == ["report (1).txt", "report.txt", "manual (2).txt", "manual.txt"])
        #expect(DiskState.text(of: temp.url.appending(path: "report (1).txt")) == "mine")
        #expect(DiskState.text(of: lateURL) == "late")
        #expect(DiskState.text(of: temp.url.appending(path: "manual.txt")) == "early")
    }

    @Test func aCaseOnlyClashFollowsTheVolume() async throws {
        let temp = try TemporaryFolder.make()
        defer { temp.remove() }
        try FileDates.writeSettled(["report.txt": "the original", "Report (1).txt": "another"], in: temp.url)
        let records = try await RelocationPlans.records(in: temp.url)
        let plan = try await plan(records, in: temp.url)
        let caseSensitive = pathconf(temp.url.path(percentEncoded: false), _PC_CASE_SENSITIVE) == 1
        let copy = try RelocationPlans.record(named: "Report (1).txt", in: records)
        let expected = caseSensitive ? "Report.txt" : try dated("Report", ".txt", from: copy)
        #expect(renames(plan) == ["Report (1).txt": expected])
    }

    @Test func aCopyWithIdenticalContentIsLeftToFindDuplicatesOnDisk() async throws {
        let temp = try TemporaryFolder.make()
        defer { temp.remove() }
        // Same size, different bytes for the notes; same bytes for the receipt.
        try FileDates.writeSettled(
            ["receipt.pdf": "same", "receipt (1).pdf": "same", "notes.txt": "abcd", "notes (1).txt": "wxyz"],
            in: temp.url
        )
        let records = try await RelocationPlans.records(in: temp.url)
        let notes = try RelocationPlans.record(named: "notes (1).txt", in: records)
        let expected = ["notes (1).txt": try dated("notes", ".txt", from: notes)]
        let plan = try await plan(records, in: temp.url)
        #expect(renames(plan) == expected)
    }
}
