import Darwin
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

    /// Removes every folder `result` reports as trashed, when `expectedFiles` knows exactly the files
    /// it holds (by name, with their bytes) and finds them all there unchanged and nothing else:
    /// only plain files, no folder or link inside, so nothing but the test's own bytes goes.
    static func removeFolders(_ result: CleanupResult, expectedFiles: (URL) -> [String: Data]?) {
        for item in result.items where item.change.isFolder {
            guard case .trashed(let trashURL?) = item.outcome else { continue }
            let original = item.change.record.url
            guard let expected = expectedFiles(original),
                  let trashDirectory = try? FileManager.default.url(
                      for: .trashDirectory,
                      in: .userDomainMask,
                      appropriateFor: original,
                      create: false
                  ),
                  canonicalPath(trashURL).hasPrefix(canonicalPath(trashDirectory) + "/"),
                  let names = try? FileManager.default.contentsOfDirectory(atPath: trashURL.path(percentEncoded: false)),
                  Set(names) == Set(expected.keys),
                  expected.allSatisfy({ name, data in
                      let url = trashURL.appending(path: name)
                      return isPlainFile(url) && (try? Data(contentsOf: url)) == data
                  }) else {
                continue
            }
            try? FileManager.default.removeItem(at: trashURL)
        }
    }

    /// True for a regular file, not a link to one.
    private static func isPlainFile(_ url: URL) -> Bool {
        var status = stat()
        return lstat(url.path(percentEncoded: false), &status) == 0 && status.st_mode & S_IFMT == S_IFREG
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
