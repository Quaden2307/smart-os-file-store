import FileStoreCore
import Foundation
import Testing

/// The executor on the shared fixture and on small folders of its own. Every folder is a temporary
/// one the test made; the only other place touched is the user's Trash, where `trashItem` puts
/// the files, and `TrashedFiles` removes those again when the runner may.
@Suite("TrashExecutor")
struct TrashExecutorTests {
    private typealias Names = FakeDownloadsFolder.Names

    private let scanner = FolderScanner()
    private let planner = DuplicatePlanner()
    private let executor = TrashExecutor()

    // MARK: - Helpers

    private func plan(_ folder: URL) async throws -> CleanupPlan {
        let records = try await scanner.scan(ScanLocation(folderURL: folder, source: .launchArgument)).records
        return try await planner.plan(records: records, in: folder)
    }

    private func change(named name: String, in plan: CleanupPlan) throws -> ProposedChange {
        try #require(plan.changes.first { $0.record.displayName == name }, "no change for \(name)")
    }

    private func outcome(for name: String, in result: CleanupResult) throws -> CleanupItemOutcome {
        try #require(result.items.first { $0.change.record.displayName == name }, "no result for \(name)").outcome
    }

    private func trashedNames(_ result: CleanupResult) -> [String] {
        result.trashed.map(\.change.record.displayName)
    }

    /// True when something is at `url`, a symbolic link included (`fileExists` would follow it).
    private func exists(_ url: URL) -> Bool {
        (try? FileManager.default.attributesOfItem(atPath: url.path(percentEncoded: false))) != nil
    }

    private func isSymbolicLink(_ url: URL) -> Bool {
        let attributes = try? FileManager.default.attributesOfItem(atPath: url.path(percentEncoded: false))
        return attributes?[.type] as? FileAttributeType == .typeSymbolicLink
    }

    /// Writes `files` (name to text) into `folder`, backdated a minute so the planner counts them.
    private func writeSettled(_ files: [String: String], in folder: URL) throws {
        let settled = Date(timeIntervalSinceNow: -60)
        for (name, text) in files {
            let url = folder.appending(path: name)
            try Data(text.utf8).write(to: url)
            try FileManager.default.setAttributes([.modificationDate: settled], ofItemAtPath: url.path(percentEncoded: false))
        }
    }

    /// The bytes the fixture wrote, for the Trash cleanup's content check.
    private func fixtureContents(of url: URL) -> Data? {
        switch url.lastPathComponent {
        case Names.reportPDF, Names.reportCopy1, Names.reportCopy2, Names.lockedReportCopy, Names.reportCopyWord:
            Data(FakeDownloadsFolder.reportContents.utf8)
        case Names.photo, Names.photoCopy:
            Data(FakeDownloadsFolder.photoContents.utf8)
        default:
            nil
        }
    }

    /// A record for a crafted plan, shaped like `template` but at another URL.
    private func record(like template: FileRecord, url: URL) -> FileRecord {
        FileRecord(
            url: url,
            displayName: url.lastPathComponent,
            kind: .file,
            localizedTypeDescription: template.localizedTypeDescription,
            contentType: template.contentType,
            sizeInBytes: template.sizeInBytes,
            dateAdded: template.dateAdded,
            dateModified: template.dateModified,
            isDownloading: false
        )
    }

    private func proposedChange(_ record: FileRecord, keptName: String) -> ProposedChange {
        ProposedChange(record: record, operation: .moveToTrash, reason: .sameContent(asFileNamed: keptName))
    }

    // MARK: - Tests

    /// The precondition for every other test here: this runner can put a file in the Trash.
    @Test func trashesOneFileIntoTheTrash() async throws {
        let temp = try TemporaryFolder.make()
        defer { temp.remove() }
        try writeSettled(["a.txt": "same bytes", "a (1).txt": "same bytes"], in: temp.url)
        let plan = try await plan(temp.url)
        #expect(plan.changes.count == 1)

        let result = await executor.execute(plan: plan, confirmedChangeIDs: Set(plan.changes.map(\.id)))
        defer { TrashedFiles.remove(result) { _ in Data("same bytes".utf8) } }

        let outcome = try outcome(for: "a (1).txt", in: result)
        guard case .trashed(let trashURL) = outcome else {
            Issue.record("expected the copy to be trashed, got \(outcome)")
            return
        }
        let trashDirectory = try FileManager.default.url(
            for: .trashDirectory, in: .userDomainMask, appropriateFor: temp.url, create: false
        )
        let destination = try #require(trashURL)
        #expect(canonicalPath(destination).hasPrefix(canonicalPath(trashDirectory) + "/"))
        #expect(!exists(temp.url.appending(path: "a (1).txt")))
        #expect(exists(temp.url.appending(path: "a.txt")))
        #expect(result.trashedCount == 1)
        #expect(result.bytesFreed == 10)
        #expect(!result.wasCancelled)
        #expect(result.action == .findDuplicates)
    }

