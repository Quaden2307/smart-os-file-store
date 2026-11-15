import Foundation

/// The same fake Downloads folder that `scripts/make-fake-downloads.sh` builds, created fresh under
/// the system temporary directory and removed afterwards. Every cleanup feature is tested on this
/// layout first, never on a real folder. It holds cases for every version 0.2 action, including
/// files each action must leave alone; `.claude/skills/cleanup-test-fixtures/SKILL.md` lists them.
///
/// Two deliberate differences from the script: `big-video.mov` is 1 MiB here instead of 200 MB,
/// and the disk image `SomeApp-2.1.dmg` is built only when a test asks for it
/// (`make(includingDiskImage: true)`), because `hdiutil` takes a second or two.
///
/// Dates: the app leaves anything added or modified in the last hour alone, and a fixture is always
/// scanned moments after it is made. So every item is dated two hours back (`FileDates.settledAge`),
/// its modification date and its Date Added both, one second apart in the order the items are made.
/// The age cases are older, the failed downloads three days old, and `setup.dmg.crdownload` is
/// left fresh.
///
/// Two files are locked (`uchg`): `locked.txt`, which has unique content, and `report (3).pdf`, a
/// duplicate, so that carrying out a plan has exactly one failure to report.
///
/// Beside the folder sits `FakeApplications/` (`applicationsURL`), standing in for /Applications.
struct FakeDownloadsFolder {
    /// File names in the fixture, so tests never retype them.
    enum Names {
        // Exact duplicates
        static let reportPDF = "report.pdf"
        static let reportCopy1 = "report (1).pdf"
        static let reportCopy2 = "report (2).pdf"
        /// A fourth identical copy, locked, so moving the duplicates to the Trash has one failure.
        static let lockedReportCopy = "report (3).pdf"
        static let reportCopyWord = "report copy.pdf"
        static let photo = "IMG_4021.jpg"
        static let photoCopy = "beach.jpg"
        static let notes = "notes.txt"
        static let notesEdited = "notes (1).txt"
        static let sameSizeA = "same-size-a.bin"
        static let sameSizeB = "same-size-b.bin"
        static let emptyA = "empty-a.txt"
        static let emptyB = "empty-b.txt"
        static let receipt = "receipt.pdf"
        /// Identical to `receipt`: a duplicate, and a messy name whose clean name is taken.
        static let receiptCopy = "receipt (1).pdf"

        // Failed downloads
        static let chromeDownload = "movie.mp4.crdownload"
        /// The finished download beside `chromeDownload`, which its reason names.
        static let finishedDownload = "movie.mp4"
        static let partialDownload = "partial.part"
        /// A Safari download package: a folder holding the partial file and an `Info.plist`.
        static let safariDownload = "presentation.key.download"
        static let safariDownloadContent = "presentation.key"
        /// Still in progress: never backdated.
        static let freshDownload = "setup.dmg.crdownload"

        // Unpacked zips
        static let zipArchive = "project.zip"
        static let zipFolder = "project"
        static let zipFolderFiles = ["readme.md", "main.swift"]
        /// Its folder lacks one of the archive's files.
        static let partialZipArchive = "photos.zip"
        static let partialZipFolder = "photos"
        static let partialZipFiles = ["a.jpg", "b.jpg", "c.jpg"]
        static let partialZipMissingFile = "c.jpg"
        /// Holds one file, which also sits beside it.
        static let singleFileZip = "contract.zip"
        static let singleFileZipContent = "contract.docx"
        /// Nothing unpacked beside it.
        static let lonelyZip = "archive-2023.zip"
        static let lonelyZipContent = "old-data.csv"

        // Installers
        /// A real disk image holding `SomeApp.app`; built only with `make(includingDiskImage: true)`.
        static let diskImage = "SomeApp-2.1.dmg"
        static let diskImageApp = "SomeApp.app"
        /// A zip holding `OtherApp.app`, which is not installed.
        static let appZip = "OtherApp-1.4.zip"
        static let appZipApp = "OtherApp.app"
        static let installer = "Tool.pkg"

        // Messy names
        static let numberedName = "manual (2).pdf"
        static let copyWordName = "budget copy.xlsx"
        static let percentEncodedName = "file%20name%20with%20junk.txt"
        static let queryLeftoverName = "brochure.pdf_dl=1"
        static let doubledExtensionName = "slides.pdf.pdf"
        static let invoice = "invoice.pdf"
        /// Its clean name belongs to `invoice`, a different file.
        static let invoiceCopy = "invoice (1).pdf"

        // Near-duplicates with different extensions
        static let todoText = "todo.txt"
        static let todoMarkdown = "todo.md"

