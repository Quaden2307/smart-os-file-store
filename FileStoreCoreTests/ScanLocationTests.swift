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
