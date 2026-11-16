import Foundation

/// Zip archives built byte by byte for the reader's tests, so they can hold what real tools never
/// write: counts in the millions, offsets past the end, two end records, names in a legacy encoding,
/// local headers that disagree with the directory. Each entry is stored uncompressed with its local
/// header and bytes, so an archive built without overrides is a valid zip to Info-ZIP too
/// (`ZipListingTests` checks that with `zipinfo`).
struct ZipBytes {
    struct Entry {
        var name: [UInt8]
        var data: [UInt8] = []
        /// The maker in the high byte: Unix (3), as ditto and Info-ZIP write it, or MS-DOS (0).
        var madeBy: UInt16 = 0x0314
        /// With bit 3 (0x0008), the CRC and sizes follow the data in a data descriptor, as ditto
        /// writes them, and the local header holds zeros.
        var flags: UInt16 = 0
        /// A Unix mode in the high half, MS-DOS attributes in the low byte.
        var externalAttributes: UInt32 = 0o100644 << 16
        /// 0xFFFFFFFF in the size fields, and the sizes in Zip64 extra fields, locally and in the
        /// directory.
        var zip64Sizes = false
        /// The uncompressed size to declare instead of the data's.
        var declaredSize: UInt64?
        /// Extra fields before any Zip64 field: Info-ZIP writes its timestamps and owner first.
        var otherExtraFields: [UInt8] = []
        /// The name the local header gives, instead of `name`.
        var localName: [UInt8]?
        /// The local header offset the directory gives, instead of the real one.
        var localOffset: UInt32?
        /// The CRC the data descriptor gives, instead of the real one.
        var descriptorCRC: UInt32?

        static func file(_ name: String, _ text: String = "") -> Entry {
            Entry(name: Array(name.utf8), data: Array(text.utf8))
        }

        static func folder(_ name: String) -> Entry {
            Entry(name: Array(name.utf8), externalAttributes: (0o040755 << 16) | 0x10)
        }

        static func link(_ name: String, to target: String) -> Entry {
            Entry(name: Array(name.utf8), data: Array(target.utf8), externalAttributes: 0o120755 << 16)
        }
    }

    var entries: [Entry]
    /// A Zip64 end record and its locator before the end record, as Info-ZIP writes for input it
    /// reads from standard input.
    var zip64End = false
    var comment: [UInt8] = []
    /// Bytes after the end record's comment.
    var trailing: [UInt8] = []
    /// An entry before the listed ones that the directory does not list.
    var unlisted: Entry?
    /// What the end records declare instead of the truth.
    var declaredEntryCount: UInt64?
    var declaredDirectorySize: UInt64?
    var declaredDirectoryOffset: UInt64?
    /// The entry count the classic end record gives beside a Zip64 one, instead of the same count.
    var classicEntryCount: UInt16?
    /// The disks the Zip64 locator counts.
    var locatorDiskCount: UInt32 = 1
    /// The disk numbers the end record gives; anything but 0 is part of a split archive.
    var disk: UInt16 = 0

    init(_ entries: [Entry]) {
        self.entries = entries
    }

    /// Info-ZIP's timestamp (UT) and owner (ux) extra fields, in the sizes it writes in a central
    /// directory: what comes before its Zip64 field (probed in segment 8 with `zip -1`).
    static let infoZipExtraFields: [UInt8] =
        littleEndian(UInt16(0x5455)) + littleEndian(UInt16(5)) + [0x03, 0x00, 0x00, 0x00, 0x00]
            + littleEndian(UInt16(0x7875)) + littleEndian(UInt16(11)) + [0x01, 0x04, 0xF5, 0x01, 0x00, 0x00, 0x04, 0x14, 0x00, 0x00, 0x00]

