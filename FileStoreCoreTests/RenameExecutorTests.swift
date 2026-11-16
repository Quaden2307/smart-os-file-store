import FileStoreCore
import Foundation
import Testing

/// The executor's renames, on small temporary folders of the test's own. A rename never replaces
/// anything, acts only on a regular file directly inside the folder that is unchanged since the
/// scan, and accepts only a new name that is one valid file name.
@Suite("Rename")
struct RenameExecutorTests {
    private let executor = CleanupExecutor()

    private func executeAll(_ plan: CleanupPlan) async -> CleanupResult {
        await executor.execute(plan: plan, confirmedChangeIDs: Set(plan.changes.map(\.id)))
    }

    private func outcome(for name: String, in result: CleanupResult) throws -> CleanupItemOutcome {
        try RelocationPlans.outcome(for: name, in: result)
    }

    // MARK: - Renaming

    @Test func renamesAFileInPlace() async throws {
        let temp = try TemporaryFolder.make()
        defer { temp.remove() }
        try FileDates.writeSettled(["invoice (1).pdf": "invoice"], in: temp.url)
        let old = temp.url.appending(path: "invoice (1).pdf")
        let new = temp.url.appending(path: "invoice.pdf")
        let inode = try #require(DiskState.inode(of: old))
        let plan = try await RelocationPlans.rename([("invoice (1).pdf", "invoice.pdf")], in: temp.url)
        let scanned = try #require(plan.changes.first?.record.url)
        #expect(plan.changes.first?.destinationPath == scanned.deletingLastPathComponent().appending(path: "invoice.pdf").path(percentEncoded: false))
        #expect(plan.bytesToFree == 0)

        let result = await executeAll(plan)

        #expect(try outcome(for: "invoice (1).pdf", in: result) == .renamed(from: old, to: new))
        #expect(result.renamed.count == 1)
        #expect(result.items.first?.createdFolders == [])
        #expect(result.trashedCount == 0)
        #expect(result.bytesFreed == 0)
        #expect(!DiskState.exists(old))
        #expect(DiskState.text(of: new) == "invoice")
        #expect(DiskState.inode(of: new) == inode)
        #expect(DiskState.entryNames(in: temp.url) == ["invoice.pdf"])

        // The same plan again finds nothing to rename.
        let again = await executeAll(plan)
        #expect(try outcome(for: "invoice (1).pdf", in: again) == .skipped(.notFound))
        #expect(DiskState.entryNames(in: temp.url) == ["invoice.pdf"])
    }

    @Test func neverReplacesAFileWithTheNewName() async throws {
        let temp = try TemporaryFolder.make()
        defer { temp.remove() }
        try FileDates.writeSettled(["a.txt": "mine", "b.txt": "theirs"], in: temp.url)
        let plan = try await RelocationPlans.rename([("a.txt", "b.txt")], in: temp.url)

        let result = await executeAll(plan)

        #expect(try outcome(for: "a.txt", in: result) == .skipped(.destinationExists(name: "b.txt")))
        #expect(DiskState.text(of: temp.url.appending(path: "a.txt")) == "mine")
        #expect(DiskState.text(of: temp.url.appending(path: "b.txt")) == "theirs")
    }

    /// A hard link is the same file under a second name, but the name is taken all the same.
    @Test func neverRenamesOntoAHardLinkOfItself() async throws {
        let temp = try TemporaryFolder.make()
        defer { temp.remove() }
        try FileDates.writeSettled(["a.txt": "alpha"], in: temp.url)
        let original = temp.url.appending(path: "a.txt")
        let link = temp.url.appending(path: "b.txt")
        try FileManager.default.linkItem(at: original, to: link)
        let plan = try await RelocationPlans.rename([("a.txt", "b.txt")], in: temp.url)

        let result = await executeAll(plan)

        #expect(try outcome(for: "a.txt", in: result) == .skipped(.destinationExists(name: "b.txt")))
        #expect(DiskState.entryNames(in: temp.url) == ["a.txt", "b.txt"])
        #expect(DiskState.inode(of: original) == DiskState.inode(of: link))
    }

