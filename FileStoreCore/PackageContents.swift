import Foundation

/// What is inside a folder, read from the disk: how many items, the total size of its files, the
/// space they take on disk, and the newest modification date of anything in it. The engine reads
/// inside a Safari download (`.download`), to tell whether anything about it changed, and a package
/// (such as an `.app`), to total what it takes on disk for Review Large Downloads: the scan, the
/// executor right before the Trash, and undo before it puts one back all read it this one way, so
/// all three see the same values.
///
/// Every item is described with `lstat` semantics: a symbolic link is counted as itself and never
/// followed, and a folder inside is opened only directly, never through a link. Nothing is written.
public struct PackageContents: Sendable, Hashable {
    /// Why the contents were not read in full. Nothing is guessed from a partial reading.
    public enum Failure: Error, Sendable, Hashable {
        /// More than `maximumItemCount` items, or folders nested deeper than `maximumDepth`: not the
        /// small folder a download is.
        case tooManyItems
        /// The folder, or one inside it, is in iCloud only; listing it would download it.
        case notDownloaded
        case accessDenied
        /// Another failure; `reason` is the system's description.
        case unreadable(reason: String)
        /// The task reading it was cancelled.
        case cancelled
    }

    /// How much one reading may take in: items and nesting. A reading that would take in more fails
    /// with `.tooManyItems`.
    public struct Limits: Sendable, Hashable {
        public let maximumItemCount: Int
        /// Each level holds one folder open while the next is read.
        public let maximumDepth: Int

        /// For a Safari download, which holds two items.
        public static let standard = Limits(maximumItemCount: PackageContents.maximumItemCount, maximumDepth: PackageContents.maximumDepth)

        // shortcut: every scan reads every package this far, so a bigger one (Xcode holds hundreds of
        // thousands of items) is left unsized and never listed as large; read sizes another way (the
        // volume's own count, or only when Review Large Downloads plans) if that proves common.
        /// For a package, such as an app, which can hold many thousands of files.
        public static let package = Limits(maximumItemCount: 25_000, maximumDepth: 32)
    }

    /// The most items read inside one folder by `Limits.standard`. A Safari download holds two.
    public static let maximumItemCount = 1_000

    /// The deepest nesting read by `Limits.standard`.
    public static let maximumDepth = 16

    /// Files, folders and links inside, at every depth.
    public let itemCount: Int

    /// The total size of the regular files inside, in bytes.
    public let totalSizeInBytes: Int64

    /// The space the regular files inside take on disk, in bytes: their allocated blocks, so sparse
    /// files and cloud placeholders count what they really occupy.
    public let allocatedSizeInBytes: Int64

    /// The newest modification date of anything inside. Nil when the folder is empty.
    public let newestModificationDate: Date?

    /// Equal when the count, size and newest date are: what tells whether anything about a folder
    /// changed. The space on disk is left out, since compression, or iCloud evicting a file, changes
    /// it without anything the user would call a change.
    public static func == (lhs: PackageContents, rhs: PackageContents) -> Bool {
        lhs.itemCount == rhs.itemCount && lhs.totalSizeInBytes == rhs.totalSizeInBytes
            && lhs.newestModificationDate == rhs.newestModificationDate
    }

    public func hash(into hasher: inout Hasher) {
        hasher.combine(itemCount)
        hasher.combine(totalSizeInBytes)
        hasher.combine(newestModificationDate)
    }

    public init(itemCount: Int, totalSizeInBytes: Int64, newestModificationDate: Date?, allocatedSizeInBytes: Int64 = 0) {
        self.itemCount = itemCount
        self.totalSizeInBytes = totalSizeInBytes
        self.allocatedSizeInBytes = allocatedSizeInBytes
        self.newestModificationDate = newestModificationDate
    }

    /// When anything about a folder holding these contents last changed: the later of the folder's
    /// own modification date, which adding or removing an item moves, and the newest inside.
    public func lastChange(ofFolderModifiedAt folderDate: Date) -> Date {
        guard let newestModificationDate else {
            return folderDate
        }
        return max(folderDate, newestModificationDate)
    }

    /// Reads the folder called `name` directly inside `parent`. A link at the name is not followed.
    static func read(named name: String, in parent: DirectoryHandle, limits: Limits = .standard) -> Result<PackageContents, Failure> {
        // A folder in iCloud only is not even opened.
        if (try? parent.status(of: name))?.isDataless == true {
            return .failure(.notDownloaded)
        }
        let folder: DirectoryHandle
        do throws(DirectoryHandle.OpenFailure) {
            folder = try parent.openFolder(named: name)
        } catch {
            return .failure(Failure(openFailure: error))
        }
        return read(folder, limits: limits)
    }

