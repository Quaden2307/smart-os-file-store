import CryptoKit
import Foundation
import os

/// Why a file could not be hashed.
public enum ContentHashError: Error, Sendable, Hashable {
    case fileNotFound(URL)

    case accessDenied(URL)

    /// The path is not a regular file: a symbolic link, a folder or a device. Links are never followed.
    case notARegularFile(URL)

    /// The file's size no longer matches what the scan saw.
    case changedSinceScan(URL)

    /// The file's bytes are not on this Mac yet (a cloud placeholder). Reading it would start a
    /// download, so it is left alone.
    case notDownloaded(URL)

    /// Reading failed for another reason. `reason` is the system's description.
    case readFailed(URL, reason: String)

    /// The task running the hash was cancelled before it finished.
    case cancelled
}

/// Hashes a file's bytes with SHA-256, streaming them through one fixed buffer so a file of any
/// size costs the same memory. It reads only, runs off the caller's actor and stops when its task
/// is cancelled.
public struct ContentHasher: Sendable {
    /// 1 MiB: large enough for full-speed reads, small enough to never matter.
    public static let defaultChunkSize = 1 << 20

    public let chunkSize: Int

    private static let logger = Logger(subsystem: "com.quaden2307.FileStoreCore", category: "ContentHasher")

    public init(chunkSize: Int = Self.defaultChunkSize) {
        self.chunkSize = max(1, chunkSize)
    }

    /// Hashes the file at `url`.
    ///
    /// - Parameters:
    ///   - expectedSizeInBytes: The size the scan saw. When the file's size differs, it is not
    ///     hashed and `.changedSinceScan` is thrown, so a plan never rests on stale information.
    ///   - onBytesRead: Called after each chunk with the number of bytes just read. It runs on the
    ///     hashing thread and must return quickly.
    /// - Throws: A `ContentHashError` naming the file, or `.cancelled`.
    @concurrent
    public func hash(
        contentsOf url: URL,
        expectedSizeInBytes: Int64? = nil,
        onBytesRead: (@Sendable (Int) -> Void)? = nil
    ) async throws(ContentHashError) -> ContentHash {
        do throws(ContentHashError) {
            return try Self.hashSynchronously(
                url: url,
                chunkSize: chunkSize,
                expectedSizeInBytes: expectedSizeInBytes,
                onBytesRead: onBytesRead
            )
        } catch {
            if error != .cancelled {
                Self.logger.warning(
                    "Could not hash \(url.path(percentEncoded: false), privacy: .private): \(error.logDescription, privacy: .public)"
                )
            }
            throw error
        }
    }

    /// The read loop. Synchronous on purpose: the buffer never lives across a suspension point,
    /// and `read(2)` into one reusable buffer leaves no per-chunk allocations behind, unlike
    /// `FileHandle`, whose autoreleased chunks pile up until the pool drains.
    private static func hashSynchronously(
        url: URL,
        chunkSize: Int,
        expectedSizeInBytes: Int64?,
        onBytesRead: (@Sendable (Int) -> Void)?
    ) throws(ContentHashError) -> ContentHash {
        let path = url.path(percentEncoded: false)

        // Look before opening: `lstat` describes a link itself and, unlike `open(2)`, never makes
        // a cloud provider download a dataless placeholder, which would block this thread for as
        // long as the download takes and ignore cancellation.
        let status: FileStatus
        do throws(FileStatus.Failure) {
            status = try FileStatus.of(path: path)
        } catch {
            throw ContentHashError(statusFailure: error, url: url)
        }
        guard status.isRegularFile else {
            throw .notARegularFile(url)
        }
        if status.isDataless {
            throw .notDownloaded(url)
        }
        if let expectedSizeInBytes, status.sizeInBytes != expectedSizeInBytes {
            throw .changedSinceScan(url)
        }

        // O_NOFOLLOW: a symbolic link put in the file's place after the scan is refused, not followed.
        let descriptor = open(path, O_RDONLY | O_NOFOLLOW | O_CLOEXEC)
        guard descriptor >= 0 else {
            throw openError(errno, url: url)
        }
        defer { close(descriptor) }

        // The path could have been swapped between `lstat` and `open`; check what was opened.
        var opened = stat()
        guard fstat(descriptor, &opened) == 0 else {
            throw .readFailed(url, reason: describe(errno))
        }
        guard (opened.st_mode & S_IFMT) == S_IFREG else {
            throw .notARegularFile(url)
        }

        let buffer = UnsafeMutableRawBufferPointer.allocate(
            byteCount: chunkSize,
            alignment: MemoryLayout<UInt64>.alignment
        )
        defer { buffer.deallocate() }

        var hasher = SHA256()
        var totalBytes: Int64 = 0
        while true {
            if Task.isCancelled {
                throw .cancelled
            }
            let count = read(descriptor, buffer.baseAddress, buffer.count)
            if count < 0 {
                if errno == EINTR {
                    continue
                }
                throw .readFailed(url, reason: describe(errno))
            }
            if count == 0 {
                break
            }
            hasher.update(bufferPointer: UnsafeRawBufferPointer(start: buffer.baseAddress, count: count))
            totalBytes += Int64(count)
            // A file that grew while being read is reported before its extra bytes are, so
            // progress never counts more than the scan said there was.
            if let expectedSizeInBytes, totalBytes > expectedSizeInBytes {
                throw .changedSinceScan(url)
            }
            onBytesRead?(count)
        }

        // The file may have shrunk while it was being read.
        if let expectedSizeInBytes, totalBytes != expectedSizeInBytes {
            throw .changedSinceScan(url)
        }
        return ContentHash(hasher.finalize())
    }

    private static func openError(_ code: Int32, url: URL) -> ContentHashError {
        switch code {
        case ENOENT, ENOTDIR:
            .fileNotFound(url)
        case EACCES, EPERM:
            .accessDenied(url)
        case ELOOP:
            // O_NOFOLLOW reports a symbolic link this way.
            .notARegularFile(url)
        default:
            .readFailed(url, reason: describe(code))
        }
    }

    private static func describe(_ code: Int32) -> String {
        String(cString: strerror(code))
    }
}

extension ContentHashError {
    fileprivate init(statusFailure: FileStatus.Failure, url: URL) {
        switch statusFailure {
        case .notFound:
            self = .fileNotFound(url)
        case .accessDenied:
            self = .accessDenied(url)
        case .other(let reason):
            self = .readFailed(url, reason: reason)
        }
    }

    /// A description without the path, which stays private in logs.
    fileprivate var logDescription: String {
        switch self {
        case .fileNotFound:
            "file not found"
        case .accessDenied:
            "access denied"
        case .notARegularFile:
            "not a regular file"
        case .changedSinceScan:
            "changed since scan"
        case .notDownloaded:
            "not downloaded"
        case .readFailed(_, let reason):
            "read failed: \(reason)"
        case .cancelled:
            "cancelled"
        }
    }
}
