import FileStoreCore
import Foundation
import Testing

/// Clear Failed Downloads carried out: through the real Trash, since `trashItem` puts things only
/// there, with `TrashedFiles` removing the test's own files and folders afterwards when the runner
/// may. Each item is rechecked right before it moves, and any sign that the download resumed
/// leaves it alone.
@Suite("Failed download executor")
struct FailedDownloadExecutorTests {
    private typealias Partials = FailedDownloads

    private func withPartials(_ body: (URL, FailedDownloads.Contents, ActivityLog) async throws -> Void) async throws {
        try await withTemporaryFolderAsync { folder in
            let contents = try Partials.write(in: folder)
            let log = try await ActivityLog.open(.inMemory)
            try await body(folder, contents, log)
        }
    }

    private func execute(
        _ plan: CleanupPlan,
        log: ActivityLog,
        only names: Set<String>? = nil
    ) async -> CleanupResult {
        let ids = plan.changes.filter { names?.contains($0.record.displayName) ?? true }.map(\.id)
        return await CleanupExecutor(recorder: log).execute(plan: plan, confirmedChangeIDs: Set(ids))
    }

    /// Removes from the Trash whatever of this test's the run put there, and nothing else.
    private func cleanUp(_ result: CleanupResult, _ contents: FailedDownloads.Contents) {
        TrashedFiles.remove(result) { contents.fileData(named: $0.lastPathComponent) }
        TrashedFiles.removeFolders(result) { _ in contents.safariFiles }
    }

    private func outcome(_ name: String, in result: CleanupResult) throws -> CleanupItemOutcome {
        try RelocationPlans.outcome(for: name, in: result)
    }

    private func plan(_ folder: URL) async throws -> CleanupPlan {
        try #require(try await Partials.plan(folder))
    }

    // MARK: - The run

    @Test func allThreeGoToTheTrashAndTheLogSaysEnoughToUndoThem() async throws {
        try await withPartials { folder, contents, log in
            let plan = try await plan(folder)
            #expect(plan.changes.map(\.record.displayName) == [Partials.chrome, Partials.firefox, Partials.safari])

            let result = await execute(plan, log: log)
            defer { cleanUp(result, contents) }

            #expect(result.trashedCount == 3)
            #expect(result.action == .clearFailedDownloads)
            let expectedBytes = Int64(contents.chrome.utf8.count + contents.firefox.utf8.count) + contents.safariSize
            #expect(result.bytesFreed == expectedBytes)
            #expect(DiskState.entryNames(in: folder) == [Partials.finished])

            let runID = try #require(result.runID)
            #expect(try await log.run(id: runID)?.action == .clearFailedDownloads)
            let rows = try await log.changes(inRun: runID)
            #expect(rows.map { URL(filePath: $0.originalPath).lastPathComponent } == [Partials.chrome, Partials.firefox, Partials.safari])
            #expect(rows.map(\.outcome) == [.trashed, .trashed, .trashed])
            #expect(rows.map(\.isFolder) == [false, false, true])
            #expect(rows.allSatisfy { $0.fileNumber != nil && $0.contentHash == nil })
            // No stored path ends in a slash, folders included: `lstat` on one would follow a link.
            #expect(rows.allSatisfy { !$0.originalPath.hasSuffix("/") && $0.resultingPath?.hasSuffix("/") == false })
            for (row, change) in zip(rows, plan.changes) {
                #expect(row.reason == change.reason)
                #expect(row.sizeInBytes == change.sizeInBytes)
                #expect(row.dateModified == change.dateModified)
            }
            let stoppedOn = try #require(plan.changes.first?.dateModified)
            #expect(rows.first?.reason == .failedDownload(stoppedOn: stoppedOn, finishedFileName: Partials.finished))
            #expect(try await log.totals() == ActivityTotals(bytesMovedToTrash: expectedBytes, filesCleaned: 3))
        }
    }

    @Test func runningItAgainRightAfterProposesNothing() async throws {
        try await withPartials { folder, contents, log in
            let result = await execute(try await plan(folder), log: log)
            defer { cleanUp(result, contents) }
            #expect(result.trashedCount == 3)

            let again = try await plan(folder)
            #expect(again.isEmpty)
            #expect(again.skippedItems.isEmpty)
        }
    }

    // MARK: - A download that may have resumed

    @Test func aPartialThatChangedAfterThePlanIsLeftAlone() async throws {
        try await withPartials { folder, contents, log in
            let plan = try await plan(folder)
            let chrome = folder.appending(path: Partials.chrome)
            let firefox = folder.appending(path: Partials.firefox)
            let inside = folder.appending(path: Partials.safari).appending(path: Partials.safariContent)
            let chromeDate = try #require(plan.changes.first { $0.record.displayName == Partials.chrome }?.dateModified)
            // Chrome wrote more and its date was put back; Firefox's date moved but stayed old;
            // Safari wrote to the file inside its package.
            try Data((contents.chrome + " and more").utf8).write(to: chrome)
            try FileDates.set(chrome, to: chromeDate)
            try FileDates.set(firefox, to: Date(timeIntervalSinceNow: -2 * 24 * 60 * 60))
            try Data(contents.safariContent.uppercased().utf8).write(to: inside)
            try FileDates.set(inside, to: Date(timeIntervalSinceNow: -2 * 24 * 60 * 60))

            let result = await execute(plan, log: log)
            defer { cleanUp(result, contents) }

            #expect(result.trashedCount == 0)
            for name in [Partials.chrome, Partials.firefox, Partials.safari] {
                #expect(try outcome(name, in: result) == .skipped(.changedSinceScan), "\(name)")
            }
            #expect(Set(DiskState.entryNames(in: folder)) == [Partials.chrome, Partials.firefox, Partials.safari, Partials.finished])
        }
    }

