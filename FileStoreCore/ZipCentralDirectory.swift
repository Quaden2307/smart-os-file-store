import Foundation

/// The bytes of an archive, by offset: a zip on disk, or bytes held in memory.
protocol ZipByteSource {
    /// How many bytes the archive has.
    var byteCount: UInt64 { get }

    /// Exactly `count` bytes from `offset`. An archive shorter than that is damaged.
    func bytes(at offset: UInt64, count: Int) throws(ZipListing.Failure) -> [UInt8]
}

/// An archive held in memory.
struct InMemoryZipBytes: ZipByteSource {
    let storage: [UInt8]

    var byteCount: UInt64 { UInt64(storage.count) }

    func bytes(at offset: UInt64, count: Int) throws(ZipListing.Failure) -> [UInt8] {
        guard count >= 0, let start = Int(exactly: offset), start <= storage.count, count <= storage.count - start else {
            throw .unlistable(.damaged)
        }
        return Array(storage[start..<(start + count)])
    }
}

/// Reads a zip archive's list of contents, as the PKWARE APPNOTE (6.3.10) lays it out: the end
/// record, the Zip64 end records when there are any, each entry's name, kind and uncompressed size
/// from the central directory, and then the local headers, to make sure they say the same.
/// Nothing is extracted: no file data is read, only the headers around it.
///
/// It is strict wherever an archive could be read two ways (decision record 0011), because tools
/// differ in where they look. Info-ZIP and ditto take the last end record they find; ditto unpacks
/// by the local headers, in the order they come. So the last end record must end at the last byte,
/// the Zip64 and the classic end records must agree, the directory must sit right before them with
/// exactly the entries and bytes it declares, and the local headers must carry the directory's
/// names and follow one another from the first byte to the directory, with nothing in between.
/// Anything else is `.damaged`, never guessed at.
enum ZipCentralDirectory {
    private static let endRecordSignature: UInt32 = 0x0605_4b50
    private static let endRecordLength = 22
    private static let longestComment = 0xFFFF
    private static let zip64LocatorSignature: UInt32 = 0x0706_4b50
    private static let zip64LocatorLength = 20
    private static let zip64RecordSignature: UInt32 = 0x0606_4b50
    /// The Zip64 end record without its extensible data: signature, size, then 44 bytes of fields.
    private static let zip64RecordLength = 56
    private static let entrySignature: UInt32 = 0x0201_4b50
    private static let entryLength = 46
    private static let localHeaderSignature: UInt32 = 0x0403_4b50
    private static let localHeaderLength = 30
    private static let dataDescriptorSignature: UInt32 = 0x0807_4b50
    /// PKWARE's archive extra data record, which comes right before a directory it encrypted.
    private static let archiveExtraDataSignature: UInt32 = 0x0806_4b50
    /// The Zip64 extended information extra field.
    private static let zip64ExtraFieldID: UInt16 = 0x0001
    /// A field whose real value is in the Zip64 extra field or the Zip64 end record.
    private static let placeholder32: UInt32 = 0xFFFF_FFFF
    private static let placeholder16: UInt16 = 0xFFFF
    /// General purpose bit 3: the CRC and sizes follow the data, in a data descriptor.
    private static let dataDescriptorFlag: UInt16 = 0x0008
    /// General purpose bit 0: the entry is encrypted.
    private static let encryptedFlag: UInt16 = 0x0001
    private static let storedMethod: UInt16 = 0
    private static let deflatedMethod: UInt16 = 8
    /// General purpose bit 11: the archive says its names are UTF-8.
    private static let utf8NamesFlag: UInt16 = 0x0800
    /// The makers whose external attributes hold a Unix mode: Unix (ditto, Info-ZIP) and macOS.
    private static let unixHosts: Set<UInt16> = [3, 19]
    private static let dosDirectoryAttribute: UInt32 = 0x10
    /// Entries read between cancellation checks.
    private static let cancellationCheckInterval = 1_024