        // Age and origin
        static let oldReceipt = "old-receipt.pdf"
        static let oldManual = "old-manual.pdf"
        static let taxForm = "tax-form-2024.pdf"
        static let statement = "statement.pdf"

        // Review lists
        static let emptyFolder = "Empty Folder"
        static let dsStoreFolder = "Folder With DS_Store"
        static let largeFile = "disk-backup.img"

        // The archive
        static let archiveFolder = "Old downloads"

        // Awkward cases
        static let noExtension = "LICENSE"
        static let hiddenFile = ".hidden-file"
        static let unicodePDF = "résumé – final ✓.pdf"
        static let subfolder = "Subfolder"
        static let symlink = "report-link.pdf"
        static let lockedFile = "locked.txt"
        static let bigVideo = "big-video.mov"

        /// Not created by `make()`: a test adds it as a fresh copy of `report.pdf`.
        static let freshReportCopy = "report-fresh.pdf"
    }

    /// Everything a top-level scan should list without the disk image: every item but the hidden file.
    static let expectedTopLevelNames: Set<String> = [
        Names.reportPDF, Names.reportCopy1, Names.reportCopy2, Names.lockedReportCopy, Names.reportCopyWord,
        Names.photo, Names.photoCopy,
        Names.notes, Names.notesEdited,
        Names.sameSizeA, Names.sameSizeB,
        Names.emptyA, Names.emptyB,
        Names.receipt, Names.receiptCopy,
        Names.chromeDownload, Names.partialDownload, Names.safariDownload, Names.freshDownload,
        Names.zipArchive, Names.zipFolder, Names.singleFileZip, Names.singleFileZipContent,
        Names.partialZipArchive, Names.partialZipFolder, Names.lonelyZip,
        Names.appZip, Names.installer,
        Names.numberedName, Names.copyWordName, Names.percentEncodedName, Names.queryLeftoverName,
        Names.doubledExtensionName, Names.invoice, Names.invoiceCopy,
        Names.todoText, Names.todoMarkdown,
        Names.oldReceipt, Names.oldManual, Names.taxForm, Names.statement,
        Names.emptyFolder, Names.dsStoreFolder, Names.largeFile,
        Names.archiveFolder,
        Names.noExtension, Names.unicodePDF, Names.subfolder, Names.symlink, Names.lockedFile, Names.bigVideo,
        Names.finishedDownload,
    ]

    static let reportContents = "quarterly report body"
    static let finishedDownloadContents = "the whole film, downloaded at last, every frame"
    static let photoContents = "holiday photo bytes"
    static let receiptContents = "receipt for order 1042"
    static let bigVideoSize = 1 << 20
    /// 600 MiB, sparse: it reports its size but takes almost no disk space and reads as zeros.
    static let largeFileSize: Int64 = 600 << 20

    /// The installed app, the same bundle the disk image holds.
    static let diskImageAppIdentifier = "com.example.SomeApp"
    static let diskImageAppVersion = "2.1"
    static let diskImageAppBuild = "210"
    static let appZipAppIdentifier = "com.example.OtherApp"
    static let appZipAppVersion = "1.4"

    /// `statement.pdf`'s download source, as a browser records it: the file's URL, then the page.
    static let statementSources = ["https://example.com/statements/statement.pdf", "https://example.com/account"]
    /// The app `statement.pdf`'s quarantine attribute names.
    static let statementDownloadingApp = "Safari"

    /// 2025-01-01 09:00 UTC, matching the script: when the old receipt and the tax form arrived.
    static let oldReceiptDate = Date(timeIntervalSince1970: 1_735_722_000)
    /// 2025-02-01 09:00 UTC: when the old receipt was last opened.
    static let oldReceiptLastOpened = Date(timeIntervalSince1970: 1_738_400_400)
    /// 2024-06-01 09:00 UTC: when the never-opened manual arrived.
    static let oldManualDate = Date(timeIntervalSince1970: 1_717_232_400)
    /// How old the failed downloads are.
    static let staleDownloadAge: TimeInterval = 3 * 24 * 60 * 60
    /// How long before the fixture was made the tax form was last opened.
    static let taxFormLastOpenedAge: TimeInterval = 24 * 60 * 60

    /// The fake Downloads folder itself.
    let url: URL

    /// The fake Applications folder beside it, holding the installed copy of the disk image's app.
    let applicationsURL: URL

    private let root: TemporaryFolder

