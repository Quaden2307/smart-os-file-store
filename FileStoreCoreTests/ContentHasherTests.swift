import CryptoKit
import FileStoreCore
import Foundation
import Testing

@Suite("ContentHasher")
struct ContentHasherTests {
    private let hasher = ContentHasher()
    private static let mebibyte = 1_048_576

    /// Deterministic pseudo-random bytes, so a multi-chunk file has no repeating pattern that a
    /// chunk-boundary bug could hide behind.
    private func pseudoRandomData(count: Int) -> Data {
        var state: UInt64 = 0x9E37_79B9_7F4A_7C15
        var bytes = [UInt8](repeating: 0, count: count)
        for index in bytes.indices {
            state = state &* 6_364_136_223_846_793_005 &+ 1_442_695_040_888_963_407
            bytes[index] = UInt8(truncatingIfNeeded: state >> 56)
        }
        return Data(bytes)
    }

    @Test func matchesCryptoKitForMultiChunkFile() async throws {
        let temp = try TemporaryFolder.make()
        defer { temp.remove() }
        let url = temp.url.appending(path: "random.bin")
        let data = pseudoRandomData(count: Self.mebibyte * 5 / 2)
        try data.write(to: url)

        let hash = try await hasher.hash(contentsOf: url, expectedSizeInBytes: Int64(data.count))

        #expect(hash.bytes == Array(SHA256.hash(data: data)))
        #expect(hash.hexString.count == 64)
    }

    @Test func matchesKnownVector() async throws {
        let temp = try TemporaryFolder.make()
        defer { temp.remove() }
        let url = temp.url.appending(path: "hello.txt")
        try Data("hello".utf8).write(to: url)

        let hash = try await hasher.hash(contentsOf: url)

        #expect(hash.hexString == "2cf24dba5fb0a30e26e83b2ac5b9e29e1b161e5c1fa7425e73043362938b9824")
    }

    @Test func reportsBytesRead() async throws {
        let temp = try TemporaryFolder.make()
        defer { temp.remove() }
        let url = temp.url.appending(path: "random.bin")
        let size = Self.mebibyte * 5 / 2
        try pseudoRandomData(count: size).write(to: url)
        let chunks = ConcurrentLog<Int>()

        _ = try await hasher.hash(contentsOf: url) { chunks.append($0) }

        #expect(chunks.values.reduce(0, +) == size)
        #expect(chunks.values.count == 3)
        #expect(chunks.values.allSatisfy { $0 > 0 && $0 <= Self.mebibyte })
    }

    @Test func missingFileIsNotFound() async throws {
        let temp = try TemporaryFolder.make()
        defer { temp.remove() }
        let url = temp.url.appending(path: "missing.pdf")

        await #expect(throws: ContentHashError.fileNotFound(url)) {
            try await hasher.hash(contentsOf: url)
        }
    }

    @Test func folderAndSymlinkAreNotRegularFiles() async throws {
        let temp = try TemporaryFolder.make()
        defer { temp.remove() }
        let folder = temp.url.appending(path: "Folder", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: false)
        let target = temp.url.appending(path: "target.txt")
        try Data("target".utf8).write(to: target)
        let link = temp.url.appending(path: "link.txt")
        try FileManager.default.createSymbolicLink(
            atPath: link.path(percentEncoded: false),
            withDestinationPath: "target.txt"
        )

        await #expect(throws: ContentHashError.notARegularFile(folder)) {
            try await hasher.hash(contentsOf: folder)
        }
        await #expect(throws: ContentHashError.notARegularFile(link)) {
            try await hasher.hash(contentsOf: link)
        }
    }

    @Test func unreadableFileIsAccessDenied() async throws {
        let temp = try TemporaryFolder.make()
        defer { temp.remove() }
        let url = temp.url.appending(path: "secret.txt")
        try Data("secret".utf8).write(to: url)
        let path = url.path(percentEncoded: false)
        try FileManager.default.setAttributes([.posixPermissions: 0o000], ofItemAtPath: path)
        defer { try? FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: path) }

        await #expect(throws: ContentHashError.accessDenied(url)) {
            try await hasher.hash(contentsOf: url)
        }
    }

    @Test func sizeMismatchIsChangedSinceScan() async throws {
        let temp = try TemporaryFolder.make()
        defer { temp.remove() }
        let url = temp.url.appending(path: "report.pdf")
        try Data("quarterly report body".utf8).write(to: url)

        await #expect(throws: ContentHashError.changedSinceScan(url)) {
            try await hasher.hash(contentsOf: url, expectedSizeInBytes: 22)
        }
        _ = try await hasher.hash(contentsOf: url, expectedSizeInBytes: 21)
    }

    @Test func cancelledHashThrowsCancelled() async throws {
        let temp = try TemporaryFolder.make()
        defer { temp.remove() }
        let url = temp.url.appending(path: "report.pdf")
        try Data("quarterly report body".utf8).write(to: url)
        let hasher = hasher
        // The task cancels itself before the hash starts, so the outcome never depends on timing.
        let task = Task {
            withUnsafeCurrentTask { $0?.cancel() }
            return try await hasher.hash(contentsOf: url)
        }

        await #expect(throws: ContentHashError.cancelled) {
            try await task.value
        }
    }

    @Test func hashes200MBWithoutLoadingIt() async throws {
        let temp = try TemporaryFolder.make()
        defer { temp.remove() }
        let url = temp.url.appending(path: "big.bin")
        let chunkCount = 200
        let size = Int64(chunkCount * Self.mebibyte)
        // A sparse file: instant to make, and it reads as zeros through the same code path.
        #expect(FileManager.default.createFile(atPath: url.path(percentEncoded: false), contents: nil))
        let handle = try FileHandle(forWritingTo: url)
        try handle.truncate(atOffset: UInt64(size))
        try handle.close()

        var expected = SHA256()
        let zeros = Data(count: Self.mebibyte)
        for _ in 0..<chunkCount {
            expected.update(data: zeros)
        }

        // Warm up once, then measure around later runs so one-off allocations do not count.
        _ = try await hasher.hash(contentsOf: url, expectedSizeInBytes: size)
        let chunks = ConcurrentLog<Int>()
        let hash = try await hasher.hash(contentsOf: url, expectedSizeInBytes: size) { chunks.append($0) }

        #expect(hash.bytes == Array(expected.finalize()))
        let sizes = chunks.values
        #expect(sizes.count == chunkCount)
        #expect(sizes.allSatisfy { $0 <= Self.mebibyte })
        #expect(sizes.reduce(0, +) == Int(size))

        // Other suites run at the same time and allocate too, so the footprint is sampled over a
        // few runs and the smallest growth counts: noise is transient, loading the file is not.
        var smallestGrowth = UInt64.max
        for _ in 0..<3 {
            let before = try #require(physicalFootprintInBytes())
            _ = try await hasher.hash(contentsOf: url, expectedSizeInBytes: size)
            let after = try #require(physicalFootprintInBytes())
            smallestGrowth = min(smallestGrowth, after > before ? after - before : 0)
        }
        #expect(smallestGrowth < UInt64(32 * Self.mebibyte), "footprint grew by \(smallestGrowth) bytes while hashing \(size) bytes")
    }
}
