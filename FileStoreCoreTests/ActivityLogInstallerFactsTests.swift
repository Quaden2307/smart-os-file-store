import FileStoreCore
import Foundation
import Testing

/// The installer facts cache in the activity log (decision record 0013): facts come back only for the
/// very same file, unchanged, read by the current reader; old rows go with old runs.
@Suite("Installer facts cache")
struct ActivityLogInstallerFactsTests {
    private let facts = InstallerFacts.apps([BundleFacts(name: "SomeApp", identifier: "com.example.SomeApp", shortVersion: "2.1", build: "210")])
    private let read = Date(timeIntervalSince1970: 1_800_000_000)

    private func key(
        identity: PersistentFileIdentity? = PersistentFileIdentity(volumeUUID: "VOLUME", fileNumber: 42),
        path: String = "/Users/someone/Downloads/SomeApp-2.1.dmg",
        size: Int64 = 7_059,
        modified: Date = Date(timeIntervalSince1970: 1_799_999_000.123_456_7),
        changed: Date = Date(timeIntervalSince1970: 1_799_999_001.765_432_1)
    ) -> InstallerFileKey {
        InstallerFileKey(identity: identity, path: path, sizeInBytes: size, dateModified: modified, statusChanged: changed)
    }

    @Test func factsComeBackForTheVerySameFileOnly() async throws {
        let log = try await ActivityLog.open(.inMemory)
        let stored = key()
        try await log.storeInstallerFacts([InstallerFactsEntry(key: stored, facts: facts)], now: read)

        #expect(try await log.installerFacts(for: [stored]) == [stored: facts])
        // Renamed or moved on its volume: the same file.
        let renamed = key(path: "/Users/someone/Downloads/renamed.dmg")
        #expect(try await log.installerFacts(for: [renamed]) == [renamed: facts])
        // Anything about it changed: read again.
        for changed in [
            key(size: 7_060),
            key(modified: stored.dateModified.addingTimeInterval(0.000_001)),
            key(changed: stored.statusChanged.addingTimeInterval(1)),
            key(identity: PersistentFileIdentity(volumeUUID: "VOLUME", fileNumber: 43)),
        ] {
            #expect(try await log.installerFacts(for: [changed]).isEmpty)
        }
    }

    @Test func withoutAnIdentityThePathStandsIn() async throws {
        let log = try await ActivityLog.open(.inMemory)
        let stored = key(identity: nil)
        try await log.storeInstallerFacts([InstallerFactsEntry(key: stored, facts: .unreadable(.passwordProtected))], now: read)
        #expect(try await log.installerFacts(for: [stored]) == [stored: .unreadable(.passwordProtected)])
        #expect(try await log.installerFacts(for: [key(identity: nil, path: "/elsewhere.dmg")]).isEmpty)
        // A file with an identity never takes a row made without one.
        #expect(try await log.installerFacts(for: [key()]).isEmpty)
    }

    @Test func aNewReadingReplacesTheOldAndATimeoutIsNeverKept() async throws {
        let log = try await ActivityLog.open(.inMemory)
        try await log.storeInstallerFacts([InstallerFactsEntry(key: key(), facts: facts)], now: read)
        let rewritten = key(size: 9_000)
        try await log.storeInstallerFacts([InstallerFactsEntry(key: rewritten, facts: .apps([]))], now: read)
        #expect(try await log.installerFacts(for: [rewritten]) == [rewritten: .apps([])])
        #expect(try await log.installerFacts(for: [key()]).isEmpty)

        let slow = key(identity: PersistentFileIdentity(volumeUUID: "VOLUME", fileNumber: 99))
        let refused = key(identity: PersistentFileIdentity(volumeUUID: "VOLUME", fileNumber: 98))
        try await log.storeInstallerFacts([
            InstallerFactsEntry(key: slow, facts: .unreadable(.timedOut)),
            InstallerFactsEntry(key: refused, facts: .unreadable(.couldNotOpen)),
        ], now: read)
        #expect(try await log.installerFacts(for: [slow, refused]).isEmpty)
    }

    @Test func rowsOfAnotherReaderOrUnreadableOnesAreMisses() async throws {
        try await withLogSandbox { sandbox in
            let location = try sandbox.realLocation()
            let databaseURL = try #require(location.databaseURL)
            let log = try await ActivityLog.open(location)
            let first = key()
            let second = key(identity: PersistentFileIdentity(volumeUUID: "VOLUME", fileNumber: 7))
            try await log.storeInstallerFacts([InstallerFactsEntry(key: first, facts: facts), InstallerFactsEntry(key: second, facts: facts)], now: read)
            try await log.close()
            do {
                let raw = try RawDatabase(databaseURL)
                try raw.execute("UPDATE installerFacts SET readerVersion = 0 WHERE fileNumber = 42")
                try raw.execute("UPDATE installerFacts SET facts = '{\"not\":\"facts\"}' WHERE fileNumber = 7")
            }
            let reopened = try await ActivityLog.open(location)
            #expect(try await reopened.installerFacts(for: [first, second]).isEmpty)
            try await reopened.close()
        }
    }

    @Test func rowsReadLongerAgoThanTheRetentionArePrunedWithTheRuns() async throws {
        let log = try await ActivityLog.open(.inMemory)
        let old = key()
        let recent = key(identity: PersistentFileIdentity(volumeUUID: "VOLUME", fileNumber: 8))
        try await log.storeInstallerFacts([InstallerFactsEntry(key: old, facts: facts)], now: read)
        try await log.storeInstallerFacts([InstallerFactsEntry(key: recent, facts: facts)], now: read.addingTimeInterval(80 * 24 * 60 * 60))

        _ = try await log.pruneIfDue(now: read.addingTimeInterval(ActivityLog.retention + 1))
        #expect(try await log.installerFacts(for: [old]).isEmpty)
        #expect(try await log.installerFacts(for: [recent]) == [recent: facts])
    }

    @Test func aLogFromBeforeTheCacheGainsTheTableAndKeepsItsRows() async throws {
        try await withLogSandbox { sandbox in
            let location = try sandbox.realLocation()
            let databaseURL = try #require(location.databaseURL)
            let log = try await ActivityLog.open(location)
            try LogSamples.writeRun(to: log, startedAt: .now, count: 2)
            try await log.close()
            // What segment 8 left: migrations up to `v4`, no `installerFacts`.
            do {
                let raw = try RawDatabase(databaseURL)
                try raw.execute("DROP TABLE installerFacts")
                try raw.execute("DELETE FROM grdb_migrations WHERE identifier = 'v5'")
            }

            let upgraded = try await ActivityLog.open(location)
            #expect(try await upgraded.runs().count == 1)
            #expect(try await upgraded.installerFacts(for: [key()]).isEmpty)
            try await upgraded.storeInstallerFacts([InstallerFactsEntry(key: key(), facts: facts)], now: read)
            #expect(try await upgraded.installerFacts(for: [key()]) == [key(): facts])
            try await upgraded.close()

            let raw = try RawDatabase(databaseURL)
            #expect(try raw.text("SELECT group_concat(identifier, ',') FROM grdb_migrations") == "v1,v2,v3,v4,v5")
            #expect(try raw.text("SELECT count(*) FROM changes") == "2")
        }
    }
}
