import Foundation
import UniformTypeIdentifiers

/// One item at the top level of the scanned folder, as it was when the scan ran.
///
/// Records are plain values. The scanner builds them, the interface shows them, and later
/// segments hand them to planners. Nothing here touches the disk after the scan.
public struct FileRecord: Sendable, Identifiable, Hashable {
    /// What kind of item sits at the URL.
    public enum Kind: Sendable, Hashable {
        /// A regular file.
        case file
        /// A plain folder. Its contents are not listed.
        case folder
        /// A symbolic link. It is never followed; the record describes the link itself.
        case symlink
        /// A folder macOS presents as a single item, for example an `.app`.
        case package
    }

    /// The item's URL, which is also its identity within one scan.
    public var id: URL { url }

    public let url: URL

    /// The file name exactly as it is on disk, including the extension.
    public let displayName: String

    public let kind: Kind

    /// macOS's description of the type, for example "PDF document". Nil when macOS has none.
    public let localizedTypeDescription: String?

    /// The uniform type, for example `.pdf`. Nil when macOS could not determine one.
    public let contentType: UTType?

    /// Size in bytes. Nil for folders and packages, whose contents are never read.
    public let sizeInBytes: Int64?

    /// When the item was added to the scanned folder. Nil when the file system does not track it.
    public let dateAdded: Date?

    /// When the item's contents last changed.
    public let dateModified: Date?

    /// True when the name ends in an extension browsers use for downloads still in progress.
    public let isDownloading: Bool

    /// When a user last opened the item, as macOS records it. Nil when it recorded none: the item
    /// was never opened, or it is a kind macOS records no date for (see `recordsLastOpened`).
    public let lastOpened: Date?

    /// Where the item was downloaded from. Nil when macOS recorded nothing.
    public let downloadSource: DownloadSource?

    /// False when the last-opened date could not be read at all (see `FileMetadata`), so a missing
    /// date means unknown, not never opened.
    public let canReadLastOpened: Bool

    /// Which file this is on its volume, however it is named later: what the Kept list follows.
    /// Nil when the volume gives its items no lasting identity, or it could not be read.
    public let persistentIdentity: PersistentFileIdentity?

    /// What is inside the item, for a folder whose name ends in `.download` (Safari's partial
    /// download), a package, or a plain folder the scan found empty (`isEmptyFolder`), or why it
    /// could not be read in full. Nil for files, links, the archive, and a plain folder holding
    /// anything but folders and the files macOS makes by itself.
    public let packageContents: Result<PackageContents, PackageContents.Failure>?

    /// The space the item takes on disk, in bytes: a file's allocated blocks, or for a package whose
    /// contents were read, theirs in total. A sparse file or a cloud placeholder counts what it
    /// really occupies. Nil for folders and links, and for a package not read in full.
    public let allocatedSizeInBytes: Int64?

    public init(
        url: URL,
        displayName: String,
        kind: Kind,
        localizedTypeDescription: String?,
        contentType: UTType?,
        sizeInBytes: Int64?,
        dateAdded: Date?,
        dateModified: Date?,
        isDownloading: Bool,
        lastOpened: Date? = nil,
        downloadSource: DownloadSource? = nil,
        canReadLastOpened: Bool = true,
        persistentIdentity: PersistentFileIdentity? = nil,
        packageContents: Result<PackageContents, PackageContents.Failure>? = nil,
        allocatedSizeInBytes: Int64? = nil
    ) {
        self.url = url
        self.displayName = displayName
        self.kind = kind
        self.localizedTypeDescription = localizedTypeDescription
        self.contentType = contentType
        self.sizeInBytes = sizeInBytes
        self.dateAdded = dateAdded
        self.dateModified = dateModified
        self.isDownloading = isDownloading
        self.lastOpened = lastOpened
        self.downloadSource = downloadSource
        self.canReadLastOpened = canReadLastOpened
        self.persistentIdentity = persistentIdentity
        self.packageContents = packageContents
        self.allocatedSizeInBytes = allocatedSizeInBytes
    }

    /// The contents the scan read in full. Nil when it read none, or not all of them.
    public var readContents: PackageContents? {
        guard case .success(let contents) = packageContents else {
            return nil
        }
        return contents
    }

