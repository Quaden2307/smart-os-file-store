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
    /// The space the item takes on disk: its allocated blocks, so a sparse file or a cloud
    /// placeholder counts what it really occupies, not its length.
    let allocatedSizeInBytes: Int64
    let modificationDate: Date
    /// When anything about the item last changed, its attributes included. No tool can set it back,
    /// unlike the modification date, so a cache keyed on it notices a file rewritten in place.
    let statusChangeDate: Date
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
            throw failure(errno)
        }
        return FileStatus(status)
    }

    /// Where `url` really is, with every link on the way resolved (`realpath`). Looks at each name
    /// and opens nothing. Nil when nothing is there.
    static func realPath(of url: URL) -> String? {
        guard let resolved = realpath(url.path(percentEncoded: false), nil) else {
            return nil
        }
        defer { free(resolved) }
        return String(cString: resolved)
    }

    /// When the item at `path` was added to its folder, read now with `getattrlist(2)`. A symbolic
    /// link is described itself. Nil when the volume does not record the date, including a volume
    /// that does not support the call at all (`ENOTSUP`, `EINVAL`): the modification date then
    /// decides alone, as it did for the scan.
    ///
    /// `lstat` has no such field, and `URL.resourceValues` may answer from a cache, so the executor
    /// asks the file system directly right before it acts.
    ///
    /// - Parameter folder: A directory descriptor that a relative `path` is looked up in, as with
    ///   `fstatat`. By default a path is resolved as usual.
    static func dateAdded(path: String, relativeTo folder: Int32 = AT_FDCWD) throws(Failure) -> Date? {
        try addedTime(path: path, relativeTo: folder).map(date(of:))
    }

    /// `time` as a `Date`.
    static func date(of time: timespec) -> Date {
        Date(timeIntervalSince1970: TimeInterval(time.tv_sec) + TimeInterval(time.tv_nsec) / 1_000_000_000)
    }

    /// The same Date Added, exactly as the volume stores it, so a move can set it back unchanged
    /// (`DiskChange.setDateAdded`).
    static func addedTime(path: String, relativeTo folder: Int32 = AT_FDCWD) throws(Failure) -> timespec? {
        var request = attrlist()
        request.bitmapcount = u_short(ATTR_BIT_MAP_COUNT)
        request.commonattr = attrgroup_t(ATTR_CMN_RETURNED_ATTRS) | attrgroup_t(ATTR_CMN_ADDEDTIME)
        // The reply: its length, which attributes were returned, then the time if it was.
        let returnedOffset = MemoryLayout<UInt32>.size
        let timeOffset = returnedOffset + MemoryLayout<attribute_set_t>.size
        var reply = [UInt8](repeating: 0, count: timeOffset + MemoryLayout<timespec>.size)
        let result = reply.withUnsafeMutableBytes { buffer in
            getattrlistat(folder, path, &request, buffer.baseAddress, buffer.count, UInt(FSOPT_NOFOLLOW))
        }
        guard result == 0 else {
            let code = errno
            if code == ENOTSUP || code == EINVAL {
                return nil
            }
            throw failure(code)
        }
        return reply.withUnsafeBytes { buffer -> timespec? in
            let returned = buffer.loadUnaligned(fromByteOffset: returnedOffset, as: attribute_set_t.self)
            guard returned.commonattr & attrgroup_t(ATTR_CMN_ADDEDTIME) != 0 else {
                return nil
            }
            return buffer.loadUnaligned(fromByteOffset: timeOffset, as: timespec.self)
        }
    }

    static func failure(_ code: Int32) -> Failure {
        switch code {
        case ENOENT, ENOTDIR:
            .notFound
        case EACCES, EPERM:
            .accessDenied
        default:
            .other(reason: String(cString: strerror(code)))
        }
    }
}

extension FileStatus {
    /// Describes what one `stat` family call returned.
    init(_ status: stat) {
        let type = status.st_mode & S_IFMT
        let flags = status.st_flags
        self.init(
            identity: FileIdentity(device: status.st_dev, inode: status.st_ino),
            isRegularFile: type == S_IFREG,
            isSymbolicLink: type == S_IFLNK,
            isDirectory: type == S_IFDIR,
            sizeInBytes: Int64(status.st_size),
            // `st_blocks` counts 512-byte units, whatever the volume's block size.
            allocatedSizeInBytes: Int64(status.st_blocks) * 512,
            modificationDate: Date(
                timeIntervalSince1970: TimeInterval(status.st_mtimespec.tv_sec)
                    + TimeInterval(status.st_mtimespec.tv_nsec) / 1_000_000_000
            ),
            statusChangeDate: Date(
                timeIntervalSince1970: TimeInterval(status.st_ctimespec.tv_sec)
                    + TimeInterval(status.st_ctimespec.tv_nsec) / 1_000_000_000
            ),
            isUserImmutable: (flags & UInt32(UF_IMMUTABLE)) != 0,
            isSystemImmutable: (flags & UInt32(SF_IMMUTABLE)) != 0,
            isDataless: (flags & UInt32(SF_DATALESS)) != 0,
            isHidden: (flags & UInt32(UF_HIDDEN)) != 0
        )
    }
}
