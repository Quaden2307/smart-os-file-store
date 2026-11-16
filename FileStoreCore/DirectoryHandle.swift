import Darwin

/// An open folder, held by file descriptor. A name looked up through it is found in this very
/// folder, whatever has happened to the path that led here since, and a folder below it is only
/// ever opened directly, never through a symbolic link. The executor checks and moves items through
/// these, so a link swapped into a path cannot send a rename anywhere else. Opening and reading
/// only; `DiskChange` makes the changes.
final class DirectoryHandle {
    enum OpenFailure: Error, Sendable, Hashable {
        case notFound
        /// A symbolic link sits at the name. It is never followed.
        case symbolicLink
        /// A file or something else that is not a folder sits at the name.
        case notAFolder
        case accessDenied
        /// Another failure; `code` is the `errno` value.
        case other(code: Int32)
    }

    /// The descriptor, open for as long as this handle lives.
    let descriptor: Int32

    private init(descriptor: Int32) {
        self.descriptor = descriptor
    }

    deinit {
        close(descriptor)
    }

    /// Opens the folder at `path`. A symbolic link at the path itself is followed, which is only
    /// right for the scanned folder: Downloads can be a link. The caller checks the folder's
    /// identity against the plan's before trusting it.
    static func open(path: String) throws(OpenFailure) -> DirectoryHandle {
        let descriptor = Darwin.open(path, O_RDONLY | O_DIRECTORY | O_CLOEXEC)
        guard descriptor >= 0 else {
            throw failure(errno)
        }
        return DirectoryHandle(descriptor: descriptor)
    }

    /// Opens the folder at `path` without following a symbolic link at the path itself: for an item
    /// named by its path alone, such as one in the Trash, whose folder cannot be opened.
    static func openWithoutFollowing(path: String) throws(OpenFailure) -> DirectoryHandle {
        let descriptor = Darwin.open(path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        guard descriptor >= 0 else {
            let code = errno
            if code == ENOTDIR || code == ELOOP {
                if let status = try? FileStatus.of(path: path), status.isSymbolicLink {
                    throw .symbolicLink
                }
            }
            throw failure(code)
        }
        return DirectoryHandle(descriptor: descriptor)
    }

    /// Opens the folder called `name` directly inside this one, never through a symbolic link.
    func openFolder(named name: String) throws(OpenFailure) -> DirectoryHandle {
        let child = openat(descriptor, name, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        guard child >= 0 else {
            let code = errno
            // A link opened with O_NOFOLLOW and O_DIRECTORY fails as "not a directory", like a
            // file does; the item itself tells them apart.
            if code == ENOTDIR || code == ELOOP {
                if let status = try? status(of: name), status.isSymbolicLink {
                    throw .symbolicLink
                }
                throw .notAFolder
            }
            throw Self.failure(code)
        }
        return DirectoryHandle(descriptor: child)
    }

    /// Opens the folder at `relativePath` below this one, several levels down at once: no symbolic
    /// link anywhere on the way is followed (ELOOP), and the path cannot lead out of this folder
    /// (ENOTCAPABLE), which only a link or `..` could make it do. Both fail as `.symbolicLink`. Only
    /// one descriptor is held, however deep the folder is.
    func openFolder(atRelativePath relativePath: String) throws(OpenFailure) -> DirectoryHandle {
        let child = openat(descriptor, relativePath, O_RDONLY | O_DIRECTORY | O_NOFOLLOW_ANY | O_RESOLVE_BENEATH | O_CLOEXEC)
        guard child >= 0 else {
            let code = errno
            switch code {
            case ELOOP, ENOTCAPABLE:
                throw .symbolicLink
            default:
                throw Self.failure(code)
            }
        }
        return DirectoryHandle(descriptor: child)
    }

    /// The folder itself, as it is now.
    func status() throws(FileStatus.Failure) -> FileStatus {
        var status = stat()
        guard fstat(descriptor, &status) == 0 else {
            throw FileStatus.failure(errno)
        }
        return FileStatus(status)
    }

    /// The item called `name` in this folder, as it is now. A symbolic link is described itself.
    func status(of name: String) throws(FileStatus.Failure) -> FileStatus {
        var status = stat()
        guard fstatat(descriptor, name, &status, AT_SYMLINK_NOFOLLOW) == 0 else {
            throw FileStatus.failure(errno)
        }
        return FileStatus(status)
    }

    /// The names of the items directly inside this folder, `.` and `..` left out, in the order the
    /// volume lists them, and no more than `limit` of them: a caller that refuses a big folder
    /// asks for one more than it allows, and the listing stops there. The folder is listed through
    /// a descriptor of its own, opened afresh for each listing, so a second listing starts from the
    /// beginning again. Reads only.
    func entryNames(limit: Int) throws(FileStatus.Failure) -> [String] {
        let listing = openat(descriptor, ".", O_RDONLY | O_DIRECTORY | O_CLOEXEC)
        guard listing >= 0 else {
            throw FileStatus.failure(errno)
        }
        guard let stream = fdopendir(listing) else {
            let code = errno
            close(listing)
            throw FileStatus.failure(code)
        }
        // Closes `listing` too.
        defer { closedir(stream) }
        var names: [String] = []
        while names.count < limit {
            errno = 0
            guard let entry = readdir(stream) else {
                // The end of the listing leaves `errno` as it was; a failure sets it.
                if errno != 0 {
                    throw FileStatus.failure(errno)
                }
                return names
            }
            let length = Int(entry.pointee.d_namlen)
            let name = withUnsafeBytes(of: entry.pointee.d_name) { bytes in
                String(decoding: bytes.prefix(length), as: UTF8.self)
            }
            if name != ".", name != ".." {
                names.append(name)
            }
        }
        return names
    }

    /// The longest name the folder's volume allows, in UTF-16 code units.
    var maximumNameLength: Int {
        let limit = fpathconf(descriptor, _PC_NAME_MAX)
        return limit > 0 ? limit : FileNameRules.defaultMaximumLength
    }

    private static func failure(_ code: Int32) -> OpenFailure {
        switch code {
        case ENOENT:
            .notFound
        case ENOTDIR, ELOOP:
            .notAFolder
        case EACCES, EPERM:
            .accessDenied
        default:
            .other(code: code)
        }
    }
}
