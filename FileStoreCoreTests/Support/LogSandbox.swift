import FileStoreCore
import Foundation
import SQLite3
import Testing

/// A temporary folder standing in for the two places an activity log can live: the user's
/// Application Support folder and the temporary directory. Tests open logs through it, so no test
/// ever looks at, or writes to, the real Library.
struct LogSandbox {
    static let appIdentifier = "com.example.FileStoreCoreTests"

    let folder: TemporaryFolder
    let roots: ActivityLogLocation.Roots

    static func make() throws -> LogSandbox {
        let folder = try TemporaryFolder.make(prefix: "ActivityLog")
        let applicationSupport = folder.url.appending(path: "Application Support", directoryHint: .isDirectory)
        let temporary = folder.url.appending(path: "Temporary", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: applicationSupport, withIntermediateDirectories: false)
        try FileManager.default.createDirectory(at: temporary, withIntermediateDirectories: false)
        return LogSandbox(folder: folder, roots: ActivityLogLocation.Roots(applicationSupport: applicationSupport, temporary: temporary))
    }

    func remove() {
        folder.remove()
    }

    /// Where the real log would live: the location for a scan of the Downloads folder.
    func realLocation() throws -> ActivityLogLocation {
        let scan = ScanLocation(folderURL: folder.url.appending(path: "Downloads"), source: .downloadsFolder)
        return try ActivityLogLocation.resolve(for: scan, appIdentifier: Self.appIdentifier, roots: roots)
    }

    /// The location for a scan folder chosen by a debug override.
    func overrideLocation(scanning scanFolder: URL, source: ScanLocation.Source = .launchArgument) throws -> ActivityLogLocation {
        let scan = ScanLocation(folderURL: scanFolder, source: source)
        return try ActivityLogLocation.resolve(for: scan, appIdentifier: Self.appIdentifier, roots: roots)
    }

    /// Everything under the stand-in Application Support folder, as relative paths.
    func applicationSupportContents() throws -> [String] {
        let root = try #require(roots.applicationSupport)
        return try FileManager.default.subpathsOfDirectory(atPath: root.path(percentEncoded: false)).sorted()
    }
}

/// Runs `body` with a fresh sandbox and removes it afterwards.
func withLogSandbox<T>(_ body: (LogSandbox) async throws -> T) async throws -> T {
    let sandbox = try LogSandbox.make()
    defer { sandbox.remove() }
    return try await body(sandbox)
}

/// What a test reads about a file without opening it.
enum FileFacts {
    /// The permission bits, such as `0o600`. Nil when nothing is at the path.
    static func permissions(of url: URL) -> Int? {
        var status = stat()
        guard lstat(url.path(percentEncoded: false), &status) == 0 else {
            return nil
        }
        return Int(status.st_mode & 0o7777)
    }

    static func size(of url: URL) -> Int64 {
        var status = stat()
        guard lstat(url.path(percentEncoded: false), &status) == 0 else {
            return 0
        }
        return Int64(status.st_size)
    }

    /// The database plus its write-ahead file: what the log takes on disk.
    static func databaseSize(at databaseURL: URL) -> Int64 {
        size(of: databaseURL) + size(of: URL(filePath: databaseURL.path(percentEncoded: false) + "-wal"))
    }
}

/// A second, plain SQLite connection to a log's file, for what the engine's own API does not
/// offer on purpose: holding the database locked, and writing rows no version of the app writes.
final class RawDatabase {
    enum Failure: Error {
        case couldNotOpen(Int32)
        case statementFailed(sql: String, message: String)
    }

    private let handle: OpaquePointer

    init(_ url: URL) throws {
        var handle: OpaquePointer?
        let code = sqlite3_open_v2(url.path(percentEncoded: false), &handle, SQLITE_OPEN_READWRITE, nil)
        guard code == SQLITE_OK, let handle else {
            sqlite3_close(handle)
            throw Failure.couldNotOpen(code)
        }
        self.handle = handle
    }

    deinit {
        sqlite3_close(handle)
    }

    func execute(_ sql: String) throws {
        var message: UnsafeMutablePointer<CChar>?
        guard sqlite3_exec(handle, sql, nil, nil, &message) == SQLITE_OK else {
            let text = message.map { String(cString: $0) } ?? ""
            sqlite3_free(message)
            throw Failure.statementFailed(sql: sql, message: text)
        }
    }

    /// The first column of the first row, as text.
    func text(_ sql: String) throws -> String? {
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(handle, sql, -1, &statement, nil) == SQLITE_OK else {
            throw Failure.statementFailed(sql: sql, message: String(cString: sqlite3_errmsg(handle)))
        }
        defer { sqlite3_finalize(statement) }
        guard sqlite3_step(statement) == SQLITE_ROW, let value = sqlite3_column_text(statement, 0) else {
            return nil
        }
        return String(cString: value)
    }
}

/// Changes and results for tests that write to a log directly, without files on disk.
enum LogSamples {
    static let folderURL = URL(filePath: "/Users/someone/Downloads", directoryHint: .isDirectory)

    static func record(named name: String, size: Int64 = 1_024, modified: Date? = Date(timeIntervalSince1970: 1_700_000_000)) -> FileRecord {
        FileRecord(
            url: folderURL.appending(path: name),
            displayName: name,
            kind: .file,
            localizedTypeDescription: nil,
            contentType: nil,
            sizeInBytes: size,
            dateAdded: modified,
            dateModified: modified,
            isDownloading: false
        )
    }

    static func trashChange(_ name: String, keptName: String = "kept.pdf", size: Int64 = 1_024) -> ProposedChange {
        ProposedChange(record: record(named: name, size: size), operation: .moveToTrash, reason: .sameContent(asFileNamed: keptName))
    }

    static func trashed(_ change: ProposedChange) -> CleanupItemResult {
        let trashURL = URL(filePath: "/Users/someone/.Trash").appending(path: change.record.displayName)
        return CleanupItemResult(change: change, outcome: .trashed(trashURL: trashURL))
    }

    /// One finished run of `count` trashed files, written the way the executor writes: a started
    /// row, then its result, per file.
    @discardableResult
    static func writeRun(
        to log: ActivityLog,
        startedAt: Date,
        count: Int,
        size: Int64 = 1_024,
        namePrefix: String = "report",
        afterEach: (Int) -> Void = { _ in }
    ) throws -> Int64 {
        let runID = try log.beginRun(
            CleanupRunStart(action: .findDuplicates, folderURL: folderURL, confirmedCount: count, startedAt: startedAt)
        )
        let hash = ContentHash(bytes: [UInt8](repeating: 0xAB, count: 32))
        for index in 0..<count {
            let change = trashChange("\(namePrefix) (\(index + 1)).pdf", size: size)
            let changeID = try log.recordedIntent(
                CleanupChangeIntent(runID: runID, sequence: index, change: change, contentHash: hash, attemptedAt: startedAt)
            )
            try log.recordResult(
                CleanupChangeResult(runID: runID, changeID: changeID, sequence: index, item: trashed(change), attemptedAt: startedAt)
            )
            afterEach(index + 1)
        }
        try log.finishRun(CleanupRunFinish(runID: runID, finishedAt: startedAt, wasCancelled: false, notReached: []))
        return runID
    }
}
