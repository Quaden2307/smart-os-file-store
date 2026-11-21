import FileStoreCore
import Foundation
import Testing

/// The managed folders: the list the log keeps, where each folder is found, and that a debug
/// override stands in for the standard folders without the real ones ever being looked up.
@Suite("FolderRegistry")
struct FolderRegistryTests {
    /// A stand-in home under `root` with the three standard folders, and a registry that takes it
    /// as a demo home.
    private struct DemoHome {
        let root: URL
        let home: URL
        let registry: FolderRegistry

        init(root: URL, folders: [String] = ["Downloads", "Desktop", "Documents"]) throws {
            self.root = root
            home = root.appending(path: "Home", directoryHint: .isDirectory)
            for name in folders + ["Library"] {
                try FileManager.default.createDirectory(at: home.appending(path: name), withIntermediateDirectories: true)
            }
            registry = FolderRegistry(
                override: FolderOverride(source: .demoHomeArgument, folderURL: home),
                rules: FolderSafetyRules(home: home, appDataFolders: [], allowedRoots: [root])
            )
        }

        func url(_ name: String) -> URL {
            home.appending(path: name, directoryHint: .isDirectory)
        }
    }

    private func expectFailure(
        _ result: Result<ManagedFolder, FolderLocationError>,
        _ expected: FolderLocationError,
        sourceLocation: SourceLocation = #_sourceLocation
    ) {
        switch result {
        case .success(let folder):
            Issue.record("Expected \(expected), found \(folder.url.lastPathComponent)", sourceLocation: sourceLocation)
        case .failure(let error):
            #expect(error == expected, sourceLocation: sourceLocation)
        }
    }

    // MARK: - The list