    @Test func aPartialThatResumedJustNowIsLeftAlone() async throws {
        try await withPartials { folder, contents, log in
            let plan = try await plan(folder)
            try Data((contents.firefox + " resumed").utf8).write(to: folder.appending(path: Partials.firefox))
            try Data("new chunk".utf8).write(to: folder.appending(path: Partials.safari).appending(path: "chunk"))

            let result = await execute(plan, log: log)
            defer { cleanUp(result, contents) }

            #expect(try outcome(Partials.firefox, in: result) == .skipped(.changedSinceScan))
            #expect(try outcome(Partials.safari, in: result) == .skipped(.changedSinceScan))
            #expect(try outcome(Partials.chrome, in: result).isTrashed)
        }
    }

    // MARK: - Kept, locked, gone or replaced

    @Test func aPartialMarkedKeptAfterThePlanStays() async throws {
        try await withPartials { folder, contents, log in
            let plan = try await plan(folder)
            let records = plan.changes.map(\.record).filter { $0.displayName != Partials.firefox }
            try await log.keep(records)

            let result = await execute(plan, log: log)
            defer { cleanUp(result, contents) }

            #expect(try outcome(Partials.chrome, in: result) == .skipped(.markedKept))
            #expect(try outcome(Partials.safari, in: result) == .skipped(.markedKept))
            #expect(try outcome(Partials.firefox, in: result).isTrashed)
        }
    }

    @Test func aLockedPartialFailsAndTheRestStillGo() async throws {
        try await withPartials { folder, contents, log in
            var firefox = folder.appending(path: Partials.firefox)
            var package = folder.appending(path: Partials.safari, directoryHint: .isDirectory)
            try setLocked(&firefox, true)
            try setLocked(&package, true)
            defer {
                try? setLocked(&firefox, false)
                try? setLocked(&package, false)
            }
            let plan = try await plan(folder)

            let result = await execute(plan, log: log)
            defer { cleanUp(result, contents) }

            #expect(try outcome(Partials.firefox, in: result) == .failed(.fileIsLocked))
            #expect(try outcome(Partials.safari, in: result) == .failed(.fileIsLocked))
            #expect(try outcome(Partials.chrome, in: result).isTrashed)
        }
    }

    @Test func aPartialThatVanishedOrWasReplacedIsLeftAlone() async throws {
        try await withPartials { folder, contents, log in
            let gone = folder.appending(path: "gone.part")
            try Data("gone".utf8).write(to: gone)
            try FileDates.set(gone, to: Date(timeIntervalSinceNow: -3 * 24 * 60 * 60))
            let plan = try await plan(folder)
            #expect(plan.changes.count == 4)

            let fileManager = FileManager.default
            try fileManager.removeItem(at: gone)
            // A folder where a file was, a link where a file was, a file where the package was.
            let chrome = folder.appending(path: Partials.chrome)
            try fileManager.removeItem(at: chrome)
            try fileManager.createDirectory(at: chrome, withIntermediateDirectories: false)
            let firefox = folder.appending(path: Partials.firefox)
            try fileManager.removeItem(at: firefox)
            try fileManager.createSymbolicLink(at: firefox, withDestinationURL: folder.appending(path: Partials.finished))
            let package = folder.appending(path: Partials.safari)
            try fileManager.removeItem(at: package)
            try Data("not a package".utf8).write(to: package)

            let result = await execute(plan, log: log)
            defer { cleanUp(result, contents) }

            #expect(try outcome("gone.part", in: result) == .skipped(.notFound))
            #expect(try outcome(Partials.chrome, in: result) == .skipped(.notARegularFile))
            #expect(try outcome(Partials.firefox, in: result) == .skipped(.notARegularFile))
            #expect(try outcome(Partials.safari, in: result) == .skipped(.notARegularFile))
            #expect(result.trashedCount == 0)
            #expect(DiskState.isSymbolicLink(firefox))
        }
    }

    // MARK: - Plans built elsewhere