    static func make(includingDiskImage: Bool = false) throws -> FakeDownloadsFolder {
        let root = try TemporaryFolder.make(prefix: "FakeDownloads")
        let fixture = FakeDownloadsFolder(
            url: root.url.appending(path: "FakeDownloads", directoryHint: .isDirectory),
            applicationsURL: root.url.appending(path: "FakeApplications", directoryHint: .isDirectory),
            root: root
        )
        do {
            try fixture.populate(includingDiskImage: includingDiskImage)
        } catch {
            // `remove()` unlocks the locked files first, so a half-built folder never leaks.
            fixture.remove()
            throw error
        }
        return fixture
    }

    /// Unlocks the locked files, then removes everything.
    func remove() {
        for name in [Names.lockedFile, Names.lockedReportCopy] {
            try? FileManager.default.setAttributes(
                [.immutable: false],
                ofItemAtPath: url(for: name).path(percentEncoded: false)
            )
        }
        root.remove()
    }

    func url(for name: String) -> URL {
        url.appending(path: name)
    }

    // MARK: - Building

    /// Builds the folder in the script's order. Every item made is remembered in that order, so it
    /// can be dated in that order at the end.
    private func populate(includingDiskImage: Bool) throws {
        let fileManager = FileManager.default
        let staging = root.url.appending(path: "Staging", directoryHint: .isDirectory)
        for folder in [url, applicationsURL, staging] {
            try fileManager.createDirectory(at: folder, withIntermediateDirectories: true)
        }
        var settled: [URL] = []
        var stale: [URL] = []

        @discardableResult
        func write(_ text: String, to name: String, into list: inout [URL]) throws -> URL {
            let file = url(for: name)
            try Data(text.utf8).write(to: file)
            list.append(file)
            return file
        }
        func write(_ text: String, to name: String) throws {
            try write(text, to: name, into: &settled)
        }
        func copy(_ source: String, to destination: String) throws {
            try fileManager.copyItem(at: url(for: source), to: url(for: destination))
            settled.append(url(for: destination))
        }
        func makeFolder(_ name: String, into list: inout [URL]) throws {
            let folder = url.appending(path: name, directoryHint: .isDirectory)
            try fileManager.createDirectory(at: folder, withIntermediateDirectories: false)
            list.append(folder)
        }
        func makeFolder(_ name: String) throws {
            try makeFolder(name, into: &settled)
        }
        func zip(_ source: URL, to name: String, keepParent: Bool) throws {
            try CommandLineTool.run(
                "/usr/bin/ditto",
                ["-c", "-k", "--norsrc", "--noextattr", "--noqtn", "--noacl"] + (keepParent ? ["--keepParent"] : [])
                    + [source.path(percentEncoded: false), url(for: name).path(percentEncoded: false)]
            )
            settled.append(url(for: name))
        }

        // Exact duplicates with typical browser names
        try write(Self.reportContents, to: Names.reportPDF)
        try copy(Names.reportPDF, to: Names.reportCopy1)
        try copy(Names.reportPDF, to: Names.reportCopy2)
        try copy(Names.reportPDF, to: Names.lockedReportCopy)
        try copy(Names.reportPDF, to: Names.reportCopyWord)

        // Same content, unrelated names
        try write(Self.photoContents, to: Names.photo)
        try copy(Names.photo, to: Names.photoCopy)

        // Same name pattern, DIFFERENT content: must never be treated as duplicates
        try write("draft one", to: Names.notes)
        try write("draft two, edited", to: Names.notesEdited)

        // Same size, different content: catches size-only comparison bugs
        try write("AAAA", to: Names.sameSizeA)
        try write("BBBB", to: Names.sameSizeB)

        // Empty files
        try write("", to: Names.emptyA)
        try write("", to: Names.emptyB)

        // A duplicate whose messy name's clean form is the identical original
        try write(Self.receiptContents, to: Names.receipt)
        try copy(Names.receipt, to: Names.receiptCopy)

        // Failed downloads, three days old, and one still in progress
        try write("partial", to: Names.chromeDownload, into: &stale)
        try write("partial", to: Names.partialDownload, into: &stale)
        try makeFolder(Names.safariDownload, into: &stale)
        try write("partial keynote", to: "\(Names.safariDownload)/\(Names.safariDownloadContent)", into: &stale)
        let downloadInfo: [String: Any] = [
            "DownloadEntryURL": "https://example.com/files/presentation.key",
            "DownloadEntryProgressBytesSoFar": 15,
            "DownloadEntryProgressTotalToLoad": 4_096,
        ]
        let infoURL = url(for: "\(Names.safariDownload)/Info.plist")
        try PropertyListSerialization.data(fromPropertyList: downloadInfo, format: .xml, options: 0).write(to: infoURL)
        stale.append(infoURL)
        var fresh: [URL] = []
        try write("partial", to: Names.freshDownload, into: &fresh)

        // Zips: unpacked beside, unpacked with a file missing, a single file beside, nothing beside
        try makeFolder(Names.zipFolder)
        try write("# Project\n", to: "\(Names.zipFolder)/\(Names.zipFolderFiles[0])")
        try write("print(\"hello\")\n", to: "\(Names.zipFolder)/\(Names.zipFolderFiles[1])")
        try zip(url(for: Names.zipFolder), to: Names.zipArchive, keepParent: true)
        try write("signed contract text", to: Names.singleFileZipContent)
        try zip(url(for: Names.singleFileZipContent), to: Names.singleFileZip, keepParent: false)
        try makeFolder(Names.partialZipFolder)
        for (index, name) in Names.partialZipFiles.enumerated() {
            try write("photo \(index + 1) pixels", to: "\(Names.partialZipFolder)/\(name)")
        }
        try zip(url(for: Names.partialZipFolder), to: Names.partialZipArchive, keepParent: true)
        let missing = url(for: "\(Names.partialZipFolder)/\(Names.partialZipMissingFile)")
        try fileManager.removeItem(at: missing)
        settled.removeAll { $0 == missing }
        let lonelySource = staging.appending(path: Names.lonelyZipContent)
        try Data("year,total\n2023,42\n".utf8).write(to: lonelySource)
        try zip(lonelySource, to: Names.lonelyZip, keepParent: false)

        // Installers: a disk image holding an app that is installed, a zip holding one that is not
        if includingDiskImage {
            let imageSource = staging.appending(path: "SomeApp", directoryHint: .isDirectory)
            try fileManager.createDirectory(at: imageSource, withIntermediateDirectories: false)
            try Self.writeApp(
                at: imageSource.appending(path: Names.diskImageApp),
                identifier: Self.diskImageAppIdentifier, version: Self.diskImageAppVersion, build: Self.diskImageAppBuild
            )
            try Self.makeDiskImage(from: imageSource, volumeName: "SomeApp", to: url(for: Names.diskImage), staging: staging)
            settled.append(url(for: Names.diskImage))
        }
        let zippedApp = staging.appending(path: Names.appZipApp)
        try Self.writeApp(at: zippedApp, identifier: Self.appZipAppIdentifier, version: Self.appZipAppVersion, build: "140")
        try zip(zippedApp, to: Names.appZip, keepParent: true)
        try write("pkg", to: Names.installer)
        try Self.writeApp(
            at: applicationsURL.appending(path: Names.diskImageApp),
            identifier: Self.diskImageAppIdentifier, version: Self.diskImageAppVersion, build: Self.diskImageAppBuild
        )

        // Messy names, each a different length so none shares a size with another file by accident
        try write("printer manual", to: Names.numberedName)
        try write("household budget", to: Names.copyWordName)
        try write("spaces", to: Names.percentEncodedName)
        try write("spring brochure", to: Names.queryLeftoverName)
        try write("team slides", to: Names.doubledExtensionName)
        try write("invoice 1041 total", to: Names.invoice)
        try write("invoice 1041 draft", to: Names.invoiceCopy)

        // Near-duplicates with different extensions: nearly the same text, never identical
        try write("buy milk, eggs and bread\n", to: Names.todoText)
        try write("buy milk, eggs and bread.\n", to: Names.todoMarkdown)

        // Age and origin (the dates are set below)
        try write("old", to: Names.oldReceipt)
        try write("an old manual nobody opened", to: Names.oldManual)
        try write("tax return form for 2024", to: Names.taxForm)
        try write("bank statement, october", to: Names.statement)

        // Review lists: an empty folder, a folder holding only Finder's .DS_Store, a large file
        try makeFolder(Names.emptyFolder)
        try makeFolder(Names.dsStoreFolder)
        try write("\0\0\0\u{1}Bud1", to: "\(Names.dsStoreFolder)/.DS_Store")
        try BulkFiles.writeSparseFile(url(for: Names.largeFile), size: Self.largeFileSize)
        settled.append(url(for: Names.largeFile))

        // The archive folder, holding a copy that must never be grouped with the report
        try makeFolder(Names.archiveFolder)
        try copy(Names.reportPDF, to: "\(Names.archiveFolder)/\(Names.reportPDF)")

        // Awkward cases
        try write("no extension", to: Names.noExtension)
        try write("hidden", to: Names.hiddenFile)
        try write("unicode", to: Names.unicodePDF)
        try makeFolder(Names.subfolder)
        try copy(Names.reportPDF, to: "\(Names.subfolder)/\(Names.reportPDF)")
        try fileManager.createSymbolicLink(
            atPath: url(for: Names.symlink).path(percentEncoded: false),
            withDestinationPath: Names.reportPDF
        )
        settled.append(url(for: Names.symlink))
        try write("locked", to: Names.lockedFile)
        try Data(count: Self.bigVideoSize).write(to: url(for: Names.bigVideo))
        settled.append(url(for: Names.bigVideo))

        // The finished download, made last so every other date stays where it was. Its size is
        // unique, so Find Duplicates never reads it.
        try write(Self.finishedDownloadContents, to: Names.finishedDownload)

        try fileManager.removeItem(at: staging)

        // Dates, after everything exists: two hours back in the order made, older for the age cases.
        try FileDates.settle(settled)
        try FileDates.settle(stale, base: Date(timeIntervalSinceNow: -Self.staleDownloadAge))
        try FileDates.set(url(for: Names.oldReceipt), to: Self.oldReceiptDate)
        try FileDates.set(url(for: Names.taxForm), to: Self.oldReceiptDate.addingTimeInterval(1))
        try FileDates.set(url(for: Names.oldManual), to: Self.oldManualDate)
        try ExtendedAttributes.setLastUsedDate(Self.oldReceiptLastOpened, on: url(for: Names.oldReceipt))
        try ExtendedAttributes.setLastUsedDate(Date(timeIntervalSinceNow: -Self.taxFormLastOpenedAge), on: url(for: Names.taxForm))
        try ExtendedAttributes.setWhereFroms(Self.statementSources, on: url(for: Names.statement))
        try ExtendedAttributes.setQuarantine(
            ExtendedAttributes.quarantineValue(app: Self.statementDownloadingApp, downloadedAt: Date(timeIntervalSinceNow: -FileDates.settledAge)),
            on: url(for: Names.statement)
        )

        // Locked last: a locked file's dates and attributes cannot be changed.
        for name in [Names.lockedFile, Names.lockedReportCopy] {
            try fileManager.setAttributes([.immutable: true], ofItemAtPath: url(for: name).path(percentEncoded: false))
        }
    }

