import Foundation
import os

/// Lists the top level of a folder. It reads only; it never changes anything on disk.
///
/// The scanner does not descend into subfolders, does not follow symbolic links, and skips
/// hidden items. It runs off the caller's actor and stops early when its task is cancelled.
/// Each record carries the metadata its reader finds: by default, last opened and download source
/// read from the item's extended attributes. It also carries the item's identity on its volume,
/// read with `lstat` as the executor reads it, so the Kept list can follow the file, and a file's
/// space on disk from the same call. For a folder whose name ends in `.download` (Safari's partial
/// download) it reads what is inside (`PackageContents`), so Clear Failed Downloads can tell when it
/// last changed; for any other package, within `PackageContents.Limits.package`, so Review Large
/// Downloads knows the space it takes; and for a plain folder, only as far as it takes to tell whether
/// it is empty, for Remove Empty Folders, keeping what it read only when it is (or could not be told).
/// The archive is never read.
public struct FolderScanner: Sendable {
    /// The resource values fetched for every item in one call, so each record costs no extra
    /// file-system round trip.
    public static let resourceKeys: Set<URLResourceKey> = [
        .addedToDirectoryDateKey,
        .contentModificationDateKey,
        .fileSizeKey,
        .contentTypeKey,
        .localizedTypeDescriptionKey,
        .isDirectoryKey,
        .isSymbolicLinkKey,
        .isPackageKey,
        .isHiddenKey,
    ]

    /// How many items are processed between cancellation checks.
    private static let cancellationCheckInterval = 64

    private static let logger = Logger(subsystem: "com.quaden2307.FileStoreCore", category: "FolderScanner")

    private let metadataReader: any FileMetadataReading

    /// - Parameter metadataReader: Reads each item's last-opened date and download source. Tests
    ///   pass their own to give records metadata without writing any to disk.
    public init(metadataReader: any FileMetadataReading = ExtendedAttributeMetadataReader()) {
        self.metadataReader = metadataReader
    }

    /// Lists the top level of `folder`.
    ///
    /// - Returns: The readable items and any that had to be skipped.
    /// - Throws: `.folderNotFound`, `.accessDenied` or `.folderUnreadable` when the folder itself
    ///   cannot be listed, and `.cancelled` when the task is cancelled. One unreadable item is
    ///   reported in the result, not thrown.
    @concurrent
    public func scan(_ folder: ManagedFolder) async throws(FolderScanError) -> FolderScanResult {
        let folderURL = folder.url
        let clock = ContinuousClock()
        let start = clock.now

        try Self.throwIfCancelled()

        let urls: [URL]
        do {
            urls = try FileManager.default.contentsOfDirectory(
                at: folderURL,
                includingPropertiesForKeys: Array(Self.resourceKeys),
                options: [.skipsHiddenFiles]
            )
        } catch {
            let scanError = FolderScanError(listingError: error, folder: folderURL)
            // The system's description embeds the folder name, so it stays private; the domain
            // and code are enough to tell what went wrong from a log alone.
            let nsError = error as NSError
            Self.logger.error(
                "Could not list \(folderURL.path(percentEncoded: false), privacy: .private): \(nsError.domain, privacy: .public) \(nsError.code, privacy: .public) \(error.localizedDescription, privacy: .private)"
            )
            throw scanError
        }

        // Read once for the whole folder. Without it, records have no identity and the Kept list
        // compares paths instead, which still protects every item marked at its current path.
        let volume = VolumeIdentity.of(folderPath: folderURL.path(percentEncoded: false))
        if volume == nil {
            Self.logger.error("Could not read the volume of \(folderURL.path(percentEncoded: false), privacy: .private); items carry no identity")
        }

        // Opened only if there is a `.download` folder to read into, and through it alone, so a
        // link put in a name's place is never followed.
        var folderHandle: Result<DirectoryHandle, PackageContents.Failure>?

        var records: [FileRecord] = []
        records.reserveCapacity(urls.count)
        var skippedItems: [FolderScanResult.SkippedItem] = []

        for (index, url) in urls.enumerated() {
            if index.isMultiple(of: Self.cancellationCheckInterval) {
                try Self.throwIfCancelled()
            }
            do {
                let values = try url.resourceValues(forKeys: Self.resourceKeys)
                // `.skipsHiddenFiles` already filters these; the check costs nothing and
                // keeps the promise even if the listing options change later.
                if values.isHidden == true {
                    continue
                }
                // A folder's URL ends in `/`, and `lstat` on that would follow a link put at the name.
                let status = try? FileStatus.of(path: url.storedPath)
                let identity = status.flatMap { volume?.identity(of: $0) }
                var packageContents: Result<PackageContents, PackageContents.Failure>?
                if values.isDirectory == true, values.isSymbolicLink != true {
                    let limits: PackageContents.Limits?
                    if FailedDownloadPlanner.partialShape(ofName: url.lastPathComponent) == .folder {
                        limits = .standard
                    } else if values.isPackage == true {
                        limits = .package
                    } else {
                        limits = nil
                    }
                    let name = url.lastPathComponent
                    if let limits {
                        let handle = folderHandle ?? Self.openHandle(on: folderURL)
                        folderHandle = handle
                        packageContents = handle.flatMap { PackageContents.read(named: name, in: $0, limits: limits) }
                    } else if !CandidateEligibility.isExcludedName(name, archiveFolderName: folder.archiveFolderName) {
                        let handle = folderHandle ?? Self.openHandle(on: folderURL)
                        folderHandle = handle
                        switch handle {
                        case .success(let folder):
                            packageContents = PackageContents.readIfEmpty(named: name, in: folder)
                        case .failure(let failure):
                            packageContents = .failure(failure)
                        }
                    }
                }
                records.append(
                    FileRecord(
                        url: url,
                        values: values,
                        metadata: metadataReader.metadata(for: url),
                        identity: identity,
                        status: status,
                        packageContents: packageContents
                    )
                )
            } catch {
                skippedItems.append(
                    FolderScanResult.SkippedItem(
                        url: url,
                        error: .itemUnreadable(url, reason: error.localizedDescription)
                    )
                )
                let nsError = error as NSError
                Self.logger.warning(
                    "Skipped unreadable item \(url.path(percentEncoded: false), privacy: .private): \(nsError.domain, privacy: .public) \(nsError.code, privacy: .public) \(error.localizedDescription, privacy: .private)"
                )
            }
        }

        try Self.throwIfCancelled()

        Self.logger.info(
            "Scanned \(records.count) items, skipped \(skippedItems.count), in \((clock.now - start).milliseconds, format: .fixed(precision: 1)) ms"
        )

        return FolderScanResult(
            folder: folder,
            records: records,
            skippedItems: skippedItems,
            scannedAt: .now
        )
    }

    /// A handle on the scanned folder, which may itself be a link (Downloads can be).
    private static func openHandle(on folderURL: URL) -> Result<DirectoryHandle, PackageContents.Failure> {
        do throws(DirectoryHandle.OpenFailure) {
            return .success(try DirectoryHandle.open(path: folderURL.path(percentEncoded: false)))
        } catch {
            return .failure(PackageContents.Failure(openFailure: error))
        }
    }

    /// Typed-throws stand-in for `Task.checkCancellation()`, which throws `CancellationError`.
    private static func throwIfCancelled() throws(FolderScanError) {
        if Task.isCancelled {
            throw .cancelled
        }
    }
}
