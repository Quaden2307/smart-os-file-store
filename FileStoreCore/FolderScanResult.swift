import Foundation

/// What one scan of a folder found.
public struct FolderScanResult: Sendable {
    /// An item the scanner saw but could not read. It is left out of `records`.
    public struct SkippedItem: Sendable, Equatable, Identifiable {
        public var id: URL { url }
        public let url: URL
        public let error: FolderScanError

        public init(url: URL, error: FolderScanError) {
            self.url = url
            self.error = error
        }
    }

    /// The folder that was scanned.
    public let folderURL: URL

    /// Every readable, non-hidden item at the top level, in file-system order.
    public let records: [FileRecord]

    /// Items that could not be read. One of these never fails the scan.
    public let skippedItems: [SkippedItem]

    /// When the scan finished.
    public let scannedAt: Date

    public init(folderURL: URL, records: [FileRecord], skippedItems: [SkippedItem], scannedAt: Date) {
        self.folderURL = folderURL
        self.records = records
        self.skippedItems = skippedItems
        self.scannedAt = scannedAt
    }
}