    /// The item's size for a cleanup: a file's size, or for a folder whose contents were read, the
    /// total of its files. Nil otherwise.
    public var contentSizeInBytes: Int64? {
        sizeInBytes ?? readContents?.totalSizeInBytes
    }

    /// When anything about the item last changed: the modification date, or for a folder whose
    /// contents were read, the later of its own date and the newest of anything inside it. Adding
    /// or removing an item changes the folder's own date; writing to one inside changes only that
    /// one's.
    public var lastChange: Date? {
        guard let contents = readContents else {
            return dateModified
        }
        guard let dateModified else {
            return contents.newestModificationDate
        }
        return contents.lastChange(ofFolderModifiedAt: dateModified)
    }

    /// True when a missing last-opened date means the item was never opened: it is a kind macOS
    /// dates when a user opens it (files and document packages, a Keynote file say), and its date
    /// could be read. macOS records none for folders or apps, and opening a symbolic link or a
    /// Finder alias opens its target, so for those a missing date means "not recorded".
    public var recordsLastOpened: Bool {
        guard canReadLastOpened else {
            return false
        }
        switch kind {
        case .file:
            return !(contentType?.conforms(to: .aliasFile) ?? false)
        case .package:
            return !(contentType?.conforms(to: .application) ?? false)
        case .folder, .symlink:
            return false
        }
    }

    /// Extensions browsers give to files that are still being downloaded. Compared case-insensitively.
    /// Clear Failed Downloads' partial downloads, so the two rules always name the same items.
    public static let inProgressDownloadExtensions: Set<String> =
        FailedDownloadPlanner.partialFileExtensions.union([FailedDownloadPlanner.partialFolderExtension])

    /// True when `url` names a download that is still in progress.
    public static func isInProgressDownload(_ url: URL) -> Bool {
        inProgressDownloadExtensions.contains(url.pathExtension.lowercased())
    }

    /// True when an item called `name` would be taken for a download still in progress, by the
    /// same rule as `isInProgressDownload(_:)`.
    public static func isInProgressDownload(name: String) -> Bool {
        isInProgressDownload(URL(filePath: name, directoryHint: .notDirectory))
    }
}

extension FileRecord {
    /// Builds a record from resource values the scanner already fetched for `url`, the metadata it
    /// read for it, its identity, its status (for a file's space on disk), and for a `.download`
    /// folder or a package, what is inside it.
    ///
    /// Resource values describe a symbolic link itself, not its target, so a link is never
    /// mistaken for a folder. A package is also a directory, so it is checked before `folder`.
    init(
        url: URL,
        values: URLResourceValues,
        metadata: FileMetadata,
        identity: PersistentFileIdentity?,
        status: FileStatus?,
        packageContents: Result<PackageContents, PackageContents.Failure>?
    ) {
        let kind: Kind
        if values.isSymbolicLink == true {
            kind = .symlink
        } else if values.isPackage == true {
            kind = .package
        } else if values.isDirectory == true {
            kind = .folder
        } else {
            kind = .file
        }

        let sizeInBytes: Int64?
        let allocatedSizeInBytes: Int64?
        switch kind {
        case .folder, .package:
            sizeInBytes = nil
            if kind == .package, case .success(let contents) = packageContents {
                allocatedSizeInBytes = contents.allocatedSizeInBytes
            } else {
                allocatedSizeInBytes = nil
            }
        case .file:
            sizeInBytes = values.fileSize.map(Int64.init)
            // Only a status of a regular file: one read of something else at the name says nothing.
            allocatedSizeInBytes = status?.isRegularFile == true ? status?.allocatedSizeInBytes : nil
        case .symlink:
            sizeInBytes = values.fileSize.map(Int64.init)
            allocatedSizeInBytes = nil
        }

        self.init(
            url: url,
            displayName: url.lastPathComponent,
            kind: kind,
            localizedTypeDescription: values.localizedTypeDescription,
            contentType: values.contentType,
            sizeInBytes: sizeInBytes,
            dateAdded: values.addedToDirectoryDate,
            dateModified: values.contentModificationDate,
            isDownloading: Self.isInProgressDownload(url),
            lastOpened: metadata.lastOpened,
            downloadSource: metadata.downloadSource,
            canReadLastOpened: metadata.canReadLastOpened,
            persistentIdentity: identity,
            packageContents: packageContents,
            allocatedSizeInBytes: allocatedSizeInBytes
        )
    }
}
