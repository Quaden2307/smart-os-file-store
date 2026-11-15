import Foundation

/// Where the Trash is for a folder: the one place undo takes a file back from. For a folder on the
/// startup disk it is `~/.Trash`; another volume has its own. Tests supply a temporary folder, since
/// putting their own files in the real Trash is all they may do there.
public struct TrashLocator: Sendable {
    private let locate: @Sendable (URL) -> URL?

    public init(_ locate: @escaping @Sendable (URL) -> URL?) {
        self.locate = locate
    }

    /// The system's Trash for the folder's volume, as `FileManager.trashItem` uses it.
    public static let system = TrashLocator { folderURL in
        try? FileManager.default.url(for: .trashDirectory, in: .userDomainMask, appropriateFor: folderURL, create: false)
    }

    /// Always `trashFolder`, whatever the folder.
    public static func fixed(_ trashFolder: URL) -> TrashLocator {
        TrashLocator { _ in trashFolder }
    }

    /// This locator with its answer for `folderURL` worked out once, so a plan of many changes in
    /// one folder asks the file system once (the system's answer is a lookup on the volume).
    public func resolved(for folderURL: URL) -> TrashLocator {
        let trashFolder = trashFolder(for: folderURL)
        return TrashLocator { _ in trashFolder }
    }

    /// The Trash for `folderURL`, or nil when its volume has none.
    public func trashFolder(for folderURL: URL) -> URL? {
        locate(folderURL)
    }

    /// True when `path` names an item directly inside the Trash for `folderURL`, where
    /// `trashItem` puts what it moves. Compared by the paths' own components; nothing is looked up.
    func holds(_ path: String, for folderURL: URL) -> Bool {
        guard let trashFolder = trashFolder(for: folderURL) else {
            return false
        }
        return UndoPaths.isDirectlyInside(path, folderPath: trashFolder.path(percentEncoded: false))
    }
}
