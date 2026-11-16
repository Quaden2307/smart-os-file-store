import CryptoKit
import Foundation

/// Reads an installer package, a xar archive, in place and in memory (decision record 0013): the
/// 28-byte header, the table of contents (zlib-compressed XML), and only the `PackageInfo` members.
/// The payload, the scripts and `Distribution`, which can hold JavaScript, are never read.
///
/// Everything is bounded before it is allocated, every range is checked against the file, and every
/// checksum the archive gives is checked. A checksum detects damage; it proves nothing about who
/// made the file. The `xar` tool is deprecated in macOS 27 and `pkgutil --expand` copies the payload
/// out, so the reader is in-house.
public enum XarArchive {
    /// Why a package's parts could not be read.
    public enum Failure: Error, Sendable, Hashable {
        case problem(InstallerFacts.Problem)
        /// The file itself: missing, unreadable, changed.
        case file(ZipListing.Failure)
    }

    static let headerLength = 28
    static let maximumCompressedTableLength = 4 << 20
    static let maximumTableLength = 16 << 20
    static let maximumMemberLength = 1 << 20
    static let maximumFiles = 10_000
    static let maximumDepth = 32

    /// The parts of the package held in memory, such as one a test builds byte by byte.
    public static func packages(inBytes bytes: [UInt8]) throws(Failure) -> [PackageFacts] {
        try packages(in: InMemoryZipBytes(storage: bytes))
    }

    /// The parts of the package in `source`: the top-level `PackageInfo` of a component package, or
    /// each top-level `<name>.pkg/PackageInfo` of a product archive.
    static func packages(in source: some ZipByteSource) throws(Failure) -> [PackageFacts] {
        let table = try tableOfContents(in: source)
        var infos: [Member] = []
        for node in table.files {
            if node.name == "PackageInfo", node.isFile {
                infos.append(try member(node))
            } else if node.isDirectory, node.name?.lowercased().hasSuffix(".pkg") == true,
                      let info = node.children.first(where: { $0.name == "PackageInfo" && $0.isFile }) {
                infos.append(try member(info))
            }
        }
        guard !infos.isEmpty else {
            throw .problem(.damaged)
        }
        guard infos.count <= InstallerFacts.maximumPackages else {
            throw .problem(.tooLarge)
        }
        return try infos.map { info throws(Failure) in
            let bytes = try contents(of: info, heapStart: table.heapStart, in: source)
            do throws(InstallerFacts.Problem) {
                return try PackageInfo.parse(bytes)
            } catch {
                throw .problem(error)
            }
        }
    }

    // MARK: - The table of contents

    private struct Table {
        let heapStart: UInt64
        let files: [FileNode]
    }

    private static func tableOfContents(in source: some ZipByteSource) throws(Failure) -> Table {
        let header = try read(source, at: 0, count: headerLength)
        guard bigEndian(header, 0, 4) == 0x7861_7221,
              bigEndian(header, 6, 2) == 1,
              case let headerSize = bigEndian(header, 4, 2), headerSize >= UInt64(headerLength), headerSize <= 4_096 else {
            throw .problem(.damaged)
        }
        let compressedLength = bigEndian(header, 8, 8)
        let tableLength = bigEndian(header, 16, 8)
        guard compressedLength > 0, tableLength > 0 else {
            throw .problem(.damaged)
        }
        guard compressedLength <= UInt64(maximumCompressedTableLength), tableLength <= UInt64(maximumTableLength) else {
            throw .problem(.tooLarge)
        }
        let heapStart = headerSize + compressedLength
        guard heapStart <= source.byteCount else {
            throw .problem(.damaged)
        }
        let compressed = try read(source, at: headerSize, count: Int(compressedLength))
        guard let xml = Inflate.inflate(compressed, expectedSize: Int(tableLength), raw: false) else {
            throw .problem(.damaged)
        }
        let parser = TableParser()
        guard UntrustedXML.parse(xml, with: parser), !parser.refused else {
            throw .problem(parser.tooLarge ? .tooLarge : .damaged)
        }
        // The table's own checksum, in the heap, over the compressed table.
        let algorithm = bigEndian(header, 24, 4)
        if algorithm != 0 {
            guard let checksum = parser.tableChecksum,
                  let expectedStyle = checksumStyle(algorithm, header: header, source: source, headerSize: headerSize),
                  checksum.style == expectedStyle,
                  let range = heapRange(offset: checksum.offset, length: checksum.size, heapStart: heapStart, byteCount: source.byteCount),
                  let digest = digest(compressed, style: checksum.style) else {
                throw .problem(.damaged)
            }
            guard try read(source, at: range.offset, count: range.count) == digest else {
                throw .problem(.damaged)
            }
        }
        return Table(heapStart: heapStart, files: parser.roots)
    }