    @Test func aNewLogListsDownloadsOnly() async throws {
        try await withTemporaryFolderAsync { root in
            let demo = try DemoHome(root: root)
            let log = try await ActivityLog.open(.inMemory)

            let folders = try await demo.registry.folders(in: log)

            #expect(folders.map(\.kind) == [.downloads])
            expectSameFolder(try #require(folders.first).url, demo.url("Downloads"))
            #expect(folders.first?.id == (try log.folderID(of: .downloads)))
            #expect(folders.first?.locator == .standard)
            #expect(try log.folderID(of: .desktop) == nil)
        }
    }

    @Test func aFoldersIDIsMadeOnceAndSurvivesReopeningAndBeingTakenOffTheList() async throws {
        try await withLogSandbox { sandbox in
            let demo = try DemoHome(root: sandbox.folder.url.appending(path: "Demo"))
            let location = try sandbox.overrideLocation(scanning: demo.home, source: .demoHomeArgument)
            let first = try await ActivityLog.open(location)
            let downloads = try #require(try await demo.registry.folders(in: first).first)
            let desktop = try await demo.registry.add(.desktop, to: first).get()
            #expect(desktop.id != downloads.id)
            // Adding what is already there changes nothing.
            #expect(try await demo.registry.add(.desktop, to: first).get().id == desktop.id)
            try await first.close()

            let second = try await ActivityLog.open(location)
            #expect(try await demo.registry.folders(in: second).map(\.id) == [downloads.id, desktop.id])

            try await demo.registry.remove(desktop, from: second)
            #expect(try await demo.registry.folders(in: second).map(\.id) == [downloads.id])
            // Off the list, the folder is still known by its ID, for the runs made in it.
            #expect(try await demo.registry.folder(id: desktop.id, in: second)?.url == desktop.url)
            // Back on the list, it is the same folder as before.
            #expect(try await demo.registry.add(.desktop, to: second).get().id == desktop.id)
            #expect(try await demo.registry.folders(in: second).map(\.id) == [downloads.id, desktop.id])
            #expect(try await demo.registry.folder(id: UUID(), in: second) == nil)
            try await second.close()
        }
    }

    // MARK: - Overrides

    @Test func aDemoHomeStandsInForAllThreeStandardFolders() async throws {
        try await withTemporaryFolderAsync { root in
            let demo = try DemoHome(root: root)
            let log = try await ActivityLog.open(.inMemory)

            expectSameFolder(try demo.registry.provisionalDownloads().url, demo.url("Downloads"))
            let desktop = try await demo.registry.add(.desktop, to: log).get()
            let documents = try await demo.registry.add(.documents, to: log).get()

            let folders = try await demo.registry.folders(in: log)
            #expect(folders.map(\.kind) == [.downloads, .desktop, .documents])
            expectSameFolder(desktop.url, demo.url("Desktop"))
            expectSameFolder(documents.url, demo.url("Documents"))
            // Never the user's own.
            let demoPath = canonicalPath(demo.home) + "/"
            #expect(folders.allSatisfy { canonicalPath($0.url).hasPrefix(demoPath) })
            #expect(demo.registry.activeOverride?.kind == .demoHome)
        }
    }

    @Test func aDemoHomeWithoutAStandardFolderDoesNotFallBackToTheRealOne() async throws {
        try await withTemporaryFolderAsync { root in
            let demo = try DemoHome(root: root, folders: ["Downloads"])
            let log = try await ActivityLog.open(.inMemory)
            try Data("x".utf8).write(to: demo.home.appending(path: "Documents"))

            expectFailure(
                try await demo.registry.add(.desktop, to: log),
                .overrideDoesNotExist(path: demo.url("Desktop").path(percentEncoded: false), source: .demoHomeArgument)
            )
            expectFailure(
                try await demo.registry.add(.documents, to: log),
                .overrideIsNotAFolder(path: demo.url("Documents").path(percentEncoded: false), source: .demoHomeArgument)
            )
            #expect(try await demo.registry.folders(in: log).map(\.kind) == [.downloads])
        }
    }

    /// A demo home that is the real home would hand out the real folders. Only the home's own
    /// path is looked at; nothing in it is.
    @Test func theRealHomeIsRefusedAsADemoHome() async throws {
        let home = FileManager.default.homeDirectoryForCurrentUser
        let registry = FolderRegistry(
            override: FolderOverride(source: .demoHomeArgument, folderURL: home),
            rules: FolderSafetyRules(home: home, appDataFolders: [])
        )
        #expect(throws: FolderLocationError.refused(.homeFolder)) {
            try registry.provisionalDownloads()
        }
        let log = try await ActivityLog.open(.inMemory)
        #expect(try await registry.folders(in: log).isEmpty)
        expectFailure(try await registry.add(.desktop, to: log), .refused(.homeFolder))
    }

    @Test func aScanFolderIsDownloadsAndThereIsNoDesktopOrDocuments() async throws {
        try await withTemporaryFolderAsync { root in
            let registry = FolderRegistry(
                override: FolderOverride(source: .scanFolderArgument, folderURL: root),
                rules: .forTests
            )
            let log = try await ActivityLog.open(.inMemory)

            expectSameFolder(try registry.provisionalDownloads().url, root)
            #expect(await registry.refusal(for: try registry.provisionalDownloads()) == nil)
            let folders = try await registry.folders(in: log)
            #expect(folders.map(\.kind) == [.downloads])
            expectSameFolder(try #require(folders.first).url, root)
            expectFailure(try await registry.add(.desktop, to: log), .standardFolderUnavailable(.desktop))
            expectFailure(try await registry.add(.documents, to: log), .standardFolderUnavailable(.documents))
            // A provisional folder is the same place under an ID the log does not hold.
            #expect(try registry.provisionalDownloads().id != folders.first?.id)
        }
    }

    /// Debug: an override that cannot be used finds no folder at all. Release: the arguments are
    /// ignored, and the registry is the one for the real folders.
    @Test func aBrokenOverrideNeverFallsBackToTheRealFolders() async throws {
        try await withTemporaryFolderAsync { root in
            let missing = root.appending(path: "does-not-exist").path(percentEncoded: false)
            let registry = FolderRegistry.forProcess(arguments: ["SmartOSFileStore", "-DemoHome", missing], environment: [:], appDataFolders: [])
            #if DEBUG
            #expect(throws: FolderLocationError.overrideDoesNotExist(path: missing, source: .demoHomeArgument)) {
                try registry.provisionalDownloads()
            }
            let log = try await ActivityLog.open(.inMemory)
            #expect(try await registry.folders(in: log).isEmpty)
            #else
            #expect(registry.activeOverride == nil)
            #endif
        }
    }

