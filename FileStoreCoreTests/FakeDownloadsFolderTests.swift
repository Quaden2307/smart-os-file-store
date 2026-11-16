import Darwin
import FileStoreCore
import Foundation
import Testing

/// The fixture itself: each case is what its name promises, so a later action's tests can rely on
/// it. These run before any action exists for most of the cases; they check the files, not a plan.
@Suite("Fake Downloads folder")
struct FakeDownloadsFolderTests {
    private typealias Names = FakeDownloadsFolder.Names

    private let scanner = FolderScanner()

    private func records(_ fixture: FakeDownloadsFolder) async throws -> [FileRecord] {
        try await scanner.scan(ScanLocation(folderURL: fixture.url, source: .launchArgument)).records
    }

    private func zipEntries(_ url: URL) throws -> Set<String> {
        let listing = try CommandLineTool.run("/usr/bin/zipinfo", ["-1", url.path(percentEncoded: false)])
        return Set(listing.split(separator: "\n").map(String.init))
    }

    private func contents(of folder: URL) throws -> Set<String> {
        Set(try FileManager.default.contentsOfDirectory(atPath: folder.path(percentEncoded: false)))
    }

    private func status(_ url: URL) throws -> stat {
        var status = stat()
        guard lstat(url.path(percentEncoded: false), &status) == 0 else {
            throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
        }
        return status
    }

    // MARK: - Dates

    /// Every item is past the one-hour grace period except the download still in progress, so the
    /// grace period never hides a case from an action's tests.
    @Test func everythingIsSettledButTheFreshDownload() async throws {
        try await withFakeDownloadsFolder { fixture in
            let eligibility = CandidateEligibility()
            let now = Date.now
            for record in try await records(fixture) {
                let settled = eligibility.isSettled(dateAdded: record.dateAdded, dateModified: record.dateModified, now: now)
                if record.displayName == Names.freshDownload {
                    #expect(!settled, "\(record.displayName) should still be fresh")
                } else {
                    #expect(settled, "\(record.displayName) should be past the grace period")
                    #expect(record.dateAdded != nil, "\(record.displayName) should have a Date Added")
                }
            }
        }
    }

    /// Items are dated in the order they were made, so "oldest first" keeps the photo it always kept.
    @Test func datingKeepsTheOrderItemsWereMade() async throws {
        try await withFakeDownloadsFolder { fixture in
            let all = try await records(fixture)
            let photo = try #require(all.first { $0.displayName == Names.photo })
            let copy = try #require(all.first { $0.displayName == Names.photoCopy })
            let photoAdded = try #require(photo.dateAdded)
            let copyAdded = try #require(copy.dateAdded)
            #expect(photoAdded < copyAdded)
            #expect(DuplicatePlanner.keptFile(among: [copy, photo])?.displayName == Names.photo)
        }
    }

    @Test func ageCasesCarryTheirDatesAndLastOpened() async throws {
        try await withFakeDownloadsFolder { fixture in
            let all = try await records(fixture)
            func record(_ name: String) throws -> FileRecord {
                try #require(all.first { $0.displayName == name }, "no record for \(name)")
            }
            #expect(try record(Names.oldReceipt).dateModified == FakeDownloadsFolder.oldReceiptDate)
            #expect(try record(Names.oldReceipt).dateAdded == FakeDownloadsFolder.oldReceiptDate)
            #expect(try record(Names.oldManual).dateModified == FakeDownloadsFolder.oldManualDate)
            #expect(try record(Names.oldManual).dateAdded == FakeDownloadsFolder.oldManualDate)
            let staleAge = try #require(try record(Names.chromeDownload).dateModified).timeIntervalSinceNow
            #expect(staleAge < -FakeDownloadsFolder.staleDownloadAge + 60)

            #expect(ExtendedAttributes.lastUsedDate(of: fixture.url(for: Names.oldReceipt)) == FakeDownloadsFolder.oldReceiptLastOpened)
            let taxOpened = try #require(ExtendedAttributes.lastUsedDate(of: fixture.url(for: Names.taxForm)))
            #expect(abs(taxOpened.timeIntervalSinceNow + FakeDownloadsFolder.taxFormLastOpenedAge) < 60)
            #expect(ExtendedAttributes.lastUsedDate(of: fixture.url(for: Names.oldManual)) == nil)
            #expect(ExtendedAttributes.whereFroms(of: fixture.url(for: Names.statement)) == FakeDownloadsFolder.statementSources)
            #expect(ExtendedAttributes.whereFroms(of: fixture.url(for: Names.reportPDF)) == nil)
            let quarantine = try #require(ExtendedAttributes.quarantine(of: fixture.url(for: Names.statement)))
            #expect(quarantine.split(separator: ";").dropFirst(2).first.map(String.init) == FakeDownloadsFolder.statementDownloadingApp)
            #expect(ExtendedAttributes.quarantine(of: fixture.url(for: Names.reportPDF)) == nil)
        }
    }

