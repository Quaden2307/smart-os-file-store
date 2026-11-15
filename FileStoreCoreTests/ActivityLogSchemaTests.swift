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

            // The migration made exactly the four tables, with one totals row and one maintenance row.
            try await log.close()
            let raw = try RawDatabase(databaseURL)
            let tables = try raw.text(
                "SELECT group_concat(name, ',') FROM (SELECT name FROM sqlite_master WHERE type = 'table' AND name NOT LIKE 'sqlite_%' AND name NOT LIKE 'grdb_%' ORDER BY name)"
            )
            #expect(tables == "changes,maintenance,runs,totals")
            #expect(try raw.text("SELECT count(*) FROM totals") == "1")
            #expect(try raw.text("SELECT count(*) FROM maintenance") == "1")
            #expect(try raw.text("SELECT group_concat(identifier, ',') FROM grdb_migrations") == "v1")
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

    @Test func theFolderAndEveryFileAreOpenToTheirOwnerOnly() async throws {
        try await withLogSandbox { sandbox in
            let location = try sandbox.realLocation()
            let databaseURL = try #require(location.databaseURL)
            let log = try await ActivityLog.open(location, now: now)
            // A row in flight, so the write-ahead file and its index exist.
            _ = try log.beginRun(
                CleanupRunStart(action: .findDuplicates, folderURL: LogSamples.folderURL, confirmedCount: 1, startedAt: now)
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
            #expect(try raw.text("SELECT group_concat(identifier, ',') FROM grdb_migrations") == "v1,v999")
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
