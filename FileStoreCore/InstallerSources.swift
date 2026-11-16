import Foundation

/// What Remove Used Installers reads besides the scanned folder: where installed apps are, the facts
/// cache, where disk images are mounted, and the package receipts. The app passes the real ones;
/// tests pass a fake Applications folder, an in-memory log, a temporary mount folder and fixed
/// receipts. It is not optional: a planner with defaults could read the real folders from a test.
public struct InstallerSources: Sendable {
    public let applicationFolders: [URL]

    /// Where facts read before are looked up. Nil reads every installer afresh.
    public let cache: (any InstallerFactsReading)?

    public let mounts: DiskImageMounts

    public let receipts: InstallReceipts

    public init(applicationFolders: [URL], cache: (any InstallerFactsReading)?, mounts: DiskImageMounts, receipts: InstallReceipts) {
        self.applicationFolders = applicationFolders
        self.cache = cache
        self.mounts = mounts
        self.receipts = receipts
    }

    /// The app's: the given folders, the activity log as the cache, the app's mount folder and this
    /// Mac's receipts.
    public static func standard(applicationFolders: [URL], cache: (any InstallerFactsReading)?) -> InstallerSources {
        InstallerSources(applicationFolders: applicationFolders, cache: cache, mounts: .shared, receipts: .system)
    }
}