    /// Every entry of the archive in `source`, in the order the directory lists them.
    static func entries(in source: some ZipByteSource, limits: ZipListing.Limits) throws(ZipListing.Failure) -> [ZipEntry] {
        try records(in: source, limits: limits).map(\.entry)
    }

    /// Every record of the archive in `source`, checked as `entries` describes.
    static func records(in source: some ZipByteSource, limits: ZipListing.Limits) throws(ZipListing.Failure) -> [Record] {
        let end = try endOfDirectory(in: source)
        // The limits, before anything is allocated for the entries or the directory is read.
        guard end.entryCount <= UInt64(limits.maximumEntryCount), end.directorySize <= UInt64(limits.maximumDirectorySize) else {
            throw .unlistable(.tooManyEntries)
        }
        let (directoryEnd, overflow) = end.directoryOffset.addingReportingOverflow(end.directorySize)
        guard !overflow,
              directoryEnd == end.directoryEnd,
              let count = Int(exactly: end.entryCount),
              let size = Int(exactly: end.directorySize) else {
            throw .unlistable(.damaged)
        }
        // Every entry takes at least its fixed part.
        let (smallest, tooMany) = count.multipliedReportingOverflow(by: entryLength)
        guard !tooMany, size >= smallest else {
            throw .unlistable(.damaged)
        }
        let directory = LittleEndianBytes(try source.bytes(at: end.directoryOffset, count: size))
        let records = try readRecords(directory, count: count, limits: limits)
        try checkLocalHeaders(records, in: source, directoryOffset: end.directoryOffset)
        return records
    }

    /// The unpacked bytes of `record`'s entry, read only when it is a file, not encrypted, stored or
    /// deflated, and at most `maximumSize` bytes packed and unpacked; nil otherwise. Deflated data is
    /// inflated into its declared size and no more. Data that does not inflate to exactly that size,
    /// or whose CRC-32 is not the directory's, is damage.
    static func contents(of record: Record, in source: some ZipByteSource, maximumSize: Int) throws(ZipListing.Failure) -> [UInt8]? {
        guard record.entry.kind == .file, record.flags & encryptedFlag == 0,
              record.compressedSize <= UInt64(maximumSize), record.uncompressedSize <= UInt64(maximumSize),
              record.method == storedMethod || record.method == deflatedMethod else {
            return nil
        }
        let header = LittleEndianBytes(try source.bytes(at: record.localHeaderOffset, count: localHeaderLength))
        let dataOffset = try sum(record.localHeaderOffset, UInt64(localHeaderLength), UInt64(try header.uint16(at: 26)), UInt64(try header.uint16(at: 28)))
        let stored = try source.bytes(at: dataOffset, count: Int(record.compressedSize))
        let bytes: [UInt8]
        if record.method == storedMethod {
            guard record.compressedSize == record.uncompressedSize else {
                throw .unlistable(.damaged)
            }
            bytes = stored
        } else {
            guard let inflated = Inflate.inflate(stored, expectedSize: Int(record.uncompressedSize), raw: true) else {
                throw .unlistable(.damaged)
            }
            bytes = inflated
        }
        guard Inflate.crc32(bytes) == record.crc else {
            throw .unlistable(.damaged)
        }
        return bytes
    }

    // MARK: - The end records

    /// Where the central directory is and how many entries it holds.
    private struct EndOfDirectory {
        var entryCount: UInt64
        var directorySize: UInt64
        var directoryOffset: UInt64
        /// Where the directory must end: at the Zip64 end record when there is one, otherwise at the end record.
        var directoryEnd: UInt64
    }