    /// On the usual case-insensitive volume "Report.PDF" is the same name as "report.pdf", yet the
    /// rename must still change how it is spelled.
    @Test func changesOnlyTheLetterCase() async throws {
        let temp = try TemporaryFolder.make()
        defer { temp.remove() }
        try FileDates.writeSettled(["report.pdf": "report"], in: temp.url)
        let inode = try #require(DiskState.inode(of: temp.url.appending(path: "report.pdf")))
        let plan = try await RelocationPlans.rename([("report.pdf", "Report.PDF")], in: temp.url)

        let result = await executeAll(plan)

        guard case .renamed = try outcome(for: "report.pdf", in: result) else {
            Issue.record("expected a rename, got \(result.items)")
            return
        }
        #expect(DiskState.entryNames(in: temp.url) == ["Report.PDF"])
        #expect(DiskState.inode(of: temp.url.appending(path: "Report.PDF")) == inode)
        #expect(DiskState.text(of: temp.url.appending(path: "Report.PDF")) == "report")
    }

    @Test func renamesToAndFromUnicodeNames() async throws {
        let temp = try TemporaryFolder.make()
        defer { temp.remove() }
        let precomposed = "caf\u{e9}.txt"
        let decomposed = "cafe\u{301}.txt"
        // Written through a file URL, so stored decomposed: `appending(path:)` decomposes names.
        try FileDates.writeSettled(
            ["resume.pdf": "cv", "invoice.pdf": "bill", "party.jpg": "fun", decomposed: "coffee"],
            in: temp.url
        )
        #expect(DiskState.entryNames(in: temp.url).map { Array($0.utf8) }.contains(Array(decomposed.utf8)))
        let plan = try await RelocationPlans.rename(
            [
                ("resume.pdf", "résumé – final ✓.pdf"),
                ("invoice.pdf", "請求書 2024.pdf"),
                ("party.jpg", "🎉 party 🎈.jpg"),
                (decomposed, precomposed),
            ],
            in: temp.url
        )

        let result = await executeAll(plan)

        #expect(result.renamed.count == 4, "\(result.items.map(\.outcome))")
        #expect(DiskState.text(of: temp.url.appending(path: "résumé – final ✓.pdf")) == "cv")
        #expect(DiskState.text(of: temp.url.appending(path: "請求書 2024.pdf")) == "bill")
        #expect(DiskState.text(of: temp.url.appending(path: "🎉 party 🎈.jpg")) == "fun")
        // A change of Unicode normalisation alone is a real rename: the volume stores the new form,
        // byte for byte as the plan gave it.
        let names = DiskState.entryNames(in: temp.url).map { Array($0.utf8) }
        #expect(names.contains(Array(precomposed.utf8)))
        #expect(!names.contains(Array(decomposed.utf8)))
    }

    /// A name stored precomposed, as browsers and command-line tools often write it, renamed to
    /// that same name: nothing would change, so nothing is done and nothing is reported as renamed.
    @Test func renameToTheStoredNameChangesNothing() async throws {
        let temp = try TemporaryFolder.make()
        defer { temp.remove() }
        let precomposed = "caf\u{e9}.txt"
        try DiskState.writeExactName("coffee", named: precomposed, in: temp.url)
        try FileDates.settle([temp.url.appending(path: precomposed)])
        let record = try #require(try await RelocationPlans.records(in: temp.url).first)
        // The scan keeps the stored form; a URL built with `appending(path:)` would not.
        #expect(Array(record.url.lastPathComponent.utf8) == Array(precomposed.utf8))
        #expect(Array(temp.url.appending(path: precomposed).lastPathComponent.utf8) != Array(precomposed.utf8))
        let plan = CleanupPlan(
            action: .fixMessyNames,
            folderURL: temp.url,
            changes: [ProposedChange(record: record, operation: .rename(to: record.url.lastPathComponent), reason: .messyName(MessyNameFix(fixes: [])))]
        )
        let before = DiskState.snapshot(of: temp.url)

        let result = await executeAll(plan)

        #expect(result.items.first?.outcome == .skipped(.notInPlan))
        #expect(result.renamed.isEmpty)
        #expect(DiskState.snapshot(of: temp.url) == before)
    }

