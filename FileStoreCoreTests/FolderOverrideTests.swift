import FileStoreCore
import Foundation
import Testing

/// The debug overrides that stand in for the user's standard folders: `-DemoHome`, `-ScanFolder`
/// and their environment variables. They exist only in Debug builds. Every test here therefore has
/// two readings: in a Debug build the override applies (or fails with a typed error); in a Release
/// build the very same input is ignored and there is no override, so running this suite in the
/// Release configuration proves the overrides are compiled out.
@Suite("FolderOverride")
struct FolderOverrideTests {
    private let noArguments = ["SmartOSFileStore"]
    private let noEnvironment: [String: String] = [:]

    /// The arguments or environment that give `folder` through `source`.
    private func input(_ source: FolderOverride.Source, _ path: String) -> (arguments: [String], environment: [String: String]) {
        switch source {
        case .demoHomeArgument, .scanFolderArgument:
            (noArguments + [source.name, path], noEnvironment)
        case .demoHomeVariable, .scanFolderVariable:
            (noArguments, [source.name: path])
        }
    }

    /// Debug: the override is `source`'s, at `folder`. Release: the same input gave no override.
    private func expectOverride(
        _ override: FolderOverride?,
        source: FolderOverride.Source,
        folder: URL,
        sourceLocation: SourceLocation = #_sourceLocation
    ) throws {
        #if DEBUG
        let override = try #require(override, sourceLocation: sourceLocation)
        #expect(override.source == source, sourceLocation: sourceLocation)
        expectSameFolder(override.folderURL, folder, sourceLocation: sourceLocation)
        #else
        #expect(override == nil, sourceLocation: sourceLocation)
        #endif
    }

    /// Debug: resolving throws `error`. Release: the unusable override is not even looked at.
    private func expectOverrideError(
        _ error: FolderLocationError,
        sourceLocation: SourceLocation = #_sourceLocation,
        resolving: () throws -> FolderOverride?
    ) throws {
        #if DEBUG
        #expect(throws: error, sourceLocation: sourceLocation) {
            try resolving()
        }
        #else
        #expect(try resolving() == nil, sourceLocation: sourceLocation)
        #endif
    }

    @Test func withoutAnOverrideThereIsNone() throws {
        #expect(try FolderOverride.resolve(arguments: noArguments, environment: noEnvironment) == nil)
        // An empty variable counts as unset.
        #expect(try FolderOverride.resolve(arguments: noArguments, environment: ["SMARTOS_DEMO_HOME": "", "SMARTOS_SCAN_FOLDER": ""]) == nil)
    }

    @Test func theNamesAreTheDocumentedOnes() {
        #expect(FolderOverride.Source.allCases.map(\.name) == ["-DemoHome", "-ScanFolder", "SMARTOS_DEMO_HOME", "SMARTOS_SCAN_FOLDER"])
        #expect(FolderOverride.Source.allCases.map(\.kind) == [.demoHome, .scanFolder, .demoHome, .scanFolder])
    }

    @Test(arguments: FolderOverride.Source.allCases)
    func eachSourceGivesItsOverrideInDebugOnly(source: FolderOverride.Source) throws {
        try withTemporaryFolder { folder in
            let input = input(source, folder.path(percentEncoded: false))
            let override = try FolderOverride.resolve(arguments: input.arguments, environment: input.environment)
            try expectOverride(override, source: source, folder: folder)
        }
    }

    /// The first that is set wins, in the documented order, and the rest are ignored entirely:
    /// a later one may even be unusable.
    @Test func theFirstOverrideSetWinsAndTheRestAreIgnored() throws {
        try withTemporaryFolder { root in
            let missing = root.appending(path: "does-not-exist").path(percentEncoded: false)
            var folders: [FolderOverride.Source: URL] = [:]
            for source in FolderOverride.Source.allCases {
                let folder = root.appending(path: source.name, directoryHint: .isDirectory)
                try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: false)
                folders[source] = folder
            }
            let sources = FolderOverride.Source.allCases
            for (index, winner) in sources.enumerated() {
                var arguments = noArguments
                var environment = noEnvironment
                // The winner is usable; everything after it in the order is set and broken.
                for (offset, source) in sources.enumerated() where offset >= index {
                    let path = offset == index ? try #require(folders[source]).path(percentEncoded: false) : missing
                    let input = input(source, path)
                    arguments += input.arguments.dropFirst()
                    environment.merge(input.environment) { first, _ in first }
                }
                let override = try FolderOverride.resolve(arguments: arguments, environment: environment)
                try expectOverride(override, source: winner, folder: try #require(folders[winner]))
            }
        }
    }

    @Test(arguments: FolderOverride.Source.allCases)
    func aMissingOrFilePathIsATypedError(source: FolderOverride.Source) throws {
        try withTemporaryFolder { folder in
            let missingPath = folder.appending(path: "does-not-exist").path(percentEncoded: false)
            try expectOverrideError(.overrideDoesNotExist(path: missingPath, source: source)) {
                let input = input(source, missingPath)
                return try FolderOverride.resolve(arguments: input.arguments, environment: input.environment)
            }
            let fileURL = folder.appending(path: "not-a-folder.txt")
            try Data("x".utf8).write(to: fileURL)
            let filePath = fileURL.path(percentEncoded: false)
            try expectOverrideError(.overrideIsNotAFolder(path: filePath, source: source)) {
                let input = input(source, filePath)
                return try FolderOverride.resolve(arguments: input.arguments, environment: input.environment)
            }
        }
    }

    @Test(arguments: [FolderOverride.Source.demoHomeArgument, .scanFolderArgument])
    func aLaunchArgumentWithoutAValueIsATypedError(source: FolderOverride.Source) throws {
        try expectOverrideError(.overrideValueMissing(source: source)) {
            // The variable is never looked at once the argument is there, even though it is usable.
            try FolderOverride.resolve(arguments: noArguments + [source.name], environment: ["SMARTOS_SCAN_FOLDER": "/tmp"])
        }
    }
}
