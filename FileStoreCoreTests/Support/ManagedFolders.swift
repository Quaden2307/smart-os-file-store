import CryptoKit
import FileStoreCore
import Foundation
import Testing

extension ManagedFolder {
    /// A stand-in Downloads at `url`, under an ID of its own. For a test that plans or scans, or
    /// records into a spy; a run recorded in a real log needs `ActivityLog.downloads(at:)`.
    ///
    /// The ID is worked out from the path, so two values a test makes for one place are the same
    /// folder, and the plans made for them compare equal.
    static func temporary(_ url: URL) -> ManagedFolder {
        let digest = Array(SHA256.hash(data: Data(url.standardizedFileURL.path(percentEncoded: false).utf8)))
        let id = UUID(uuid: (
            digest[0], digest[1], digest[2], digest[3], digest[4], digest[5], digest[6], digest[7],
            digest[8], digest[9], digest[10], digest[11], digest[12], digest[13], digest[14], digest[15]
        ))
        return ManagedFolder(id: id, kind: .downloads, url: url)
    }
}

extension FolderRegistry {
    /// A registry whose Downloads is the folder at `url`, as `-ScanFolder` makes it, with the rules
    /// a test under the temporary directory needs.
    static func testing(downloads url: URL) -> FolderRegistry {
        FolderRegistry(override: FolderOverride(source: .scanFolderArgument, folderURL: url), rules: .forTests)
    }
}

extension ActivityLog {
    /// The log's own Downloads folder, said to be at `url`: what a test hands the planners and the
    /// executor when its runs go into this log, which refuses a run for a folder it does not hold.
    ///
    /// When the log cannot say, the folder gets an ID the log does not hold, and the first write
    /// for it fails the test.
    func downloads(at url: URL) -> ManagedFolder {
        ManagedFolder(id: (try? folderID(of: .downloads)) ?? UUID(), kind: .downloads, url: url)
    }

    /// Marks `records` Kept in the log's own Downloads folder, said to be where the first of them is.
    func keep(_ records: [FileRecord], now: Date = .now) async throws {
        guard let first = records.first else { return }
        try await keep(records, in: downloads(at: first.url.deletingLastPathComponent()), now: now)
    }
}

extension FolderSafetyRules {
    /// The rules as a test under the temporary directory needs them: a home that is nowhere, and
    /// the temporary directory exempt from the system-location rule.
    static let forTests = FolderSafetyRules(
        home: URL(filePath: "/nowhere/home", directoryHint: .isDirectory),
        appDataFolders: [],
        allowedRoots: [FileManager.default.temporaryDirectory]
    )
}

extension CleanupPlan {
    /// The same plan, said to be for `folder`: a plan built elsewhere, as a test hands the executor
    /// to see that it is refused.
    func claimed(for folder: ManagedFolder) -> CleanupPlan {
        CleanupPlan(
            action: action,
            folder: folder,
            changes: changes,
            duplicateGroups: duplicateGroups,
            nearDuplicateGroups: nearDuplicateGroups,
            skippedItems: skippedItems,
            installerFactsRead: installerFactsRead,
            archiveProblem: archiveProblem,
            topLevelSizeOnDisk: topLevelSizeOnDisk
        )
    }
}

/// A stand-in home with Downloads and Desktop, both on the list of a log in memory, for tests of
/// what belongs to which folder. The registry takes the home as a demo home, so nothing real is
/// ever looked up.
struct ManagedHome {
    let home: URL
    let registry: FolderRegistry
    let log: ActivityLog
    let downloads: ManagedFolder
    let desktop: ManagedFolder

    /// - Parameter location: Where the log lives. In memory unless the test opens it a second time.
    init(root: URL, location: ActivityLogLocation = .inMemory) async throws {
        home = root.appending(path: "Home", directoryHint: .isDirectory)
        for name in ["Downloads", "Desktop", "Documents"] {
            try FileManager.default.createDirectory(at: home.appending(path: name), withIntermediateDirectories: true)
        }
        registry = FolderRegistry(
            override: FolderOverride(source: .demoHomeArgument, folderURL: home),
            rules: FolderSafetyRules(home: home, appDataFolders: [], allowedRoots: [root])
        )
        log = try await ActivityLog.open(location)
        downloads = try #require(try await registry.folders(in: log).first)
        desktop = try await registry.add(.desktop, to: log).get()
    }

    /// A folder of the user's own choosing inside the home, on the list.
    func addCustomFolder(named name: String) async throws -> ManagedFolder {
        let url = home.appending(path: name, directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: false)
        return try await registry.add(customFolderAt: url, to: log).get()
    }
}

extension FileRecord {
    /// This record as the scan makes it for a cloud placeholder: the same item, flagged as not on
    /// this Mac. No test can make a real placeholder; the system alone sets that flag on a file.
    func flaggedAsPlaceholder() -> FileRecord {
        FileRecord(
            url: url,
            displayName: displayName,
            kind: kind,
            localizedTypeDescription: localizedTypeDescription,
            contentType: contentType,
            sizeInBytes: sizeInBytes,
            dateAdded: dateAdded,
            dateModified: dateModified,
            isDownloading: isDownloading,
            lastOpened: lastOpened,
            downloadSource: downloadSource,
            canReadLastOpened: canReadLastOpened,
            persistentIdentity: persistentIdentity,
            packageContents: packageContents,
            allocatedSizeInBytes: allocatedSizeInBytes,
            isDataless: true
        )
    }
}
