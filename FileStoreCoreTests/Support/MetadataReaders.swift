import FileStoreCore
import Foundation

/// Reads no metadata at all: the scan the app made before last opened and download sources were
/// read, for comparison in the benchmark.
struct NoMetadataReader: FileMetadataReading {
    func metadata(for url: URL) -> FileMetadata {
        FileMetadata()
    }
}

/// Supplies metadata by file name, so a test can give records any metadata without touching disk.
struct FixedMetadataReader: FileMetadataReading {
    let metadataByName: [String: FileMetadata]

    func metadata(for url: URL) -> FileMetadata {
        metadataByName[url.lastPathComponent] ?? FileMetadata()
    }
}
