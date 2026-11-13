import Foundation

/// The same fake Downloads folder that `scripts/make-fake-downloads.sh` builds, created fresh under
/// the system temporary directory and removed afterwards. Every cleanup feature is tested on this
/// layout first, never on a real folder.
///
/// One deliberate difference from the script: `big-video.mov` is 1 MiB here instead of 200 MB, so
/// tests stay fast.
///
/// Every file is backdated by a minute (`settledAge`), because cleanup actions skip files modified
/// in the last few seconds and a fixture is always scanned moments after it is made.
/// `old-receipt.pdf` is older still.
struct FakeDownloadsFolder {
    /// File names in the fixture, so tests never retype them.
    enum Names {
        static let reportPDF = "report.pdf"
        static let reportCopy1 = "report (1).pdf"
        static let reportCopy2 = "report (2).pdf"
        static let reportCopyWord = "report copy.pdf"
        static let photo = "IMG_4021.jpg"
        static let photoCopy = "beach.jpg"
        static let notes = "notes.txt"
        static let notesEdited = "notes (1).txt"
        static let sameSizeA = "same-size-a.bin"
        static let sameSizeB = "same-size-b.bin"
        static let emptyA = "empty-a.txt"
        static let emptyB = "empty-b.txt"
        static let diskImage = "SomeApp-2.1.dmg"
        static let installer = "Tool.pkg"
        static let zipArchive = "project.zip"
        static let zipFolder = "project"
        static let chromeDownload = "movie.mp4.crdownload"
        static let safariDownload = "Unconfirmed 48213.download"
        static let partialDownload = "partial.part"
        static let noExtension = "LICENSE"
        static let hiddenFile = ".hidden-file"
        static let unicodePDF = "résumé – final ✓.pdf"
        static let percentEncodedName = "file%20name%20with%20junk.txt"
        static let subfolder = "Subfolder"
        static let symlink = "report-link.pdf"
        static let lockedFile = "locked.txt"
        static let bigVideo = "big-video.mov"
        static let oldReceipt = "old-receipt.pdf"
        /// Not created by `make()`: a test adds it as a fresh copy of `report.pdf`.
        static let freshReportCopy = "report-fresh.pdf"
    }

    /// Everything a top-level scan should list: every item except the hidden file.
    static let expectedTopLevelNames: Set<String> = [
        Names.reportPDF, Names.reportCopy1, Names.reportCopy2, Names.reportCopyWord,
        Names.photo, Names.photoCopy,
        Names.notes, Names.notesEdited,
        Names.sameSizeA, Names.sameSizeB,
        Names.emptyA, Names.emptyB,
        Names.diskImage, Names.installer, Names.zipArchive, Names.zipFolder,
        Names.chromeDownload, Names.safariDownload, Names.partialDownload,
        Names.noExtension, Names.unicodePDF, Names.percentEncodedName,
        Names.subfolder, Names.symlink, Names.lockedFile, Names.bigVideo, Names.oldReceipt,
    ]

    static let reportContents = "quarterly report body"
    static let bigVideoSize = 1 << 20
    /// 2025-01-01 09:00 UTC, matching the script's `touch -t 202501010900`.
    static let oldReceiptDate = Date(timeIntervalSince1970: 1_735_722_000)
    /// How far back every written file's modification date is set, so none looks freshly
    /// modified. Copies made with `copyItem` inherit the date.
    static let settledAge: TimeInterval = 60

    /// The fake Downloads folder itself.
    let url: URL

    private let root: TemporaryFolder

    static func make() throws -> FakeDownloadsFolder {
        let root = try TemporaryFolder.make(prefix: "FakeDownloads")
        let folder = root.url.appending(path: "FakeDownloads", directoryHint: .isDirectory)
        let fixture = FakeDownloadsFolder(url: folder, root: root)
        do {
            try populate(folder)
        } catch {
            // `remove()` unlocks the locked file first, so a half-built folder never leaks.
            fixture.remove()
            throw error
        }
        return fixture
    }

    /// Unlocks the locked file, then removes everything.
    func remove() {
        try? FileManager.default.setAttributes(
            [.immutable: false],
            ofItemAtPath: url(for: Names.lockedFile).path(percentEncoded: false)
        )
        root.remove()
    }

    func url(for name: String) -> URL {
        url.appending(path: name)
    }

    private static func populate(_ folder: URL) throws {
        let fileManager = FileManager.default
        try fileManager.createDirectory(at: folder, withIntermediateDirectories: true)
        let settledModificationDate = Date(timeIntervalSinceNow: -settledAge)

        func settle(_ name: String) throws {
            try fileManager.setAttributes(
                [.modificationDate: settledModificationDate],
                ofItemAtPath: folder.appending(path: name).path(percentEncoded: false)
            )
        }
        func write(_ text: String, to name: String) throws {
            try Data(text.utf8).write(to: folder.appending(path: name))
            try settle(name)
        }
        func copy(_ source: String, to destination: String) throws {
            try fileManager.copyItem(at: folder.appending(path: source), to: folder.appending(path: destination))
        }
        func makeFolder(_ name: String) throws {
            try fileManager.createDirectory(
                at: folder.appending(path: name, directoryHint: .isDirectory),
                withIntermediateDirectories: false
            )
        }

        // Exact duplicates with typical browser names
        try write(reportContents, to: Names.reportPDF)
        try copy(Names.reportPDF, to: Names.reportCopy1)
        try copy(Names.reportPDF, to: Names.reportCopy2)
        try copy(Names.reportPDF, to: Names.reportCopyWord)

        // Same content, unrelated names
        try write("holiday photo bytes", to: Names.photo)
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

        // Installers, archives and leftovers for later cleanup actions
        try write("dmg", to: Names.diskImage)
        try write("pkg", to: Names.installer)
        try write("zip", to: Names.zipArchive)
        try makeFolder(Names.zipFolder)
        try write("x", to: "\(Names.zipFolder)/readme.md")
        try write("partial", to: Names.chromeDownload)
        try write("partial", to: Names.safariDownload)
        try write("partial", to: Names.partialDownload)

        // Awkward cases
        try write("no extension", to: Names.noExtension)
        try write("hidden", to: Names.hiddenFile)
        try write("unicode", to: Names.unicodePDF)
        try write("spaces", to: Names.percentEncodedName)
        try makeFolder(Names.subfolder)
        try copy(Names.reportPDF, to: "\(Names.subfolder)/\(Names.reportPDF)")
        try fileManager.createSymbolicLink(
            atPath: folder.appending(path: Names.symlink).path(percentEncoded: false),
            withDestinationPath: Names.reportPDF
        )
        try write("locked", to: Names.lockedFile)
        try fileManager.setAttributes(
            [.immutable: true],
            ofItemAtPath: folder.appending(path: Names.lockedFile).path(percentEncoded: false)
        )

        // One larger file (kept small in tests)
        try Data(count: bigVideoSize).write(to: folder.appending(path: Names.bigVideo))
        try settle(Names.bigVideo)

        // An old file for age-based rules
        try write("old", to: Names.oldReceipt)
        try fileManager.setAttributes(
            [.modificationDate: oldReceiptDate],
            ofItemAtPath: folder.appending(path: Names.oldReceipt).path(percentEncoded: false)
        )
    }
}

/// Runs `body` with a fresh fake Downloads folder and removes it afterwards.
func withFakeDownloadsFolder<T>(_ body: (FakeDownloadsFolder) async throws -> T) async throws -> T {
    let folder = try FakeDownloadsFolder.make()
    defer { folder.remove() }
    return try await body(folder)
}
