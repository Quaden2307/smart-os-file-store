import FileStoreCore
import Foundation
import Testing

/// Reading last opened and the download source from real extended attributes, written by the test
/// the way macOS writes them, and decoding malformed ones as nil, never as an error.
@Suite("ExtendedAttributeMetadataReader")
struct ExtendedAttributeMetadataReaderTests {
    private typealias Reader = ExtendedAttributeMetadataReader

    private let reader = ExtendedAttributeMetadataReader()

    /// 2025-02-01 09:00:00.25 UTC.
    private static let openedAt = Date(timeIntervalSince1970: 1_738_400_400.25)
    private static let sources = ["https://example.com/files/report.pdf", "https://www.example.com/reports"]

    /// A fresh file in a fresh temporary folder, removed afterwards.
    private func withFile(_ body: (URL) throws -> Void) throws {
        try withTemporaryFolder { folder in
            let file = folder.appending(path: "file.pdf")
            try Data("contents".utf8).write(to: file)
            try body(file)
        }
    }

    /// The 16-byte value Launch Services writes: seconds and nanoseconds, little-endian.
    private static func timespec(seconds: Int64, nanoseconds: Int64) -> Data {
        var value = Data()
        withUnsafeBytes(of: seconds.littleEndian) { value.append(contentsOf: $0) }
        withUnsafeBytes(of: nanoseconds.littleEndian) { value.append(contentsOf: $0) }
        return value
    }

    private static func plist(_ object: Any) throws -> Data {
        try PropertyListSerialization.data(fromPropertyList: object, format: .binary, options: 0)
    }

    // MARK: - Real attributes

    @Test func readsAttributesWrittenTheWayMacOSWritesThem() throws {
        try withFile { file in
            try ExtendedAttributes.setLastUsedDate(Self.openedAt, on: file)
            try ExtendedAttributes.setWhereFroms(Self.sources, on: file)
            try ExtendedAttributes.setQuarantine(ExtendedAttributes.quarantineValue(app: "Google Chrome", downloadedAt: Self.openedAt), on: file)

            let metadata = reader.metadata(for: file)

            #expect(metadata.lastOpened == Self.openedAt)
            let source = try #require(metadata.downloadSource)
            #expect(source.addresses == Self.sources)
            #expect(source.downloadingApp == "Google Chrome")
            #expect(source.fileAddress == Self.sources[0])
            #expect(source.site == "example.com")
        }
    }

    /// No attributes: never opened, as far as anyone can tell, and no source.
    @Test func fileWithoutAttributesHasNoMetadata() throws {
        try withFile { file in
            let metadata = reader.metadata(for: file)
            #expect(metadata == FileMetadata())
            #expect(metadata.canReadLastOpened)
        }
    }

    /// An item that went away between the listing and the read: nothing could be read, so its
    /// missing date means unknown, not never opened.
    @Test func missingItemCannotBeRead() throws {
        try withTemporaryFolder { folder in
            #expect(reader.metadata(for: folder.appending(path: "gone.pdf")) == FileMetadata(canReadLastOpened: false))
        }
    }

