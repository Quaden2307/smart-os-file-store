import Foundation
import os

/// An app installed in one of the application folders.
public struct InstalledApp: Sendable, Hashable {
    public let facts: BundleFacts

    /// Where it is: `/Applications/SomeApp.app`.
    public let url: URL

    public init(facts: BundleFacts, url: URL) {
        self.facts = facts
        self.url = url
    }
}

/// The apps installed on this Mac, as far as Remove Used Installers looks: the `.app` bundles at the
/// top level of each application folder. Links, hidden items and subfolders are left out.
public enum InstalledApps {
    private static let logger = Logger(subsystem: "com.quaden2307.FileStoreCore", category: "InstalledApps")

    /// The most names read from one folder.
    static let maximumNames = 5_000

    /// Every app at the top level of `folders`, in folder order, then name order. A folder that
    /// cannot be read adds nothing. A link at the folder itself is followed, as for Downloads; none
    /// inside is.
    @concurrent
    public static func read(folders: [URL]) async -> [InstalledApp] {
        var apps: [InstalledApp] = []
        for folderURL in folders {
            guard let folder = try? DirectoryHandle.open(path: folderURL.path(percentEncoded: false)),
                  let names = try? folder.entryNames(limit: maximumNames) else {
                continue
            }
            if names.count == maximumNames {
                logger.notice("Read only the first \(maximumNames) items of an application folder")
            }
            for name in names.filter(BundleInfo.isAppName).sorted(by: { $0.localizedStandardCompare($1) == .orderedAscending }) {
                if let facts = BundleInfo.read(bundleNamed: name, in: folder) {
                    apps.append(InstalledApp(facts: facts, url: folderURL.appending(path: name, directoryHint: .isDirectory)))
                }
            }
        }
        return apps
    }
}

/// The folders installed apps are looked for in.
public enum ApplicationFolders {
    /// Debug-only launch argument that replaces the folders with one, for hand testing with a fake
    /// Applications folder. Release builds ignore it.
    public static let launchArgumentName = "-ApplicationsFolder"

    /// `/Applications` and `~/Applications`, or in a debug build the folder given with
    /// `-ApplicationsFolder`. A value that is missing or not a folder gives no folders at all, so a
    /// mistake never looks in the real ones.
    public static func resolve(
        arguments: [String] = ProcessInfo.processInfo.arguments,
        home: URL = FileManager.default.homeDirectoryForCurrentUser
    ) -> [URL] {
        #if DEBUG
        if let override = debugOverride(arguments: arguments) {
            return override
        }
        #endif
        return [
            URL(filePath: "/Applications", directoryHint: .isDirectory),
            home.appending(path: "Applications", directoryHint: .isDirectory),
        ]
    }

    #if DEBUG
    private static let logger = Logger(subsystem: "com.quaden2307.FileStoreCore", category: "ApplicationFolders")

    private static func debugOverride(arguments: [String]) -> [URL]? {
        guard let flagIndex = arguments.firstIndex(of: launchArgumentName) else {
            return nil
        }
        let valueIndex = arguments.index(after: flagIndex)
        var isFolder: ObjCBool = false
        guard valueIndex < arguments.endIndex,
              case let path = (arguments[valueIndex] as NSString).expandingTildeInPath,
              FileManager.default.fileExists(atPath: path, isDirectory: &isFolder), isFolder.boolValue else {
            logger.error("\(launchArgumentName, privacy: .public) is not followed by a folder; no application folder is read")
            return []
        }
        logger.notice("Applications are looked for only in \(path, privacy: .private) (debug builds only)")
        return [URL(filePath: path, directoryHint: .isDirectory)]
    }
    #endif
}