    @Test func forThisProcessAnOverrideExemptsTheTemporaryDirectoryInDebugOnly() throws {
        try withTemporaryFolder { root in
            let registry = FolderRegistry.forProcess(
                arguments: ["SmartOSFileStore", "-ScanFolder", root.path(percentEncoded: false)],
                environment: [:],
                appDataFolders: []
            )
            #if DEBUG
            expectSameFolder(try registry.provisionalDownloads().url, root)
            #else
            #expect(registry.activeOverride == nil)
            #endif
            // Without an override nothing is exempt.
            let plain = FolderRegistry.forProcess(arguments: ["SmartOSFileStore"], environment: [:], appDataFolders: [])
            #expect(plain.activeOverride == nil)
            #expect(plain.rules.allowedRoots.isEmpty)
        }
    }

    // MARK: - The rules

    @Test func downloadsThatLeadsSomewhereRefusedIsRefused() async throws {
        try await withTemporaryFolderAsync { root in
            let demo = try DemoHome(root: root, folders: ["Desktop"])
            try FileManager.default.createSymbolicLink(at: demo.home.appending(path: "Downloads"), withDestinationURL: demo.home)
            let log = try await ActivityLog.open(.inMemory)

            // Where it is, is known without looking; the rules say no before anything is listed.
            let provisional = try demo.registry.provisionalDownloads()
            #expect(await demo.registry.refusal(for: provisional) == .homeFolder)
            #expect(try await demo.registry.folders(in: log).isEmpty)
        }
    }

