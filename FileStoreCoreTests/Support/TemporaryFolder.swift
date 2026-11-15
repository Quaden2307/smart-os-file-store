import Foundation

/// A fresh folder under the system temporary directory.
///
/// Tests only ever touch folders they created this way. Never the real Downloads folder,
/// the Desktop, Documents or any other user folder.
struct TemporaryFolder {
    let url: URL

    static func make(prefix: String = "FileStoreCoreTests") throws -> TemporaryFolder {
        let url = FileManager.default.temporaryDirectory
            .appending(path: "\(prefix)-\(UUID().uuidString)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return TemporaryFolder(url: url)
    }

    /// Removes the folder. Best effort: a failure here must not hide the test's own result.
    func remove() {
        try? FileManager.default.removeItem(at: url)
    }
}

/// Runs `body` with a fresh temporary folder and removes it afterwards.
func withTemporaryFolder<T>(_ body: (URL) throws -> T) throws -> T {
    let folder = try TemporaryFolder.make()
    defer { folder.remove() }
    return try body(folder.url)
}

/// Runs `body`, which may suspend, with a fresh temporary folder and removes it afterwards.
func withTemporaryFolderAsync<T>(_ body: (URL) async throws -> T) async throws -> T {
    let folder = try TemporaryFolder.make()
    defer { folder.remove() }
    return try await body(folder.url)
}
