import FileStoreCore
import Foundation
import Testing

/// The activity log's database: made on first use with its tables and owner-only permissions,
/// opened again without losing anything, set up to hand each row to the disk, and refused when a
/// newer version of the app wrote it or when it cannot be written.
@Suite("Activity log schema")
struct ActivityLogSchemaTests {
    private let now = Date(timeIntervalSince1970: 1_800_000_000)

    @Test func aNewLogIsMadeFromAnEmptyFileWithItsTablesAndZeroTotals() async throws {
        try await withLogSandbox { sandbox in
            let location = try sandbox.realLocation()
            let databaseURL = try #require(location.databaseURL)
            #expect(location.kind == .applicationSupport)
            #expect(FileFacts.permissions(of: databaseURL) == nil)

            let log = try await ActivityLog.open(location, now: now)

            #expect(try await log.runs().isEmpty)
            #expect(try await log.totals() == .zero)
            #expect(FileFacts.size(of: databaseURL) > 0)
            #expect(databaseURL.lastPathComponent == "FileStore.sqlite")
            #expect(canonicalPath(databaseURL.deletingLastPathComponent()).hasSuffix("/Application Support/" + LogSandbox.appIdentifier))

            // The migrations made exactly the seven tables, with one totals row, one maintenance row
            // and one folder: Downloads.
            try await log.close()
            let raw = try RawDatabase(databaseURL)
            let tables = try raw.text(
                "SELECT group_concat(name, ',') FROM (SELECT name FROM sqlite_master WHERE type = 'table' AND name NOT LIKE 'sqlite_%' AND name NOT LIKE 'grdb_%' ORDER BY name)"
            )
            #expect(tables == "changes,dailyTotals,folders,installerFacts,keptItems,maintenance,runs,totals")
            #expect(try raw.text("SELECT group_concat(kind, ',') FROM folders") == "downloads")
            #expect(try raw.text("SELECT count(*) FROM installerFacts") == "0")
            #expect(try raw.text("SELECT count(*) FROM keptItems") == "0")
            #expect(try raw.text("SELECT count(*) FROM totals") == "1")
            #expect(try raw.text("SELECT count(*) FROM maintenance") == "1")
            #expect(try raw.text("SELECT group_concat(identifier, ',') FROM grdb_migrations") == "v1,v2,v3,v4,v5,v6,v7,v8,v9")
        }
    }

    @Test func openingAgainKeepsEveryRowAndAppliesNothingTwice() async throws {
        try await withLogSandbox { sandbox in
            let location = try sandbox.realLocation()
            let first = try await ActivityLog.open(location, now: now)
            let runID = try LogSamples.writeRun(to: first, startedAt: now, count: 3, size: 500)
            try await first.close()

            let second = try await ActivityLog.open(location, now: now.addingTimeInterval(60))

            let runs = try await second.runs()
            #expect(runs.map(\.id) == [runID])
            #expect(runs.first?.state == .finished)
            #expect(runs.first?.doneCount == 3)
            #expect(try await second.changes(inRun: runID).count == 3)
            #expect(try await second.totals() == ActivityTotals(bytesMovedToTrash: 1_500, filesCleaned: 3))
        }
    }

    @Test func aLogFromBeforeChatCleanupsGainsTheOriginAndReadsItsRunsAsTheApps() async throws {
        try await withLogSandbox { sandbox in
            let location = try sandbox.realLocation()
            let databaseURL = try #require(location.databaseURL)
            // What the version before chat cleanups left: no `runs.origin`, and migrations up to `v5`.
            let runID = try LegacyLog.make(at: location, version: 5, startedAt: now)

            let upgraded = try await ActivityLog.open(location, now: now)
            #expect(try await upgraded.run(id: runID)?.origin == .app)
            #expect(try await upgraded.changes(inRun: runID).count == 2)
            try await upgraded.close()

            let raw = try RawDatabase(databaseURL)
            #expect(try raw.text("SELECT group_concat(identifier, ',') FROM grdb_migrations") == "v1,v2,v3,v4,v5,v6,v7,v8,v9")
            #expect(try raw.text("SELECT count(*) FROM runs WHERE origin IS NULL") == "1")
        }
    }