    /// The end record's values, or the Zip64 end record's when its locator sits right before it.
    private static func endOfDirectory(in source: some ZipByteSource) throws(ZipListing.Failure) -> EndOfDirectory {
        let size = source.byteCount
        guard size >= UInt64(endRecordLength) else {
            throw .unlistable(.damaged)
        }
        let tailLength = Int(min(size, UInt64(endRecordLength + longestComment)))
        let tailStart = size - UInt64(tailLength)
        let tail = LittleEndianBytes(try source.bytes(at: tailStart, count: tailLength))

        // The last end record in the file, where Info-ZIP and ditto look, must be the one whose
        // comment runs exactly to the last byte, and the only such one: every reader then finds the
        // same record. One hidden in a comment would otherwise list other contents.
        var last: Int?
        var reachingTheEnd: [Int] = []
        for index in stride(from: tailLength - endRecordLength, through: 0, by: -1) {
            guard try tail.uint32(at: index) == endRecordSignature else { continue }
            if last == nil {
                last = index
            }
            if index + endRecordLength + Int(try tail.uint16(at: index + 20)) == tailLength {
                reachingTheEnd.append(index)
            }
        }
        guard let index = last, reachingTheEnd == [index] else {
            throw .unlistable(.damaged)
        }
        let recordOffset = tailStart + UInt64(index)
        let disk = try tail.uint16(at: index + 4)
        let directoryDisk = try tail.uint16(at: index + 6)
        let entriesOnDisk = try tail.uint16(at: index + 8)
        let entries = try tail.uint16(at: index + 10)
        let directorySize = try tail.uint32(at: index + 12)
        let directoryOffset = try tail.uint32(at: index + 16)

        if let zip64 = try zip64EndOfDirectory(in: source, endRecordOffset: recordOffset) {
            // Each of the end record's own values must be its placeholder or the Zip64 record's
            // value: a reader that takes the end record at its word must find the same directory.
            guard disk == 0 || disk == placeholder16,
                  directoryDisk == 0 || directoryDisk == placeholder16,
                  entriesOnDisk == placeholder16 || UInt64(entriesOnDisk) == zip64.entryCount,
                  entries == placeholder16 || UInt64(entries) == zip64.entryCount,
                  directorySize == placeholder32 || UInt64(directorySize) == zip64.directorySize,
                  directoryOffset == placeholder32 || UInt64(directoryOffset) == zip64.directoryOffset else {
                throw .unlistable(.damaged)
            }
            return zip64
        }
        // An archive split over several disks lists only part of itself here.
        guard disk == 0, directoryDisk == 0, entriesOnDisk == entries else {
            throw .unlistable(.damaged)
        }
        return EndOfDirectory(
            entryCount: UInt64(entries),
            directorySize: UInt64(directorySize),
            directoryOffset: UInt64(directoryOffset),
            directoryEnd: recordOffset
        )
    }

    /// The Zip64 end record's values, when its locator sits right before the end record. The
    /// locator and the record are read on their own: a long comment can leave them outside the tail
    /// searched for the end record.
    private static func zip64EndOfDirectory(in source: some ZipByteSource, endRecordOffset: UInt64) throws(ZipListing.Failure) -> EndOfDirectory? {
        guard endRecordOffset >= UInt64(zip64LocatorLength) else {
            return nil
        }
        let locatorOffset = endRecordOffset - UInt64(zip64LocatorLength)
        let locator = LittleEndianBytes(try source.bytes(at: locatorOffset, count: zip64LocatorLength))
        guard try locator.uint32(at: 0) == zip64LocatorSignature else {
            return nil
        }
        let recordDisk = try locator.uint32(at: 4)
        let recordOffset = try locator.uint64(at: 8)
        let diskCount = try locator.uint32(at: 16)
        // On the one disk, and room for the whole record before the locator.
        guard recordDisk == 0, diskCount == 1, recordOffset <= locatorOffset, locatorOffset - recordOffset >= UInt64(zip64RecordLength) else {
            throw .unlistable(.damaged)
        }
        let record = LittleEndianBytes(try source.bytes(at: recordOffset, count: zip64RecordLength))
        // The record's size counts what follows its first 12 bytes, and the record ends at the locator.
        guard try record.uint32(at: 0) == zip64RecordSignature,
              try record.uint64(at: 4) == locatorOffset - recordOffset - 12 else {
            throw .unlistable(.damaged)
        }
        let disk = try record.uint32(at: 16)
        let directoryDisk = try record.uint32(at: 20)
        let entriesOnDisk = try record.uint64(at: 24)
        let entries = try record.uint64(at: 32)
        guard disk == 0, directoryDisk == 0, entriesOnDisk == entries else {
            throw .unlistable(.damaged)
        }
        return EndOfDirectory(
            entryCount: entries,
            directorySize: try record.uint64(at: 40),
            directoryOffset: try record.uint64(at: 48),
            directoryEnd: recordOffset
        )
    }