    /// Under the default thresholds only the three age cases carry age marks, and only the three
    /// stale partial downloads carry Failed download. Everything else is two hours old, a folder, a
    /// link or a download still in progress, and carries none.
    @Test func ageCasesCarryTheirMarks() async throws {
        try await withFakeDownloadsFolder { fixture in
            let expected: [String: [FileMark]] = [
                Names.oldReceipt: [.unused, .old],
                Names.oldManual: [.neverOpened, .old],
                Names.taxForm: [.old],
                Names.chromeDownload: [.failedDownload],
                Names.partialDownload: [.failedDownload],
                Names.safariDownload: [.failedDownload],
            ]
            let now = Date.now
            let settings = CleanupSettings()
            let all = try await records(fixture)
            #expect(all.count == FakeDownloadsFolder.expectedTopLevelNames.count)
            for record in all {
                let marks = FileMarker.marks(for: record, now: now, settings: settings)
                #expect(marks == expected[record.displayName, default: []], "\(record.displayName) has marks \(marks)")
            }
        }
    }

    // MARK: - Zips and downloads

    @Test func zipsHoldWhatTheirCasesNeed() async throws {
        try await withFakeDownloadsFolder { fixture in
            let project = try zipEntries(fixture.url(for: Names.zipArchive))
            #expect(project == Set(["\(Names.zipFolder)/"] + Names.zipFolderFiles.map { "\(Names.zipFolder)/\($0)" }))
            #expect(try contents(of: fixture.url(for: Names.zipFolder)) == Set(Names.zipFolderFiles))

            let photos = try zipEntries(fixture.url(for: Names.partialZipArchive))
            #expect(photos == Set(["\(Names.partialZipFolder)/"] + Names.partialZipFiles.map { "\(Names.partialZipFolder)/\($0)" }))
            let unpacked = try contents(of: fixture.url(for: Names.partialZipFolder))
            #expect(unpacked == Set(Names.partialZipFiles).subtracting([Names.partialZipMissingFile]))

            #expect(try zipEntries(fixture.url(for: Names.singleFileZip)) == [Names.singleFileZipContent])
            #expect(FileManager.default.fileExists(atPath: fixture.url(for: Names.singleFileZipContent).path(percentEncoded: false)))
            #expect(try zipEntries(fixture.url(for: Names.lonelyZip)) == [Names.lonelyZipContent])
            #expect(!FileManager.default.fileExists(atPath: fixture.url(for: Names.lonelyZipContent).path(percentEncoded: false)))

            let app = try zipEntries(fixture.url(for: Names.appZip))
            #expect(app.contains("\(Names.appZipApp)/Contents/Info.plist"))
            #expect(app.contains("\(Names.appZipApp)/Contents/MacOS/OtherApp"))
        }
    }

