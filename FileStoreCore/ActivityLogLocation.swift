import CryptoKit
import Foundation

/// Where the activity log's database lives.
///
/// The real log is one file in the user's Library:
/// `~/Library/Application Support/<app identifier>/FileStore.sqlite`. Nothing in it leaves the Mac.
/// When the scan folder is a debug override, the log is a separate database under the temporary
/// directory, one per overridden folder, so hand testing on a fake folder never writes to the real
/// log. Tests use a database in memory.
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

    /// The location for a scan that resolved to `scan`: the real log for the Downloads folder, a
    /// separate temporary one for a debug override.
    public static func resolve(
        for scan: ScanLocation,
        appIdentifier: String,
        roots: Roots = .standard
    ) throws(ActivityLogError) -> ActivityLogLocation {
        switch scan.source {
        case .downloadsFolder:
            try applicationSupport(appIdentifier: appIdentifier, roots: roots)
        case .launchArgument, .environmentVariable:
            try temporary(key: scan.folderURL.path(percentEncoded: false), appIdentifier: appIdentifier, roots: roots)
        }
    }

    /// The location when the scan folder could not be resolved. A broken override is still an
    /// override: it gets a temporary log, never the real one.
    public static func resolve(
        forFailedScan error: ScanLocationError,
        appIdentifier: String,
        roots: Roots = .standard
    ) throws(ActivityLogError) -> ActivityLogLocation {
        switch error {
        case .downloadsFolderUnavailable:
            try applicationSupport(appIdentifier: appIdentifier, roots: roots)
        case .overrideValueMissing:
            try temporary(key: "", appIdentifier: appIdentifier, roots: roots)
        case .overrideDoesNotExist(let path, _), .overrideIsNotAFolder(let path, _):
            try temporary(key: path, appIdentifier: appIdentifier, roots: roots)
        }
    }

    /// The location for the current process: resolves the scan folder as the app does, then the log
    /// that belongs to it.
    public static func resolve(
        arguments: [String] = ProcessInfo.processInfo.arguments,
        environment: [String: String] = ProcessInfo.processInfo.environment,
        appIdentifier: String,
        roots: Roots = .standard
    ) throws(ActivityLogError) -> ActivityLogLocation {
        let scan: ScanLocation
        do throws(ScanLocationError) {
            scan = try ScanLocation.resolve(arguments: arguments, environment: environment)
        } catch {
            return try resolve(forFailedScan: error, appIdentifier: appIdentifier, roots: roots)
        }
        return try resolve(for: scan, appIdentifier: appIdentifier, roots: roots)
    }

    private static func applicationSupport(appIdentifier: String, roots: Roots) throws(ActivityLogError) -> ActivityLogLocation {
        guard let root = roots.applicationSupport, isOneFolderName(appIdentifier) else {
            throw .locationUnavailable
        }
        return ActivityLogLocation(kind: .applicationSupport, rootURL: root, folderNames: [appIdentifier])
    }

    /// One folder per overridden scan folder, named by a hash of its path, so the same fake folder
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
