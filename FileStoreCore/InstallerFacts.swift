import Foundation

/// What was read from one installer, or why it could not be read. A plain, bounded value: every
/// string in it came from the installer, which may be hostile, and was checked against a limit
/// before it was kept. The activity log caches it (`InstallerFileKey`), so an installer is read
/// once, not on every scan.
public enum InstallerFacts: Sendable, Hashable, Codable {
    /// A disk image's or a zip's top-level apps. Empty for a disk image that holds none.
    case apps([BundleFacts])
    /// A package's parts, each with the apps it installs.
    case packages([PackageFacts])
    /// It could not be read, so only its name can be compared.
    case unreadable(Problem)

    /// Why an installer could not be read. The raw values are what the activity log stores, written
    /// out so that renaming a case cannot change them.
    public enum Problem: String, Error, Sendable, Hashable, Codable, CaseIterable {
        /// It is encrypted. Nothing ever asks for the password.
        case passwordProtected = "passwordProtected"
        /// It asks to accept a licence agreement before it opens.
        case licenseAgreement = "licenseAgreement"
        /// Opening, checking or reading it took longer than its time limit. Never cached.
        case timedOut = "timedOut"
        /// It could not be attached, mounted or read this time for a reason that says nothing about
        /// the file (a tool that could not start, a mount the system refused). Never cached.
        case couldNotOpen = "couldNotOpen"
        /// Its format is broken, its file system failed the system's check, it could not be
        /// attached or mounted, or it is not the kind of file its name says.
        case damaged = "damaged"
        /// More than the reader accepts: entries, apps, parts or bytes.
        case tooLarge = "tooLarge"
        /// A file system with no checker, or a compression this reader does not read.
        case unsupported = "unsupported"
    }

    /// The most apps one installer may hold, and the most parts one package.
    public static let maximumApps = 16
    public static let maximumPackages = 64

    /// True when the facts say something lasting about the file, so they may be cached. A
    /// timeout, or a failure to open it this time, says something about the moment.
    var isLasting: Bool {
        self != .unreadable(.timedOut) && self != .unreadable(.couldNotOpen)
    }
}

/// One part of a package (a component package), as its `PackageInfo` describes it.
public struct PackageFacts: Sendable, Hashable, Codable {
    /// The identifier its receipt is filed under: `com.example.SomeApp.pkg`.
    public let identifier: String

    public let version: String?

    /// The apps it installs: the bundles whose path ends in `.app`, not inside another app.
    public let apps: [BundleFacts]

    public init(identifier: String, version: String?, apps: [BundleFacts]) {
        self.identifier = identifier
        self.version = version
        self.apps = apps
    }
}

/// macOS's record that a package was installed, as `pkgutil` reports it.
public struct InstallReceipt: Sendable, Hashable {
    public let identifier: String
    public let version: String?

    public init(identifier: String, version: String?) {
        self.identifier = identifier
        self.version = version
    }
}

/// The file an installer's facts were read from, as the cache keys them: its identity on the
/// volume, or its path where the volume gives none, and its size, modification date and status
/// change time when it was read. Facts are used again only for the very same file, unchanged.
public struct InstallerFileKey: Sendable, Hashable {
    public let identity: PersistentFileIdentity?
    public let path: String
    public let sizeInBytes: Int64
    public let dateModified: Date
    public let statusChanged: Date

    public init(identity: PersistentFileIdentity?, path: String, sizeInBytes: Int64, dateModified: Date, statusChanged: Date) {
        self.identity = identity
        self.path = path
        self.sizeInBytes = sizeInBytes
        self.dateModified = dateModified
        self.statusChanged = statusChanged
    }
}

/// Facts newly read while planning, for the app to store in the activity log afterwards. The
/// planner itself writes nothing.
public struct InstallerFactsEntry: Sendable, Hashable {
    public let key: InstallerFileKey
    public let facts: InstallerFacts

    public init(key: InstallerFileKey, facts: InstallerFacts) {
        self.key = key
        self.facts = facts
    }
}

/// Where cached facts are looked up: the activity log.
public protocol InstallerFactsReading: Sendable {
    /// The cached facts for each key that has a row for the very same file, unchanged.
    func installerFacts(for keys: [InstallerFileKey]) async throws(ActivityLogError) -> [InstallerFileKey: InstallerFacts]
}
