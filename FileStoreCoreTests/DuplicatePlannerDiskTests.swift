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
            // The reports (4 × 21 bytes), the receipt copy (22) and the photo copy (19), largest saving first.
            #expect(plan.duplicateGroups.map(\.kept.displayName) == [Names.reportPDF, Names.receipt, Names.photo])
            #expect(plan.changes.count == 6)
            #expect(plan.bytesToFree == 125)
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

    @Test func findsReceiptGroupKeepingTheCleanName() async throws {
        try await withFakeDownloadsFolder { fixture in
            let plan = try await plan(fixture)

            let receipts = try #require(group(keeping: Names.receipt, in: plan))
            #expect(receipts.duplicates.map(\.displayName) == [Names.receiptCopy])
        }
    }

    @Test func doesNotGroupLookalikesOrUniqueFiles() async throws {
        try await withFakeDownloadsFolder { fixture in
            let plan = try await plan(fixture)

            let mustStayAlone: Set<String> = [
                Names.notes, Names.notesEdited, Names.todoText, Names.todoMarkdown,
                Names.sameSizeA, Names.sameSizeB, Names.invoice, Names.invoiceCopy,
                Names.installer, Names.appZip, Names.zipArchive, Names.partialZipArchive,
                Names.singleFileZip, Names.singleFileZipContent, Names.lonelyZip,
                Names.numberedName, Names.copyWordName, Names.percentEncodedName,
                Names.queryLeftoverName, Names.doubledExtensionName,
                Names.oldReceipt, Names.oldManual, Names.taxForm, Names.statement,
                Names.lockedFile, Names.unicodePDF, Names.noExtension, Names.bigVideo, Names.largeFile,
            ]
            #expect(groupedNames(plan).isDisjoint(with: mustStayAlone))
        }
    }

    @Test func excludesEmptyHiddenSubfolderSymlinkAndInProgress() async throws {
        try await withFakeDownloadsFolder { fixture in
            let plan = try await plan(fixture)

            let neverCandidates: Set<String> = [
                Names.emptyA, Names.emptyB, Names.hiddenFile, Names.symlink,
                Names.chromeDownload, Names.safariDownload, Names.partialDownload, Names.freshDownload,
                Names.subfolder, Names.zipFolder, Names.partialZipFolder,
                Names.emptyFolder, Names.dsStoreFolder, Names.archiveFolder,
            ]
            #expect(groupedNames(plan).isDisjoint(with: neverCandidates))
            for change in plan.changes {
                expectSameFolder(change.record.url.deletingLastPathComponent(), fixture.url)
            }
        }
    }

    /// A new file is left alone for the whole grace period, judged on both of its dates: one that
    /// was just put in the folder is new even when its modification date is old.
    @Test func excludesFileAddedOrModifiedInLastHour() async throws {
        try await withFakeDownloadsFolder { fixture in
            let fresh = fixture.url(for: Names.freshReportCopy)
            try Data(FakeDownloadsFolder.reportContents.utf8).write(to: fresh)

            let written = try await plan(fixture)
            #expect(group(keeping: Names.reportPDF, in: written)?.duplicates.count == 4)
            #expect(!groupedNames(written).contains(Names.freshReportCopy))

            // An old modification date alone is not enough: it was still added moments ago.
            try FileManager.default.setAttributes(
                [.modificationDate: Date(timeIntervalSinceNow: -FileDates.settledAge)],
                ofItemAtPath: fresh.path(percentEncoded: false)
            )
            let modifiedLongAgo = try await plan(fixture)
            #expect(!groupedNames(modifiedLongAgo).contains(Names.freshReportCopy))

            try FileDates.settle([fresh])
            let settled = try await plan(fixture)
            let reports = try #require(group(keeping: Names.reportPDF, in: settled))
            #expect(reports.duplicates.count == 5)
            #expect(reports.duplicates.map(\.displayName).contains(Names.freshReportCopy))
        }
    }

    /// A copy keeps its original's modification date but is new to the folder, so it waits too.
    @Test func excludesCopyMadeMomentsAgo() async throws {
        try await withFakeDownloadsFolder { fixture in
            let copy = fixture.url(for: Names.freshReportCopy)
            try FileManager.default.copyItem(at: fixture.url(for: Names.reportPDF), to: copy)
            let records = try await scan(fixture)
            let record = try #require(records.first { $0.displayName == Names.freshReportCopy })
            let original = try #require(records.first { $0.displayName == Names.reportPDF })
            #expect(record.dateModified == original.dateModified)

            let plan = try await planner.plan(records: records, in: fixture.url)

            #expect(!groupedNames(plan).contains(Names.freshReportCopy))
            #expect(group(keeping: Names.reportPDF, in: plan)?.duplicates.count == 4)
        }
    }

    /// The archive's name and downloads in progress are never candidates, whatever they hold: here
    /// regular files identical to a real pair, including a plain file ending in `.download`.
    @Test func neverGroupsTheArchiveNameOrDownloadsInProgress() async throws {
        let temp = try TemporaryFolder.make()
        defer { temp.remove() }
        let excluded = ["old downloads", "a.download", "a.crdownload", "a.part"]
        var files = ["a.txt": "alpha", "a (1).txt": "alpha"]
        for name in excluded {
            files[name] = "alpha"
        }
        try FileDates.writeSettled(files, in: temp.url)

        let plan = try await planner.plan(
            records: try await scanner.scan(ScanLocation(folderURL: temp.url, source: .launchArgument)).records,
            in: temp.url
        )

        #expect(plan.changes.map(\.record.displayName) == ["a (1).txt"])
        #expect(groupedNames(plan).isDisjoint(with: excluded))
    }

    @Test func hashesOnlyFilesSharingASize() async throws {
        try await withFakeDownloadsFolder { fixture in
            let log = ConcurrentLog<DuplicateScanProgress>()
            _ = try await plan(fixture) { log.append($0) }

            // 5 reports × 21, 2 receipts × 22, 2 photos × 19, 2 invoices × 18, 2 same-size × 4,
            // 2 three-byte files (Tool.pkg, old-receipt.pdf), 2 six-byte files (the percent name,
            // locked.txt). Every other file, the zips among them, has a size of its own.
            let last = try #require(log.values.last)
            #expect(last.filesToHash == 17)
            #expect(last.bytesToHash == 249)
            #expect(last.filesHashed == 17)
            #expect(last.bytesHashed == 249)
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
            #expect(plan.changes.count == 5)
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
    /// Records that are hidden or outside the folder are dropped before hashing, even when handed
    /// in directly. The scanner never produces them; a plan must not reach past its folder.
    @Test func ignoresHiddenAndOutsideFolderRecords() async throws {
        let temp = try TemporaryFolder.make()
        defer { temp.remove() }
        let inside = temp.url.appending(path: "Inside", directoryHint: .isDirectory)
        let outside = temp.url.appending(path: "Outside", directoryHint: .isDirectory)
        let settled = Date(timeIntervalSinceNow: -FileDates.settledAge)
        for folder in [inside, outside] {
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: false)
        }
        for (folder, name) in [(inside, "a.txt"), (inside, "a (1).txt"), (inside, ".a.txt"), (outside, "a (2).txt")] {
            let url = folder.appending(path: name)
            try Data("alpha".utf8).write(to: url)
            try FileDates.set(url, to: settled)
        }
        let insideRecords = try await scanner.scan(ScanLocation(folderURL: inside, source: .launchArgument)).records
        let outsideRecords = try await scanner.scan(ScanLocation(folderURL: outside, source: .launchArgument)).records
        // The scanner itself skips the hidden file; the record below stands in for a plan built elsewhere.
        #expect(insideRecords.count == 2)
        let hidden = FileRecord(
            url: inside.appending(path: ".a.txt"),
            displayName: ".a.txt",
            kind: .file,
            localizedTypeDescription: nil,
            contentType: nil,
            sizeInBytes: 5,
            dateAdded: settled,
            dateModified: settled,
            isDownloading: false
        )

        let plan = try await planner.plan(records: insideRecords + outsideRecords + [hidden], in: inside)

        #expect(plan.duplicateGroups.count == 1)
        #expect(plan.changes.map(\.record.displayName) == ["a (1).txt"])
        #expect(plan.skippedItems.isEmpty)
    }
    /// Two names for one file (a hard link) hold the same bytes by definition. They are not
    /// duplicates of each other, nothing is proposed for them, and a real copy is still found.
    @Test func hardLinksAreNotDuplicates() async throws {
        let temp = try TemporaryFolder.make()
        defer { temp.remove() }
        let fileManager = FileManager.default
        for name in ["a.txt", "a (2).txt"] {
            try Data("alpha".utf8).write(to: temp.url.appending(path: name))
        }
        try fileManager.linkItem(
            atPath: temp.url.appending(path: "a.txt").path(percentEncoded: false),
            toPath: temp.url.appending(path: "a (1).txt").path(percentEncoded: false)
        )
        let records = try await scanner.scan(ScanLocation(folderURL: temp.url, source: .launchArgument)).records
        #expect(records.count == 3)
        // Each name of a hard link has a Date Added of its own, so the plan is made two hours on
        // rather than by dating files back; then all three names are candidates and the hard-link
        // rule itself is what keeps `a (1).txt` out of the plan.
        let later = Date(timeIntervalSinceNow: 2 * 3_600)
        #expect(planner.candidates(in: records, now: later).count == 3)

        let plan = try await planner.plan(records: records, in: temp.url, now: later)

        #expect(plan.duplicateGroups.count == 1)
        #expect(plan.duplicateGroups.first?.kept.displayName == "a.txt")
        #expect(plan.changes.map(\.record.displayName) == ["a (2).txt"])
        #expect(plan.skippedItems.isEmpty)

        // Only the two names of one file left: nothing to find, now and on every later run.
        try fileManager.removeItem(at: temp.url.appending(path: "a (2).txt"))
        let again = try await planner.plan(
            records: try await scanner.scan(ScanLocation(folderURL: temp.url, source: .launchArgument)).records,
            in: temp.url,
            now: later
        )
        #expect(again.isEmpty)
        #expect(again.skippedItems.isEmpty)
    }
}