    /// No zip shares its size with any other top-level file, so the duplicate finder never reads
    /// one; `DuplicatePlannerDiskTests.hashesOnlyFilesSharingASize` counts on it.
    @Test func zipsHaveSizesOfTheirOwn() async throws {
        try await withFakeDownloadsFolder { fixture in
            let files = try await records(fixture).filter { $0.kind == .file }
            let zipNames: Set<String> = [Names.zipArchive, Names.partialZipArchive, Names.singleFileZip, Names.lonelyZip, Names.appZip]
            let zips = files.filter { zipNames.contains($0.displayName) }
            #expect(zips.count == zipNames.count)
            for zip in zips {
                let sameSize = files.filter { $0.sizeInBytes == zip.sizeInBytes && $0.displayName != zip.displayName }
                #expect(sameSize.isEmpty, "\(zip.displayName) shares its size with \(sameSize.map(\.displayName))")
            }
        }
    }

    @Test func safariPackageIsAnInProgressDownload() async throws {
        try await withFakeDownloadsFolder { fixture in
            let record = try #require(try await records(fixture).first { $0.displayName == Names.safariDownload })
            #expect(record.isDownloading)
            // A package where Safari's type is registered, a plain folder elsewhere; never a file.
            #expect(record.kind == .package || record.kind == .folder)
            #expect(try contents(of: fixture.url(for: Names.safariDownload)) == [Names.safariDownloadContent, "Info.plist"])
        }
    }

    // MARK: - Review lists and the archive

    @Test func reviewCasesAreWhatTheySay() async throws {
        try await withFakeDownloadsFolder { fixture in
            #expect(try contents(of: fixture.url(for: Names.emptyFolder)).isEmpty)
            #expect(try contents(of: fixture.url(for: Names.dsStoreFolder)) == [".DS_Store"])
            #expect(try contents(of: fixture.url(for: Names.archiveFolder)) == [Names.reportPDF])

            let large = try status(fixture.url(for: Names.largeFile))
            #expect(Int64(large.st_size) == FakeDownloadsFolder.largeFileSize)
            // Sparse: blocks are 512 bytes, and next to nothing is allocated.
            #expect(Int64(large.st_blocks) * 512 < 1 << 20)
        }
    }

    // MARK: - Installers

    /// The real disk image is built only on request. It is a compressed UDIF image (its last 512
    /// bytes start with the `koly` trailer), made without mounting anything, and the installed
    /// app beside the folder is the same bundle.
    @Test func diskImageAndInstalledAppMatch() async throws {
        try await withFakeDownloadsFolder(includingDiskImage: true) { fixture in
            let image = fixture.url(for: Names.diskImage)
            let data = try Data(contentsOf: image)
            #expect(data.count > 512)
            #expect(data.suffix(512).prefix(4) == Data("koly".utf8))
            let listed = Set(try await records(fixture).map(\.displayName))
            #expect(listed == FakeDownloadsFolder.expectedTopLevelNames.union([Names.diskImage, Names.encryptedImage]))
            // The encrypted image starts as an encrypted image does, so it is never attached.
            #expect(try Data(contentsOf: fixture.url(for: Names.encryptedImage)).prefix(8) == Data("encrcdsa".utf8))

            let info = fixture.applicationsURL.appending(path: "\(Names.diskImageApp)/Contents/Info.plist")
            let plist = try #require(
                try PropertyListSerialization.propertyList(from: Data(contentsOf: info), format: nil) as? [String: Any]
            )
            #expect(plist["CFBundleIdentifier"] as? String == FakeDownloadsFolder.diskImageAppIdentifier)
            #expect(plist["CFBundleShortVersionString"] as? String == FakeDownloadsFolder.diskImageAppVersion)
            #expect(plist["CFBundleVersion"] as? String == FakeDownloadsFolder.diskImageAppBuild)
        }
    }

    @Test func diskImageIsLeftOutByDefault() async throws {
        try await withFakeDownloadsFolder { fixture in
            #expect(!FileManager.default.fileExists(atPath: fixture.url(for: Names.diskImage).path(percentEncoded: false)))
            #expect(!FileManager.default.fileExists(atPath: fixture.url(for: Names.encryptedImage).path(percentEncoded: false)))
            let installed = try contents(of: fixture.applicationsURL)
            #expect(Set(installed) == FakeDownloadsFolder.installedApps)
        }
    }
}
