import Foundation

/// What a zip archive holds, read from its central directory alone: every entry's name, kind and
/// uncompressed size. Nothing is extracted and nothing is written (decision record 0011).
///
/// Reading is bounded whatever an archive declares (`Limits`). Its counts and sizes are checked
/// before anything is allocated, so a hostile archive cannot exhaust memory or time. The format's
/// rules are in `ZipCentralDirectory`; a zip on disk is read through `ZipArchiveFile`.
public struct ZipListing: Sendable, Hashable {
    /// The most an archive may declare before it is refused.
    public struct Limits: Sendable, Hashable {
        /// 100,000 entries, names of 1,024 bytes (the longest path macOS allows), and a central
        /// directory of 32 MiB. A zip of 50,000 small files has a directory of about 4 MiB.
        public static let standard = Limits(maximumEntryCount: 100_000, maximumNameLength: 1_024, maximumDirectorySize: 32 << 20)

        public let maximumEntryCount: Int

        /// In bytes, as stored.
        public let maximumNameLength: Int

        /// In bytes. The directory is read in one piece, so this is also the most memory it takes.
        public let maximumDirectorySize: Int

        public init(maximumEntryCount: Int, maximumNameLength: Int, maximumDirectorySize: Int) {
            self.maximumEntryCount = max(0, maximumEntryCount)
            self.maximumNameLength = max(0, maximumNameLength)
            self.maximumDirectorySize = max(0, maximumDirectorySize)
        }
    }

    /// Why what an archive holds cannot be listed. Nothing is guessed from part of a listing.
    public enum Problem: Sendable, Hashable {
        /// Not a zip, cut short, split over several disks, or with records that disagree. Bytes
        /// after the end record count too, and so does a second end record (decision record 0011).
        case damaged
        /// The central directory is itself encrypted, so not even the names can be read.
        case encryptedListing
        /// More entries than `Limits.maximumEntryCount`, or a central directory larger than
        /// `Limits.maximumDirectorySize`.
        case tooManyEntries
        /// A name longer than `Limits.maximumNameLength`.
        case nameTooLong
        /// A name that is not UTF-8: a legacy code page, which cannot be read reliably.
        case unreadableNames
    }

    /// Why a zip was not listed.
    public enum Failure: Error, Sendable, Hashable {
        case notFound
        case accessDenied
        /// In iCloud only. It is never opened: opening it would download it.
        case notDownloaded
        /// A symbolic link, a folder or anything else that is not a regular file. Links are never followed.
        case notARegularFile
        /// Not the file expected: another file, size or date than the one looked at, or it changed
        /// while it was being read.
        case changedSinceScan
        /// Reading failed for another reason; `reason` is the system's description.
        case unreadable(reason: String)
        /// The file was read, and what it holds cannot be listed.
        case unlistable(Problem)
        /// The task was cancelled before the listing was read.
        case cancelled
    }

    /// Every entry, in the order the central directory lists them.
    public let entries: [ZipEntry]

    public init(entries: [ZipEntry]) {
        self.entries = entries
    }

    /// Reads the zip at `url`, which is not followed if it is a symbolic link. The planner and the
    /// executor read through their handle on the scanned folder instead.
    @concurrent
    public static func read(at url: URL, limits: Limits = .standard) async throws(Failure) -> ZipListing {
        let path = url.path(percentEncoded: false)
        let looked: FileStatus
        do throws(FileStatus.Failure) {
            looked = try FileStatus.of(path: path)
        } catch {
            throw Failure(statusFailure: error)
        }
        try checkBeforeOpening(looked)
        return try read(try ZipArchiveFile.open(atPath: path), lookedAt: looked, limits: limits).listing
    }

    /// Lists a whole archive held in memory, such as one a test builds byte by byte.
    public static func parse(_ bytes: [UInt8], limits: Limits = .standard) throws(Failure) -> ZipListing {
        ZipListing(entries: try ZipCentralDirectory.entries(in: InMemoryZipBytes(storage: bytes), limits: limits))
    }

    /// The unpacked bytes of the entries at `paths` in an archive held in memory, as the installer
    /// reader reads them: only plain, unencrypted files, stored or deflated, of at most
    /// `maximumEntrySize` bytes; the others are missing from the result.
    public static func contents(
        ofEntries paths: Set<String>,
        inBytes bytes: [UInt8],
        maximumEntrySize: Int,
        limits: Limits = .standard
    ) throws(Failure) -> [String: [UInt8]] {
        let source = InMemoryZipBytes(storage: bytes)
        var contents: [String: [UInt8]] = [:]
        for record in try ZipCentralDirectory.records(in: source, limits: limits) where paths.contains(record.entry.path) {
            contents[record.entry.path] = try ZipCentralDirectory.contents(of: record, in: source, maximumSize: maximumEntrySize)
        }
        return contents
    }