    @Test func trashesOnlyTickedFiles() async throws {
        try await withFakeDownloadsFolder { fixture in
            let plan = try await plan(fixture.url)
            let ticked: Set<ProposedChange.ID> = try [
                change(named: Names.reportCopy1, in: plan).id,
                change(named: Names.photoCopy, in: plan).id,
            ]

            let result = await executor.execute(plan: plan, confirmedChangeIDs: ticked)
            defer { TrashedFiles.remove(result, expectedContents: fixtureContents) }

            #expect(result.items.count == 2)
            #expect(Set(trashedNames(result)) == [Names.reportCopy1, Names.photoCopy])
            #expect(result.bytesFreed == 40)
            #expect(!exists(fixture.url(for: Names.reportCopy1)))
            #expect(!exists(fixture.url(for: Names.photoCopy)))
            for name in [Names.reportPDF, Names.reportCopy2, Names.lockedReportCopy, Names.reportCopyWord, Names.photo] {
                #expect(exists(fixture.url(for: name)), "\(name) should still be there")
            }
        }
    }

    @Test func lockedFileFailsAndOthersComplete() async throws {
        try await withFakeDownloadsFolder { fixture in
            let plan = try await plan(fixture.url)
            let ticked: Set<ProposedChange.ID> = try [
                change(named: Names.lockedReportCopy, in: plan).id,
                change(named: Names.reportCopyWord, in: plan).id,
            ]

            let result = await executor.execute(plan: plan, confirmedChangeIDs: ticked)
            defer { TrashedFiles.remove(result, expectedContents: fixtureContents) }

            #expect(try outcome(for: Names.lockedReportCopy, in: result) == .failed(.fileIsLocked))
            #expect(exists(fixture.url(for: Names.lockedReportCopy)))
            #expect(trashedNames(result) == [Names.reportCopyWord])
            #expect(!exists(fixture.url(for: Names.reportCopyWord)))
            #expect(result.failed.count == 1)
            #expect(result.skipped.isEmpty)
        }
    }

    @Test func deletedFileIsSkipped() async throws {
        try await withFakeDownloadsFolder { fixture in
            let plan = try await plan(fixture.url)
            let target = try change(named: Names.reportCopy1, in: plan)
            try FileManager.default.removeItem(at: fixture.url(for: Names.reportCopy1))

            let result = await executor.execute(plan: plan, confirmedChangeIDs: [target.id])

            #expect(try outcome(for: Names.reportCopy1, in: result) == .skipped(.notFound))
            #expect(result.trashedCount == 0)
        }
    }

    @Test func appendedFileIsSkipped() async throws {
        try await withFakeDownloadsFolder { fixture in
            let plan = try await plan(fixture.url)
            let target = try change(named: Names.reportCopy1, in: plan)
            let url = fixture.url(for: Names.reportCopy1)
            let handle = try FileHandle(forWritingTo: url)
            try handle.seekToEnd()
            try handle.write(contentsOf: Data(" and more".utf8))
            try handle.close()

            let result = await executor.execute(plan: plan, confirmedChangeIDs: [target.id])

            #expect(try outcome(for: Names.reportCopy1, in: result) == .skipped(.changedSinceScan))
            #expect(exists(url))
            #expect(result.trashedCount == 0)
        }
    }

    @Test func replacedSameSizeFileIsSkipped() async throws {
        try await withFakeDownloadsFolder { fixture in
            let url = fixture.url(for: Names.reportCopy1)
            let path = url.path(percentEncoded: false)
            // A whole-second date survives the round trip through `setAttributes` exactly, so after
            // the swap the restored date matches the scan's and only the content check can catch it.
            let settled = Date(timeIntervalSince1970: (Date().timeIntervalSince1970 - 120).rounded(.down))
            try FileManager.default.setAttributes([.modificationDate: settled], ofItemAtPath: path)
            let plan = try await plan(fixture.url)
            let target = try change(named: Names.reportCopy1, in: plan)
            #expect(target.dateModified == settled)

            let replacement = Data("QUARTERLY REPORT BODY".utf8)
            #expect(replacement.count == FakeDownloadsFolder.reportContents.utf8.count)
            try replacement.write(to: url)
            try FileManager.default.setAttributes([.modificationDate: settled], ofItemAtPath: path)

            let result = await executor.execute(plan: plan, confirmedChangeIDs: [target.id])

            #expect(try outcome(for: Names.reportCopy1, in: result) == .skipped(.changedSinceScan))
            #expect(try Data(contentsOf: url) == replacement)
            #expect(result.trashedCount == 0)
        }
    }

