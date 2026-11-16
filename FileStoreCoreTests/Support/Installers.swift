import FileStoreCore
import Foundation

extension InstallerSources {
    /// A test's sources: the given fake Applications folders (none by default, so no real one is
    /// ever read), the given cache, the tests' own mount folder, and fixed receipts.
    static func testing(
        applications: [URL] = [],
        cache: (any InstallerFactsReading)? = nil,
        receipts: [InstallReceipt] = [],
        mounts: DiskImageMounts = TestMounts.shared
    ) -> InstallerSources {
        InstallerSources(applicationFolders: applications, cache: cache, mounts: mounts, receipts: .fixed(receipts))
    }
}

enum TestMounts {
    /// The tests' folder for mounting disk images, under the temporary directory, never the app's.
    static let root = FileManager.default.temporaryDirectory.appending(path: "FileStoreCoreTests.mounts", directoryHint: .isDirectory)

    static let shared = DiskImageMounts(root: root)
}