    /// The volume compares names without regard to Unicode normalisation, so a name taken in the
    /// other form is taken.
    @Test func nameTakenInAnotherNormalisationIsTaken() async throws {
        let temp = try TemporaryFolder.make()
        defer { temp.remove() }
        let precomposed = "na\u{ef}ve.txt"
        let decomposed = "nai\u{308}ve.txt"
        try DiskState.writeExactName("theirs", named: precomposed, in: temp.url)
        try FileDates.writeSettled(["x.txt": "mine"], in: temp.url)
        #expect(DiskState.entryNames(in: temp.url).map { Array($0.utf8) }.contains(Array(precomposed.utf8)))
        let plan = try await RelocationPlans.rename([("x.txt", decomposed)], in: temp.url)

        let result = await executeAll(plan)

        #expect(try outcome(for: "x.txt", in: result) == .skipped(.destinationExists(name: decomposed)))
        #expect(DiskState.text(of: temp.url.appending(path: precomposed)) == "theirs")
        #expect(DiskState.text(of: temp.url.appending(path: "x.txt")) == "mine")
        #expect(DiskState.entryNames(in: temp.url).count == 2)
    }

    /// The limit is 255 UTF-16 code units, as APFS counts: 255 "é" (510 bytes) fit, 128 emoji
    /// (256 code units) do not.
    @Test func newNameMustFitTheVolumesLimit() async throws {
        let temp = try TemporaryFolder.make()
        defer { temp.remove() }
        try FileDates.writeSettled(["a.txt": "a", "b.txt": "b", "c.txt": "c", "d.txt": "d", "e.txt": "e"], in: temp.url)
        let longest = String(repeating: "a", count: 251) + ".txt"
        let tooLong = String(repeating: "b", count: 252) + ".txt"
        let accented = String(repeating: "é", count: 251) + ".txt"
        let emoji = String(repeating: "😀", count: 127)
        let tooManyEmoji = String(repeating: "😀", count: 128)
        #expect(longest.utf16.count == 255 && tooLong.utf16.count == 256 && accented.utf8.count == 506)
        let plan = try await RelocationPlans.rename(
            [("a.txt", longest), ("b.txt", tooLong), ("c.txt", accented), ("d.txt", emoji), ("e.txt", tooManyEmoji)],
            in: temp.url
        )

        let result = await executeAll(plan)

        #expect(try outcome(for: "a.txt", in: result) == .renamed(from: temp.url.appending(path: "a.txt"), to: temp.url.appending(path: longest)))
        #expect(try outcome(for: "b.txt", in: result) == .skipped(.invalidName))
        #expect(try outcome(for: "c.txt", in: result) == .renamed(from: temp.url.appending(path: "c.txt"), to: temp.url.appending(path: accented)))
        #expect(try outcome(for: "d.txt", in: result) == .renamed(from: temp.url.appending(path: "d.txt"), to: temp.url.appending(path: emoji)))
        #expect(try outcome(for: "e.txt", in: result) == .skipped(.invalidName))
        #expect(DiskState.text(of: temp.url.appending(path: "b.txt")) == "b")
        #expect(DiskState.text(of: temp.url.appending(path: "e.txt")) == "e")
    }

    @Test func invalidNewNamesAreRefusedAndChangeNothing() async throws {
        let temp = try TemporaryFolder.make()
        defer { temp.remove() }
        let badNames = ["", ".", "..", "a/b.txt", "a\u{0}b.txt", ".hidden.txt", "Old downloads", "OLD DOWNLOADS", "x.crdownload", "y.PART"]
        let sources = badNames.indices.map { "file \($0).txt" }
        try FileDates.writeSettled(Dictionary(uniqueKeysWithValues: sources.map { ($0, $0) }), in: temp.url)
        let plan = try await RelocationPlans.rename(Array(zip(sources, badNames)), in: temp.url)
        let before = DiskState.snapshot(of: temp.url)

        let result = await executeAll(plan)

        #expect(result.items.count == badNames.count)
        for (source, badName) in zip(sources, badNames) {
            #expect(try outcome(for: source, in: result) == .skipped(.invalidName), "\(badName.debugDescription)")
        }
        #expect(DiskState.snapshot(of: temp.url) == before)
        #expect(!DiskState.exists(temp.url.appending(path: "a")))
    }

