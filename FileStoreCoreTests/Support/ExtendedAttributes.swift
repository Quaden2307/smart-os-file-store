import Darwin
import Foundation

/// The extended attributes macOS keeps on downloads and opened files, written the way the system
/// writes them so fixtures look like real Downloads items.
enum ExtendedAttributes {
    /// When the file was last opened: written by Launch Services whenever a file is opened, as a
    /// 16-byte `timespec` (seconds, then nanoseconds, little-endian).
    static let lastUsedDateName = "com.apple.lastuseddate#PS"

    /// Where the file was downloaded from: a binary property list of URL strings, written by
    /// browsers (Finder's Get Info shows it as "Where from").
    static let whereFromsName = "com.apple.metadata:kMDItemWhereFroms"

    /// Which app downloaded the file: text of the form `flags;time;app;event`, the flags and the
    /// time in hexadecimal, written by the quarantine system for the browser.
    static let quarantineName = "com.apple.quarantine"

    static func setLastUsedDate(_ date: Date, on url: URL) throws {
        let seconds = date.timeIntervalSince1970.rounded(.down)
        var value = Data()
        withUnsafeBytes(of: Int64(seconds).littleEndian) { value.append(contentsOf: $0) }
        withUnsafeBytes(of: Int64((date.timeIntervalSince1970 - seconds) * 1_000_000_000).littleEndian) { value.append(contentsOf: $0) }
        try set(value, name: lastUsedDateName, on: url)
    }

    static func lastUsedDate(of url: URL) -> Date? {
        guard let value = get(lastUsedDateName, of: url), value.count == 16 else { return nil }
        let seconds = value.prefix(8).withUnsafeBytes { Int64(littleEndian: $0.loadUnaligned(as: Int64.self)) }
        let nanoseconds = value.suffix(8).withUnsafeBytes { Int64(littleEndian: $0.loadUnaligned(as: Int64.self)) }
        return Date(timeIntervalSince1970: TimeInterval(seconds) + TimeInterval(nanoseconds) / 1_000_000_000)
    }

    static func setWhereFroms(_ sources: [String], on url: URL) throws {
        let value = try PropertyListSerialization.data(fromPropertyList: sources, format: .binary, options: 0)
        try set(value, name: whereFromsName, on: url)
    }

    static func whereFroms(of url: URL) -> [String]? {
        guard let value = get(whereFromsName, of: url) else { return nil }
        return try? PropertyListSerialization.propertyList(from: value, format: nil) as? [String]
    }

    static func setQuarantine(_ value: String, on url: URL) throws {
        try set(Data(value.utf8), name: quarantineName, on: url)
    }

    static func quarantine(of url: URL) -> String? {
        get(quarantineName, of: url).flatMap { String(data: $0, encoding: .utf8) }
    }

    /// A quarantine value as Safari leaves one, for a file downloaded at `date`.
    static func quarantineValue(app: String, downloadedAt date: Date) -> String {
        String(format: "0083;%08x;%@;6B29FC40-CA47-1067-B31D-00DD010662DA", Int(date.timeIntervalSince1970), app)
    }

    /// Writes `value` exactly as given, for attributes that are deliberately malformed.
    static func setRaw(_ value: Data, name: String, on url: URL) throws {
        try set(value, name: name, on: url)
    }

    private static func set(_ value: Data, name: String, on url: URL) throws {
        let result = value.withUnsafeBytes { buffer in
            setxattr(url.path(percentEncoded: false), name, buffer.baseAddress, buffer.count, 0, XATTR_NOFOLLOW)
        }
        guard result == 0 else {
            throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
        }
    }

    private static func get(_ name: String, of url: URL) -> Data? {
        let path = url.path(percentEncoded: false)
        let size = getxattr(path, name, nil, 0, 0, XATTR_NOFOLLOW)
        guard size >= 0 else { return nil }
        var value = Data(count: size)
        let read = value.withUnsafeMutableBytes { buffer in
            getxattr(path, name, buffer.baseAddress, size, 0, XATTR_NOFOLLOW)
        }
        return read == size ? value : nil
    }
}
