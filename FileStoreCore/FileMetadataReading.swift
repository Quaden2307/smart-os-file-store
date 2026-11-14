import Foundation

/// Reads an item's `FileMetadata`. The scanner calls it once for each item it lists.
///
/// `ExtendedAttributeMetadataReader` reads from disk. Tests and planners supply their own reader,
/// so they can give records any metadata without touching a file.
public protocol FileMetadataReading: Sendable {
    /// What macOS recorded about the item at `url`. Never fails: anything missing, unreadable or
    /// malformed is nil.
    func metadata(for url: URL) -> FileMetadata
}
