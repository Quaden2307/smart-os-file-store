import Darwin
import Foundation
import os

/// Reads `FileMetadata` from the extended attributes macOS keeps on an item. It only reads: nothing
/// here changes a file or its attributes.
///
/// Last opened is `com.apple.lastuseddate#PS`, the attribute Launch Services writes when a user
/// opens a document. It is read directly, not through Spotlight's `kMDItemLastUsedDate`, so it is
/// there the moment an item is scanned, in any folder, indexed or not
/// (docs/decisions/0002-reading-last-opened.md). The download source is the address list browsers
/// store in `com.apple.metadata:kMDItemWhereFroms` and the app named in `com.apple.quarantine`.
///
/// A symbolic link is described itself, never followed. A missing, unreadable, oversized or
/// malformed attribute is nil, never an error. When the last-opened attribute cannot be read at all,
/// `canReadLastOpened` says so, so the missing date is not taken for "never opened".
public struct ExtendedAttributeMetadataReader: FileMetadataReading {
    public static let lastUsedDateName = "com.apple.lastuseddate#PS"
    public static let whereFromsName = "com.apple.metadata:kMDItemWhereFroms"
    public static let quarantineName = "com.apple.quarantine"

    /// The last-used date is a `timespec`: two 64-bit integers.
    static let lastUsedDateSize = 16

    /// Larger values are ignored. A where-froms list holds a few addresses, but a browser that
    /// recorded a `data:` address could otherwise hand over megabytes per file.
    static let whereFromsSizeLimit = 64 * 1_024
    static let quarantineSizeLimit = 1_024

    /// Most values fit this first buffer, so reading one costs a single call.
    private static let firstReadSize = 1_024

    private static let logger = Logger(subsystem: "com.quaden2307.FileStoreCore", category: "ExtendedAttributeMetadataReader")

    public init() {}

    public func metadata(for url: URL) -> FileMetadata {
        let path = url.path(percentEncoded: false)

        var lastOpened: Date?
        var canReadLastOpened = true
        switch Self.read(Self.lastUsedDateName, at: path, sizeLimit: Self.lastUsedDateSize) {
        case .value(let value):
            lastOpened = Self.lastUsedDate(from: value)
            if lastOpened == nil {
                Self.logIgnored(Self.lastUsedDateName, path: path)
            }
        case .none:
            break
        case .unreadable:
            canReadLastOpened = false
        }

        var addresses: [String] = []
        if case .value(let value) = Self.read(Self.whereFromsName, at: path, sizeLimit: Self.whereFromsSizeLimit) {
            addresses = Self.whereFroms(from: value)
            if addresses.isEmpty {
                Self.logIgnored(Self.whereFromsName, path: path)
            }
        }

        var downloadingApp: String?
        if case .value(let value) = Self.read(Self.quarantineName, at: path, sizeLimit: Self.quarantineSizeLimit) {
            downloadingApp = Self.quarantineAgent(from: value)
            if downloadingApp == nil {
                Self.logIgnored(Self.quarantineName, path: path)
            }
        }

        return FileMetadata(
            lastOpened: lastOpened,
            downloadSource: DownloadSource(addresses: addresses, downloadingApp: downloadingApp),
            canReadLastOpened: canReadLastOpened
        )
    }

    // MARK: - Decoding

    /// Decodes `com.apple.lastuseddate#PS`: a `timespec` of two little-endian 64-bit integers,
    /// seconds then nanoseconds. Nil for any other size, for nanoseconds outside 0 to 999,999,999,
    /// and for a time at or before 1970, none of which Launch Services writes.
    public static func lastUsedDate(from value: Data) -> Date? {
        guard value.count == lastUsedDateSize else {
            return nil
        }
        let (seconds, nanoseconds) = value.withUnsafeBytes { bytes in
            (
                Int64(littleEndian: bytes.loadUnaligned(fromByteOffset: 0, as: Int64.self)),
                Int64(littleEndian: bytes.loadUnaligned(fromByteOffset: 8, as: Int64.self))
            )
        }
        guard seconds > 0, (0..<1_000_000_000).contains(nanoseconds) else {
            return nil
        }
        return Date(timeIntervalSince1970: TimeInterval(seconds) + TimeInterval(nanoseconds) / 1_000_000_000)
    }