    // MARK: - The directory's records

    /// One record of the central directory: the entry it lists, and what its local header and data
    /// descriptor must say.
    struct Record {
        let entry: ZipEntry
        let flags: UInt16
        /// How the data is stored: 0 stored, 8 deflated, anything else not read.
        let method: UInt16
        let crc: UInt32
        let compressedSize: UInt64
        let uncompressedSize: UInt64
        let localHeaderOffset: UInt64
    }

    /// The `count` records of `directory`, which must hold exactly them and nothing more.
    private static func readRecords(_ directory: LittleEndianBytes, count: Int, limits: ZipListing.Limits) throws(ZipListing.Failure) -> [Record] {
        var records: [Record] = []
        records.reserveCapacity(count)
        var position = 0
        for index in 0..<count {
            if index.isMultiple(of: cancellationCheckInterval), Task.isCancelled {
                throw .cancelled
            }
            let signature = try directory.uint32(at: position)
            guard signature == entrySignature else {
                throw .unlistable(index == 0 && signature == archiveExtraDataSignature ? .encryptedListing : .damaged)
            }
            let madeBy = try directory.uint16(at: position + 4)
            let flags = try directory.uint16(at: position + 8)
            let method = try directory.uint16(at: position + 10)
            let crc = try directory.uint32(at: position + 16)
            let storedCompressedSize = try directory.uint32(at: position + 20)
            let storedSize = try directory.uint32(at: position + 24)
            let nameLength = Int(try directory.uint16(at: position + 28))
            let extraLength = Int(try directory.uint16(at: position + 30))
            let commentLength = Int(try directory.uint16(at: position + 32))
            let attributes = try directory.uint32(at: position + 38)
            let storedOffset = try directory.uint32(at: position + 42)
            // Checked before the name is read.
            guard nameLength <= limits.maximumNameLength else {
                throw .unlistable(.nameTooLong)
            }
            let nameStart = position + entryLength
            let name = try directory.slice(at: nameStart, count: nameLength)
            let extra = try directory.slice(at: nameStart + nameLength, count: extraLength)
            let next = nameStart + nameLength + extraLength + commentLength
            guard next <= directory.count else {
                throw .unlistable(.damaged)
            }
            guard let path = String(validating: name, as: UTF8.self) else {
                // With the flag, the archive says its names are UTF-8, and this one is not.
                throw .unlistable(flags & utf8NamesFlag != 0 ? .damaged : .unreadableNames)
            }
            let zip64 = try zip64Values(
                in: extra,
                uncompressed: storedSize == placeholder32,
                compressed: storedCompressedSize == placeholder32,
                offset: storedOffset == placeholder32
            )
            let size = zip64.uncompressed ?? UInt64(storedSize)
            guard let uncompressedSize = Int64(exactly: size) else {
                throw .unlistable(.damaged)
            }
            records.append(
                Record(
                    entry: ZipEntry(path: path, kind: kind(of: path, madeBy: madeBy, attributes: attributes), uncompressedSize: uncompressedSize),
                    flags: flags,
                    method: method,
                    crc: crc,
                    compressedSize: zip64.compressed ?? UInt64(storedCompressedSize),
                    uncompressedSize: size,
                    localHeaderOffset: zip64.offset ?? UInt64(storedOffset)
                )
            )
            position = next
        }
        guard position == directory.count else {
            throw .unlistable(.damaged)
        }
        return records
    }