    @Test func renameToTheSameNameChangesNothing() async throws {
        let temp = try TemporaryFolder.make()
        defer { temp.remove() }
        try FileDates.writeSettled(["a.txt": "alpha"], in: temp.url)
        let plan = try await RelocationPlans.rename([("a.txt", "a.txt")], in: temp.url)

        let result = await executeAll(plan)

        #expect(try outcome(for: "a.txt", in: result) == .skipped(.notInPlan))
        #expect(DiskState.entryNames(in: temp.url) == ["a.txt"])
    }

    // MARK: - The source

    @Test func sourceChangedSinceTheScanIsSkipped() async throws {
        let temp = try TemporaryFolder.make()
        defer { temp.remove() }
        try FileDates.writeSettled(["a.txt": "alpha"], in: temp.url)
        let plan = try await RelocationPlans.rename([("a.txt", "b.txt")], in: temp.url)
        let handle = try FileHandle(forWritingTo: temp.url.appending(path: "a.txt"))
        try handle.seekToEnd()
        try handle.write(contentsOf: Data(" and more".utf8))
        try handle.close()

        let result = await executeAll(plan)

        #expect(try outcome(for: "a.txt", in: result) == .skipped(.changedSinceScan))
        #expect(DiskState.entryNames(in: temp.url) == ["a.txt"])
    }

    @Test func sourceGoneIsSkipped() async throws {
        let temp = try TemporaryFolder.make()
        defer { temp.remove() }
        try FileDates.writeSettled(["a.txt": "alpha"], in: temp.url)
        let plan = try await RelocationPlans.rename([("a.txt", "b.txt")], in: temp.url)
        try FileManager.default.removeItem(at: temp.url.appending(path: "a.txt"))

        let result = await executeAll(plan)

        #expect(try outcome(for: "a.txt", in: result) == .skipped(.notFound))
        #expect(DiskState.entryNames(in: temp.url).isEmpty)
    }

    /// A link is never renamed, and its target is never touched.
    @Test func symbolicLinkSourceIsRefused() async throws {
        let temp = try TemporaryFolder.make()
        defer { temp.remove() }
        try FileDates.writeSettled(["target.txt": "target"], in: temp.url)
        let link = temp.url.appending(path: "link.txt")
        try FileManager.default.createSymbolicLink(atPath: link.path(percentEncoded: false), withDestinationPath: "target.txt")
        try FileDates.settle([link])
        let plan = try await RelocationPlans.rename([("link.txt", "renamed.txt")], in: temp.url)

        let result = await executeAll(plan)

        #expect(try outcome(for: "link.txt", in: result) == .skipped(.notARegularFile))
        #expect(DiskState.isSymbolicLink(link))
        #expect(DiskState.entryNames(in: temp.url) == ["link.txt", "target.txt"])
    }

    /// A plan may name a file in a subfolder; only items directly inside the folder are renamed.
    @Test func sourceInsideASubfolderIsRefused() async throws {
        let temp = try TemporaryFolder.make()
        defer { temp.remove() }
        let subfolder = temp.url.appending(path: "Sub", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: subfolder, withIntermediateDirectories: false)
        try FileDates.writeSettled(["inner.txt": "inner"], in: subfolder)
        let template = try RelocationPlans.record(named: "inner.txt", in: try await RelocationPlans.records(in: subfolder))
        let plan = CleanupPlan(
            action: .fixMessyNames,
            folderURL: temp.url,
            changes: [ProposedChange(record: template, operation: .rename(to: "outer.txt"), reason: .messyName(MessyNameFix(fixes: [])))]
        )

        let result = await executeAll(plan)

        #expect(try outcome(for: "inner.txt", in: result) == .skipped(.outsideFolder))
        #expect(DiskState.entryNames(in: subfolder) == ["inner.txt"])
        #expect(DiskState.entryNames(in: temp.url) == ["Sub"])
    }

