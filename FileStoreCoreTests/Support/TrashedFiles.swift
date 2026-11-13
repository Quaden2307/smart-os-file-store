import FileStoreCore
import Foundation

/// Files the executor sent to the Trash during a test.
///
/// `FileManager.trashItem` can only put a file in the user's Trash, so the tests that exercise it
/// write there. This removes those files again by the exact URL the executor returned, and only
/// after checking that the URL lies in the Trash and that the file still holds the bytes the test
/// wrote. macOS protects the Trash (Full Disk Access), so a runner that is not allowed in leaves
/// the files there; nothing a test asserts depends on this cleanup.
enum TrashedFiles {
    /// Removes every file `result` reports as trashed, when `expectedContents` knows its bytes.
    static func remove(_ result: CleanupResult, expectedContents: (URL) -> Data?) {
        for item in result.items {
            guard case .trashed(let trashURL?) = item.outcome else { continue }
            let original = item.change.record.url
            guard let expected = expectedContents(original) else { continue }
            remove(trashURL, original: original, expected: expected)
        }
    }

    private static func remove(_ trashURL: URL, original: URL, expected: Data) {
        let fileManager = FileManager.default
        guard let trashDirectory = try? fileManager.url(
            for: .trashDirectory,
            in: .userDomainMask,
            appropriateFor: original,
            create: false
        ) else { return }
        guard canonicalPath(trashURL).hasPrefix(canonicalPath(trashDirectory) + "/") else { return }
        guard let actual = try? Data(contentsOf: trashURL), actual == expected else { return }
        try? fileManager.removeItem(at: trashURL)
    }
}
