import Foundation

/// Which folders the app may look after. Every way a folder becomes managed, and every launch that
/// finds one again, asks here, so the rules live in one place (decision record 0026).
///
/// A folder is judged by where it really is: links in its path are resolved first (`realpath`),
/// which looks at each name on the way and opens nothing. Names are compared without regard to
/// letter case or Unicode form, so a rule can refuse one folder too many but never one too few.
public struct FolderSafetyRules: Sendable {
    public enum Refusal: Error, Sendable, Hashable {
        /// Nothing is there, it is not a folder, or it cannot be looked at.
        case notAFolder
        /// The top of a disk.
        case volumeRoot
        /// The home folder itself, or a folder that holds it.
        case homeFolder
        case trash
        /// In the user's Library or the Mac's.
        case insideLibrary
        /// An application, or a folder inside one.
        case insideApplication
        /// The app's own data: the activity log's folder, or a folder that holds it.
        case appData
        /// A folder macOS keeps for itself.
        case systemLocation
        /// The same folder as one already managed, inside one, or holding one.
        case overlapsManagedFolder
    }

    /// The folders macOS keeps for itself, as real paths: these and everything in them.
    public static let systemLocations = [
        "/System", "/Library", "/Applications", "/usr", "/bin", "/sbin", "/private", "/dev", "/cores", "/opt", "/Network",
    ]

    /// Folders that only hold other people's or other disks' folders: refused themselves, not what
    /// is in them.
    static let systemFoldersThemselves = ["/Volumes", "/Users"]

    public let home: URL

    /// Other home folders judged as `home` is. A debug demo home is `home`; the user's real one is
    /// named here, so it stays refused while a fake one stands in for it.
    public let otherHomes: [URL]

    /// Where the app keeps its own data.
    public let appDataFolders: [URL]

    /// Folders whose contents are exempt from the system-location rule. Empty for the app's real
    /// folders. Tests and a debug override name the temporary directory, which macOS keeps under
    /// `/private`, so a throwaway folder can stand in for Downloads.
    public let allowedRoots: [URL]

    public init(home: URL, otherHomes: [URL] = [], appDataFolders: [URL], allowedRoots: [URL] = []) {
        self.home = home
        self.otherHomes = otherHomes
        self.appDataFolders = appDataFolders
        self.allowedRoots = allowedRoots
    }

    /// Why the folder at `url` may not be managed, or nil when it may.
    ///
    /// - Parameter managed: The folders already managed, other than this one.
    public func refusal(for url: URL, managed: [URL] = []) -> Refusal? {
        guard let path = FileStatus.realPath(of: url),
              let status = try? FileStatus.of(path: path),
              status.isDirectory else {
            return .notAFolder
        }
        let folder = Self.names(in: path)
        guard !folder.isEmpty else {
            return .volumeRoot
        }
        let homes = ([home] + otherHomes).map { Self.names(in: $0) }
        if homes.contains(where: { $0.starts(with: folder) }) {
            return .homeFolder
        }
        if folder.contains(".trash") || folder.contains(".trashes") {
            return .trash
        }
        if homes.contains(where: { folder.starts(with: $0 + ["library"]) }) || folder.starts(with: ["library"]) {
            return .insideLibrary
        }
        if folder.contains(where: { $0.hasSuffix(".app") }) {
            return .insideApplication
        }
        if appDataFolders.contains(where: { Self.overlap(folder, Self.names(in: $0)) }) {
            return .appData
        }
        let isAllowed = allowedRoots.contains { root in
            let root = Self.names(in: root)
            return folder.count > root.count && folder.starts(with: root)
        }
        let isSystem = Self.systemLocations.contains { folder.starts(with: Self.names(in: $0)) }
            || Self.systemFoldersThemselves.contains { folder == Self.names(in: $0) }
        if isSystem, !isAllowed {
            return .systemLocation
        }
        // The top of any other disk: a folder on another disk than the folder it is in. After the
        // system's own folders, several of which macOS keeps on a second disk.
        guard let parent = try? FileStatus.of(path: (path as NSString).deletingLastPathComponent),
              parent.identity.device == status.identity.device else {
            return .volumeRoot
        }
        if managed.contains(where: { Self.overlap(folder, Self.names(in: $0)) }) {
            return .overlapsManagedFolder
        }
        return nil
    }

    /// True when one folder is the other, or is inside it.
    private static func overlap(_ lhs: [String], _ rhs: [String]) -> Bool {
        lhs.starts(with: rhs) || rhs.starts(with: lhs)
    }

    /// The names on the way to `url`, where it really is. A folder that is not there yet (the app's
    /// data folder before first use) is taken as its path spells it.
    private static func names(in url: URL) -> [String] {
        names(in: FileStatus.realPath(of: url) ?? url.standardizedFileURL.path(percentEncoded: false))
    }

    /// The names in `path`, each in one letter case and one Unicode form.
    private static func names(in path: String) -> [String] {
        path.split(separator: "/").map { $0.precomposedStringWithCanonicalMapping.lowercased() }
    }
}