    /// A file written moments ago may still be being written: it is left alone until the grace
    /// period has passed, even when a plan lists it.
    @Test func fileInsideTheGracePeriodIsSkipped() async throws {
        let temp = try TemporaryFolder.make()
        defer { temp.remove() }
        try Data("fresh".utf8).write(to: temp.url.appending(path: "fresh.txt"))
        let plan = try await RelocationPlans.rename([("fresh.txt", "renamed.txt")], in: temp.url)

        let result = await executeAll(plan)

        #expect(try outcome(for: "fresh.txt", in: result) == .skipped(.changedSinceScan))
        #expect(DiskState.entryNames(in: temp.url) == ["fresh.txt"])

        // Control: with no grace period the same plan renames it, so the check above is what kept it.
        let noGrace = CleanupExecutor(eligibility: CandidateEligibility(gracePeriod: 0))
        let control = await noGrace.execute(plan: plan, confirmedChangeIDs: Set(plan.changes.map(\.id)))
        #expect(control.renamed.count == 1)
    }

    @Test func lockedFileFailsAloneAndTheRestComplete() async throws {
        let temp = try TemporaryFolder.make()
        defer { temp.remove() }
        try FileDates.writeSettled(["a.txt": "a", "b.txt": "b", "c.txt": "c"], in: temp.url)
        let lockedPath = temp.url.appending(path: "b.txt").path(percentEncoded: false)
        let plan = try await RelocationPlans.rename([("a.txt", "a2.txt"), ("b.txt", "b2.txt"), ("c.txt", "c2.txt")], in: temp.url)
        try FileManager.default.setAttributes([.immutable: true], ofItemAtPath: lockedPath)
        defer { try? FileManager.default.setAttributes([.immutable: false], ofItemAtPath: lockedPath) }

        let result = await executeAll(plan)

        #expect(try outcome(for: "b.txt", in: result) == .failed(.fileIsLocked))
        #expect(result.renamed.map(\.change.record.displayName) == ["a.txt", "c.txt"])
        #expect(result.failed.count == 1)
        #expect(DiskState.entryNames(in: temp.url) == ["a2.txt", "b.txt", "c2.txt"])
    }

    @Test func removedFolderSkipsEverything() async throws {
        let temp = try TemporaryFolder.make()
        defer { temp.remove() }
        let folder = temp.url.appending(path: "Gone", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: false)
        try FileDates.writeSettled(["a.txt": "alpha"], in: folder)
        let plan = try await RelocationPlans.rename([("a.txt", "b.txt")], in: folder)
        try FileManager.default.removeItem(at: folder)

        let result = await executeAll(plan)

        #expect(try outcome(for: "a.txt", in: result) == .skipped(.folderUnavailable))
    }

    // MARK: - Races, cancellation and the action's rules

    /// Another app puts a file under the new name after the last check, a moment before the
    /// rename: the rename fails rather than replacing it.
    @Test func nameTakenRightBeforeTheRenameIsNotReplaced() async throws {
        let temp = try TemporaryFolder.make()
        defer { temp.remove() }
        try FileDates.writeSettled(["a.txt": "mine"], in: temp.url)
        let plan = try await RelocationPlans.rename([("a.txt", "b.txt")], in: temp.url)
        let intruder = temp.url.appending(path: "b.txt")
        let calls = ConcurrentLog<String>()

        let result = await executor.execute(
            plan: plan,
            confirmedChangeIDs: Set(plan.changes.map(\.id)),
            beforeChange: { change in
                calls.append(change.record.displayName)
                do {
                    try Data("theirs".utf8).write(to: intruder, options: .withoutOverwriting)
                } catch {
                    calls.append("write failed: \(error)")
                }
            }
        )

        #expect(calls.values == ["a.txt"])
        #expect(try outcome(for: "a.txt", in: result) == .skipped(.destinationExists(name: "b.txt")))
        #expect(DiskState.text(of: intruder) == "theirs")
        #expect(DiskState.text(of: temp.url.appending(path: "a.txt")) == "mine")
    }

