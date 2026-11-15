import FileStoreCore
import Foundation
import Testing
import UniformTypeIdentifiers

@Suite("FolderScanner")
struct FolderScannerTests {
    private typealias Names = FakeDownloadsFolder.Names

    private let scanner = FolderScanner()

    /// The source only matters for the app's debug status line.
    private func location(_ url: URL) -> ScanLocation {
        ScanLocation(folderURL: url, source: .launchArgument)
    }

    @Test func listsNormalFilesWithMetadata() async throws {
        try await withFakeDownloadsFolder { fixture in
            let result = try await scanner.scan(location(fixture.url))
            let report = try #require(result.records.first { $0.displayName == Names.reportPDF })
            #expect(report.kind == .file)
            #expect(report.sizeInBytes == Int64(FakeDownloadsFolder.reportContents.utf8.count))
            #expect(report.contentType == .pdf)
            #expect(report.localizedTypeDescription?.isEmpty == false)
            #expect(report.dateAdded != nil)
            #expect(report.dateModified != nil)
            #expect(report.isDownloading == false)
            #expect(report.id == report.url)
            #expect(result.skippedItems.isEmpty)
        }
    }

    @Test func recordsCarryTheIdentityTheExecutorReads() async throws {
        try await withFakeDownloadsFolder { fixture in
            let result = try await scanner.scan(location(fixture.url))
            let volume = try fixture.url.resourceValues(forKeys: [.volumeUUIDStringKey]).volumeUUIDString
            for name in [Names.reportPDF, Names.symlink, "Subfolder"] {
                let record = try #require(result.records.first { $0.displayName == name })
                let identity = try #require(record.persistentIdentity, "no identity for \(name)")
                #expect(identity.volumeUUID == volume)
                // The item's own number, a link's included: what `lstat` reads, never its target's.
                #expect(identity.fileNumber == DiskState.inode(of: fixture.url(for: name)))
            }
            #expect(Set(result.records.compactMap(\.persistentIdentity)).count == result.records.count)
        }
    }

    @Test func listsFolderWithoutSize() async throws {
        try await withFakeDownloadsFolder { fixture in
            let result = try await scanner.scan(location(fixture.url))
            for name in [Names.subfolder, Names.zipFolder] {
                let folder = try #require(result.records.first { $0.displayName == name })
                #expect(folder.kind == .folder)
                #expect(folder.sizeInBytes == nil)
                #expect(folder.contentType == .folder)
            }
        }
    }

    @Test func reportsPackageAsPackage() async throws {
        let temp = try TemporaryFolder.make()
        defer { temp.remove() }
        let app = temp.url.appending(path: "Fake.app", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: app, withIntermediateDirectories: false)

        let result = try await scanner.scan(location(temp.url))

        #expect(result.records.count == 1)
        let record = try #require(result.records.first)
        #expect(record.kind == .package)
        #expect(record.sizeInBytes == nil)
    }

    @Test func reportsSymlinkWithoutFollowing() async throws {
        try await withFakeDownloadsFolder { fixture in
            let result = try await scanner.scan(location(fixture.url))
            let link = try #require(result.records.first { $0.displayName == Names.symlink })
            #expect(link.kind == .symlink)
            #expect(link.contentType == .symbolicLink)
        }
    }

    @Test func symlinkToFolderOutsideIsNotAFolder() async throws {
        let temp = try TemporaryFolder.make()
        defer { temp.remove() }
        let outside = temp.url.appending(path: "outside", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: outside, withIntermediateDirectories: false)
        try Data("x".utf8).write(to: outside.appending(path: "inside.txt"))
        let scanned = temp.url.appending(path: "scanned", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: scanned, withIntermediateDirectories: false)
        try FileManager.default.createSymbolicLink(
            atPath: scanned.appending(path: "folder-link").path(percentEncoded: false),
            withDestinationPath: "../outside"
        )

        let result = try await scanner.scan(location(scanned))

        #expect(result.records.count == 1)
        #expect(result.records.first?.kind == .symlink)
        #expect(!result.records.contains { $0.displayName == "inside.txt" })
    }

    @Test func skipsHiddenFiles() async throws {
        try await withFakeDownloadsFolder { fixture in
            let result = try await scanner.scan(location(fixture.url))
            #expect(!result.records.contains { $0.displayName == Names.hiddenFile })
            #expect(!result.records.contains { $0.displayName.hasPrefix(".") })
        }
    }

    @Test func doesNotListSubfolderContents() async throws {
        try await withFakeDownloadsFolder { fixture in
            let result = try await scanner.scan(location(fixture.url))
            let names = Set(result.records.map(\.displayName))
            #expect(names == FakeDownloadsFolder.expectedTopLevelNames)
            #expect(result.records.count == FakeDownloadsFolder.expectedTopLevelNames.count)
            // Every record is a direct child of the scanned folder; nothing comes from deeper down.
            let parents = Set(result.records.map { canonicalPath($0.url.deletingLastPathComponent()) })
            #expect(parents == [canonicalPath(fixture.url)])
        }
    }

    @Test func keepsUnicodeName() async throws {
        try await withFakeDownloadsFolder { fixture in
            let result = try await scanner.scan(location(fixture.url))
            let record = try #require(result.records.first { $0.displayName == Names.unicodePDF })
            #expect(record.url.lastPathComponent == Names.unicodePDF)
            #expect(record.kind == .file)
        }
    }