    /// Decodes `com.apple.metadata:kMDItemWhereFroms`: a property list (browsers write the binary
    /// format) holding an array of strings, in the order they were recorded. Blank strings and
    /// entries that are not strings are dropped; anything but an array gives an empty list.
    public static func whereFroms(from value: Data) -> [String] {
        guard let list = try? PropertyListSerialization.propertyList(from: value, options: [], format: nil) as? [Any] else {
            return []
        }
        return list
            .compactMap { $0 as? String }
            .filter { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
    }

    /// Decodes the app named in `com.apple.quarantine`: UTF-8 text of the form
    /// `flags;time;app;event`, the flags in hexadecimal, for example `0083;6735f2a1;Safari;0B5E…`.
    /// Nil when the text does not have that shape or names no app.
    public static func quarantineAgent(from value: Data) -> String? {
        guard let text = String(data: value, encoding: .utf8) else {
            return nil
        }
        let fields = text
            .trimmingCharacters(in: CharacterSet(charactersIn: "\0").union(.whitespacesAndNewlines))
            .split(separator: ";", omittingEmptySubsequences: false)
        guard fields.count >= 3, let flags = fields.first, !flags.isEmpty, flags.allSatisfy(\.isHexDigit) else {
            return nil
        }
        let app = fields[2].trimmingCharacters(in: .whitespacesAndNewlines)
        return app.isEmpty ? nil : app
    }

    // MARK: - Reading

    /// What reading one attribute found.
    private enum AttributeRead {
        case value(Data)
        /// The item has no such attribute, or its value is larger than the reader accepts.
        case none
        /// Nothing could be read: the volume keeps no extended attributes (`ENOTSUP`), permission
        /// was refused, or the item went away.
        case unreadable
    }

    private enum FirstRead {
        case value(Data)
        case largerThanBuffer
        case failed(errno_t)
    }

    /// The raw value of the attribute `name` on the item at `path`, never following a symbolic link.
    private static func read(_ name: String, at path: String, sizeLimit: Int) -> AttributeRead {
        let firstRead = withUnsafeTemporaryAllocation(byteCount: min(sizeLimit, firstReadSize), alignment: 1) { buffer -> FirstRead in
            let count = getxattr(path, name, buffer.baseAddress, buffer.count, 0, XATTR_NOFOLLOW)
            if count >= 0 {
                return .value(Data(UnsafeRawBufferPointer(rebasing: buffer[..<count])))
            }
            let code = errno
            return code == ERANGE ? .largerThanBuffer : .failed(code)
        }
        switch firstRead {
        case .value(let data):
            return .value(data)
        case .failed(let code):
            return code == ENOATTR ? .none : .unreadable
        case .largerThanBuffer:
            // Ask for the size, then read exactly that much. The value can change in between; a
            // failed second read then counts as no value.
            let size = getxattr(path, name, nil, 0, 0, XATTR_NOFOLLOW)
            guard size > 0, size <= sizeLimit else {
                if size > sizeLimit {
                    logIgnored(name, path: path)
                }
                return .none
            }
            var data = Data(count: size)
            let count = data.withUnsafeMutableBytes { buffer in
                getxattr(path, name, buffer.baseAddress, buffer.count, 0, XATTR_NOFOLLOW)
            }
            return count >= 0 ? .value(data.prefix(count)) : .none
        }
    }

    /// Names the attribute, never its value, which can hold private addresses.
    private static func logIgnored(_ name: String, path: String) {
        logger.debug("Ignored unusable \(name, privacy: .public) on \(path, privacy: .private)")
    }
}
