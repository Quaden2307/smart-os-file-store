import Foundation

/// Path rules undo shares. Paths are taken apart as text, never through `URL`, and only
/// `isItemDirectlyIn` reads the disk, so a name reaches the system in exactly the bytes the log stored (a URL can hand
/// back a name in another Unicode form, record 0005). Comparisons are `String`'s, which treat the
/// two forms of a name as equal, as the volume does.
enum UndoPaths {
    /// One valid, visible name: what a file in the scanned folder can be called.
    static func isSingleName(_ name: String) -> Bool {
        FileNameRules.isSingleName(name, maximumLength: FileNameRules.defaultMaximumLength) && !name.hasPrefix(".")
    }

    /// The path's names, outermost first, without empty ones: `/a/b/` gives `a` and `b`.
    static func components(of path: String) -> [String] {
        path.split(separator: "/").map(String.init)
    }

    /// The last name of `path`, exactly as stored. Nil for `/` or an empty path.
    static func name(of path: String) -> String? {
        components(of: path).last
    }

    /// The folder `path` names an item in, exactly as stored.
    static func parent(of path: String) -> String {
        "/" + components(of: path).dropLast().joined(separator: "/")
    }

    /// True when the folder `path` names an item in is the folder whose identity is `folderIdentity`,
    /// however either is spelled, and the item's name is one visible name. The folder at the path
    /// may itself be reached through a link, as the scanned folder may.
    static func isItemDirectlyIn(_ path: String, folderIdentity: FileIdentity) -> Bool {
        guard let name = name(of: path), isSingleName(name),
              let parent = try? FileStatus.of(path: parent(of: path), followingLinks: true) else {
            return false
        }
        return parent.isDirectory && parent.identity == folderIdentity
    }

    /// True when `path` names an item directly inside the folder at `folderPath`.
    static func isDirectlyInside(_ path: String, folderPath: String) -> Bool {
        let parts = components(of: path)
        guard let name = parts.last, isSingleName(name) else {
            return false
        }
        return Array(parts.dropLast()) == components(of: folderPath)
    }

    /// The folders between the folder at `folderPath` and the item at `path`, outermost first: at
    /// least one, each a single visible name. Nil when the item is not inside a folder inside it.
    static func folderNames(from folderPath: String, toItemAt path: String) -> [String]? {
        let parts = components(of: path)
        let folder = components(of: folderPath)
        guard let name = parts.last, isSingleName(name), parts.count >= folder.count + 2, parts.starts(with: folder) else {
            return nil
        }
        let names = Array(parts.dropFirst(folder.count).dropLast())
        guard names.allSatisfy(isSingleName) else {
            return nil
        }
        return names
    }
}