    /// The values the Zip64 extended information field holds for an entry: one for each of the
    /// uncompressed size, compressed size and local header offset whose own field is a
    /// placeholder, in that order. Other fields in `extra` are skipped.
    private static func zip64Values(
        in extra: ArraySlice<UInt8>,
        uncompressed: Bool,
        compressed: Bool,
        offset: Bool
    ) throws(ZipListing.Failure) -> (uncompressed: UInt64?, compressed: UInt64?, offset: UInt64?) {
        guard uncompressed || compressed || offset else {
            return (nil, nil, nil)
        }
        let fields = LittleEndianBytes(Array(extra))
        var position = 0
        while position + 4 <= fields.count {
            let id = try fields.uint16(at: position)
            let length = Int(try fields.uint16(at: position + 2))
            let data = LittleEndianBytes(Array(try fields.slice(at: position + 4, count: length)))
            if id == zip64ExtraFieldID {
                var cursor = 0
                func next(_ wanted: Bool) throws(ZipListing.Failure) -> UInt64? {
                    guard wanted else {
                        return nil
                    }
                    defer { cursor += 8 }
                    return try data.uint64(at: cursor)
                }
                return (try next(uncompressed), try next(compressed), try next(offset))
            }
            position += 4 + length
        }
        throw .unlistable(.damaged)
    }

    /// What an entry is. A name ending in `/` is a folder. Otherwise a Unix or macOS maker records the
    /// item's mode in the high half of the external attributes; any other maker, or none recorded,
    /// marks a folder with the DOS directory attribute.
    private static func kind(of path: String, madeBy: UInt16, attributes: UInt32) -> ZipEntry.Kind {
        if path.hasSuffix("/") {
            return .folder
        }
        let mode = (attributes >> 16) & UInt32(S_IFMT)
        if unixHosts.contains(madeBy >> 8), mode != 0 {
            switch mode {
            case UInt32(S_IFDIR):
                return .folder
            case UInt32(S_IFLNK):
                return .symbolicLink
            case UInt32(S_IFREG):
                return .file
            default:
                return .other
            }
        }
        return attributes & dosDirectoryAttribute != 0 ? .folder : .file
    }

    // MARK: - The local headers

    /// Checks that the local headers say what the directory says. Each record's local header must
    /// carry its name, and the entries must follow one another from the first byte to the directory
    /// with nothing in between: a header, its data, and its data descriptor when it has one, whose
    /// CRC and sizes agree with the directory. ditto unpacks by the local headers, so an entry the
    /// directory does not list, or lists under another name, would otherwise be unpacked unseen.
    private static func checkLocalHeaders(_ records: [Record], in source: some ZipByteSource, directoryOffset: UInt64) throws(ZipListing.Failure) {
        let order = records.indices.sorted { records[$0].localHeaderOffset < records[$1].localHeaderOffset }
        var expected: UInt64 = 0
        for (rank, index) in order.enumerated() {
            if rank.isMultiple(of: cancellationCheckInterval), Task.isCancelled {
                throw .cancelled
            }
            let record = records[index]
            guard record.localHeaderOffset == expected else {
                throw .unlistable(.damaged)
            }
            let name = Array(record.entry.path.utf8)
            let header = LittleEndianBytes(try source.bytes(at: record.localHeaderOffset, count: localHeaderLength + name.count))
            guard try header.uint32(at: 0) == localHeaderSignature,
                  Int(try header.uint16(at: 26)) == name.count,
                  try header.slice(at: localHeaderLength, count: name.count).elementsEqual(name) else {
                throw .unlistable(.damaged)
            }
            let flags = try header.uint16(at: 6)
            let headerLength = UInt64(localHeaderLength + name.count) + UInt64(try header.uint16(at: 28))
            let dataEnd = try sum(record.localHeaderOffset, headerLength, record.compressedSize)
            let next = rank + 1 < order.count ? records[order[rank + 1]].localHeaderOffset : directoryOffset
            guard next >= dataEnd else {
                throw .unlistable(.damaged)
            }
            if flags & dataDescriptorFlag != 0 {
                try checkDataDescriptor(at: dataEnd, length: next - dataEnd, of: record, in: source)
            } else {
                // The header itself holds the CRC and the sizes; a Zip64 entry's are placeholders here.
                let compressed = try header.uint32(at: 18)
                let uncompressed = try header.uint32(at: 22)
                guard next == dataEnd,
                      try header.uint32(at: 14) == record.crc,
                      compressed == placeholder32 || UInt64(compressed) == record.compressedSize,
                      uncompressed == placeholder32 || UInt64(uncompressed) == record.uncompressedSize else {
                    throw .unlistable(.damaged)
                }
            }
            expected = next
        }
        guard expected == directoryOffset else {
            throw .unlistable(.damaged)
        }
    }