    var bytes: [UInt8] {
        var archive: [UInt8] = []
        if let unlisted {
            archive += Self.local(unlisted)
        }
        var directory: [UInt8] = []
        for entry in entries {
            let offset = entry.localOffset ?? UInt32(archive.count)
            archive += Self.local(entry)

            let declared = entry.declaredSize ?? UInt64(entry.data.count)
            var extra = entry.otherExtraFields
            if entry.zip64Sizes {
                extra += le(UInt16(0x0001)) + le(UInt16(16)) + le(declared) + le(UInt64(entry.data.count))
            }
            let storedSize = UInt32(entry.data.count)
            directory += le(UInt32(0x0201_4b50)) + le(entry.madeBy) + le(UInt16(entry.zip64Sizes ? 45 : 20)) + le(entry.flags)
            directory += le(UInt16(0)) + le(UInt16(0)) + le(UInt16(0x21)) + le(Self.crc32(entry.data))
            directory += le(entry.zip64Sizes ? UInt32.max : storedSize) + le(entry.zip64Sizes ? UInt32.max : UInt32(truncatingIfNeeded: declared))
            directory += le(UInt16(entry.name.count)) + le(UInt16(extra.count)) + le(UInt16(0)) + le(UInt16(0)) + le(UInt16(0))
            directory += le(entry.externalAttributes) + le(offset) + entry.name + extra
        }
        let directoryOffset = UInt64(archive.count)
        archive += directory
        let count = declaredEntryCount ?? UInt64(entries.count)
        let size = declaredDirectorySize ?? UInt64(directory.count)
        let start = declaredDirectoryOffset ?? directoryOffset
        if zip64End {
            let recordOffset = UInt64(archive.count)
            archive += le(UInt32(0x0606_4b50)) + le(UInt64(44)) + le(UInt16(45)) + le(UInt16(45)) + le(UInt32(0)) + le(UInt32(0))
            archive += le(count) + le(count) + le(size) + le(start)
            archive += le(UInt32(0x0706_4b50)) + le(UInt32(0)) + le(recordOffset) + le(locatorDiskCount)
        }
        let classicCount = classicEntryCount ?? UInt16(clamping: count)
        archive += le(UInt32(0x0605_4b50)) + le(disk) + le(disk) + le(classicCount) + le(classicCount)
        archive += le(UInt32(clamping: size)) + le(UInt32(clamping: start)) + le(UInt16(comment.count)) + comment
        return archive + trailing
    }

    /// An entry's local header, its data, and its data descriptor when its flags call for one.
    private static func local(_ entry: Entry) -> [UInt8] {
        let crc = crc32(entry.data)
        let storedSize = UInt32(entry.data.count)
        let declared = entry.declaredSize ?? UInt64(entry.data.count)
        let streamed = entry.flags & 0x0008 != 0
        let name = entry.localName ?? entry.name
        var header = le(UInt32(0x0403_4b50)) + le(UInt16(20)) + le(entry.flags) + le(UInt16(0)) + le(UInt16(0)) + le(UInt16(0x21))
        var extra: [UInt8] = []
        if entry.zip64Sizes {
            header += le(streamed ? 0 : crc) + le(UInt32.max) + le(UInt32.max)
            extra = le(UInt16(0x0001)) + le(UInt16(16)) + le(declared) + le(UInt64(entry.data.count))
        } else if streamed {
            header += le(UInt32(0)) + le(UInt32(0)) + le(UInt32(0))
        } else {
            header += le(crc) + le(storedSize) + le(UInt32(truncatingIfNeeded: declared))
        }
        header += le(UInt16(name.count)) + le(UInt16(extra.count)) + name + extra
        var bytes = header + entry.data
        if streamed {
            bytes += le(UInt32(0x0807_4b50)) + le(entry.descriptorCRC ?? crc) + le(storedSize) + le(UInt32(truncatingIfNeeded: declared))
        }
        return bytes
    }

    /// An end record with no comment, for an archive that hides one in its own comment.
    static func emptyEndRecord() -> [UInt8] {
        le(UInt32(0x0605_4b50)) + [UInt8](repeating: 0, count: 18)
    }

    /// CRC-32 (IEEE), so Info-ZIP accepts what is built.
    private static func crc32(_ bytes: [UInt8]) -> UInt32 {
        var crc: UInt32 = 0xFFFF_FFFF
        for byte in bytes {
            crc ^= UInt32(byte)
            for _ in 0..<8 {
                crc = (crc >> 1) ^ (0xEDB8_8320 & (0 &- (crc & 1)))
            }
        }
        return ~crc
    }

    static func littleEndian<Value: FixedWidthInteger>(_ value: Value) -> [UInt8] {
        withUnsafeBytes(of: value.littleEndian) { Array($0) }
    }
}

private func le<Value: FixedWidthInteger>(_ value: Value) -> [UInt8] {
    ZipBytes.littleEndian(value)
}
