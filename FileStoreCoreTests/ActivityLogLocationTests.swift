import FileStoreCore
import Foundation
import Testing

/// Where the activity log lives: Application Support for the user's real folders, and a separate
/// database under the temporary directory whenever a debug override (a scan folder or a demo home)
/// stands in for them, so hand testing never opens, makes or writes the real log.
@Suite("Activity log location")
struct ActivityLogLocationTests {
    private let appIdentifier = LogSandbox.appIdentifier

    @Test func theRealFoldersUseApplicationSupport() async throws {
        try await withLogSandbox { sandbox in
            let applicationSupport = try #require(sandbox.roots.applicationSupport)

            let location = try sandbox.realLocation()

            #expect(location.kind == .applicationSupport)
            #expect(location.databaseURL == applicationSupport.appending(path: appIdentifier).appending(path: "FileStore.sqlite"))
            #expect(location.folderURL == applicationSupport.appending(path: appIdentifier, directoryHint: .isDirectory))
        }
    }

    @Test(arguments: FolderOverride.Source.allCases)
    func anOverrideNeverOpensOrMakesAnythingInApplicationSupport(source: FolderOverride.Source) async throws {
        try await withLogSandbox { sandbox in
            let fakeDownloads = sandbox.folder.url.appending(path: "FakeDownloads", directoryHint: .isDirectory)
            let now = Date(timeIntervalSince1970: 1_800_000_000)

            let location = try sandbox.overrideLocation(scanning: fakeDownloads, source: source)
            let log = try await ActivityLog.open(location, now: now)
            try LogSamples.writeRun(to: log, startedAt: now, count: 2)
            _ = try await log.pruneIfDue(now: now)

            #expect(location.kind == .temporary)
            let databaseURL = try #require(location.databaseURL)
            #expect(canonicalPath(databaseURL).hasPrefix(canonicalPath(sandbox.roots.temporary) + "/"))
            #expect(FileFacts.size(of: databaseURL) > 0)
            // The stand-in for the real Library was never touched: not a folder, not a file.
            #expect(try sandbox.applicationSupportContents() == [])
            #expect(FileFacts.permissions(of: databaseURL.deletingLastPathComponent()) == 0o700)
            #expect(FileFacts.permissions(of: databaseURL) == 0o600)
        }
    }

    @Test func eachOverriddenFolderHasItsOwnLogAndFindsItAgain() async throws {
        try await withLogSandbox { sandbox in
            let first = sandbox.folder.url.appending(path: "FakeDownloads-1", directoryHint: .isDirectory)
            let second = sandbox.folder.url.appending(path: "FakeDownloads-2", directoryHint: .isDirectory)

            let firstLocation = try sandbox.overrideLocation(scanning: first)
            let secondLocation = try sandbox.overrideLocation(scanning: second)

            #expect(firstLocation != secondLocation)
            #expect(firstLocation.databaseURL != secondLocation.databaseURL)
            #expect(try sandbox.overrideLocation(scanning: first) == firstLocation)
            // The same folder, whichever way it was chosen.
            #expect(try sandbox.overrideLocation(scanning: first, source: .scanFolderVariable) == firstLocation)
            // A demo home at the same path is another override, with a log of its own.
            let demoHome = try sandbox.overrideLocation(scanning: first, source: .demoHomeArgument)
            #expect(demoHome.kind == .temporary)
            #expect(demoHome != firstLocation)
            #expect(try sandbox.overrideLocation(scanning: first, source: .demoHomeVariable) == demoHome)
        }
    }

    @Test func aBrokenOverrideStillStaysOutOfApplicationSupport() async throws {
        try await withLogSandbox { sandbox in
            let failures: [FolderLocationError] = [
                .overrideValueMissing(source: .scanFolderArgument),
                .overrideValueMissing(source: .demoHomeArgument),
                .overrideDoesNotExist(path: "/nowhere/at/all", source: .scanFolderArgument),
                .overrideDoesNotExist(path: "/nowhere/at/all", source: .demoHomeVariable),
                .overrideIsNotAFolder(path: "/etc/hosts", source: .scanFolderVariable),
                .refused(.homeFolder),
                .bookmarkUnusable,
            ]
            for failure in failures {
                let location = try ActivityLogLocation.resolve(forFailedOverride: failure, appIdentifier: appIdentifier, roots: sandbox.roots)
                #expect(location.kind == .temporary, "\(failure)")
            }
            // Only a Downloads folder that cannot be found leaves the real log's place as it is.
            let real = try ActivityLogLocation.resolve(forFailedOverride: .standardFolderUnavailable(.downloads), appIdentifier: appIdentifier, roots: sandbox.roots)
            #expect(real == (try sandbox.realLocation()))
        }
    }

