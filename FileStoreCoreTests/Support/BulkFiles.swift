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
            let name = String(format: "small-%05d.%@", index, extensions[pair % extensions.count])
            try data.write(to: folder.appending(path: name))
            total += Int64(size)
        }
        return total
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