    @Test func aLogFromBeforeFoldersGainsTheColumnAndReadsItsRowsAsFiles() async throws {
        try await withLogSandbox { sandbox in
            let location = try sandbox.realLocation()
            let databaseURL = try #require(location.databaseURL)
            // What the version before segment 7 left: no `changes.isFolder`, no `installerFacts`, and
            // migrations up to `v3`.
            let runID = try LegacyLog.make(at: location, version: 3, startedAt: now)

            let upgraded = try await ActivityLog.open(location, now: now)
            let changes = try await upgraded.changes(inRun: runID)
            #expect(changes.count == 2)
            #expect(changes.allSatisfy { !$0.isFolder && !$0.undoEvidence.isFolder })
            try await upgraded.close()

            let raw = try RawDatabase(databaseURL)
            #expect(try raw.text("SELECT group_concat(identifier, ',') FROM grdb_migrations") == "v1,v2,v3,v4,v5,v6,v7,v8,v9")
            #expect(try raw.text("SELECT count(*) FROM changes WHERE isFolder = 0") == "2")
            // Only 0 and 1 are a value it may hold.
            #expect(throws: (any Error).self) {
                try raw.execute("UPDATE changes SET isFolder = 2")
            }
        }
    }

    @Test func theFolderAndEveryFileAreOpenToTheirOwnerOnly() async throws {
        try await withLogSandbox { sandbox in
            let location = try sandbox.realLocation()
            let databaseURL = try #require(location.databaseURL)
            let log = try await ActivityLog.open(location, now: now)
            // A row in flight, so the write-ahead file and its index exist.
            _ = try log.beginRun(
                CleanupRunStart(action: .findDuplicates, folder: log.downloads(at: LogSamples.folderURL), confirmedCount: 1, startedAt: now)
            )

            let path = databaseURL.path(percentEncoded: false)
            #expect(FileFacts.permissions(of: databaseURL.deletingLastPathComponent()) == 0o700)
            #expect(FileFacts.permissions(of: databaseURL) == 0o600)
            #expect(FileFacts.permissions(of: URL(filePath: path + "-wal")) == 0o600)
            #expect(FileFacts.permissions(of: URL(filePath: path + "-shm")) == 0o600)
        }
    }

    @Test func aLogInAFileHandsEachRowToTheDisk() async throws {
        try await withLogSandbox { sandbox in
            let log = try await ActivityLog.open(try sandbox.realLocation(), now: now)

            let settings = try await log.storageSettings()

            #expect(settings.journalMode == "wal")
            // 2 is FULL. GRDB's write-ahead setup would leave it at 1 (NORMAL).
            #expect(settings.synchronous == 2)
        }
    }

    @Test func aLogInMemoryWorksWithoutAnyFile() async throws {
        let log = try await ActivityLog.open(.inMemory, now: now)
        let runID = try LogSamples.writeRun(to: log, startedAt: now, count: 2)

        #expect(ActivityLogLocation.inMemory.databaseURL == nil)
        #expect(try await log.changes(inRun: runID).count == 2)
        #expect(try await log.totals().filesCleaned == 2)
    }

    /// Every version that shipped before folders: its rows are kept, all of them belong to the one
    /// Downloads folder the migration makes, and a row without a folder is refused from then on.
    @Test(arguments: 1...LegacyLog.newestVersion)
    func aLogFromAnyEarlierVersionGainsFoldersAndItsRowsBelongToDownloads(version: Int) async throws {
        try await withLogSandbox { sandbox in
            let location = try sandbox.realLocation()
            let databaseURL = try #require(location.databaseURL)
            let runID = try LegacyLog.make(at: location, version: version, count: 3, startedAt: now)

            let upgraded = try await ActivityLog.open(location, now: now)
            let run = try #require(try await upgraded.run(id: runID))
            #expect(run.folderPath == LegacyLog.folderPath)
            #expect(run.doneCount == 3)
            #expect(run.origin == .app)
            let changes = try await upgraded.changes(inRun: runID)
            #expect(changes.map(\.originalPath) == (1...3).map { "\(LegacyLog.folderPath)/report (\($0)).pdf" })
            #expect(changes.allSatisfy { $0.outcome == .trashed && !$0.isFolder })
            #expect(try await upgraded.totals() == ActivityTotals(bytesMovedToTrash: 3_072, filesCleaned: 3))
            // The Kept list a version from 3 on left is still there, entry for entry.
            #expect(try upgraded.currentKeptItems().items.map(\.path).sorted() == (version >= 3 ? ["kept by path.pdf", "kept.pdf"] : []).map { "\(LegacyLog.folderPath)/\($0)" })
            try await upgraded.close()

            let raw = try RawDatabase(databaseURL)
            #expect(try raw.text("SELECT group_concat(identifier, ',') FROM grdb_migrations") == "v1,v2,v3,v4,v5,v6,v7,v8,v9")
            // One folder, Downloads, under an ID that is a UUID and not its path.
            #expect(try raw.text("SELECT count(*) FROM folders") == "1")
            let downloads = try #require(try raw.text("SELECT id FROM folders WHERE kind = 'downloads' AND removedAt IS NULL"))
            #expect(UUID(uuidString: downloads) != nil)
            #expect(run.folderID == UUID(uuidString: downloads))
            for table in ["runs", "changes", "keptItems"] {
                #expect(try raw.text("SELECT count(*) FROM \(table) WHERE folderID IS NOT '\(downloads)'") == "0", "\(table)")
            }
            // A row must name a folder, and one the table holds.
            #expect(throws: (any Error).self) {
                try raw.execute("INSERT INTO runs (action, folderPath, startedAt, state, confirmedCount) VALUES ('findDuplicates', '/x', 0, 'finished', 0)")
            }
            #expect(throws: (any Error).self) {
                try raw.execute("UPDATE changes SET folderID = NULL")
            }
            #expect(throws: (any Error).self) {
                try raw.execute("PRAGMA foreign_keys = ON; UPDATE runs SET folderID = 'no such folder'")
            }
            // A standard folder has one row, and neither a name nor a bookmark.
            #expect(throws: (any Error).self) {
                try raw.execute("INSERT INTO folders (id, kind) VALUES ('\(UUID().uuidString)', 'downloads')")
            }
            #expect(throws: (any Error).self) {
                try raw.execute("INSERT INTO folders (id, kind, displayName) VALUES ('\(UUID().uuidString)', 'desktop', 'Desktop')")
            }
            #expect(throws: (any Error).self) {
                try raw.execute("INSERT INTO folders (id, kind) VALUES ('\(UUID().uuidString)', 'custom')")
            }
        }
    }

    @Test func aDatabaseFromANewerVersionIsRefusedAndLeftAsItIs() async throws {
        try await withLogSandbox { sandbox in
            let location = try sandbox.realLocation()
            let databaseURL = try #require(location.databaseURL)
            let log = try await ActivityLog.open(location, now: now)
            try LogSamples.writeRun(to: log, startedAt: now, count: 1)
            try await log.close()
            // What a later version of the app would leave: a migration this version has never heard of.
            do {
                let raw = try RawDatabase(databaseURL)
                try raw.execute("INSERT INTO grdb_migrations (identifier) VALUES ('v999')")
                try raw.execute("ALTER TABLE runs ADD COLUMN fromTheFuture TEXT")
            }

            await #expect(throws: ActivityLogError.newerVersion) {
                _ = try await ActivityLog.open(location, now: now)
            }

            let raw = try RawDatabase(databaseURL)
            #expect(try raw.text("SELECT group_concat(identifier, ',') FROM grdb_migrations") == "v1,v2,v3,v4,v5,v6,v7,v8,v9,v999")
            #expect(try raw.text("SELECT count(*) FROM runs") == "1")
        }
    }

    @Test func aDatabaseThatCannotBeWrittenIsRefusedWhenItIsOpened() async throws {
        try await withLogSandbox { sandbox in
            let location = try sandbox.realLocation()
            let databaseURL = try #require(location.databaseURL)
            let folderPath = databaseURL.deletingLastPathComponent().path(percentEncoded: false)
            let log = try await ActivityLog.open(location, now: now)
            try await log.close()
            try FileManager.default.setAttributes([.posixPermissions: 0o400], ofItemAtPath: databaseURL.path(percentEncoded: false))
            try FileManager.default.setAttributes([.posixPermissions: 0o500], ofItemAtPath: folderPath)
            defer {
                try? FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: folderPath)
                try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: databaseURL.path(percentEncoded: false))
            }

            do {
                _ = try await ActivityLog.open(location, now: now)
                Issue.record("a read-only database was opened as a working log")
            } catch ActivityLogError.unreadable {
                // Refused at the door, not in the middle of a cleanup.
            }
        }
    }

    @Test func aLinkWhereTheLogsFolderShouldBeIsNeverFollowed() async throws {
        try await withLogSandbox { sandbox in
            let location = try sandbox.realLocation()
            let folderURL = try #require(location.folderURL)
            let elsewhere = sandbox.folder.url.appending(path: "Elsewhere", directoryHint: .isDirectory)
            try FileManager.default.createDirectory(at: elsewhere, withIntermediateDirectories: false)
            try FileManager.default.createSymbolicLink(at: folderURL, withDestinationURL: elsewhere)

            do {
                _ = try await ActivityLog.open(location, now: now)
                Issue.record("a link was followed to a folder somewhere else")
            } catch ActivityLogError.unreadable {
                // Left alone.
            }

            #expect(try FileManager.default.contentsOfDirectory(atPath: elsewhere.path(percentEncoded: false)).isEmpty)
        }
    }

    @Test func aLinkWhereTheDatabaseShouldBeIsNeverFollowed() async throws {
        try await withLogSandbox { sandbox in
            let location = try sandbox.realLocation()
            let databaseURL = try #require(location.databaseURL)
            let elsewhere = sandbox.folder.url.appending(path: "elsewhere.sqlite")
            try Data().write(to: elsewhere)
            try FileManager.default.createDirectory(at: databaseURL.deletingLastPathComponent(), withIntermediateDirectories: true)
            try FileManager.default.createSymbolicLink(at: databaseURL, withDestinationURL: elsewhere)

            do {
                _ = try await ActivityLog.open(location, now: now)
                Issue.record("a link was followed to a database somewhere else")
            } catch ActivityLogError.unreadable {
                // Left alone.
            }

            #expect(FileFacts.size(of: elsewhere) == 0)
        }
    }
}