    /// Reads the folder at `path`, which is not followed if it is a link: for an item in the Trash,
    /// whose folder cannot be opened.
    static func read(atPath path: String, limits: Limits = .standard) -> Result<PackageContents, Failure> {
        if (try? FileStatus.of(path: path))?.isDataless == true {
            return .failure(.notDownloaded)
        }
        let folder: DirectoryHandle
        do throws(DirectoryHandle.OpenFailure) {
            folder = try DirectoryHandle.openWithoutFollowing(path: path)
        } catch {
            return .failure(Failure(openFailure: error))
        }
        return read(folder, limits: limits)
    }

    private static func read(_ folder: DirectoryHandle, limits: Limits) -> Result<PackageContents, Failure> {
        var tally = Tally(limits: limits)
        do throws(Failure) {
            try tally.add(folder, depth: 1)
        } catch {
            return .failure(error)
        }
        return .success(
            PackageContents(
                itemCount: tally.count,
                totalSizeInBytes: tally.size,
                newestModificationDate: tally.newest,
                allocatedSizeInBytes: tally.allocated
            )
        )
    }

    /// The running totals of one reading.
    private struct Tally {
        let limits: Limits
        var count = 0
        var size: Int64 = 0
        var allocated: Int64 = 0
        var newest: Date?

        /// Adds everything inside `folder`, which is `depth` levels below the folder being read.
        mutating func add(_ folder: DirectoryHandle, depth: Int) throws(Failure) {
            // Checked on the open folder itself, so nothing can be swapped in between: a folder in
            // iCloud only is never listed.
            let status: FileStatus
            do throws(FileStatus.Failure) {
                status = try folder.status()
            } catch {
                throw Failure(statusFailure: error)
            }
            if status.isDataless {
                throw .notDownloaded
            }
            // A package can hold thousands of items: a cancelled scan or run stops between folders.
            if Task.isCancelled {
                throw .cancelled
            }
            let names: [String]
            do throws(FileStatus.Failure) {
                // One more than the items still allowed, so a folder too big is found without
                // listing all of it.
                names = try folder.entryNames(limit: limits.maximumItemCount - count + 1)
            } catch {
                throw Failure(statusFailure: error)
            }
            for name in names {
                count += 1
                guard count <= limits.maximumItemCount else {
                    throw .tooManyItems
                }
                let item: FileStatus
                do throws(FileStatus.Failure) {
                    item = try folder.status(of: name)
                } catch {
                    throw Failure(statusFailure: error)
                }
                newest = max(newest ?? item.modificationDate, item.modificationDate)
                if item.isRegularFile {
                    size += item.sizeInBytes
                    allocated += item.allocatedSizeInBytes
                } else if item.isDirectory {
                    if item.isDataless {
                        throw .notDownloaded
                    }
                    guard depth < limits.maximumDepth else {
                        throw .tooManyItems
                    }
                    let child: DirectoryHandle
                    do throws(DirectoryHandle.OpenFailure) {
                        child = try folder.openFolder(named: name)
                    } catch {
                        throw Failure(openFailure: error)
                    }
                    try add(child, depth: depth + 1)
                }
            }
        }
    }
}

extension PackageContents.Failure {
    init(statusFailure: FileStatus.Failure) {
        switch statusFailure {
        case .notFound:
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
            self = .unreadable(reason: "a symbolic link")
        case .notAFolder:
            self = .unreadable(reason: String(cString: strerror(ENOTDIR)))
        case .other(let code):
            self = .unreadable(reason: String(cString: strerror(code)))
        }
    }
}

extension CleanupSkipReason {
    /// The reason matching a folder's contents that could not be read. Nil for `.tooManyItems`: such
    /// a folder is not a download, so it is not reported as one that could not be checked.
    init?(packageFailure: PackageContents.Failure) {
        switch packageFailure {
        case .tooManyItems:
            return nil
        case .notDownloaded:
            self = .notDownloaded
        case .accessDenied:
            self = .accessDenied
        case .unreadable(let reason):
            self = .unreadable(reason: reason)
        case .cancelled:
            self = .cancelled
        }
    }
}
