import Darwin

/// A zip open for reading, held by descriptor. It is read with `pread` alone, so no file position
/// is shared or moved, and nothing here can change the file. The descriptor closes with it. The
/// installer readers read packages and `Info.plist` files through it too.
final class ZipArchiveFile: ZipByteSource {
    /// Read only: never for writing, never through a link at the name, and never waiting on a pipe
    /// put at the name after it was looked at.
    private static let openFlags = O_RDONLY | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC

    private let descriptor: Int32

    /// The size when it was opened. The listing reads nothing past it.
    let byteCount: UInt64

    private init(descriptor: Int32, byteCount: UInt64) {
        self.descriptor = descriptor
        self.byteCount = byteCount
    }

    deinit {
        close(descriptor)
    }

    /// Opens the item called `name` directly inside `folder`.
    static func open(named name: String, in folder: DirectoryHandle) throws(ZipListing.Failure) -> ZipArchiveFile {
        let descriptor = openat(folder.descriptor, name, openFlags)
        guard descriptor >= 0 else {
            throw ZipListing.Failure(openError: errno)
        }
        return try adopt(descriptor)
    }

    /// Opens the item at `path`. A symbolic link at the path itself is not followed.
    static func open(atPath path: String) throws(ZipListing.Failure) -> ZipArchiveFile {
        let descriptor = Darwin.open(path, openFlags)
        guard descriptor >= 0 else {
            throw ZipListing.Failure(openError: errno)
        }
        return try adopt(descriptor)
    }

    private static func adopt(_ descriptor: Int32) throws(ZipListing.Failure) -> ZipArchiveFile {
        var status = stat()
        guard fstat(descriptor, &status) == 0 else {
            let code = errno
            close(descriptor)
            throw .unreadable(reason: String(cString: strerror(code)))
        }
        return ZipArchiveFile(descriptor: descriptor, byteCount: UInt64(max(0, status.st_size)))
    }

    /// The open file as it is now.
    func status() throws(ZipListing.Failure) -> FileStatus {
        var status = stat()
        guard fstat(descriptor, &status) == 0 else {
            throw .unreadable(reason: String(cString: strerror(errno)))
        }
        return FileStatus(status)
    }

    func bytes(at offset: UInt64, count: Int) throws(ZipListing.Failure) -> [UInt8] {
        guard count >= 0,
              let start = off_t(exactly: offset),
              offset <= byteCount,
              UInt64(count) <= byteCount - offset else {
            throw .unlistable(.damaged)
        }
        var buffer = [UInt8](repeating: 0, count: count)
        var filled = 0
        while filled < count {
            let (result, code) = buffer.withUnsafeMutableBytes { raw -> (Int, Int32) in
                guard let base = raw.baseAddress else {
                    return (0, 0)
                }
                let result = pread(descriptor, base + filled, count - filled, start + off_t(filled))
                return (result, result < 0 ? errno : 0)
            }
            if result < 0 {
                if code == EINTR {
                    continue
                }
                throw .unreadable(reason: String(cString: strerror(code)))
            }
            // The file ends before the size it had when opened: it was cut short meanwhile.
            guard result > 0 else {
                throw .unlistable(.damaged)
            }
            filled += result
        }
        return buffer
    }
}

extension ZipListing.Failure {
    /// The failure matching an `open` that did not succeed.
    init(openError code: Int32) {
        switch code {
        case ENOENT, ENOTDIR:
            self = .notFound
        case EACCES, EPERM:
            self = .accessDenied
        case ELOOP:
            // O_NOFOLLOW refuses a symbolic link put at the name.
            self = .notARegularFile
        default:
            self = .unreadable(reason: String(cString: strerror(code)))
        }
    }
}