    @Test func aPlanCannotTrashSomethingThatIsNotAPartialDownload() async throws {
        try await withPartials { folder, contents, log in
            let records = try await RelocationPlans.records(in: folder)
            let finished = try RelocationPlans.record(named: Partials.finished, in: records)
            let chrome = try RelocationPlans.record(named: Partials.chrome, in: records)
            let safari = try RelocationPlans.record(named: Partials.safari, in: records)
            let stoppedOn = try #require(finished.dateModified)
            // The package described as a file: the log would record it as one, and undo could never
            // prove it, so it is refused.
            let packageAsFile = FileRecord(
                url: safari.url,
                displayName: safari.displayName,
                kind: .file,
                localizedTypeDescription: nil,
                contentType: nil,
                sizeInBytes: safari.contentSizeInBytes,
                dateAdded: safari.dateAdded,
                dateModified: safari.lastChange,
                isDownloading: true
            )
            let plan = CleanupPlan(
                action: .clearFailedDownloads,
                folder: log.downloads(at: folder),
                changes: [
                    // A finished file dressed up as a failed download.
                    ProposedChange(record: finished, operation: .moveToTrash, reason: .failedDownload(stoppedOn: stoppedOn, finishedFileName: nil)),
                    // A partial with another action's reason.
                    ProposedChange(record: chrome, operation: .moveToTrash, reason: .sameContent(asFileNamed: Partials.finished)),
                    ProposedChange(record: packageAsFile, operation: .moveToTrash, reason: .failedDownload(stoppedOn: stoppedOn, finishedFileName: nil)),
                ]
            )

            let result = await execute(plan, log: log)
            defer { cleanUp(result, contents) }

            #expect(try outcome(Partials.finished, in: result) == .skipped(.notInPlan))
            #expect(try outcome(Partials.chrome, in: result) == .skipped(.notInPlan))
            #expect(try outcome(Partials.safari, in: result) == .skipped(.notInPlan))
            #expect(Set(DiskState.entryNames(in: folder)) == [Partials.chrome, Partials.firefox, Partials.safari, Partials.finished])
        }
    }

    @Test func findDuplicatesCannotTrashAPartialDownload() async throws {
        try await withTemporaryFolderAsync { folder in
            // A partial with exactly the bytes of a finished file: a group Find Duplicates never makes.
            try FileDates.writeSettled(["song.mp3": "same bytes", "song.mp3.part": "same bytes"], in: folder)
            let records = try await RelocationPlans.records(in: folder)
            let kept = try RelocationPlans.record(named: "song.mp3", in: records)
            let partial = try RelocationPlans.record(named: "song.mp3.part", in: records)
            let hash = try await ContentHasher().hash(contentsOf: partial.url)
            let plan = CleanupPlan(
                action: .findDuplicates,
                folder: .temporary(folder),
                changes: [ProposedChange(record: partial, operation: .moveToTrash, reason: .sameContent(asFileNamed: "song.mp3"))],
                duplicateGroups: [DuplicateGroup(contentHash: hash, kept: kept, duplicates: [partial], fileSizeInBytes: 10)]
            )
            let log = try await ActivityLog.open(.inMemory)

            let result = await execute(plan, log: log)
            defer { TrashedFiles.remove(result) { _ in Data("same bytes".utf8) } }

            #expect(try outcome("song.mp3.part", in: result) == .skipped(.notInPlan))
            #expect(DiskState.entryNames(in: folder) == ["song.mp3", "song.mp3.part"])
        }
    }

    // MARK: - Undo

    @Test func undoingTheRunPutsAllThreeBackFromTheRealTrash() async throws {
        try await withPartials { folder, contents, log in
            let result = await execute(try await plan(folder), log: log)
            defer { cleanUp(result, contents) }
            #expect(result.trashedCount == 3)
            let runID = try #require(result.runID)

            let undo = try await UndoFixtures.undo(.run(runID), in: folder, trash: .system, log: log)

            #expect(Set(undo.undone.map(\.originalName)) == [Partials.chrome, Partials.firefox, Partials.safari])
            #expect(undo.notUndone.isEmpty)
            #expect(undo.bytesTakenFromTrash == result.bytesFreed)
            #expect(Set(DiskState.entryNames(in: folder)) == [Partials.chrome, Partials.firefox, Partials.safari, Partials.finished])
            #expect(DiskState.text(of: folder.appending(path: Partials.firefox)) == contents.firefox)
            let package = folder.appending(path: Partials.safari)
            #expect(Set(DiskState.entryNames(in: package)) == [Partials.safariContent, Partials.safariInfo])
            #expect(DiskState.text(of: package.appending(path: Partials.safariContent)) == contents.safariContent)
            #expect(try await log.changes(inRun: runID).allSatisfy { $0.undoneAt != nil })
            #expect(try await log.totals() == .zero)
            // Put back just now, they are inside the grace period again, and failed downloads once
            // it has passed.
            #expect(try await plan(folder).isEmpty)
            let later = try #require(try await Partials.plan(folder, now: Date(timeIntervalSinceNow: 2 * 60 * 60)))
            #expect(later.changes.count == 3)
        }
    }

    private func setLocked(_ url: inout URL, _ locked: Bool) throws {
        var values = URLResourceValues()
        values.isUserImmutable = locked
        try url.setResourceValues(values)
    }
}

private extension CleanupItemOutcome {
    var isTrashed: Bool {
        if case .trashed = self {
            return true
        }
        return false
    }
}