    /// Permission refused on the way to the item: unknown, not never opened.
    @Test func refusedPermissionCannotBeRead() throws {
        try withTemporaryFolder { folder in
            let sealed = folder.appending(path: "sealed", directoryHint: .isDirectory)
            try FileManager.default.createDirectory(at: sealed, withIntermediateDirectories: false)
            let file = sealed.appending(path: "file.pdf")
            try Data("contents".utf8).write(to: file)
            try ExtendedAttributes.setLastUsedDate(Self.openedAt, on: file)
            let sealedPath = sealed.path(percentEncoded: false)
            try FileManager.default.setAttributes([.posixPermissions: 0o000], ofItemAtPath: sealedPath)
            defer { try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: sealedPath) }

            let metadata = reader.metadata(for: file)

            #expect(metadata.lastOpened == nil)
            #expect(!metadata.canReadLastOpened)
            #expect(metadata.downloadSource == nil)
        }
    }

    @Test func eachSourceAttributeWorksAlone() throws {
        try withFile { file in
            try ExtendedAttributes.setWhereFroms(Self.sources, on: file)
            let source = try #require(reader.metadata(for: file).downloadSource)
            #expect(source.addresses == Self.sources)
            #expect(source.downloadingApp == nil)
        }
        try withFile { file in
            // AirDrop and Messages record the app but no address.
            try ExtendedAttributes.setQuarantine("0082;6735f2a1;sharingd;", on: file)
            let source = try #require(reader.metadata(for: file).downloadSource)
            #expect(source.addresses.isEmpty)
            #expect(source.downloadingApp == "sharingd")
            #expect(source.site == nil)
        }
    }

    /// A link is described itself: its target's attributes are never read.
    @Test func symbolicLinkIsNotFollowed() throws {
        try withFile { file in
            try ExtendedAttributes.setLastUsedDate(Self.openedAt, on: file)
            try ExtendedAttributes.setWhereFroms(Self.sources, on: file)
            let link = file.deletingLastPathComponent().appending(path: "link.pdf")
            try FileManager.default.createSymbolicLink(atPath: link.path(percentEncoded: false), withDestinationPath: file.lastPathComponent)

            let linkMetadata = reader.metadata(for: link)
            #expect(linkMetadata == FileMetadata())
            #expect(linkMetadata.canReadLastOpened)
            #expect(reader.metadata(for: file).lastOpened == Self.openedAt)
        }
    }

    @Test func folderAttributesAreRead() throws {
        try withTemporaryFolder { folder in
            let subfolder = folder.appending(path: "Folder", directoryHint: .isDirectory)
            try FileManager.default.createDirectory(at: subfolder, withIntermediateDirectories: false)
            try ExtendedAttributes.setLastUsedDate(Self.openedAt, on: subfolder)
            #expect(reader.metadata(for: subfolder).lastOpened == Self.openedAt)
        }
    }

    // MARK: - Malformed attributes on disk

    @Test func malformedAttributesReadAsNil() throws {
        try withFile { file in
            try ExtendedAttributes.setRaw(Data(repeating: 7, count: 15), name: Reader.lastUsedDateName, on: file)
            try ExtendedAttributes.setRaw(Data("not a property list".utf8), name: Reader.whereFromsName, on: file)
            try ExtendedAttributes.setRaw(Data("garbage".utf8), name: Reader.quarantineName, on: file)

            // Malformed is not unreadable: the attribute was there, so "no date" stands.
            #expect(reader.metadata(for: file) == FileMetadata())
        }
    }

    /// A value larger than the reader accepts is ignored, however well-formed.
    @Test func oversizedWhereFromsIsIgnored() throws {
        try withFile { file in
            let huge = "https://example.com/" + String(repeating: "a", count: 70 * 1_024)
            try ExtendedAttributes.setWhereFroms([huge], on: file)
            #expect(reader.metadata(for: file).downloadSource == nil)
        }
    }

    /// A value larger than the first buffer but inside the limit takes the second read.
    @Test func whereFromsLargerThanTheFirstBufferIsRead() throws {
        try withFile { file in
            let long = "https://example.com/" + String(repeating: "b", count: 4 * 1_024)
            try ExtendedAttributes.setWhereFroms([long, "https://example.com/page"], on: file)
            #expect(reader.metadata(for: file).downloadSource?.addresses == [long, "https://example.com/page"])
        }
    }

    @Test func readingChangesNothing() throws {
        try withFile { file in
            try ExtendedAttributes.setLastUsedDate(Self.openedAt, on: file)
            let path = file.path(percentEncoded: false)
            var before = stat()
            #expect(lstat(path, &before) == 0)

            _ = reader.metadata(for: file)

            var after = stat()
            #expect(lstat(path, &after) == 0)
            #expect(after.st_ctimespec.tv_sec == before.st_ctimespec.tv_sec)
            #expect(after.st_ctimespec.tv_nsec == before.st_ctimespec.tv_nsec)
            #expect(after.st_mtimespec.tv_sec == before.st_mtimespec.tv_sec)
            #expect(after.st_mtimespec.tv_nsec == before.st_mtimespec.tv_nsec)
            #expect(ExtendedAttributes.lastUsedDate(of: file) == Self.openedAt)
        }
    }

    // MARK: - Decoders

    @Test func lastUsedDateDecoding() {
        #expect(Reader.lastUsedDate(from: Self.timespec(seconds: 1_738_400_400, nanoseconds: 250_000_000)) == Self.openedAt)
        #expect(Reader.lastUsedDate(from: Self.timespec(seconds: 1_738_400_400, nanoseconds: 0)) == Date(timeIntervalSince1970: 1_738_400_400))

        // Wrong sizes
        #expect(Reader.lastUsedDate(from: Data()) == nil)
        #expect(Reader.lastUsedDate(from: Data(repeating: 1, count: 15)) == nil)
        #expect(Reader.lastUsedDate(from: Self.timespec(seconds: 1_738_400_400, nanoseconds: 0) + Data([0])) == nil)
        // Nanoseconds out of range, and times Launch Services never writes
        #expect(Reader.lastUsedDate(from: Self.timespec(seconds: 1_738_400_400, nanoseconds: 1_000_000_000)) == nil)
        #expect(Reader.lastUsedDate(from: Self.timespec(seconds: 1_738_400_400, nanoseconds: -1)) == nil)
        #expect(Reader.lastUsedDate(from: Self.timespec(seconds: 0, nanoseconds: 0)) == nil)
        #expect(Reader.lastUsedDate(from: Self.timespec(seconds: -86_400, nanoseconds: 0)) == nil)
    }

    @Test func whereFromsDecoding() throws {
        #expect(Reader.whereFroms(from: try Self.plist(Self.sources)) == Self.sources)
        let xml = try PropertyListSerialization.data(fromPropertyList: Self.sources, format: .xml, options: 0)
        #expect(Reader.whereFroms(from: xml) == Self.sources)
        // Blank and non-string entries are dropped; the rest keep their order.
        #expect(Reader.whereFroms(from: try Self.plist(["", "https://a.example/x", 42, "  ", "b"] as [Any])) == ["https://a.example/x", "b"])

        #expect(Reader.whereFroms(from: Data()) == [])
        #expect(Reader.whereFroms(from: Data("not a property list".utf8)) == [])
        #expect(Reader.whereFroms(from: try Self.plist(["key": "https://example.com"])) == [])
        #expect(Reader.whereFroms(from: try Self.plist([1, 2, 3])) == [])
        #expect(Reader.whereFroms(from: try Self.plist([String]())) == [])
        #expect(Reader.whereFroms(from: try Self.plist("https://example.com")) == [])
    }

    @Test func quarantineAgentDecoding() {
        func agent(_ text: String) -> String? {
            Reader.quarantineAgent(from: Data(text.utf8))
        }
        #expect(agent("0083;6735f2a1;Safari;0B5E6C1A-1111-2222-3333-444455556666") == "Safari")
        #expect(agent("0081;6735f2a1;Google Chrome;") == "Google Chrome")
        #expect(agent("0081;6735f2a1;Firefox") == "Firefox")
        #expect(agent("0083;6735f2a1;Safari;uuid\0") == "Safari")

        #expect(agent("") == nil)
        #expect(agent("garbage") == nil)
        #expect(agent("0083;6735f2a1") == nil)
        #expect(agent("zz83;6735f2a1;Safari;uuid") == nil)
        #expect(agent(";6735f2a1;Safari;uuid") == nil)
        #expect(agent("0083;6735f2a1;;uuid") == nil)
        #expect(agent("0083;6735f2a1;   ;uuid") == nil)
        #expect(Reader.quarantineAgent(from: Data([0x30, 0x30, 0x3B, 0xFF, 0xFE, 0x3B, 0x41])) == nil)
    }
}