    @Test func missingKeptFileSkipsWholeGroup() async throws {
        try await withFakeDownloadsFolder { fixture in
            let plan = try await plan(fixture.url)
            try FileManager.default.removeItem(at: fixture.url(for: Names.reportPDF))

            let result = await executor.execute(plan: plan, confirmedChangeIDs: Set(plan.changes.map(\.id)))
            defer { TrashedFiles.remove(result, expectedContents: fixtureContents) }

            for name in [Names.reportCopy1, Names.reportCopy2, Names.lockedReportCopy, Names.reportCopyWord] {
                #expect(try outcome(for: name, in: result) == .skipped(.keptFileMissing(name: Names.reportPDF)))
                #expect(exists(fixture.url(for: name)), "\(name) should still be there")
            }
            #expect(trashedNames(result) == [Names.photoCopy])
        }
    }

    @Test func changedKeptFileSkipsWholeGroup() async throws {
        try await withFakeDownloadsFolder { fixture in
            let plan = try await plan(fixture.url)
            let reportChanges = plan.changes.filter { $0.reason == .sameContent(asFileNamed: Names.reportPDF) }
            #expect(reportChanges.count == 4)
            try Data("QUARTERLY REPORT BODY".utf8).write(to: fixture.url(for: Names.reportPDF))

            let result = await executor.execute(plan: plan, confirmedChangeIDs: Set(reportChanges.map(\.id)))

            #expect(result.items.count == 4)
            for item in result.items {
                let name = item.change.record.displayName
                if name == Names.lockedReportCopy {
                    // The lock is found before the kept copy is read: a locked file cannot move anyway.
                    #expect(item.outcome == .failed(.fileIsLocked))
                } else {
                    #expect(item.outcome == .skipped(.keptFileNotVerified(name: Names.reportPDF)), "\(name)")
                }
                #expect(exists(item.change.record.url))
            }
            #expect(result.trashedCount == 0)
        }
    }

    /// The names make the kept file certain: `x.pdf` has no copy suffix, `x (1).pdf` does.
    @Test func craftedPlanNeverTrashesEveryCopy() async throws {
        // A: the kept file listed as a change of its own group.
        do {
            let temp = try TemporaryFolder.make()
            defer { temp.remove() }
            try writeSettled(["x.pdf": "same", "x (1).pdf": "same"], in: temp.url)
            let real = try await plan(temp.url)
            let group = try #require(real.duplicateGroups.first)
            #expect(group.kept.displayName == "x.pdf")
            let crafted = CleanupPlan(
                action: .findDuplicates,
                folderURL: temp.url,
                changes: [proposedChange(group.kept, keptName: "x (1).pdf")] + real.changes,
                duplicateGroups: [
                    DuplicateGroup(
                        contentHash: group.contentHash,
                        kept: group.kept,
                        duplicates: [group.kept] + group.duplicates,
                        fileSizeInBytes: group.fileSizeInBytes
                    ),
                ]
            )

            let result = await executor.execute(plan: crafted, confirmedChangeIDs: Set(crafted.changes.map(\.id)))
            defer { TrashedFiles.remove(result) { _ in Data("same".utf8) } }

            #expect(try outcome(for: "x.pdf", in: result) == .skipped(.keptFile))
            #expect(trashedNames(result) == ["x (1).pdf"])
            #expect(exists(temp.url.appending(path: "x.pdf")))
        }

        // B: two groups that each keep the other's duplicate.
        do {
            let temp = try TemporaryFolder.make()
            defer { temp.remove() }
            try writeSettled(["x.pdf": "same", "x (1).pdf": "same"], in: temp.url)
            let real = try await plan(temp.url)
            let group = try #require(real.duplicateGroups.first)
            let kept = group.kept
            let copy = try #require(group.duplicates.first)
            let crafted = CleanupPlan(
                action: .findDuplicates,
                folderURL: temp.url,
                changes: [proposedChange(copy, keptName: kept.displayName), proposedChange(kept, keptName: copy.displayName)],
                duplicateGroups: [
                    DuplicateGroup(contentHash: group.contentHash, kept: kept, duplicates: [copy], fileSizeInBytes: 4),
                    DuplicateGroup(contentHash: group.contentHash, kept: copy, duplicates: [kept], fileSizeInBytes: 4),
                ]
            )

            let result = await executor.execute(plan: crafted, confirmedChangeIDs: Set(crafted.changes.map(\.id)))

            #expect(try outcome(for: "x.pdf", in: result) == .skipped(.keptFile))
            #expect(try outcome(for: "x (1).pdf", in: result) == .skipped(.keptFile))
            #expect(result.trashedCount == 0)
            #expect(exists(kept.url))
            #expect(exists(copy.url))
        }

        // C: the kept file under another spelling of its name. On the usual case-insensitive volume
        // that is the same file, refused by identity; on a case-sensitive one it does not exist.
        do {
            let temp = try TemporaryFolder.make()
            defer { temp.remove() }
            try writeSettled(["x.pdf": "same", "x (1).pdf": "same"], in: temp.url)
            let real = try await plan(temp.url)
            let group = try #require(real.duplicateGroups.first)
            #expect(group.kept.displayName == "x.pdf")
            let upper = record(like: group.kept, url: temp.url.appending(path: "X.PDF"))
            let crafted = CleanupPlan(
                action: .findDuplicates,
                folderURL: temp.url,
                changes: [proposedChange(upper, keptName: group.kept.displayName)],
                duplicateGroups: [
                    DuplicateGroup(contentHash: group.contentHash, kept: group.kept, duplicates: [upper], fileSizeInBytes: 4),
                ]
            )

            let result = await executor.execute(plan: crafted, confirmedChangeIDs: Set(crafted.changes.map(\.id)))

            let outcome = try outcome(for: "X.PDF", in: result)
            #expect(outcome == .skipped(.keptFile) || outcome == .skipped(.notFound))
            #expect(result.trashedCount == 0)
            #expect(exists(temp.url.appending(path: "x.pdf")))
            #expect(exists(temp.url.appending(path: "x (1).pdf")))
        }
    }

