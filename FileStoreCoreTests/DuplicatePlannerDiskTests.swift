import FileStoreCore
import Foundation
import Testing

/// The planner on the shared fixture: scan, then plan, and check what would and would not change.
/// Nothing here moves a file; the only removals are in a temporary folder the test made itself.
@Suite("DuplicatePlanner (disk)")
struct DuplicatePlannerDiskTests {
    private typealias Names = FakeDownloadsFolder.Names

    private let scanner = FolderScanner()
    private let planner = DuplicatePlanner()

    private func scan(_ fixture: FakeDownloadsFolder) async throws -> [FileRecord] {
        try await scanner.scan(ScanLocation(folderURL: fixture.url, source: .launchArgument)).records
    }

    private func plan(
        _ fixture: FakeDownloadsFolder,
        onProgress: (@Sendable (DuplicateScanProgress) -> Void)? = nil
    ) async throws -> CleanupPlan {
        let records = try await scan(fixture)
        return try await planner.plan(records: records, in: fixture.url, onProgress: onProgress)
    }

    private func group(keeping name: String, in plan: CleanupPlan) -> DuplicateGroup? {
        plan.duplicateGroups.first { $0.kept.displayName == name }
    }

    /// Every file that appears in any group, kept or not.
    private func groupedNames(_ plan: CleanupPlan) -> Set<String> {
        Set(plan.duplicateGroups.flatMap { [$0.kept.displayName] + $0.duplicates.map(\.displayName) })
    }

