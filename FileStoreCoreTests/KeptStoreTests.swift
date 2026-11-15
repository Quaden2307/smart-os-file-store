import FileStoreCore
import Foundation
import Testing

/// The Kept list in the activity log, against real files in a temporary folder: it follows a file
/// through renames and moves, never passes to a different file, and forgets a file that is gone.
@Suite("Kept list in the activity log")
struct KeptStoreTests {
    private func write(_ name: String, _ text: String = "contents", in folder: URL) throws {
        try Data(text.utf8).write(to: folder.appending(path: name))
    }

    private func scan(_ folder: URL) async throws -> [FileRecord] {
        try await RelocationPlans.records(in: folder)
    }

    private func record(_ name: String, in folder: URL) async throws -> FileRecord {
        try RelocationPlans.record(named: name, in: try await scan(folder))
    }

    @Test func keepStopKeepingAndStopKeepingAll() async throws {
        let temp = try TemporaryFolder.make()
        defer { temp.remove() }
        try write("a.txt", in: temp.url)
        try write("b.txt", in: temp.url)
        try FileManager.default.createDirectory(at: temp.url.appending(path: "Folder"), withIntermediateDirectories: false)
        let records = try await scan(temp.url)
        let a = try RelocationPlans.record(named: "a.txt", in: records)
        let b = try RelocationPlans.record(named: "b.txt", in: records)
        let folder = try RelocationPlans.record(named: "Folder", in: records)
        let log = try await ActivityLog.open(.inMemory)

        try await log.keep([a, folder])
        // Keeping again changes nothing.
        try await log.keep([a])
        var list = try await log.keptItems(forFolder: temp.url)
        #expect(list.count == 2)
        #expect(list.contains(a))
        #expect(list.contains(folder))
        #expect(!list.contains(b))
        #expect(try await log.isKept(a))
        #expect(try await !log.isKept(b))
        #expect(list.items.allSatisfy { $0.identity != nil })

        try await log.stopKeeping([a])
        list = try await log.keptItems(forFolder: temp.url)
        #expect(!list.contains(a))
        #expect(list.contains(folder))

        try await log.keep([a, b])
        try await log.stopKeepingAll()
        #expect(try await log.keptItems(forFolder: temp.url).isEmpty)
    }

