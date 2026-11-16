import FileStoreCore
import Foundation
import Testing

/// The zip reader on archives built byte by byte (`ZipBytes`): what it lists, and every shape it
/// refuses without allocating for it, guessing, or trapping. Real zips are in `UnpackedZipDiskTests`.
@Suite("Zip listing")
struct ZipListingTests {
    private typealias Entry = ZipBytes.Entry

    private func list(_ archive: ZipBytes, limits: ZipListing.Limits = .standard) throws -> [ZipEntry] {
        try ZipListing.parse(archive.bytes, limits: limits).entries
    }

    private func failure(_ bytes: [UInt8], limits: ZipListing.Limits = .standard) -> ZipListing.Failure? {
        do throws(ZipListing.Failure) {
            _ = try ZipListing.parse(bytes, limits: limits)
            return nil
        } catch {
            return error
        }
    }

    private func failure(_ archive: ZipBytes, limits: ZipListing.Limits = .standard) -> ZipListing.Failure? {
        failure(archive.bytes, limits: limits)
    }

    private var plain: ZipBytes {
        ZipBytes([.folder("project/"), .file("project/readme.md", "# Project\n"), .link("project/latest", to: "readme.md")])
    }

    // MARK: - What it lists

    @Test func itListsNamesKindsAndSizes() throws {
        #expect(try list(plain) == [
            ZipEntry(path: "project/", kind: .folder, uncompressedSize: 0),
            ZipEntry(path: "project/readme.md", kind: .file, uncompressedSize: 10),
            ZipEntry(path: "project/latest", kind: .symbolicLink, uncompressedSize: 9),
        ])
    }

    @Test func whatItBuildsIsAValidZipToInfoZipToo() throws {
        try withTemporaryFolder { folder in
            for (name, archive) in [("plain.zip", plain), ("zip64.zip", zip64Archive)] {
                let url = folder.appending(path: name)
                try Data(archive.bytes).write(to: url)
                let theirs = try ZipTools.zipinfoListing(of: url)
                let ours = try ZipListing.parse(archive.bytes).summaries
                #expect(theirs == ours, "\(name)")
            }
        }
    }

    @Test func kindsComeFromTheUnixModeOrTheDOSAttributes() throws {
        var unixFolder = Entry.file("noslash")
        unixFolder.externalAttributes = 0o040755 << 16
        var pipe = Entry.file("fifo")
        pipe.externalAttributes = 0o010644 << 16
        var dosFolder = Entry.file("DOSDIR")
        dosFolder.madeBy = 0x0014
        dosFolder.externalAttributes = 0x10
        var dosFile = Entry.file("DOSFILE.TXT", "abc")
        dosFile.madeBy = 0x0014
        dosFile.externalAttributes = 0x20
        var unixWithoutMode = Entry.file("nomode")
        unixWithoutMode.externalAttributes = 0x10

        #expect(try list(ZipBytes([unixFolder, pipe, dosFolder, dosFile, unixWithoutMode])).map(\.kind) == [.folder, .other, .folder, .file, .folder])
    }

    // MARK: - Zip64

    private var zip64Archive: ZipBytes {
        var big = Entry.file("disk.img", "sparse")
        big.zip64Sizes = true
        big.declaredSize = 4_831_838_208
        big.otherExtraFields = ZipBytes.infoZipExtraFields
        var archive = ZipBytes([big, .file("small.txt", "small")])
        archive.zip64End = true
        return archive
    }

    @Test func zip64SizesAndEndRecordsAreRead() throws {
        // The Zip64 field after Info-ZIP's own fields, as `zip -1` of a 4.5 GiB file writes it.
        #expect(try list(zip64Archive).map(\.uncompressedSize) == [4_831_838_208, 5])
    }

    @Test func aLocatorPushedOutOfTheTailByALongCommentIsStillFound() throws {
        var archive = zip64Archive
        archive.comment = [UInt8](repeating: 0x20, count: 0xFFFF)

        #expect(try list(archive).count == 2)
    }

    @Test func aZip64PlaceholderWithoutItsFieldIsDamaged() {
        var entry = Entry.file("big.bin", "x")
        entry.zip64Sizes = true
        var archive = ZipBytes([entry])
        // The directory's Zip64 field, which comes after the local header's, renamed to another field.
        var bytes = archive.bytes
        let field: [UInt8] = [0x01, 0x00, 0x10, 0x00]
        guard let start = bytes.ranges(of: field).last?.lowerBound else {
            Issue.record("no Zip64 field")
            return
        }
        bytes[start] = 0x99
        #expect(failure(bytes) == .unlistable(.damaged))

        archive.entries[0].declaredSize = UInt64(Int64.max) + 1
        #expect(failure(archive) == .unlistable(.damaged))
    }

    // MARK: - Limits, checked before anything is allocated

    @Test func millionsOfDeclaredEntriesAreRefusedAtOnce() {
        var archive = ZipBytes([.file("a.txt", "a")])
        archive.zip64End = true
        archive.declaredEntryCount = 10_000_000

        #expect(failure(archive) == .unlistable(.tooManyEntries))
    }

    @Test func theEntryCountNameLengthAndDirectorySizeHaveLimits() {
        let three = ZipBytes([.file("a.txt", "a"), .file("b.txt", "b"), .file("c.txt", "c")])
        #expect(failure(three, limits: ZipListing.Limits(maximumEntryCount: 2, maximumNameLength: 1_024, maximumDirectorySize: 1 << 20)) == .unlistable(.tooManyEntries))
        #expect(failure(three, limits: ZipListing.Limits(maximumEntryCount: 10, maximumNameLength: 1_024, maximumDirectorySize: 100)) == .unlistable(.tooManyEntries))
        #expect(failure(three, limits: ZipListing.Limits(maximumEntryCount: 10, maximumNameLength: 4, maximumDirectorySize: 1 << 20)) == .unlistable(.nameTooLong))

        let long = ZipBytes([.file(String(repeating: "n", count: 1_025), "x")])
        #expect(failure(long) == .unlistable(.nameTooLong))
        let longest = ZipBytes([.file(String(repeating: "n", count: 1_024), "x")])
        #expect(failure(longest) == nil)
    }

    // MARK: - Damage

    @Test func aTruncatedArchiveIsDamaged() {
        let bytes = plain.bytes
        #expect(failure(Array(bytes.dropLast(1))) == .unlistable(.damaged))
        #expect(failure(Array(bytes.prefix(bytes.count / 2))) == .unlistable(.damaged))
        #expect(failure([]) == .unlistable(.damaged))
        #expect(failure(Array("not a zip at all, just text".utf8)) == .unlistable(.damaged))
    }

    @Test func aDirectoryOutsideTheFileOrOverflowingIsDamaged() {
        var outside = plain
        outside.declaredDirectoryOffset = 1_000_000
        #expect(failure(outside) == .unlistable(.damaged))

        var overflowing = plain
        overflowing.zip64End = true
        overflowing.declaredDirectoryOffset = UInt64.max - 8
        #expect(failure(overflowing) == .unlistable(.damaged))

        var shorter = plain
        shorter.declaredDirectorySize = 10
        #expect(failure(shorter) == .unlistable(.damaged))
    }

    @Test func aRecordPastTheDeclaredDirectoryIsDamaged() {
        var archive = plain
        archive.declaredEntryCount = 4
        archive.declaredDirectorySize = nil
        #expect(failure(archive) == .unlistable(.damaged))

        var fewer = plain
        fewer.declaredEntryCount = 2
        #expect(failure(fewer) == .unlistable(.damaged))
    }

    @Test func bytesAfterTheEndRecordAreDamage() {
        var archive = plain
        archive.trailing = [0x00]

        #expect(failure(archive) == .unlistable(.damaged))
    }

    @Test func twoEndRecordsThatCouldBothBeTheEndAreDamage() {
        // A second end record hidden in the comment, which also reaches the last byte.
        var archive = plain
        archive.comment = ZipBytes.emptyEndRecord()

        #expect(failure(archive) == .unlistable(.damaged))
    }

    @Test func anEndRecordInTheCommentIsDamageEvenWhenItDoesNotReachTheEnd() {
        // Info-ZIP and ditto would take it, as the last end record in the file, and list other contents.
        var archive = plain
        archive.comment = ZipBytes.emptyEndRecord() + Array(" and more".utf8)

        #expect(failure(archive) == .unlistable(.damaged))
    }

    @Test func aZip64EndRecordMustAgreeWithTheClassicOne() throws {
        var archive = zip64Archive
        #expect(try list(archive).count == 2)

        archive.classicEntryCount = 1
        #expect(failure(archive) == .unlistable(.damaged))

        archive.classicEntryCount = 0xFFFF
        #expect(try list(archive).count == 2)

        archive.locatorDiskCount = 0
        #expect(failure(archive) == .unlistable(.damaged))
    }

    // MARK: - Local headers

    @Test func aLocalHeaderUnderAnotherNameIsDamage() {
        // ditto unpacks by the local headers: this one would write evil.txt, which nothing lists.
        var entry = Entry.file("one.txt", "secret")
        entry.localName = Array("evil.txt".utf8)

        #expect(failure(ZipBytes([entry])) == .unlistable(.damaged))
    }

    @Test func anEntryTheDirectoryDoesNotListIsDamage() {
        var archive = ZipBytes([.file("one.txt", "listed")])
        archive.unlisted = .file("secret.txt", "unpacked unseen")

        #expect(failure(archive) == .unlistable(.damaged))
    }

    @Test func twoRecordsSharingOneLocalHeaderAreDamage() {
        var second = Entry.file("b.txt", "bbbb")
        second.localOffset = 0
        let archive = ZipBytes([.file("a.txt", "aaaa"), second])

        #expect(failure(archive) == .unlistable(.damaged))
    }

    @Test func aDataDescriptorIsReadAndMustAgree() throws {
        var streamed = Entry.file("streamed.txt", "written before its size was known")
        streamed.flags = 0x0008
        #expect(try list(ZipBytes([streamed, .file("plain.txt", "plain")])).map(\.uncompressedSize) == [33, 5])

        streamed.descriptorCRC = 0x1234_5678
        #expect(failure(ZipBytes([streamed])) == .unlistable(.damaged))
    }

    @Test func aSplitArchiveIsDamaged() {
        var archive = plain
        archive.disk = 1

        #expect(failure(archive) == .unlistable(.damaged))
    }

    // MARK: - Encryption and names

    @Test func anEncryptedListingIsRefusedAsEncrypted() {
        var bytes = plain.bytes
        let directory: [UInt8] = [0x50, 0x4b, 0x01, 0x02]
        guard let start = bytes.firstRange(of: directory)?.lowerBound else {
            Issue.record("no directory")
            return
        }
        // PKWARE's archive extra data record, where an encrypted directory starts.
        bytes.replaceSubrange(start..<(start + 4), with: [0x50, 0x4b, 0x06, 0x08])

        #expect(failure(bytes) == .unlistable(.encryptedListing))
    }

    @Test func encryptedEntriesWithAReadableListingAreListed() throws {
        var entry = Entry.file("secret.txt", "secret contents")
        entry.flags = 0x0009

        #expect(try list(ZipBytes([entry])) == [ZipEntry(path: "secret.txt", kind: .file, uncompressedSize: 15)])
    }

    @Test func namesMustBeUTF8() throws {
        let legacy = Entry(name: [0x52, 0xE9, 0x73, 0x75, 0x6D, 0xE9])
        #expect(failure(ZipBytes([legacy])) == .unlistable(.unreadableNames))

        var flagged = legacy
        flagged.flags = 0x0800
        #expect(failure(ZipBytes([flagged])) == .unlistable(.damaged))

        // UTF-8 without the flag, as ditto writes it.
        #expect(try list(ZipBytes([.file("résumé – ✓.txt", "x")])).map(\.path) == ["résumé – ✓.txt"])
    }

    // MARK: - Cancellation

    @Test func aCancelledReadingStops() async {
        let bytes = plain.bytes
        // A task of its own, cancelled before it reads: never this test's own task.
        let reading = Task { () -> ZipListing.Failure? in
            while !Task.isCancelled {
                await Task.yield()
            }
            do throws(ZipListing.Failure) {
                _ = try ZipListing.parse(bytes)
                return nil
            } catch {
                return error
            }
        }
        reading.cancel()

        #expect(await reading.value == .cancelled)
    }
}
