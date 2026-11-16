import Foundation

extension UnpackedTree {
    /// Why what is at a place could not be read in full. Nothing is guessed from part of it.
    enum ReadFailure: Error, Sendable, Hashable {
        /// Nothing is at the place.
        case missing
        /// Something there is in iCloud only. Listing a folder like that would download it.
        case notDownloaded
        case accessDenied
        /// Another failure, or something changed while it was read; `reason` says which.
        case unreadable(reason: String)
        /// More than `maximumListedNames` names in the folders read.
        case tooLarge
        case cancelled
    }

    /// The most names listed for one place. A folder a zip names may hold any number of extra
    /// items, and each is listed, though never looked at.
    static let maximumListedNames = 250_000

    /// What one reading found.
    struct Reading {
        let tree: UnpackedTree

        /// The item at the place, as it was looked at, so a caller can look at it again later.
        let rootStatus: FileStatus

        /// When anything found that the zip names as a file or a link was last written: the newest
        /// of their modification dates, the root's included when it is one. Folders' own dates are
        /// left out, since they move whenever anything is added inside, such as Finder's `.DS_Store`.
        let newestChange: Date?
    }

    /// What is at `name` directly inside `folder`, as far as `expected` asks: the root, and inside a
    /// folder each item `expected` names, found by its exact name. Extra items are listed but never
    /// described or opened, and a folder `expected` does not name is never opened.
    ///
    /// Links are never followed. Every item is described with `lstat` semantics, and each folder is
    /// opened from the root by its path, with no link allowed anywhere on the way. A folder in iCloud
    /// only is never listed, and anything in iCloud only fails the reading.
    ///
    static func read(named name: String, in folder: DirectoryHandle, expecting expected: UnpackedTree) throws(ReadFailure) -> Reading {
        let rootStatus: FileStatus
        do throws(FileStatus.Failure) {
            rootStatus = try folder.status(of: name)
        } catch {
            throw error == .notFound ? .missing : ReadFailure(statusFailure: error)
        }
        if rootStatus.isDataless {
            throw .notDownloaded
        }
        let root = Item(rootStatus)
        guard root == .folder, expected.root == .folder, !expected.contents.isEmpty else {
            let newestChange = root == .folder ? nil : rootStatus.modificationDate
            return Reading(tree: UnpackedTree(root: root), rootStatus: rootStatus, newestChange: newestChange)
        }
        let rootFolder: DirectoryHandle
        do throws(DirectoryHandle.OpenFailure) {
            rootFolder = try folder.openFolder(named: name)
        } catch {
            throw ReadFailure(openFailure: error)
        }
        // The folder opened must be the one looked at, not one put in its place since.
        guard let opened = try? rootFolder.status(), opened.isDirectory, opened.identity == rootStatus.identity else {
            throw .unreadable(reason: "replaced while it was read")
        }
        let (contents, newestChange) = try contents(of: rootFolder, expecting: expected)
        return Reading(tree: UnpackedTree(root: .folder, contents: contents), rootStatus: rootStatus, newestChange: newestChange)
    }

    /// The items `expected` names inside `root`, folder by folder, parents first, and the newest
    /// modification date among the files and links found.
    private static func contents(of root: DirectoryHandle, expecting expected: UnpackedTree) throws(ReadFailure) -> ([String: Item], Date?) {
        // The names each folder must hold, by the folder's path ("" for the root).
        var childNames: [String: [String]] = [:]
        for path in expected.contents.keys {
            let (parent, name) = split(path)
            childNames[parent, default: []].append(name)
        }
        // A folder's path sorts before every path below it, so parents come first.
        let folders = childNames.keys.sorted()

        var found: [String: Item] = [:]
        var newestChange: Date?
        // Each folder found so far, by its path in the zip, with its path as the disk spells it.
        var diskPaths: [String: String] = ["": ""]
        var listed = 0
        for folderPath in folders {
            if Task.isCancelled {
                throw .cancelled
            }
            // A folder that is missing, or is something else, holds nothing to find.
            guard let diskPath = diskPaths[folderPath] else { continue }
            let handle: DirectoryHandle
            if diskPath.isEmpty {
                handle = root
            } else {
                do throws(DirectoryHandle.OpenFailure) {
                    handle = try root.openFolder(atRelativePath: diskPath)
                } catch {
                    throw ReadFailure(openFailure: error)
                }
            }
            // Checked on the open folder itself, so nothing can be swapped in between.
            let folderStatus: FileStatus
            let names: [String]
            do throws(FileStatus.Failure) {
                folderStatus = try handle.status()
                // One more than the names still allowed, so a folder too big is found without listing all of it.
                names = folderStatus.isDataless ? [] : try handle.entryNames(limit: maximumListedNames - listed + 1)
            } catch {
                throw ReadFailure(statusFailure: error)
            }
            if folderStatus.isDataless {
                throw .notDownloaded
            }
            listed += names.count
            guard listed <= maximumListedNames else {
                throw .tooLarge
            }
            // By name. Swift's string equality takes NFC and NFD for one name and keeps letter case,
            // so `README.md` is never found as `readme.md`.
            var spelled: [String: String] = [:]
            for name in names where spelled[name] == nil {
                spelled[name] = name
            }
            for child in childNames[folderPath] ?? [] {
                guard let diskName = spelled[child] else { continue }
                let status: FileStatus
                do throws(FileStatus.Failure) {
                    status = try handle.status(of: diskName)
                } catch {
                    if error == .notFound { continue }
                    throw ReadFailure(statusFailure: error)
                }
                if status.isDataless {
                    throw .notDownloaded
                }
                let path = folderPath.isEmpty ? child : folderPath + "/" + child
                let item = Item(status)
                found[path] = item
                if item == .folder {
                    diskPaths[path] = diskPath.isEmpty ? diskName : diskPath + "/" + diskName
                } else {
                    newestChange = max(newestChange ?? status.modificationDate, status.modificationDate)
                }
            }
        }
        return (found, newestChange)
    }

    /// The folder's path and the last name of `path`: `("src/app", "main.swift")`, or `("", name)`.
    private static func split(_ path: String) -> (parent: String, name: String) {
        guard let slash = path.lastIndex(of: "/") else {
            return ("", path)
        }
        return (String(path[..<slash]), String(path[path.index(after: slash)...]))
    }
}

extension UnpackedTree.ReadFailure {
    init(statusFailure: FileStatus.Failure) {
        switch statusFailure {
        case .notFound:
            // Something vanished while it was read.
            self = .unreadable(reason: String(cString: strerror(ENOENT)))
        case .accessDenied:
            self = .accessDenied
        case .other(let reason):
            self = .unreadable(reason: reason)
        }
    }

    init(openFailure: DirectoryHandle.OpenFailure) {
        switch openFailure {
        case .accessDenied:
            self = .accessDenied
        case .notFound:
            self = .unreadable(reason: String(cString: strerror(ENOENT)))
        case .symbolicLink:
            self = .unreadable(reason: "a symbolic link on the way")
        case .notAFolder:
            self = .unreadable(reason: String(cString: strerror(ENOTDIR)))
        case .other(let code):
            self = .unreadable(reason: String(cString: strerror(code)))
        }
    }
}