    @Test func cancelAfterTheFirstItemSkipsTheRest() async throws {
        let temp = try TemporaryFolder.make()
        defer { temp.remove() }
        try FileDates.writeSettled(["a.txt": "a", "b.txt": "b", "c.txt": "c"], in: temp.url)
        let plan = try await RelocationPlans.rename([("a.txt", "a2.txt"), ("b.txt", "b2.txt"), ("c.txt", "c2.txt")], in: temp.url)
        // Cancelled from inside the executor's own task, never the test's (see TrashExecutorTests).
        let executor = executor
        let ids = Set(plan.changes.map(\.id))
        let task = Task {
            await executor.execute(plan: plan, confirmedChangeIDs: ids) { progress in
                if progress.itemsCompleted == 1 {
                    withUnsafeCurrentTask { $0?.cancel() }
                }
            }
        }

        let result = await task.value

        #expect(result.wasCancelled)
        #expect(result.renamed.map(\.change.record.displayName) == ["a.txt"])
        #expect(try outcome(for: "b.txt", in: result) == .skipped(.cancelled))
        #expect(try outcome(for: "c.txt", in: result) == .skipped(.cancelled))
        #expect(DiskState.entryNames(in: temp.url) == ["a2.txt", "b.txt", "c.txt"])
    }

    /// A plan may only use its action's operation: Find Duplicates cannot rename, Fix messy names
    /// cannot move, Archive old downloads cannot trash, whatever a plan built elsewhere lists.
    @Test func eachActionMayOnlyUseItsOwnOperation() async throws {
        let temp = try TemporaryFolder.make()
        defer { temp.remove() }
        try FileDates.writeSettled(["a.txt": "a", "b.txt": "b", "c.txt": "c"], in: temp.url)
        let records = try await RelocationPlans.records(in: temp.url)
        let archive = temp.url.appending(path: "Old downloads", directoryHint: .isDirectory)
        let crafted: [(CleanupAction, String, ProposedChange.Operation)] = [
            (.findDuplicates, "a.txt", .rename(to: "a2.txt")),
            (.fixMessyNames, "b.txt", .move(to: archive, name: "b.txt")),
            (.archiveOldDownloads, "c.txt", .moveToTrash),
        ]
        let before = DiskState.snapshot(of: temp.url)

        for (action, name, operation) in crafted {
            let change = ProposedChange(record: try RelocationPlans.record(named: name, in: records), operation: operation, reason: .messyName(MessyNameFix(fixes: [])))
            let plan = CleanupPlan(action: action, folderURL: temp.url, changes: [change])
            let result = await executeAll(plan)
            #expect(try outcome(for: name, in: result) == .skipped(.notInPlan), "\(action)")
        }
        #expect(DiskState.snapshot(of: temp.url) == before)
    }

    @Test func actionsAllowExactlyTheirOwnOperation() {
        let folder = URL(filePath: "/nowhere", directoryHint: .isDirectory)
        let operations: [ProposedChange.Operation] = [.moveToTrash, .rename(to: "x"), .move(to: folder, name: "x")]
        let allowed: [CleanupAction: [Bool]] = [
            .findDuplicates: [true, false, false],
            .clearFailedDownloads: [true, false, false],
            .removeUnpackedZips: [true, false, false],
            .removeUsedInstallers: [true, false, false],
            .fixMessyNames: [false, true, false],
            .reviewNearDuplicates: [true, false, false],
            .archiveOldDownloads: [false, false, true],
        ]
        #expect(Set(allowed.keys) == Set(CleanupAction.allCases))
        for (action, expected) in allowed {
            #expect(operations.map(action.allows) == expected, "\(action)")
        }
    }
}