    /// A standard folder that is not there (its disk is away, say) is not a refused place: it stays
    /// on the list, and whoever lists it reports that it cannot be found.
    @Test func aStandardFolderThatIsNotThereIsNotRefused() async throws {
        try await withTemporaryFolderAsync { root in
            let missing = root.appending(path: "Downloads", directoryHint: .isDirectory)
            let registry = FolderRegistry.testing(downloads: missing)
            let log = try await ActivityLog.open(.inMemory)

            let provisional = try registry.provisionalDownloads()
            #expect(await registry.refusal(for: provisional) == nil)
            let folders = try await registry.folders(in: log)
            #expect(folders.map(\.kind) == [.downloads])
            await #expect(throws: FolderScanError.folderNotFound(provisional.url)) {
                try await FolderScanner().scan(provisional)
            }
            // A file where the folder should be is not a refused place either; a custom folder must be there.
            try Data("x".utf8).write(to: root.appending(path: "Downloads"))
            #expect(await registry.refusal(for: provisional) == nil)
            #expect(await registry.refusal(for: ManagedFolder(kind: .custom, url: root.appending(path: "Nowhere"))) == .notAFolder)
        }
    }

    @Test func aCustomFolderMustPassTheRulesToBeAdded() async throws {
        try await withTemporaryFolderAsync { root in
            let demo = try DemoHome(root: root)
            let log = try await ActivityLog.open(.inMemory)
            _ = try await demo.registry.add(.documents, to: log).get()
            let projects = demo.url("Documents/Projects")
            let pictures = demo.url("Pictures")
            for folder in [projects, pictures] {
                try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            }

            expectFailure(try await demo.registry.add(customFolderAt: demo.home, to: log), .refused(.homeFolder))
            expectFailure(try await demo.registry.add(customFolderAt: demo.url("Library"), to: log), .refused(.insideLibrary))
            expectFailure(try await demo.registry.add(customFolderAt: projects, to: log), .refused(.overlapsManagedFolder))
            expectFailure(try await demo.registry.add(customFolderAt: demo.url("Downloads"), to: log), .refused(.overlapsManagedFolder))
            expectFailure(try await demo.registry.add(customFolderAt: demo.url("Missing"), to: log), .refused(.notAFolder))
            #expect(try await demo.registry.folders(in: log).map(\.kind) == [.downloads, .documents])

            let added = try await demo.registry.add(customFolderAt: pictures, named: "Holiday pictures", to: log).get()
            #expect(added.kind == .custom)
            #expect(added.displayName == "Holiday pictures")
            expectSameFolder(added.url, pictures)
            // The same folder a second time is a folder already managed.
            expectFailure(try await demo.registry.add(customFolderAt: pictures, to: log), .refused(.overlapsManagedFolder))
        }
    }

    // MARK: - Custom folders

    @Test func aCustomFolderIsFoundAgainAfterItIsRenamedAndNotWhenItIsGone() async throws {
        try await withTemporaryFolderAsync { root in
            let demo = try DemoHome(root: root)
            let log = try await ActivityLog.open(.inMemory)
            let original = demo.url("Projects")
            try FileManager.default.createDirectory(at: original, withIntermediateDirectories: false)
            let added = try await demo.registry.add(customFolderAt: original, to: log).get()
            #expect(added.displayName == "Projects")

            // Renamed and moved into another folder: the bookmark follows it, the ID stays.
            let moved = demo.url("Archive/Old projects")
            try FileManager.default.createDirectory(at: moved.deletingLastPathComponent(), withIntermediateDirectories: false)
            try FileManager.default.moveItem(at: original, to: moved)
            // A different folder made at the old place is not the managed one.
            try FileManager.default.createDirectory(at: original, withIntermediateDirectories: false)

            let found = try #require(try await demo.registry.folders(in: log).first { $0.kind == .custom })
            #expect(found.id == added.id)
            expectSameFolder(found.url, moved)
            #expect(found.displayName == "Projects")
            #expect(try await demo.registry.folder(id: added.id, in: log)?.id == added.id)

            // Gone: not listed, and not found by its ID either.
            try FileManager.default.removeItem(at: moved)
            #expect(try await demo.registry.folders(in: log).map(\.kind) == [.downloads])
            #expect(try await demo.registry.folder(id: added.id, in: log) == nil)
        }
    }

    @Test func aMissingCustomFolderStaysListedUnderItsNameAndANewOneIsNotIt() async throws {
        try await withTemporaryFolderAsync { root in
            let demo = try DemoHome(root: root)
            let log = try await ActivityLog.open(.inMemory)
            let projects = demo.url("Projects")
            try FileManager.default.createDirectory(at: projects, withIntermediateDirectories: false)
            let added = try await demo.registry.add(customFolderAt: projects, to: log).get()
            try await demo.registry.setDisplayName(of: added.id, to: "  Work  ", in: log)
            try await demo.registry.setDisplayName(of: added.id, to: "   ", in: log)

            let hidden = demo.url(".away")
            try FileManager.default.moveItem(at: projects, to: hidden)
            try FileManager.default.removeItem(at: hidden)
            let gone = try #require(try await demo.registry.entries(in: log).first { $0.id == added.id })
            #expect(gone.folder == nil)
            #expect(gone.storedName == "Work")

            try FileManager.default.createDirectory(at: projects, withIntermediateDirectories: false)
            // A new folder at the old place is not the one that was added.
            #expect(try await demo.registry.entries(in: log).first { $0.id == added.id }?.folder == nil)
            #expect(try await demo.registry.folders(in: log).map(\.kind) == [.downloads])
        }
    }

    @Test func aRenamedCustomFolderKeepsItsIDAndFilesOnDisk() async throws {
        try await withTemporaryFolderAsync { root in
            let demo = try DemoHome(root: root)
            let log = try await ActivityLog.open(.inMemory)
            let projects = demo.url("Projects")
            try FileManager.default.createDirectory(at: projects, withIntermediateDirectories: false)
            let added = try await demo.registry.add(customFolderAt: projects, to: log).get()
            try await demo.registry.setDisplayName(of: added.id, to: "Work", in: log)
            let found = try #require(try await demo.registry.folders(in: log).first { $0.id == added.id })
            #expect(found.displayName == "Work")
            expectSameFolder(found.url, projects)
            #expect(FileManager.default.fileExists(atPath: projects.path(percentEncoded: false)))
        }
    }
}
