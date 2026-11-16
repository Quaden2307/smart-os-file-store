import CryptoKit
import Foundation
import zlib

/// Installer packages (xar archives) built byte by byte for the package reader's tests, so they can
/// hold what `pkgbuild` never writes: bad checksums, huge declared lengths, a document type, members
/// outside the file. Without overrides the archive is valid to the `xar` tool too (`XarArchiveTests`
/// checks that).
struct XarBytes {
    enum Encoding {
        case none
        case gzip
        /// Declared as bzip2, which the reader does not read.
        case bzip2
    }

    indirect enum Item {
        case file(String, [UInt8], Encoding)
        case directory(String, [Item])
    }

    var items: [Item]
    /// Replaces the whole table of contents.
    var tableOverride: String?
    /// The uncompressed table length the header declares instead of the truth.
    var declaredTableLength: UInt64?
    var corruptTableChecksum = false
    var corruptMemberChecksums = false
    /// Added to every member's offset.
    var offsetShift: UInt64 = 0

    init(_ items: [Item]) {
        self.items = items
    }

    /// A component package holding only `PackageInfo`.
    static func component(_ packageInfo: String, encoding: Encoding = .gzip) -> XarBytes {
        XarBytes([.file("PackageInfo", Array(packageInfo.utf8), encoding)])
    }

    /// A `PackageInfo` for `identifier` at `version`, installing `apps` (path, bundle id, version).
    static func packageInfo(identifier: String, version: String, apps: [(path: String, id: String, version: String)] = []) -> String {
        let bundles = apps.map { "    <bundle path=\"\($0.path)\" id=\"\($0.id)\" CFBundleShortVersionString=\"\($0.version)\" CFBundleVersion=\"1\"/>" }
        return """
            <?xml version="1.0" encoding="utf-8"?>
            <pkg-info format-version="2" identifier="\(identifier)" version="\(version)" install-location="/Applications" auth="root">
            \(bundles.joined(separator: "\n"))
            </pkg-info>
            """
    }

    func bytes() -> [UInt8] {
        var heap = [UInt8](repeating: 0, count: 20)
        var nextID = 1
        func xml(for items: [Item]) -> String {
            items.map { item in
                defer { nextID += 1 }
                switch item {
                case .directory(let name, let children):
                    return "<file id=\"\(nextID)\"><name>\(name)</name><type>directory</type>\(xml(for: children))</file>"
                case .file(let name, let data, let encoding):
                    let stored = encoding == .none ? data : Self.zlib(data)
                    let offset = UInt64(heap.count) + offsetShift
                    heap += stored
                    let style = switch encoding {
                    case .none: "application/octet-stream"
                    case .gzip: "application/x-gzip"
                    case .bzip2: "application/x-bzip2"
                    }
                    let archived = corruptMemberChecksums ? String(repeating: "0", count: 40) : Self.sha1(stored)
                    return """
                        <file id="\(nextID)"><name>\(name)</name><type>file</type><data>\
                        <archived-checksum style="sha1">\(archived)</archived-checksum>\
                        <extracted-checksum style="sha1">\(Self.sha1(data))</extracted-checksum>\
                        <encoding style="\(style)"/><size>\(data.count)</size><offset>\(offset)</offset><length>\(stored.count)</length>\
                        </data></file>
                        """
                }
            }.joined()
        }
        let files = xml(for: items)
        let table = tableOverride ?? """
            <?xml version="1.0" encoding="UTF-8"?>
            <xar><toc><checksum style="sha1"><size>20</size><offset>0</offset></checksum>\(files)</toc></xar>
            """
        let tableBytes = Array(table.utf8)
        let compressed = Self.zlib(tableBytes)
        var digest = Array(Insecure.SHA1.hash(data: compressed))
        if corruptTableChecksum {
            digest[0] ^= 0xFF
        }
        heap.replaceSubrange(0..<20, with: digest)

        var header: [UInt8] = Array("xar!".utf8)
        header += Self.bigEndian(UInt64(28), length: 2)
        header += Self.bigEndian(UInt64(1), length: 2)
        header += Self.bigEndian(UInt64(compressed.count), length: 8)
        header += Self.bigEndian(declaredTableLength ?? UInt64(tableBytes.count), length: 8)
        header += Self.bigEndian(UInt64(1), length: 4)
        return header + compressed + heap
    }

    /// `data` compressed as zlib writes it, header and Adler-32 included: what xar calls gzip.
    static func zlib(_ data: [UInt8]) -> [UInt8] {
        var length = compressBound(UInt(data.count))
        var output = [UInt8](repeating: 0, count: Int(length))
        let status = output.withUnsafeMutableBufferPointer { destination in
            data.withUnsafeBufferPointer { source in
                compress2(destination.baseAddress, &length, source.baseAddress, UInt(source.count), Z_BEST_COMPRESSION)
            }
        }
        precondition(status == Z_OK, "zlib could not compress test data")
        return Array(output.prefix(Int(length)))
    }

    private static func sha1(_ data: [UInt8]) -> String {
        Insecure.SHA1.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    private static func bigEndian(_ value: UInt64, length: Int) -> [UInt8] {
        (0..<length).reversed().map { UInt8(truncatingIfNeeded: value >> (8 * UInt64($0))) }
    }
}
