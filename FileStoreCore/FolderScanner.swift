import Foundation
import os

/// Lists the top level of a folder. It reads only; it never changes anything on disk.
///
/// The scanner does not descend into subfolders, does not follow symbolic links, and skips
/// hidden items. It runs off the caller's actor and stops early when its task is cancelled.
/// Each record carries the metadata its reader finds: by default, last opened and download source
/// read from the item's extended attributes.
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

    /// Lists the top level of `location.folderURL`.
    ///
    /// - Returns: The readable items and any that had to be skipped.
    /// - Throws: `.folderNotFound`, `.accessDenied` or `.folderUnreadable` when the folder itself
    ///   cannot be listed, and `.cancelled` when the task is cancelled. One unreadable item is
    ///   reported in the result, not thrown.
    @concurrent
    public func scan(_ location: ScanLocation) async throws(FolderScanError) -> FolderScanResult {
        let folderURL = location.folderURL
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
                records.append(FileRecord(url: url, values: values, metadata: metadataReader.metadata(for: url)))
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
            folderURL: folderURL,
            records: records,
            skippedItems: skippedItems,
            scannedAt: .now
        )
    }

    /// Typed-throws stand-in for `Task.checkCancellation()`, which throws `CancellationError`.
    private static func throwIfCancelled() throws(FolderScanError) {
        if Task.isCancelled {
            throw .cancelled
        }
    }
}
