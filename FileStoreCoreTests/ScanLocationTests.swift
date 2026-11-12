import FileStoreCore
import Foundation
import Testing

@Suite("ScanLocation")
struct ScanLocationTests {
    private let noArguments = ["SmartOSFileStore"]
    private let noEnvironment: [String: String] = [:]

    @Test func defaultIsDownloadsFolder() throws {
        let location = try ScanLocation.resolve(arguments: noArguments, environment: noEnvironment)
        let downloads = try #require(
            FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask).first
        )
        #expect(location.source == .downloadsFolder)
        expectSameFolder(location.folderURL, downloads)
    }

    @Test func launchArgumentOverridesDownloads() throws {
        try withTemporaryFolder { folder in
            let location = try ScanLocation.resolve(
                arguments: noArguments + ["-ScanFolder", folder.path(percentEncoded: false)],
                environment: noEnvironment
            )
            #expect(location.source == .launchArgument)
            expectSameFolder(location.folderURL, folder)
        }
    }

    @Test func environmentVariableOverridesDownloads() throws {
        try withTemporaryFolder { folder in
            let location = try ScanLocation.resolve(
                arguments: noArguments,
                environment: ["SMARTOS_SCAN_FOLDER": folder.path(percentEncoded: false)]
            )
            #expect(location.source == .environmentVariable)
            expectSameFolder(location.folderURL, folder)
        }
    }

    @Test func launchArgumentWinsOverEnvironmentVariable() throws {
        try withTemporaryFolder { argumentFolder in
            try withTemporaryFolder { environmentFolder in
                let location = try ScanLocation.resolve(
                    arguments: noArguments + ["-ScanFolder", argumentFolder.path(percentEncoded: false)],
                    environment: ["SMARTOS_SCAN_FOLDER": environmentFolder.path(percentEncoded: false)]
                )
                #expect(location.source == .launchArgument)
                expectSameFolder(location.folderURL, argumentFolder)
            }
        }
    }

    @Test func missingOverridePathIsTypedError() throws {
        try withTemporaryFolder { folder in
            let missingPath = folder.appending(path: "does-not-exist").path(percentEncoded: false)
            #expect(throws: ScanLocationError.overrideDoesNotExist(path: missingPath, source: .launchArgument)) {
                try ScanLocation.resolve(
                    arguments: noArguments + ["-ScanFolder", missingPath],
                    environment: noEnvironment
                )
            }
            #expect(throws: ScanLocationError.overrideDoesNotExist(path: missingPath, source: .environmentVariable)) {
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
            #expect(throws: ScanLocationError.overrideIsNotAFolder(path: filePath, source: .launchArgument)) {
                try ScanLocation.resolve(
                    arguments: noArguments + ["-ScanFolder", filePath],
                    environment: noEnvironment
                )
            }
            #expect(throws: ScanLocationError.overrideIsNotAFolder(path: filePath, source: .environmentVariable)) {
                try ScanLocation.resolve(
                    arguments: noArguments,
                    environment: ["SMARTOS_SCAN_FOLDER": filePath]
                )
            }
        }
    }

    @Test func launchArgumentWithoutValueIsTypedError() {
        #expect(throws: ScanLocationError.overrideValueMissing(source: .launchArgument)) {
            try ScanLocation.resolve(arguments: noArguments + ["-ScanFolder"], environment: noEnvironment)
        }
    }
}

// MARK: - Helpers

/// Runs `body` with a fresh folder under the system temporary directory and removes it afterwards.
/// Tests never touch the real Downloads folder or any other user folder.
private func withTemporaryFolder<T>(_ body: (URL) throws -> T) throws -> T {
    let folder = FileManager.default.temporaryDirectory
        .appending(path: "ScanLocationTests-\(UUID().uuidString)", directoryHint: .isDirectory)
    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: folder) }
    return try body(folder)
}

private func expectSameFolder(
    _ actual: URL,
    _ expected: URL,
    sourceLocation: SourceLocation = #_sourceLocation
) {
    #expect(canonicalPath(actual) == canonicalPath(expected), sourceLocation: sourceLocation)
}

/// Resolves symlinks (the temporary directory lives under a symlinked /var) and drops a trailing slash.
private func canonicalPath(_ url: URL) -> String {
    var path = url.standardizedFileURL.resolvingSymlinksInPath().path(percentEncoded: false)
    while path.count > 1, path.hasSuffix("/") {
        path.removeLast()
    }
    return path
}