    @Test func findsReportGroupKeepingReportPDF() async throws {
        try await withFakeDownloadsFolder { fixture in
            let plan = try await plan(fixture)

            let reports = try #require(group(keeping: Names.reportPDF, in: plan))
            #expect(
                reports.duplicates.map(\.displayName)
                    == [Names.reportCopy1, Names.reportCopy2, Names.lockedReportCopy, Names.reportCopyWord]
            )
            #expect(reports.fileSizeInBytes == 21)
            #expect(reports.reclaimableBytes == 84)
            let reportChanges = plan.changes.filter { $0.reason == .sameContent(asFileNamed: Names.reportPDF) }
            #expect(reportChanges.count == 4)
            #expect(reportChanges.allSatisfy { $0.operation == .moveToTrash && $0.sizeInBytes == 21 })

            #expect(plan.action == .findDuplicates)
            expectSameFolder(plan.folderURL, fixture.url)
            #expect(plan.duplicateGroups.count == 2)
            #expect(plan.changes.count == 5)
            #expect(plan.bytesToFree == 103)
            #expect(plan.skippedItems.isEmpty)
        }
    }

    @Test func findsPhotoGroupKeepingOlderFile() async throws {
        try await withFakeDownloadsFolder { fixture in
            let plan = try await plan(fixture)

            let photos = try #require(group(keeping: Names.photo, in: plan))
            #expect(photos.duplicates.map(\.displayName) == [Names.photoCopy])
            let keptAdded = try #require(photos.kept.dateAdded)
            let copyAdded = try #require(photos.duplicates.first?.dateAdded)
            #expect(keptAdded <= copyAdded)
        }
    }

    @Test func doesNotGroupNotesOrSameSizePairs() async throws {
        try await withFakeDownloadsFolder { fixture in
            let plan = try await plan(fixture)

            let mustStayAlone: Set<String> = [
                Names.notes, Names.notesEdited,
                Names.sameSizeA, Names.sameSizeB,
                Names.diskImage, Names.installer, Names.zipArchive, Names.oldReceipt,
                Names.lockedFile, Names.percentEncodedName,
                Names.unicodePDF, Names.noExtension, Names.bigVideo,
            ]
            #expect(groupedNames(plan).isDisjoint(with: mustStayAlone))
        }
    }

    @Test func excludesEmptyHiddenSubfolderSymlinkAndInProgress() async throws {
        try await withFakeDownloadsFolder { fixture in
            let plan = try await plan(fixture)

            let neverCandidates: Set<String> = [
                Names.emptyA, Names.emptyB, Names.hiddenFile, Names.symlink,
                Names.chromeDownload, Names.safariDownload, Names.partialDownload,
                Names.subfolder, Names.zipFolder,
            ]
            #expect(groupedNames(plan).isDisjoint(with: neverCandidates))
            for change in plan.changes {
                expectSameFolder(change.record.url.deletingLastPathComponent(), fixture.url)
            }
        }
    }

    @Test func excludesFileModifiedInLastTenSeconds() async throws {
        try await withFakeDownloadsFolder { fixture in
            let fresh = fixture.url(for: Names.freshReportCopy)
            try Data(FakeDownloadsFolder.reportContents.utf8).write(to: fresh)

            let before = try await plan(fixture)
            #expect(group(keeping: Names.reportPDF, in: before)?.duplicates.count == 4)
            #expect(!groupedNames(before).contains(Names.freshReportCopy))

            try FileManager.default.setAttributes(
                [.modificationDate: Date(timeIntervalSinceNow: -60)],
                ofItemAtPath: fresh.path(percentEncoded: false)
            )
            let after = try await plan(fixture)
            let reports = try #require(group(keeping: Names.reportPDF, in: after))
            #expect(reports.duplicates.count == 5)
            #expect(reports.duplicates.map(\.displayName).contains(Names.freshReportCopy))
        }
    }

    @Test func hashesOnlyFilesSharingASize() async throws {
        try await withFakeDownloadsFolder { fixture in
            let log = ConcurrentLog<DuplicateScanProgress>()
            _ = try await plan(fixture) { log.append($0) }

            // 5 reports × 21, 2 photos × 19, 2 same-size × 4, 4 three-byte files, 2 six-byte files.
            let last = try #require(log.values.last)
            #expect(last.filesToHash == 15)
            #expect(last.bytesToHash == 175)
            #expect(last.filesHashed == 15)
            #expect(last.bytesHashed == 175)
        }
    }

    @Test func reportsProgressMonotonically() async throws {
        try await withFakeDownloadsFolder { fixture in
            let log = ConcurrentLog<DuplicateScanProgress>()
            _ = try await plan(fixture) { log.append($0) }

            let values = log.values
            #expect(values.count >= 2)
            #expect(values.first?.filesHashed == 0)
            #expect(values.first?.bytesHashed == 0)
            for (earlier, later) in zip(values, values.dropFirst()) {
                #expect(earlier.filesHashed <= later.filesHashed)
                #expect(earlier.bytesHashed <= later.bytesHashed)
                #expect(earlier.filesToHash == later.filesToHash)
            }
            #expect(values.last?.fractionCompleted == 1)
        }
    }

    @Test func skipsUnreadableFileAndContinues() async throws {
        try await withFakeDownloadsFolder { fixture in
            let unreadable = fixture.url(for: Names.reportCopy2)
            let path = unreadable.path(percentEncoded: false)
            try FileManager.default.setAttributes([.posixPermissions: 0o000], ofItemAtPath: path)
            defer { try? FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: path) }

            let plan = try await plan(fixture)

            let reports = try #require(group(keeping: Names.reportPDF, in: plan))
            #expect(reports.duplicates.map(\.displayName) == [Names.reportCopy1, Names.lockedReportCopy, Names.reportCopyWord])
            #expect(plan.changes.count == 4)
            #expect(plan.skippedItems.count == 1)
            let skipped = try #require(plan.skippedItems.first)
            #expect(canonicalPath(skipped.url) == canonicalPath(unreadable))
            #expect(skipped.reason == .accessDenied)
        }
    }

    @Test func skipsFileThatChangedSinceScan() async throws {
        try await withFakeDownloadsFolder { fixture in
            let records = try await scan(fixture)
            let changed = fixture.url(for: Names.reportCopy1)
            let handle = try FileHandle(forWritingTo: changed)
            try handle.seekToEnd()
            try handle.write(contentsOf: Data(" and more".utf8))
            try handle.close()

            let plan = try await planner.plan(records: records, in: fixture.url)

            let reports = try #require(group(keeping: Names.reportPDF, in: plan))
            #expect(reports.duplicates.map(\.displayName) == [Names.reportCopy2, Names.lockedReportCopy, Names.reportCopyWord])
            #expect(plan.skippedItems.count == 1)
            let skipped = try #require(plan.skippedItems.first)
            #expect(canonicalPath(skipped.url) == canonicalPath(changed))
            #expect(skipped.reason == .changedSinceScan)
        }
    }

    @Test func planIsEmptyAfterRemovingPlannedFiles() async throws {
        try await withFakeDownloadsFolder { fixture in
            let first = try await plan(fixture)
            #expect(!first.isEmpty)

            // Removes the planned files directly, inside a folder this test created, to check the
            // planner alone; the executor has its own idempotence test. The locked copy is unlocked
            // first, or it could not be removed.
            try FileManager.default.setAttributes(
                [.immutable: false],
                ofItemAtPath: fixture.url(for: Names.lockedReportCopy).path(percentEncoded: false)
            )
            for change in first.changes {
                try FileManager.default.removeItem(at: change.record.url)
            }

            let second = try await plan(fixture)
            #expect(second.isEmpty)
            #expect(second.duplicateGroups.isEmpty)
            #expect(second.skippedItems.isEmpty)
            #expect(second.bytesToFree == 0)
        }
    }

    @Test func cancelledPlanThrowsCancelled() async throws {
        try await withFakeDownloadsFolder { fixture in
            let records = try await scan(fixture)
            let planner = planner
            let folderURL = fixture.url
            // The task cancels itself before the search starts, so the outcome never depends on timing.
            let task = Task {
                withUnsafeCurrentTask { $0?.cancel() }
                return try await planner.plan(records: records, in: folderURL)
            }

            await #expect(throws: DuplicatePlanError.cancelled) {
                try await task.value
            }
        }
    }
}