    /// Checks the data descriptor of `length` bytes at `offset`. Its length says its shape: 12 or 20
    /// bytes without the signature, 16 or 24 with it, with sizes of 4 or 8 bytes. Its CRC and
    /// sizes must be the directory's.
    private static func checkDataDescriptor(at offset: UInt64, length: UInt64, of record: Record, in source: some ZipByteSource) throws(ZipListing.Failure) {
        guard [12, 16, 20, 24].contains(length) else {
            throw .unlistable(.damaged)
        }
        let descriptor = LittleEndianBytes(try source.bytes(at: offset, count: Int(length)))
        let signed = length == 16 || length == 24
        let wide = length == 20 || length == 24
        let start = signed ? 4 : 0
        if signed {
            guard try descriptor.uint32(at: 0) == dataDescriptorSignature else {
                throw .unlistable(.damaged)
            }
        }
        let compressed = wide ? try descriptor.uint64(at: start + 4) : UInt64(try descriptor.uint32(at: start + 4))
        let uncompressed = wide ? try descriptor.uint64(at: start + 12) : UInt64(try descriptor.uint32(at: start + 8))
        guard try descriptor.uint32(at: start) == record.crc,
              compressed == record.compressedSize,
              uncompressed == record.uncompressedSize else {
            throw .unlistable(.damaged)
        }
    }

    /// The sum of `values`, or damage when it overflows.
    private static func sum(_ values: UInt64...) throws(ZipListing.Failure) -> UInt64 {
        var total: UInt64 = 0
        for value in values {
            let (next, overflow) = total.addingReportingOverflow(value)
            guard !overflow else {
                throw .unlistable(.damaged)
            }
            total = next
        }
        return total
    }
}

/// A run of bytes read as the little-endian fields zip stores. Every read is bounds-checked: a field
/// past the end is damage, never a trap.
struct LittleEndianBytes {
    private let bytes: [UInt8]

    init(_ bytes: [UInt8]) {
        self.bytes = bytes
    }

    var count: Int { bytes.count }

    func uint16(at offset: Int) throws(ZipListing.Failure) -> UInt16 {
        try integer(at: offset, length: 2)
    }

    func uint32(at offset: Int) throws(ZipListing.Failure) -> UInt32 {
        try integer(at: offset, length: 4)
    }

    func uint64(at offset: Int) throws(ZipListing.Failure) -> UInt64 {
        try integer(at: offset, length: 8)
    }

    /// `length` bytes from `offset`.
    func slice(at offset: Int, count length: Int) throws(ZipListing.Failure) -> ArraySlice<UInt8> {
        guard offset >= 0, length >= 0, offset <= bytes.count, length <= bytes.count - offset else {
            throw .unlistable(.damaged)
        }
        return bytes[offset..<(offset + length)]
    }

    private func integer<Value: FixedWidthInteger & UnsignedInteger>(at offset: Int, length: Int) throws(ZipListing.Failure) -> Value {
        var value: Value = 0
        for (shift, byte) in try slice(at: offset, count: length).enumerated() {
            value |= Value(byte) << (8 * shift)
        }
        return value
    }
}