    @Test func flagsInProgressDownloads() async throws {
        try await withFakeDownloadsFolder { fixture in
            let result = try await scanner.scan(location(fixture.url))
            for name in [Names.chromeDownload, Names.safariDownload, Names.partialDownload, Names.freshDownload] {
                let record = try #require(result.records.first { $0.displayName == name })
                #expect(record.isDownloading, "\(name) should be flagged as downloading")
            }
            let report = try #require(result.records.first { $0.displayName == Names.reportPDF })
            #expect(report.isDownloading == false)
        }
        #expect(FileRecord.isInProgressDownload(URL(fileURLWithPath: "/tmp/Archive.CRDOWNLOAD")))
        #expect(!FileRecord.isInProgressDownload(URL(fileURLWithPath: "/tmp/download")))
    }

    // MARK: - Metadata

    /// The reader decides each record's metadata; nothing is written to or read from attributes.
    @Test func recordsCarryTheReadersMetadata() async throws {
        let temp = try TemporaryFolder.make()
        defer { temp.remove() }
        try Data("a".utf8).write(to: temp.url.appending(path: "opened.pdf"))
        try Data("b".utf8).write(to: temp.url.appending(path: "plain.pdf"))
        let opened = Date(timeIntervalSince1970: 1_738_400_400)
        let source = try #require(DownloadSource(addresses: ["https://example.com/opened.pdf"], downloadingApp: "Safari"))
        let reader = FixedMetadataReader(metadataByName: ["opened.pdf": FileMetadata(lastOpened: opened, downloadSource: source)])

        let result = try await FolderScanner(metadataReader: reader).scan(location(temp.url))

        let openedRecord = try #require(result.records.first { $0.displayName == "opened.pdf" })
        #expect(openedRecord.lastOpened == opened)
        #expect(openedRecord.downloadSource == source)
        let plainRecord = try #require(result.records.first { $0.displayName == "plain.pdf" })
        #expect(plainRecord.lastOpened == nil)
        #expect(plainRecord.downloadSource == nil)
        #expect(ExtendedAttributes.lastUsedDate(of: openedRecord.url) == nil)
    }

    @Test func defaultReaderReadsTheFixturesAttributes() async throws {
        try await withFakeDownloadsFolder { fixture in
            let records = try await scanner.scan(location(fixture.url)).records
            func record(_ name: String) throws -> FileRecord {
                try #require(records.first { $0.displayName == name }, "no record for \(name)")
            }
            let statement = try #require(try record(Names.statement).downloadSource)
            #expect(statement.addresses == FakeDownloadsFolder.statementSources)
            #expect(statement.downloadingApp == FakeDownloadsFolder.statementDownloadingApp)
            #expect(statement.site == "example.com")
            #expect(try record(Names.oldReceipt).lastOpened == FakeDownloadsFolder.oldReceiptLastOpened)
            #expect(try record(Names.oldManual).lastOpened == nil)
            #expect(try record(Names.reportPDF).downloadSource == nil)
            let taxOpened = try #require(try record(Names.taxForm).lastOpened)
            #expect(abs(taxOpened.timeIntervalSinceNow + FakeDownloadsFolder.taxFormLastOpenedAge) < 60)
        }
    }

    @Test func emptyFolderGivesNoRecords() async throws {
        let temp = try TemporaryFolder.make()
        defer { temp.remove() }
        let location = location(temp.url)

        let result = try await scanner.scan(location)

        #expect(result.records.isEmpty)
        #expect(result.skippedItems.isEmpty)
        #expect(result.folderURL == location.folderURL)
    }

    @Test func missingFolderIsTypedError() async throws {
        let temp = try TemporaryFolder.make()
        defer { temp.remove() }
        let location = location(temp.url.appending(path: "does-not-exist", directoryHint: .isDirectory))

        await #expect(throws: FolderScanError.folderNotFound(location.folderURL)) {
            try await scanner.scan(location)
        }
    }

    @Test func unreadableFolderIsAccessDenied() async throws {
        let temp = try TemporaryFolder.make()
        defer { temp.remove() }
        let sealed = temp.url.appending(path: "sealed", directoryHint: .isDirectory)
        let sealedPath = sealed.path(percentEncoded: false)
        try FileManager.default.createDirectory(at: sealed, withIntermediateDirectories: false)
        try FileManager.default.setAttributes([.posixPermissions: 0o000], ofItemAtPath: sealedPath)
        defer { try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: sealedPath) }
        let location = location(sealed)

        await #expect(throws: FolderScanError.accessDenied(location.folderURL)) {
            try await scanner.scan(location)
        }
    }

    @Test func cancelledScanThrowsCancelled() async throws {
        try await withFakeDownloadsFolder { fixture in
            let location = location(fixture.url)
            let scanner = scanner
            // The task cancels itself before the scan starts, so the outcome never depends on timing.
            let task = Task {
                withUnsafeCurrentTask { $0?.cancel() }
                return try await scanner.scan(location)
            }
            await #expect(throws: FolderScanError.cancelled) {
                try await task.value
            }
        }
    }
}
