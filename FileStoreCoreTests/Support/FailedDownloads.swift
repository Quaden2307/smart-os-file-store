import FileStoreCore
import Foundation

/// A folder of partial downloads for the Clear Failed Downloads tests, written into a temporary
/// folder: Chrome's `movie.mp4.crdownload`, Firefox's `partial.part` and Safari's package
/// `presentation.key.download/` (the partial file and an `Info.plist`), three days old inside and
/// out, and the finished `movie.mp4` beside them, two hours old. Every file holds the test's own
/// marker, so whatever a test sends to the real Trash can be told apart and removed again.
enum FailedDownloads {
    static let chrome = "movie.mp4.crdownload"
    static let firefox = "partial.part"
    static let safari = "presentation.key.download"
    static let safariContent = "presentation.key"
    static let safariInfo = "Info.plist"
    static let finished = "movie.mp4"

    /// How long ago the partials stopped: well past the grace period.
    static let staleAge: TimeInterval = 3 * 24 * 60 * 60

    /// What each file holds, by its path inside the folder.
    struct Contents {
        let marker: String

        var chrome: String { "chrome partial \(marker)" }
        var firefox: String { "firefox partial \(marker)" }
        var safariContent: String { "keynote partial \(marker)" }
        var safariInfo: String { "<plist>\(marker)</plist>" }
        var finished: String { "the finished film \(marker)" }

        /// The files inside the Safari package, by name.
        var safariFiles: [String: Data] {
            [FailedDownloads.safariContent: Data(safariContent.utf8), FailedDownloads.safariInfo: Data(safariInfo.utf8)]
        }

        /// The bytes the Safari package's files add up to.
        var safariSize: Int64 {
            Int64(safariContent.utf8.count + safariInfo.utf8.count)
        }

        /// The bytes of a partial file, by name; nil for anything else.
        func fileData(named name: String) -> Data? {
            switch name {
            case FailedDownloads.chrome:
                Data(chrome.utf8)
            case FailedDownloads.firefox:
                Data(firefox.utf8)
            default:
                nil
            }
        }
    }

    /// Writes the partials and the finished file into `folder`, the partials dated `staleAge` back.
    @discardableResult
    static func write(in folder: URL, marker: String = UUID().uuidString) throws -> Contents {
        let contents = Contents(marker: marker)
        let package = folder.appending(path: safari, directoryHint: .isDirectory)
        try Data(contents.chrome.utf8).write(to: folder.appending(path: chrome))
        try Data(contents.firefox.utf8).write(to: folder.appending(path: firefox))
        try FileManager.default.createDirectory(at: package, withIntermediateDirectories: false)
        try Data(contents.safariContent.utf8).write(to: package.appending(path: safariContent))
        try Data(contents.safariInfo.utf8).write(to: package.appending(path: safariInfo))
        try Data(contents.finished.utf8).write(to: folder.appending(path: finished))
        // The package's own date last: making its files moved it.
        try FileDates.settle(
            [
                folder.appending(path: chrome),
                folder.appending(path: firefox),
                package.appending(path: safariContent),
                package.appending(path: safariInfo),
                package,
            ],
            base: Date(timeIntervalSinceNow: -staleAge)
        )
        try FileDates.settle([folder.appending(path: finished)])
        return contents
    }

    /// The Clear Failed Downloads plan for `folder` as it is now, with the given Kept list.
    static func plan(_ folder: URL, keeping keptItems: KeptItems = KeptItems(), now: Date = .now) async throws -> CleanupPlan? {
        let records = try await RelocationPlans.records(in: folder)
        return try await CleanupPlanners.plan(
            .clearFailedDownloads,
            records: records,
            in: folder,
            eligibility: CandidateEligibility(),
            keptItems: keptItems,
            now: now
        )
    }
}