    /// The checksum algorithm the header names: 1 is SHA-1, 2 MD5, and 3 one named after the header's
    /// fixed part.
    private static func checksumStyle(_ algorithm: UInt64, header: [UInt8], source: some ZipByteSource, headerSize: UInt64) -> String? {
        switch algorithm {
        case 1: return "sha1"
        case 2: return "md5"
        case 3: break
        default: return nil
        }
        guard headerSize > UInt64(headerLength),
              let full = try? read(source, at: 0, count: Int(headerSize)),
              let name = String(validating: full[headerLength...].prefix { $0 != 0 }, as: UTF8.self) else {
            return nil
        }
        return name.lowercased()
    }

    // MARK: - Members

    private struct Member {
        let offset: UInt64
        let length: UInt64
        let size: UInt64
        let encoding: String
        let archivedChecksum: Checksum?
        let extractedChecksum: Checksum?
    }

    private static func member(_ node: FileNode) throws(Failure) -> Member {
        guard let offset = node.offset, let length = node.length, let size = node.size, let encoding = node.encoding else {
            throw .problem(.damaged)
        }
        guard length <= UInt64(maximumMemberLength), size <= UInt64(maximumMemberLength) else {
            throw .problem(.tooLarge)
        }
        return Member(offset: offset, length: length, size: size, encoding: encoding, archivedChecksum: node.archivedChecksum, extractedChecksum: node.extractedChecksum)
    }

    private static func contents(of member: Member, heapStart: UInt64, in source: some ZipByteSource) throws(Failure) -> [UInt8] {
        guard let range = heapRange(offset: member.offset, length: member.length, heapStart: heapStart, byteCount: source.byteCount) else {
            throw .problem(.damaged)
        }
        let stored = try read(source, at: range.offset, count: range.count)
        try verify(stored, against: member.archivedChecksum)
        let contents: [UInt8]
        switch member.encoding {
        case "application/octet-stream":
            guard member.length == member.size else {
                throw .problem(.damaged)
            }
            contents = stored
        case "application/x-gzip":
            guard let inflated = Inflate.inflate(stored, expectedSize: Int(member.size), raw: false) else {
                throw .problem(.damaged)
            }
            contents = inflated
        default:
            throw .problem(.unsupported)
        }
        try verify(contents, against: member.extractedChecksum)
        return contents
    }

    private static func verify(_ bytes: [UInt8], against checksum: Checksum?) throws(Failure) {
        guard let checksum else { return }
        guard let digest = digest(bytes, style: checksum.style),
              digest.map({ String(format: "%02x", $0) }).joined() == checksum.hex.lowercased() else {
            throw .problem(.damaged)
        }
    }

    // MARK: - Helpers

    static func digest(_ bytes: [UInt8], style: String) -> [UInt8]? {
        switch style {
        case "sha1": Array(Insecure.SHA1.hash(data: bytes))
        case "md5": Array(Insecure.MD5.hash(data: bytes))
        case "sha256": Array(SHA256.hash(data: bytes))
        case "sha512": Array(SHA512.hash(data: bytes))
        default: nil
        }
    }

    /// `length` bytes at `offset` in the heap, as an offset in the file, when they lie inside it.
    private static func heapRange(offset: UInt64, length: UInt64, heapStart: UInt64, byteCount: UInt64) -> (offset: UInt64, count: Int)? {
        let (start, overflow) = heapStart.addingReportingOverflow(offset)
        guard !overflow, start <= byteCount, length <= byteCount - start, let count = Int(exactly: length) else {
            return nil
        }
        return (start, count)
    }

    private static func read(_ source: some ZipByteSource, at offset: UInt64, count: Int) throws(Failure) -> [UInt8] {
        do throws(ZipListing.Failure) {
            return try source.bytes(at: offset, count: count)
        } catch {
            if case .unlistable = error {
                throw .problem(.damaged)
            }
            throw .file(error)
        }
    }

