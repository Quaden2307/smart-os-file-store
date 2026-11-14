import Foundation

/// Folders the size of a real Downloads folder, for the scale tests and the benchmark: thousands of
/// small files and a few sparse files of several gigabytes. Sparse files cost no disk space and
/// read as zeros through the same code path as any file.
enum BulkFiles {
    /// Ten size classes, so every small file shares its size with many others and is hashed.
    static let smallSizes = [64, 128, 256, 512, 1_024, 2_048, 4_096, 8_192, 16_384, 32_768]
    private static let extensions = ["txt", "pdf", "jpg", "zip", "bin"]

    enum Failure: Error {
        case couldNotCreate(URL)
    }

    /// Writes `count` small files in identical pairs: `small-00000` and `small-00001` share size
    /// class and content, and so on, so a duplicate plan has `count / 2` groups to build.
    /// - Returns: The total size of the files.
    @discardableResult
    static func writeSmallFiles(count: Int, in folder: URL) throws -> Int64 {
        var total: Int64 = 0
        for index in 0..<count {
            let pair = index / 2
            let size = smallSizes[pair % smallSizes.count]
            var data = Data(count: size)
            withUnsafeBytes(of: UInt32(pair).bigEndian) { bytes in
                data.replaceSubrange(0..<4, with: bytes)
            }
            try data.write(to: folder.appending(path: smallFileName(index)))
            total += Int64(size)
        }
        return total
    }

    /// Where every bulk file was downloaded from, and with which app.
    static let downloadSources = ["https://example.com/files/bulk.bin", "https://example.com/downloads"]
    static let downloadingApp = "Safari"
    /// When every other bulk file was last opened: 2025-02-01 09:00 UTC, so it is Unused.
    static let lastOpened = Date(timeIntervalSince1970: 1_738_400_400)

    /// Gives each file `writeSmallFiles` made the attributes a real download carries: a download
    /// source and a quarantine attribute naming the browser, and to every other file (the even
    /// indexes) a last-opened date.
    /// - Returns: How many files got a last-opened date.
    @discardableResult
    static func addDownloadAttributes(count: Int, in folder: URL) throws -> Int {
        let quarantine = ExtendedAttributes.quarantineValue(app: downloadingApp, downloadedAt: lastOpened)
        var opened = 0
        for index in 0..<count {
            let file = folder.appending(path: smallFileName(index))
            try ExtendedAttributes.setWhereFroms(downloadSources, on: file)
            try ExtendedAttributes.setQuarantine(quarantine, on: file)
            if index.isMultiple(of: 2) {
                try ExtendedAttributes.setLastUsedDate(lastOpened, on: file)
                opened += 1
            }
        }
        return opened
    }

    /// `small-00000.txt`, `small-00001.txt`, `small-00002.pdf`…: the extension changes with each pair.
    private static func smallFileName(_ index: Int) -> String {
        String(format: "small-%05d.%@", index, extensions[(index / 2) % extensions.count])
    }

    /// A file of `size` bytes with nothing allocated: it reads as zeros.
    static func writeSparseFile(_ url: URL, size: Int64) throws {
        guard FileManager.default.createFile(atPath: url.path(percentEncoded: false), contents: nil) else {
            throw Failure.couldNotCreate(url)
        }
        let handle = try FileHandle(forWritingTo: url)
        try handle.truncate(atOffset: UInt64(size))
        try handle.close()
    }
}