    @Test func refusesPathOutsideFolderAndSymlink() async throws {
        try await withFakeDownloadsFolder { fixture in
            let plan = try await plan(fixture.url)
            let group = try #require(plan.duplicateGroups.first { $0.kept.displayName == Names.reportPDF })

            // An identical file beside the scanned folder, addressed through it with "..".
            let outside = fixture.url.deletingLastPathComponent().appending(path: "outside.pdf")
            try Data(FakeDownloadsFolder.reportContents.utf8).write(to: outside)
            try FileManager.default.setAttributes(
                [.modificationDate: Date(timeIntervalSinceNow: -60)],
                ofItemAtPath: outside.path(percentEncoded: false)
            )
            let sneaky = record(like: group.kept, url: fixture.url.appending(path: "../outside.pdf"))
            let link = record(like: group.kept, url: fixture.url(for: Names.symlink))
            let crafted = CleanupPlan(
                action: .findDuplicates,
                folderURL: fixture.url,
                changes: [sneaky, link].map { proposedChange($0, keptName: Names.reportPDF) },
                duplicateGroups: [
                    DuplicateGroup(contentHash: group.contentHash, kept: group.kept, duplicates: [sneaky, link], fileSizeInBytes: 21),
                ]
            )

            let result = await executor.execute(plan: crafted, confirmedChangeIDs: Set(crafted.changes.map(\.id)))

            #expect(try outcome(for: "outside.pdf", in: result) == .skipped(.outsideFolder))
            #expect(try outcome(for: Names.symlink, in: result) == .skipped(.notARegularFile))
            #expect(exists(outside))
            #expect(isSymbolicLink(fixture.url(for: Names.symlink)))
            #expect(exists(fixture.url(for: Names.reportPDF)))
            #expect(result.trashedCount == 0)
        }
    }

