import Foundation

/// Identifies a file on its volume, however its path is spelled.
struct FileIdentity: Hashable, Sendable {
    let device: dev_t
    let inode: ino_t
}

/// What the file system says about a path right now, from one `lstat(2)` call.
///
/// Used to recheck a file immediately before acting on it. Unlike `URL.resourceValues`, nothing
/// here can be a value cached at scan time, and a symbolic link is described, never followed.
struct FileStatus: Sendable {
    enum Failure: Error, Sendable, Hashable {
        case notFound
        case accessDenied
        /// Another failure; `reason` is the system's description.
        case other(reason: String)
    }

    let identity: FileIdentity
    let isRegularFile: Bool
    let isSymbolicLink: Bool
    let isDirectory: Bool
    let sizeInBytes: Int64
    let modificationDate: Date
    /// Locked by the user (`uchg`, Finder's "Locked" checkbox).
    let isUserImmutable: Bool
    /// Locked by the system (`schg`).
    let isSystemImmutable: Bool
    /// A cloud placeholder whose bytes are not on this Mac.
    let isDataless: Bool
    /// Hidden by flag (`UF_HIDDEN`). A leading dot is a separate check on the name.
    let isHidden: Bool

    /// Describes the item at `path`. A symbolic link is described itself unless `followingLinks`
    /// is set, which is only right for a folder that may itself be a link (Downloads can be).
    static func of(path: String, followingLinks: Bool = false) throws(Failure) -> FileStatus {
        var status = stat()
        let result = followingLinks ? stat(path, &status) : lstat(path, &status)
        guard result == 0 else {
            let code = errno
            switch code {
            case ENOENT, ENOTDIR:
                throw .notFound
            case EACCES, EPERM:
                throw .accessDenied
            default:
                throw .other(reason: String(cString: strerror(code)))
            }
        }
        let type = status.st_mode & S_IFMT
        let flags = status.st_flags
        return FileStatus(
            identity: FileIdentity(device: status.st_dev, inode: status.st_ino),
            isRegularFile: type == S_IFREG,
            isSymbolicLink: type == S_IFLNK,
            isDirectory: type == S_IFDIR,
            sizeInBytes: Int64(status.st_size),
            modificationDate: Date(
                timeIntervalSince1970: TimeInterval(status.st_mtimespec.tv_sec)
                    + TimeInterval(status.st_mtimespec.tv_nsec) / 1_000_000_000
            ),
            isUserImmutable: (flags & UInt32(UF_IMMUTABLE)) != 0,
            isSystemImmutable: (flags & UInt32(SF_IMMUTABLE)) != 0,
            isDataless: (flags & UInt32(SF_DATALESS)) != 0,
            isHidden: (flags & UInt32(UF_HIDDEN)) != 0
        )
    }
}