    /// Reads the zip called `name` directly inside `folder`, through the handle and never through a
    /// link. `isExpected` decides from a look at the item, before it is opened, whether it is still
    /// the file the caller means.
    static func read(
        named name: String,
        in folder: DirectoryHandle,
        limits: Limits,
        isExpected: (FileStatus) -> Bool
    ) throws(Failure) -> ZipListing {
        let looked: FileStatus
        do throws(FileStatus.Failure) {
            looked = try folder.status(of: name)
        } catch {
            throw Failure(statusFailure: error)
        }
        try checkBeforeOpening(looked)
        guard isExpected(looked) else {
            throw .changedSinceScan
        }
        return try read(try ZipArchiveFile.open(named: name, in: folder), lookedAt: looked, limits: limits).listing
    }

    /// Reads the zip called `name` directly inside `folder`, as above, and the unpacked bytes of the
    /// entries `wanted` picks from the listing, each at most `maximumEntrySize` bytes packed and
    /// unpacked. An entry that is not a plain, unencrypted file, stored or deflated, within the limit
    /// is left out of the contents. Nothing is written: the bytes stay in memory.
    static func read(
        named name: String,
        in folder: DirectoryHandle,
        limits: Limits,
        contentsOf wanted: ([ZipEntry]) -> Set<String>,
        maximumEntrySize: Int
    ) throws(Failure) -> (listing: ZipListing, contents: [String: [UInt8]], status: FileStatus) {
        let looked: FileStatus
        do throws(FileStatus.Failure) {
            looked = try folder.status(of: name)
        } catch {
            throw Failure(statusFailure: error)
        }
        try checkBeforeOpening(looked)
        let read = try read(
            try ZipArchiveFile.open(named: name, in: folder),
            lookedAt: looked,
            limits: limits,
            contentsOf: wanted,
            maximumEntrySize: maximumEntrySize
        )
        return (read.listing, read.contents, looked)
    }

    /// Only a regular file is opened, and never a placeholder: opening one would download it.
    private static func checkBeforeOpening(_ looked: FileStatus) throws(Failure) {
        guard looked.isRegularFile else {
            throw .notARegularFile
        }
        if looked.isDataless {
            throw .notDownloaded
        }
    }

    /// Lists the open `file`, which must be the very file looked at and stay unchanged throughout,
    /// and reads the contents of the entries `wanted` picks.
    private static func read(
        _ file: ZipArchiveFile,
        lookedAt looked: FileStatus,
        limits: Limits,
        contentsOf wanted: ([ZipEntry]) -> Set<String> = { _ in [] },
        maximumEntrySize: Int = 0
    ) throws(Failure) -> (listing: ZipListing, contents: [String: [UInt8]]) {
        let opened = try file.status()
        guard opened.isRegularFile, opened.identity == looked.identity, isUnchanged(opened, since: looked) else {
            throw .changedSinceScan
        }
        let entries: [ZipEntry]
        var contents: [String: [UInt8]] = [:]
        do throws(Failure) {
            let records = try ZipCentralDirectory.records(in: file, limits: limits)
            entries = records.map(\.entry)
            let paths = wanted(entries)
            for record in records where paths.contains(record.entry.path) {
                contents[record.entry.path] = try ZipCentralDirectory.contents(of: record, in: file, maximumSize: maximumEntrySize)
            }
        } catch {
            // A file written to while it was read can look damaged; that is a change, not damage.
            if case .unlistable = error, let now = try? file.status(), !isUnchanged(now, since: opened) {
                throw .changedSinceScan
            }
            throw error
        }
        guard isUnchanged(try file.status(), since: opened) else {
            throw .changedSinceScan
        }
        return (ZipListing(entries: entries), contents)
    }

    private static func isUnchanged(_ status: FileStatus, since earlier: FileStatus) -> Bool {
        status.sizeInBytes == earlier.sizeInBytes && status.modificationDate == earlier.modificationDate
    }
}

extension ZipListing.Failure {
    init(statusFailure: FileStatus.Failure) {
        switch statusFailure {
        case .notFound:
            self = .notFound
        case .accessDenied:
            self = .accessDenied
        case .other(let reason):
            self = .unreadable(reason: reason)
        }
    }
}
