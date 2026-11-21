import CryptoKit
import Foundation

/// Where the activity log's database lives.
///
/// The real log is one file in the user's Library:
/// `~/Library/Application Support/<app identifier>/FileStore.sqlite`. Nothing in it leaves the Mac.
/// When the folders are a debug override (`FolderOverride`), the log is a separate database under
/// the temporary directory, one per overridden folder or demo home, so hand testing on fake folders
/// never writes to the real log. Tests use a database in memory.
public struct ActivityLogLocation: Sendable, Hashable {
    public enum Kind: Sendable, Hashable {
        /// The user's real log, in Application Support.
        case applicationSupport

        /// A debug override's own log, under the temporary directory.
        case temporary

        /// No file at all. For tests.
        case inMemory
    }

    /// The folders a location is worked out from. Tests pass folders of their own, so that not
    /// even working out a location looks at the real Library.
    public struct Roots: Sendable, Hashable {
        /// The user's Application Support folder. Nil when the system reports none.
        public var applicationSupport: URL?

        public var temporary: URL

        public init(applicationSupport: URL?, temporary: URL) {
            self.applicationSupport = applicationSupport
            self.temporary = temporary
        }

        /// The current user's own folders.
        public static var standard: Roots {
            Roots(
                applicationSupport: FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first,
                temporary: FileManager.default.temporaryDirectory
            )
        }
    }

    public static let fileName = "FileStore.sqlite"

    /// Added to the app identifier for the folder that holds every debug override's log.
    static let temporaryFolderSuffix = ".debug"

    public let kind: Kind

    /// A folder that already exists and that the log's own folders are made in: Application
    /// Support, or the temporary directory. Nil in memory.
    let rootURL: URL?

    /// The log's own folders below the root, outermost first. Made on first use.
    let folderNames: [String]

    /// The folder holding the database. Nil in memory.
    public var folderURL: URL? {
        guard let rootURL else { return nil }
        return folderNames.reduce(rootURL) { $0.appending(path: $1, directoryHint: .isDirectory) }
    }

    /// The database file. Nil in memory.
    public var databaseURL: URL? {
        folderURL?.appending(path: Self.fileName, directoryHint: .notDirectory)
    }

    public static let inMemory = ActivityLogLocation(kind: .inMemory, rootURL: nil, folderNames: [])

    /// The location for the folders `override` stands in for: the real log for the user's real
    /// folders (no override), a separate temporary one for a debug override.
    public static func resolve(
        for override: FolderOverride?,
        appIdentifier: String,
        roots: Roots = .standard
    ) throws(ActivityLogError) -> ActivityLogLocation {
        guard let override else {
            return try applicationSupport(appIdentifier: appIdentifier, roots: roots)
        }
        return try temporary(
            key: key(override.kind, path: override.folderURL.path(percentEncoded: false)),
            appIdentifier: appIdentifier,
            roots: roots
        )
    }

    /// The location when the folders could not be found. A broken override is still an override:
    /// it gets a temporary log, never the real one. Only a standard folder the system does not
    /// report leaves the real log's place as it is.
    public static func resolve(
        forFailedOverride error: FolderLocationError,
        appIdentifier: String,
        roots: Roots = .standard
    ) throws(ActivityLogError) -> ActivityLogLocation {
        switch error {
        case .overrideDoesNotExist(let path, let source), .overrideIsNotAFolder(let path, let source):
            try temporary(key: key(source.kind, path: path), appIdentifier: appIdentifier, roots: roots)
        case .standardFolderUnavailable:
            try applicationSupport(appIdentifier: appIdentifier, roots: roots)
        case .overrideValueMissing, .refused, .bookmarkUnusable:
            try temporary(key: "", appIdentifier: appIdentifier, roots: roots)
        }
    }

    /// The location for the current process: resolves the override as the app does, then the log
    /// that belongs to it.
    public static func resolve(
        arguments: [String] = ProcessInfo.processInfo.arguments,
        environment: [String: String] = ProcessInfo.processInfo.environment,
        appIdentifier: String,
        roots: Roots = .standard
    ) throws(ActivityLogError) -> ActivityLogLocation {
        let override: FolderOverride?
        do throws(FolderLocationError) {
            override = try FolderOverride.resolve(arguments: arguments, environment: environment)
        } catch {
            return try resolve(forFailedOverride: error, appIdentifier: appIdentifier, roots: roots)
        }
        return try resolve(for: override, appIdentifier: appIdentifier, roots: roots)
    }

    /// What an override's log is named after. A scan folder's key is its path alone, as it was
    /// before demo homes, so a fake folder from an earlier build finds its log again; a demo home's
    /// is marked, so the two never share a log even at the same path.
    private static func key(_ kind: FolderOverride.Kind, path: String) -> String {
        switch kind {
        case .scanFolder:
            path
        case .demoHome:
            "demo-home:" + path
        }
    }

    private static func applicationSupport(appIdentifier: String, roots: Roots) throws(ActivityLogError) -> ActivityLogLocation {
        guard let root = roots.applicationSupport, isOneFolderName(appIdentifier) else {
            throw .locationUnavailable
        }
        return ActivityLogLocation(kind: .applicationSupport, rootURL: root, folderNames: [appIdentifier])
    }

    /// One folder per override, named by a hash of its key, so the same fake folder
    /// finds its log again on the next launch and two fake folders never share one.
    private static func temporary(key: String, appIdentifier: String, roots: Roots) throws(ActivityLogError) -> ActivityLogLocation {
        guard isOneFolderName(appIdentifier) else {
            throw .locationUnavailable
        }
        let digest = SHA256.hash(data: Data(key.utf8))
        let name = digest.prefix(8).map { String(format: "%02x", $0) }.joined()
        return ActivityLogLocation(
            kind: .temporary,
            rootURL: roots.temporary,
            folderNames: [appIdentifier + temporaryFolderSuffix, name]
        )
    }

    /// The app identifier becomes a folder name, so it must be exactly one.
    private static func isOneFolderName(_ name: String) -> Bool {
        !name.isEmpty && name != "." && name != ".." && !name.contains("/") && !name.contains("\0")
    }
}
