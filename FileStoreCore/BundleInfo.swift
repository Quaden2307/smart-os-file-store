import Foundation

/// What an app bundle says about itself in `Contents/Info.plist`: what a used installer is matched
/// by. The values come from files that may be hostile, so each is a non-empty string within its
/// limit, or nil.
public struct BundleFacts: Sendable, Hashable, Codable {
    /// The bundle's file name without `.app`: the name Finder shows.
    public let name: String

    /// `CFBundleIdentifier`.
    public let identifier: String?

    /// `CFBundleShortVersionString`, the version people see.
    public let shortVersion: String?

    /// `CFBundleVersion`, the build.
    public let build: String?

    public init(name: String, identifier: String?, shortVersion: String?, build: String?) {
        self.name = name
        self.identifier = identifier
        self.shortVersion = shortVersion
        self.build = build
    }
}

/// Reads an app's `Info.plist`, bounded, as plain values: `PropertyListSerialization` builds
/// strings, numbers and collections, never objects of a class the file names.
enum BundleInfo {
    static let maximumPlistSize = 1 << 20
    static let maximumIdentifierLength = 255
    static let maximumVersionLength = 64

    /// True for a name that may be an app bundle: `.app` in any letter case, not hidden.
    static func isAppName(_ name: String) -> Bool {
        !name.hasPrefix(".") && name.count > 4 && name.lowercased().hasSuffix(".app")
    }

    /// The bundle's name: its file name without `.app`.
    static func appName(ofBundleNamed bundleName: String) -> String {
        String(bundleName.dropLast(4))
    }

    /// The facts in `bytes`, an `Info.plist`, for the bundle called `bundleName`. Nil when the bytes
    /// are not a dictionary property list within the size limit.
    static func parse(_ bytes: [UInt8], bundleName: String) -> BundleFacts? {
        guard bytes.count <= maximumPlistSize,
              let plist = try? PropertyListSerialization.propertyList(from: Data(bytes), options: [], format: nil),
              let dictionary = plist as? [String: Any] else {
            return nil
        }
        return BundleFacts(
            name: appName(ofBundleNamed: bundleName),
            identifier: bounded(dictionary["CFBundleIdentifier"], maximumIdentifierLength),
            shortVersion: bounded(dictionary["CFBundleShortVersionString"], maximumVersionLength),
            build: bounded(dictionary["CFBundleVersion"], maximumVersionLength)
        )
    }

    /// The facts of the app bundle called `bundleName` directly inside `folder`, read through the
    /// handle: the bundle must be a real folder, and no link on the way to its `Info.plist` is
    /// followed. Nil when it is not an app this can read.
    static func read(bundleNamed bundleName: String, in folder: DirectoryHandle) -> BundleFacts? {
        guard let bundle = try? folder.status(of: bundleName), bundle.isDirectory, !bundle.isSymbolicLink, !bundle.isDataless,
              let contents = try? folder.openFolder(atRelativePath: bundleName + "/Contents"),
              let info = try? contents.status(of: "Info.plist"),
              info.isRegularFile, !info.isDataless, info.sizeInBytes <= Int64(maximumPlistSize),
              let file = try? ZipArchiveFile.open(named: "Info.plist", in: contents),
              // The file opened may not be the one looked at; its own size is checked too.
              file.byteCount <= UInt64(maximumPlistSize),
              let bytes = try? file.bytes(at: 0, count: Int(file.byteCount)) else {
            return nil
        }
        return parse(bytes, bundleName: bundleName)
    }

    /// `value` when it is a non-empty string of at most `limit` bytes.
    static func bounded(_ value: Any?, _ limit: Int) -> String? {
        guard let text = value as? String, !text.isEmpty, text.utf8.count <= limit else {
            return nil
        }
        return text
    }
}