    /// With the user's real folders, and without opening anything: an override's log is under the
    /// temporary directory and nowhere near the real one.
    @Test func withTheRealFoldersAnOverrideResolvesUnderTheTemporaryDirectory() throws {
        let scan = FolderOverride(source: .scanFolderArgument, folderURL: URL(filePath: "/tmp/FakeDownloads", directoryHint: .isDirectory))
        let realLibrary = try #require(FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first)

        let location = try ActivityLogLocation.resolve(for: scan, appIdentifier: "com.quaden2307.SmartOSFileStore")

        let databasePath = canonicalPath(try #require(location.databaseURL))
        #expect(location.kind == .temporary)
        #expect(databasePath.hasPrefix(canonicalPath(FileManager.default.temporaryDirectory) + "/"))
        #expect(!databasePath.hasPrefix(canonicalPath(realLibrary) + "/"))
        #expect(databasePath.contains("/com.quaden2307.SmartOSFileStore.debug/"))

        let real = try ActivityLogLocation.resolve(for: nil, appIdentifier: "com.quaden2307.SmartOSFileStore")
        #expect(real.kind == .applicationSupport)
        #expect(real.databaseURL == realLibrary.appending(path: "com.quaden2307.SmartOSFileStore").appending(path: "FileStore.sqlite"))
    }

    /// From launch arguments, as the app resolves it. Debug: the override gets a temporary log.
    /// Release: the same arguments are ignored, the scan is of Downloads, and the log is the real one.
    @Test func theLaunchArgumentChoosesTheTemporaryLogInDebugBuildsOnly() async throws {
        try await withLogSandbox { sandbox in
            let fakeDownloads = sandbox.folder.url.appending(path: "FakeDownloads", directoryHint: .isDirectory)
            try FileManager.default.createDirectory(at: fakeDownloads, withIntermediateDirectories: false)

            let fromArgument = try ActivityLogLocation.resolve(
                arguments: ["SmartOSFileStore", FolderOverride.Source.scanFolderArgument.name, fakeDownloads.path(percentEncoded: false)],
                environment: [:],
                appIdentifier: appIdentifier,
                roots: sandbox.roots
            )
            let fromEnvironment = try ActivityLogLocation.resolve(
                arguments: ["SmartOSFileStore"],
                environment: [FolderOverride.Source.scanFolderVariable.name: fakeDownloads.path(percentEncoded: false)],
                appIdentifier: appIdentifier,
                roots: sandbox.roots
            )
            let plain = try ActivityLogLocation.resolve(
                arguments: ["SmartOSFileStore"],
                environment: [:],
                appIdentifier: appIdentifier,
                roots: sandbox.roots
            )

            #expect(plain == (try sandbox.realLocation()))
            #if DEBUG
            #expect(fromArgument.kind == .temporary)
            #expect(fromEnvironment == fromArgument)
            #else
            #expect(fromArgument == plain)
            #expect(fromEnvironment == plain)
            #endif
        }
    }

    @Test(arguments: ["", ".", "..", "a/b", "/absolute"])
    func anAppIdentifierThatIsNotOneFolderNameIsRefused(identifier: String) async throws {
        try await withLogSandbox { sandbox in
            let override = FolderOverride(source: .scanFolderArgument, folderURL: sandbox.folder.url)

            #expect(throws: ActivityLogError.locationUnavailable) {
                try ActivityLogLocation.resolve(for: nil, appIdentifier: identifier, roots: sandbox.roots)
            }
            #expect(throws: ActivityLogError.locationUnavailable) {
                try ActivityLogLocation.resolve(for: override, appIdentifier: identifier, roots: sandbox.roots)
            }
        }
    }

    @Test func withoutAnApplicationSupportFolderThereIsNoRealLog() throws {
        let roots = ActivityLogLocation.Roots(applicationSupport: nil, temporary: FileManager.default.temporaryDirectory)
        #expect(throws: ActivityLogError.locationUnavailable) {
            try ActivityLogLocation.resolve(for: nil, appIdentifier: appIdentifier, roots: roots)
        }
    }
}