    @Test func secondRunFindsNothing() async throws {
        let temp = try TemporaryFolder.make()
        defer { temp.remove() }
        let contents = ["a.txt": "alpha", "a (1).txt": "alpha", "a (2).txt": "alpha", "b.jpg": "beta", "c.jpg": "beta"]
        try writeSettled(contents, in: temp.url)
        let first = try await plan(temp.url)
        #expect(first.changes.count == 3)
        let ids = Set(first.changes.map(\.id))
        let log = ConcurrentLog<CleanupExecutionProgress>()

        let result = await executor.execute(plan: first, confirmedChangeIDs: ids) { log.append($0) }
        defer { TrashedFiles.remove(result) { url in contents[url.lastPathComponent].map { Data($0.utf8) } } }

        #expect(result.trashedCount == 3)
        #expect(result.bytesFreed == 14)

        let second = try await plan(temp.url)
        #expect(second.isEmpty)
        #expect(second.duplicateGroups.isEmpty)

        let again = await executor.execute(plan: first, confirmedChangeIDs: ids)
        #expect(again.items.count == 3)
        #expect(again.items.allSatisfy { $0.outcome == .skipped(.notFound) })
        #expect(again.trashedCount == 0)

        let values = log.values
        #expect(values.count == 4)
        #expect(values.first?.itemsCompleted == 0)
        #expect(values.first?.bytesFreed == 0)
        for (earlier, later) in zip(values, values.dropFirst()) {
            #expect(earlier.itemsCompleted < later.itemsCompleted)
            #expect(earlier.bytesFreed <= later.bytesFreed)
            #expect(earlier.itemsTotal == 3 && later.itemsTotal == 3)
        }
        #expect(values.last?.itemsCompleted == 3)
        #expect(values.last?.bytesFreed == 14)
        #expect(values.last?.fractionCompleted == 1)
    }

    @Test func preCancelledTaskTrashesNothing() async throws {
        try await withFakeDownloadsFolder { fixture in
            let plan = try await plan(fixture.url)
            let ids = Set(plan.changes.map(\.id))
            let executor = executor
            // The task cancels itself before execution starts, so the outcome never depends on timing.
            let task = Task {
                withUnsafeCurrentTask { $0?.cancel() }
                return await executor.execute(plan: plan, confirmedChangeIDs: ids)
            }

            let result = await task.value

            #expect(result.wasCancelled)
            #expect(result.items.count == 5)
            #expect(result.items.allSatisfy { $0.outcome == .skipped(.cancelled) })
            #expect(result.trashedCount == 0)
            for change in plan.changes {
                #expect(exists(change.record.url))
            }
        }
    }

    @Test func cancelAfterFirstItemSkipsTheRest() async throws {
        let temp = try TemporaryFolder.make()
        defer { temp.remove() }
        try writeSettled(["a.txt": "alpha", "a (1).txt": "alpha", "a (2).txt": "alpha"], in: temp.url)
        let plan = try await plan(temp.url)
        #expect(plan.changes.map(\.record.displayName) == ["a (1).txt", "a (2).txt"])

        // The progress callback runs inside the executing task, so it can cancel that task.
        let result = await executor.execute(plan: plan, confirmedChangeIDs: Set(plan.changes.map(\.id))) { progress in
            if progress.itemsCompleted == 1 {
                withUnsafeCurrentTask { $0?.cancel() }
            }
        }
        defer { TrashedFiles.remove(result) { _ in Data("alpha".utf8) } }

        #expect(result.wasCancelled)
        #expect(trashedNames(result) == ["a (1).txt"])
        #expect(try outcome(for: "a (2).txt", in: result) == .skipped(.cancelled))
        #expect(exists(temp.url.appending(path: "a (2).txt")))
        #expect(exists(temp.url.appending(path: "a.txt")))
    }

    @Test func unavailableFolderSkipsEverything() async throws {
        try await withFakeDownloadsFolder { fixture in
            let real = try await plan(fixture.url)
            // The plan names a file as its folder, as a plan from an ejected volume might name a path that is gone.
            let crafted = CleanupPlan(
                action: .findDuplicates,
                folderURL: fixture.url(for: Names.reportPDF),
                changes: real.changes,
                duplicateGroups: real.duplicateGroups
            )

            let result = await executor.execute(plan: crafted, confirmedChangeIDs: Set(crafted.changes.map(\.id)))

            #expect(result.items.count == 5)
            #expect(result.items.allSatisfy { $0.outcome == .skipped(.folderUnavailable) })
            #expect(result.trashedCount == 0)
            for change in real.changes {
                #expect(exists(change.record.url))
            }
        }
    }

    @Test func unknownConfirmedIDsAreIgnored() async throws {
        try await withFakeDownloadsFolder { fixture in
            let plan = try await plan(fixture.url)
            let madeUp = fixture.url(for: "never-planned.pdf")

            let result = await executor.execute(plan: plan, confirmedChangeIDs: [madeUp])

            #expect(result.items.isEmpty)
            #expect(result.trashedCount == 0)
            #expect(!result.wasCancelled)
            for change in plan.changes {
                #expect(exists(change.record.url))
            }
        }
    }
}