    @Test func keptSurvivesARenameAndFindDuplicatesStillKeepsIt() async throws {
        let temp = try TemporaryFolder.make()
        defer { temp.remove() }
        try FileDates.writeSettled(["report.pdf": "quarterly report body", "report (1).pdf": "quarterly report body"], in: temp.url)
        let log = try await ActivityLog.open(.inMemory)
        try await log.keep([try await record("report (1).pdf", in: temp.url)])

        try FileManager.default.moveItem(at: temp.url.appending(path: "report (1).pdf"), to: temp.url.appending(path: "renamed.pdf"))
        let records = try await scan(temp.url)
        let list = try await log.keptItems(forFolder: temp.url)
        let renamed = try RelocationPlans.record(named: "renamed.pdf", in: records)
        #expect(list.contains(renamed))
        #expect(!list.contains(try RelocationPlans.record(named: "report.pdf", in: records)))

        let plan = try #require(
            try await CleanupPlanners.plan(.findDuplicates, records: records, in: temp.url, eligibility: CandidateEligibility(), keptItems: list)
        )
        #expect(try #require(plan.duplicateGroups.first).kept.id == renamed.id)
        #expect(plan.changes.map(\.record.displayName) == ["report.pdf"])
    }

    @Test func aNewFileWithTheOldNameIsNotKept() async throws {
        let temp = try TemporaryFolder.make()
        defer { temp.remove() }
        try write("a.txt", "the kept one", in: temp.url)
        let log = try await ActivityLog.open(.inMemory)
        try await log.keep([try await record("a.txt", in: temp.url)])

        try FileManager.default.moveItem(at: temp.url.appending(path: "a.txt"), to: temp.url.appending(path: "b.txt"))
        try write("a.txt", "a different file", in: temp.url)
        let records = try await scan(temp.url)
        let list = try await log.keptItems(forFolder: temp.url)

        #expect(!list.contains(try RelocationPlans.record(named: "a.txt", in: records)))
        #expect(list.contains(try RelocationPlans.record(named: "b.txt", in: records)))
    }

    @Test func keepMarksTheFileAtThePlaceNowWhenItWasSavedAsANewCopySinceTheScan() async throws {
        let temp = try TemporaryFolder.make()
        defer { temp.remove() }
        try write("notes.txt", "first draft", in: temp.url)
        let scanned = try await record("notes.txt", in: temp.url)
        // Saved the way most document apps save: a new file swapped in, with a new number.
        try Data("second draft".utf8).write(to: temp.url.appending(path: "notes.txt"), options: .atomic)
        let log = try await ActivityLog.open(.inMemory)

        try await log.keep([scanned])

        let list = try await log.keptItems(forFolder: temp.url)
        #expect(list.count == 1)
        #expect(list.contains(try await record("notes.txt", in: temp.url)))
    }

    @Test func aFileMovedIntoASubfolderAndBackStaysKept() async throws {
        let temp = try TemporaryFolder.make()
        defer { temp.remove() }
        try write("a.txt", in: temp.url)
        let subfolder = temp.url.appending(path: "Sub", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: subfolder, withIntermediateDirectories: false)
        let log = try await ActivityLog.open(.inMemory)
        try await log.keep([try await record("a.txt", in: temp.url)])

        try FileManager.default.moveItem(at: temp.url.appending(path: "a.txt"), to: subfolder.appending(path: "a.txt"))
        // Out of the listing, but still on the disk: the entry stays.
        #expect(try await log.keptItems(forFolder: temp.url).count == 1)

        try FileManager.default.moveItem(at: subfolder.appending(path: "a.txt"), to: temp.url.appending(path: "a.txt"))
        #expect(try await log.keptItems(forFolder: temp.url).contains(try await record("a.txt", in: temp.url)))
    }

    @Test func theEntryOfAFileThatIsGoneIsDropped() async throws {
        let temp = try TemporaryFolder.make()
        defer { temp.remove() }
        try write("a.txt", in: temp.url)
        try write("b.txt", in: temp.url)
        let records = try await scan(temp.url)
        let log = try await ActivityLog.open(.inMemory)
        try await log.keep(records)

        try FileManager.default.removeItem(at: temp.url.appending(path: "a.txt"))
        let list = try await log.keptItems(forFolder: temp.url)

        #expect(list.count == 1)
        #expect(list.contains(try RelocationPlans.record(named: "b.txt", in: records)))
        // Gone from the database too, not only from this answer.
        #expect(try log.currentKeptItems().count == 1)
    }

    @Test func entriesWithoutAnIdentityAreDroppedOnlyInsideAFolderThatCanBeReached() async throws {
        let temp = try TemporaryFolder.make()
        defer { temp.remove() }
        let folder = temp.url.appending(path: "Folder", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: false)
        // As a volume without lasting file numbers would give them: no identity, only a path. Keep
        // reads the identity again from disk, so the files are made only once they are marked.
        func pathOnly(_ url: URL) -> FileRecord {
            FileRecord(
                url: url,
                displayName: url.lastPathComponent,
                kind: .file,
                localizedTypeDescription: nil,
                contentType: nil,
                sizeInBytes: 8,
                dateAdded: nil,
                dateModified: nil,
                isDownloading: false
            )
        }
        let present = pathOnly(folder.appending(path: "here.txt"))
        let gone = pathOnly(folder.appending(path: "gone.txt"))
        let elsewhere = pathOnly(temp.url.appending(path: "Elsewhere/gone.txt"))
        let log = try await ActivityLog.open(.inMemory)
        try await log.keep([present, gone, elsewhere])
        #expect(try log.currentKeptItems().items.allSatisfy { $0.identity == nil })
        try write("here.txt", in: folder)

        // While the folder cannot be reached (its disk unplugged, say), nothing is dropped.
        #expect(try await log.keptItems(forFolder: temp.url.appending(path: "Unplugged")).count == 3)

        let list = try await log.keptItems(forFolder: folder)
        #expect(list.contains(present))
        #expect(!list.contains(gone))
        // Outside the folder, nothing is looked at.
        #expect(list.contains(elsewhere))
    }

    @Test func eachDebugOverrideHasItsOwnKeptList() async throws {
        try await withLogSandbox { sandbox in
            let temp = try TemporaryFolder.make()
            defer { temp.remove() }
            try write("a.txt", in: temp.url)
            let a = try await record("a.txt", in: temp.url)

            let real = try await ActivityLog.open(try sandbox.realLocation())
            let first = try await ActivityLog.open(try sandbox.overrideLocation(scanning: sandbox.folder.url.appending(path: "Fake-1")))
            let second = try await ActivityLog.open(try sandbox.overrideLocation(scanning: sandbox.folder.url.appending(path: "Fake-2")))

            try await first.keep([a])

            #expect(try await first.isKept(a))
            #expect(try await !real.isKept(a))
            #expect(try await !second.isKept(a))
            try await real.close()
            try await second.close()

            // The override finds its own list again on the next launch.
            let firstLocation = first.location
            try await first.close()
            let reopened = try await ActivityLog.open(firstLocation)
            #expect(try await reopened.isKept(a))
            try await reopened.close()
        }
    }

    @Test func aLogFromBeforeKeptGainsTheTableAndKeepsItsRows() async throws {
        try await withLogSandbox { sandbox in
            let location = try sandbox.realLocation()
            let databaseURL = try #require(location.databaseURL)
            let log = try await ActivityLog.open(location)
            try LogSamples.writeRun(to: log, startedAt: .now, count: 2)
            try await log.close()
            // What the version before Kept left: no `keptItems`, no `changes.isFolder`, and
            // migrations up to `v2`.
            do {
                let raw = try RawDatabase(databaseURL)
                try raw.execute("DROP TABLE keptItems")
                try raw.execute("ALTER TABLE changes DROP COLUMN isFolder")
                try raw.execute("DELETE FROM grdb_migrations WHERE identifier IN ('v3', 'v4')")
            }

            let upgraded = try await ActivityLog.open(location)
            #expect(try await upgraded.runs().count == 1)
            #expect(try upgraded.currentKeptItems().isEmpty)
            try await upgraded.close()

            let raw = try RawDatabase(databaseURL)
            #expect(try raw.text("SELECT group_concat(identifier, ',') FROM grdb_migrations") == "v1,v2,v3,v4")
            #expect(try raw.text("SELECT count(*) FROM changes") == "2")
        }
    }
}
