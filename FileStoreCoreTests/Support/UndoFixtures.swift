import Darwin
import FileStoreCore
import Foundation
import Testing

/// A temporary folder standing in for the Trash. Undo takes a file only from the Trash it is given,
/// so tests that need to empty it, edit what is in it or put something else there use this one and
/// never touch the user's.
struct FakeTrash {
    let folder: TemporaryFolder

    /// The folder's real path, links resolved (`/private/var/…`): undo names a Trash item by a path
    /// on which no link may be followed, as `trashItem` reports it.
    let url: URL

    var locator: TrashLocator { .fixed(url) }

    static func make() throws -> FakeTrash {
        let folder = try TemporaryFolder.make(prefix: "FakeTrash")
        // `realpath`, not `resolvingSymlinksInPath`, which hands back `/var/…`: `/var` is the link.
        guard let resolved = realpath(folder.url.path(percentEncoded: false), nil) else {
            folder.remove()
            throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
        }
        defer { free(resolved) }
        return FakeTrash(folder: folder, url: URL(filePath: String(cString: resolved), directoryHint: .isDirectory))
    }

    func remove() {
        folder.remove()
    }

    /// Moves the file at `url` in, as `trashItem` does: the same file on the same disk, under `name`.
    func take(_ url: URL, as name: String? = nil) throws -> URL {
        let destination = self.url.appending(path: name ?? url.lastPathComponent)
        try FileManager.default.moveItem(at: url, to: destination)
        return destination
    }
}

/// Runs written to a log the way the executor writes them, for files a test moved itself, and the
/// undo calls most tests make.
enum UndoFixtures {
    static let now = Date(timeIntervalSince1970: 1_800_000_000)

    /// What a test reads about a file before the change, to compare after the undo.
    struct FileSnapshot: Equatable {
        let inode: UInt64
        let size: Int64
        let text: String
    }

    static func snapshot(of url: URL) -> FileSnapshot? {
        var status = stat()
        guard lstat(url.path(percentEncoded: false), &status) == 0, let text = DiskState.text(of: url) else {
            return nil
        }
        return FileSnapshot(inode: status.st_ino, size: Int64(status.st_size), text: text)
    }

    /// Writes `files` (name to text) into `folder`, dated well past the grace period.
    static func write(_ files: [String: String], in folder: URL) throws {
        try FileDates.writeSettled(files, in: folder)
    }

    /// A Find Duplicates run that moved each named file of `folder` into `trash`, recorded as the
    /// executor records one: a started row with the content hash and disk ID, the move, the result.
    /// - Returns: The run's identifier, and where each file went, by name.
    @discardableResult
    static func trashRun(
        _ names: [String],
        in folder: URL,
        to trash: FakeTrash,
        log: ActivityLog
    ) async throws -> (runID: Int64, trashURLs: [String: URL]) {
        let records = try await RelocationPlans.records(in: folder)
        let runID = try log.beginRun(CleanupRunStart(action: .findDuplicates, folderURL: folder, confirmedCount: names.count, startedAt: now))
        var trashURLs: [String: URL] = [:]
        for (sequence, name) in names.enumerated() {
            let record = try RelocationPlans.record(named: name, in: records)
            let change = ProposedChange(record: record, operation: .moveToTrash, reason: .sameContent(asFileNamed: "kept.txt"))
            let hash = try await ContentHasher().hash(contentsOf: record.url)
            let inode = try #require(DiskState.inode(of: record.url))
            let changeID = try log.recordedIntent(
                CleanupChangeIntent(runID: runID, sequence: sequence, change: change, contentHash: hash, fileNumber: inode, attemptedAt: now)
            )
            let trashURL = try trash.take(record.url)
            trashURLs[name] = trashURL
            try log.recordResult(
                CleanupChangeResult(
                    runID: runID,
                    changeID: changeID,
                    sequence: sequence,
                    item: CleanupItemResult(change: change, outcome: .trashed(trashURL: trashURL)),
                    attemptedAt: now
                )
            )
        }
        try log.finishRun(CleanupRunFinish(runID: runID, finishedAt: now, wasCancelled: false, notReached: []))
        return (runID, trashURLs)
    }

    /// A Clear Failed Downloads run that moved each named item of `folder` into `trash`, files and
    /// `.download` folders alike, recorded as the executor records one: a started row with the disk
    /// ID and no content hash (no folder is ever hashed), the move, the result.
    @discardableResult
    static func failedDownloadRun(
        _ names: [String],
        in folder: URL,
        to trash: FakeTrash,
        log: ActivityLog
    ) async throws -> (runID: Int64, trashURLs: [String: URL]) {
        let records = try await RelocationPlans.records(in: folder)
        let runID = try log.beginRun(
            CleanupRunStart(action: .clearFailedDownloads, folderURL: folder, confirmedCount: names.count, startedAt: now)
        )
        var trashURLs: [String: URL] = [:]
        for (sequence, name) in names.enumerated() {
            let record = try RelocationPlans.record(named: name, in: records)
            let stoppedOn = try #require(record.lastChange)
            let change = ProposedChange(
                record: record,
                operation: .moveToTrash,
                reason: .failedDownload(stoppedOn: stoppedOn, finishedFileName: nil)
            )
            let inode = try #require(DiskState.inode(of: record.url))
            let changeID = try log.recordedIntent(
                CleanupChangeIntent(runID: runID, sequence: sequence, change: change, contentHash: nil, fileNumber: inode, attemptedAt: now)
            )
            let trashURL = try trash.take(folder.appending(path: name))
            trashURLs[name] = trashURL
            try log.recordResult(
                CleanupChangeResult(
                    runID: runID,
                    changeID: changeID,
                    sequence: sequence,
                    item: CleanupItemResult(change: change, outcome: .trashed(trashURL: trashURL)),
                    attemptedAt: now
                )
            )
        }
        try log.finishRun(CleanupRunFinish(runID: runID, finishedAt: now, wasCancelled: false, notReached: []))
        return (runID, trashURLs)
    }

    /// Plans `target` from the log and the disk now, and carries it out.
    static func undo(
        _ target: UndoTarget,
        in folder: URL,
        trash: TrashLocator,
        log: ActivityLog,
        recorder: (any CleanupRecording)? = nil,
        beforeChange: (@Sendable (UndoStep) -> Void)? = nil
    ) async throws -> UndoResult {
        let plan = try await UndoPlanner(trash: trash).plan(target, log: log, folderURL: folder)
        return await CleanupExecutor(recorder: recorder ?? (log as any CleanupRecording)).undo(plan, trash: trash, beforeChange: beforeChange)
    }

    /// The outcome for the file whose original name is `name`.
    static func outcome(for name: String, in result: UndoResult) throws -> UndoItemOutcome {
        try #require(result.items.first { $0.originalName == name }, "no undo result for \(name)").outcome
    }

    static func change(named name: String, inRun runID: Int64, log: ActivityLog) async throws -> ActivityChange {
        try #require(try await log.changes(inRun: runID).first { URL(filePath: $0.originalPath).lastPathComponent == name }, "no change for \(name)")
    }

    static func isUndone(_ outcome: UndoItemOutcome) -> Bool {
        if case .undone = outcome {
            return true
        }
        return false
    }
}