    /// A minimal app bundle: an `Info.plist` with the bundle id and versions, and an executable.
    static func writeApp(at appURL: URL, identifier: String, version: String, build: String) throws {
        let contents = appURL.appending(path: "Contents", directoryHint: .isDirectory)
        let executableFolder = contents.appending(path: "MacOS", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: executableFolder, withIntermediateDirectories: true)
        let name = appURL.deletingPathExtension().lastPathComponent
        let info: [String: Any] = [
            "CFBundleIdentifier": identifier,
            "CFBundleName": name,
            "CFBundleExecutable": name,
            "CFBundlePackageType": "APPL",
            "CFBundleShortVersionString": version,
            "CFBundleVersion": build,
        ]
        try PropertyListSerialization.data(fromPropertyList: info, format: .xml, options: 0)
            .write(to: contents.appending(path: "Info.plist"))
        let executable = executableFolder.appending(path: name)
        try Data("#!/bin/sh\nexit 0\n".utf8).write(to: executable)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: executable.path(percentEncoded: false))
    }

    /// A compressed disk image (UDZO) of `source`, made without mounting anything: `hdiutil
    /// makehybrid` writes the file system straight into an image, then `convert` compresses it.
    /// Tried twice, since `hdiutil` occasionally reports a busy resource.
    private static func makeDiskImage(from source: URL, volumeName: String, to image: URL, staging: URL) throws {
        let raw = staging.appending(path: "image-raw.dmg").path(percentEncoded: false)
        var lastError: (any Error)?
        for _ in 0..<2 {
            do {
                try? FileManager.default.removeItem(atPath: raw)
                try CommandLineTool.run(
                    "/usr/bin/hdiutil",
                    ["makehybrid", "-quiet", "-hfs", "-default-volume-name", volumeName, "-o", raw, source.path(percentEncoded: false)]
                )
                try CommandLineTool.run(
                    "/usr/bin/hdiutil",
                    ["convert", "-quiet", raw, "-format", "UDZO", "-ov", "-o", image.path(percentEncoded: false)]
                )
                return
            } catch {
                lastError = error
            }
        }
        if let lastError {
            throw lastError
        }
    }
}

/// Runs `body` with a fresh fake Downloads folder and removes it afterwards.
func withFakeDownloadsFolder<T>(
    includingDiskImage: Bool = false,
    _ body: (FakeDownloadsFolder) async throws -> T
) async throws -> T {
    let folder = try FakeDownloadsFolder.make(includingDiskImage: includingDiskImage)
    defer { folder.remove() }
    return try await body(folder)
}
