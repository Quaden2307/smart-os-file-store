import FileStoreCore
import Foundation
import Testing

/// The folder the app scans. The `-ScanFolder` argument and `SMARTOS_SCAN_FOLDER` variable exist
/// only in Debug builds. Every test here therefore has two readings: in a Debug build the override
/// applies (or fails with a typed error); in a Release build the very same input is ignored and
/// Downloads is used, so running this suite in the Release configuration proves the override is
/// compiled out.
@Suite("ScanLocation")
struct ScanLocationTests {
    private let noArguments = ["SmartOSFileStore"]
    private let noEnvironment: [String: String] = [:]

    private func downloadsFolder() throws -> URL {
        try #require(FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask).first)
    }

    /// Debug: the override chose `folder`. Release: the same input resolved to Downloads.
    private func expectOverride(
        _ location: ScanLocation,
        source: ScanLocation.Source,
        folder: URL,
        sourceLocation: SourceLocation = #_sourceLocation
    ) throws {
        #if DEBUG
        #expect(location.source == source, sourceLocation: sourceLocation)
        expectSameFolder(location.folderURL, folder, sourceLocation: sourceLocation)
        #else
        #expect(location.source == .downloadsFolder, sourceLocation: sourceLocation)
        expectSameFolder(location.folderURL, try downloadsFolder(), sourceLocation: sourceLocation)
        #endif
    }

    /// Debug: resolving throws `error`. Release: the unusable override is not even looked at.
    private func expectOverrideError(
        _ error: ScanLocationError,
        sourceLocation: SourceLocation = #_sourceLocation,
        resolving: () throws -> ScanLocation
    ) throws {
        #if DEBUG
        #expect(throws: error, sourceLocation: sourceLocation) {
            try resolving()
        }
        #else
        let location = try resolving()
        #expect(location.source == .downloadsFolder, sourceLocation: sourceLocation)
        expectSameFolder(location.folderURL, try downloadsFolder(), sourceLocation: sourceLocation)
        #endif
    }

    @Test func defaultIsDownloadsFolder() throws {
        let location = try ScanLocation.resolve(arguments: noArguments, environment: noEnvironment)
        #expect(location.source == .downloadsFolder)
        expectSameFolder(location.folderURL, try downloadsFolder())
    }

    @Test func launchArgumentOverridesDownloadsInDebugOnly() throws {
        try withTemporaryFolder { folder in
            let location = try ScanLocation.resolve(
                arguments: noArguments + ["-ScanFolder", folder.path(percentEncoded: false)],
                environment: noEnvironment
            )
            try expectOverride(location, source: .launchArgument, folder: folder)
        }
    }

    @Test func environmentVariableOverridesDownloadsInDebugOnly() throws {
        try withTemporaryFolder { folder in
            let location = try ScanLocation.resolve(
                arguments: noArguments,
                environment: ["SMARTOS_SCAN_FOLDER": folder.path(percentEncoded: false)]
            )
            try expectOverride(location, source: .environmentVariable, folder: folder)
        }
    }

    @Test func launchArgumentWinsOverEnvironmentVariable() throws {
        try withTemporaryFolder { argumentFolder in
            try withTemporaryFolder { environmentFolder in
                let location = try ScanLocation.resolve(
                    arguments: noArguments + ["-ScanFolder", argumentFolder.path(percentEncoded: false)],
                    environment: ["SMARTOS_SCAN_FOLDER": environmentFolder.path(percentEncoded: false)]
                )
                try expectOverride(location, source: .launchArgument, folder: argumentFolder)
            }
        }
    }

    @Test func missingOverridePathIsTypedError() throws {
        try withTemporaryFolder { folder in
            let missingPath = folder.appending(path: "does-not-exist").path(percentEncoded: false)
            try expectOverrideError(.overrideDoesNotExist(path: missingPath, source: .launchArgument)) {
                try ScanLocation.resolve(
                    arguments: noArguments + ["-ScanFolder", missingPath],
                    environment: noEnvironment
                )
            }
            try expectOverrideError(.overrideDoesNotExist(path: missingPath, source: .environmentVariable)) {
                try ScanLocation.resolve(
                    arguments: noArguments,
                    environment: ["SMARTOS_SCAN_FOLDER": missingPath]
                )
            }
        }
    }

    @Test func fileOverridePathIsTypedError() throws {
        try withTemporaryFolder { folder in
            let fileURL = folder.appending(path: "not-a-folder.txt")
            try Data("x".utf8).write(to: fileURL)
            let filePath = fileURL.path(percentEncoded: false)
            try expectOverrideError(.overrideIsNotAFolder(path: filePath, source: .launchArgument)) {
                try ScanLocation.resolve(
                    arguments: noArguments + ["-ScanFolder", filePath],
                    environment: noEnvironment
                )
            }
            try expectOverrideError(.overrideIsNotAFolder(path: filePath, source: .environmentVariable)) {
                try ScanLocation.resolve(
                    arguments: noArguments,
                    environment: ["SMARTOS_SCAN_FOLDER": filePath]
                )
            }
        }
    }

    @Test func launchArgumentWithoutValueIsTypedError() throws {
        try expectOverrideError(.overrideValueMissing(source: .launchArgument)) {
            try ScanLocation.resolve(arguments: noArguments + ["-ScanFolder"], environment: noEnvironment)
        }
    }
}