    private static func bigEndian(_ bytes: [UInt8], _ offset: Int, _ length: Int) -> UInt64 {
        bytes[offset..<(offset + length)].reduce(0) { $0 << 8 | UInt64($1) }
    }
}

/// A checksum the table of contents gives: the algorithm's name and the digest in hex.
private struct Checksum {
    let style: String
    var hex = ""
}

/// One `<file>` of the table of contents.
private final class FileNode {
    var name: String?
    var type: String?
    var offset: UInt64?
    var length: UInt64?
    var size: UInt64?
    var encoding: String?
    var archivedChecksum: Checksum?
    var extractedChecksum: Checksum?
    var children: [FileNode] = []

    var isFile: Bool { type == "file" }
    var isDirectory: Bool { type == "directory" }
}

/// Builds the file tree of a table of contents. Only a file's own `<name>`, `<type>` and `<data>`
/// count: the same words inside an extended attribute (`<ea>`) describe the attribute.
private final class TableParser: NSObject, XMLParserDelegate {
    private(set) var roots: [FileNode] = []
    private(set) var tableChecksum: (style: String, offset: UInt64, size: UInt64)?
    private(set) var refused = false
    private(set) var tooLarge = false

    private var elements: [String] = []
    private var files: [FileNode] = []
    private var fileCount = 0
    private var text = ""
    private var checksumStyle: String?
    private var checksumOffset: UInt64?
    private var checksumSize: UInt64?

    func parser(_ parser: XMLParser, didStartElement name: String, namespaceURI: String?, qualifiedName: String?, attributes: [String: String] = [:]) {
        text = ""
        if name == "file" {
            fileCount += 1
            guard fileCount <= XarArchive.maximumFiles, files.count < XarArchive.maximumDepth else {
                tooLarge = true
                refuse(parser)
                return
            }
            files.append(FileNode())
        } else if let file = files.last, elements.last == "data", name == "encoding" {
            file.encoding = attributes["style"]
        } else if let file = files.last, elements.last == "data", name == "archived-checksum" {
            file.archivedChecksum = attributes["style"].map { Checksum(style: $0) }
        } else if let file = files.last, elements.last == "data", name == "extracted-checksum" {
            file.extractedChecksum = attributes["style"].map { Checksum(style: $0) }
        } else if name == "checksum", elements == ["xar", "toc"] {
            checksumStyle = attributes["style"]
        }
        elements.append(name)
    }

    func parser(_ parser: XMLParser, foundCharacters string: String) {
        text += string
        if text.utf8.count > 4_096 {
            refuse(parser)
        }
    }

    func parser(_ parser: XMLParser, didEndElement name: String, namespaceURI: String?, qualifiedName: String?) {
        elements.removeLast()
        let value = text.trimmingCharacters(in: .whitespacesAndNewlines)
        text = ""
        let parent = elements.last
        if name == "file", let file = files.popLast() {
            if let owner = files.last {
                owner.children.append(file)
            } else {
                roots.append(file)
            }
            return
        }
        if elements == ["xar", "toc", "checksum"] {
            switch name {
            case "offset": checksumOffset = UInt64(value)
            case "size": checksumSize = UInt64(value)
            default: break
            }
            if let checksumStyle, let checksumOffset, let checksumSize {
                tableChecksum = (checksumStyle, checksumOffset, checksumSize)
            }
            return
        }
        guard let file = files.last else { return }
        switch (parent, name) {
        case ("file", "name"):
            // Some archives give a file's name twice; two different names are one too many.
            if let existing = file.name, existing != value {
                refuse(parser)
            }
            file.name = value
        case ("file", "type"):
            file.type = value
        case ("data", "offset"):
            file.offset = UInt64(value)
        case ("data", "length"):
            file.length = UInt64(value)
        case ("data", "size"):
            file.size = UInt64(value)
        case ("data", "archived-checksum"):
            file.archivedChecksum?.hex = value
        case ("data", "extracted-checksum"):
            file.extractedChecksum?.hex = value
        default:
            break
        }
    }

    private func refuse(_ parser: XMLParser) {
        refused = true
        parser.abortParsing()
    }
}
