import FileStoreCore
import Foundation
import Synchronization
import Testing

/// Remove Unpacked Zips planned on real zips, made in the test with `ditto` and Info-ZIP's `zip`:
/// the shared fixture, a Zip64 archive, damaged and encrypted zips, the system's own entries, and
/// numbered copies. Nothing here changes a file but those the test made itself.
@Suite("Unpacked zips (disk)")
struct UnpackedZipDiskTests {
    private typealias Names = FakeDownloadsFolder.Names

    private func plan(_ folder: URL, keeping keptItems: KeptItems = KeptItems()) async throws -> CleanupPlan {
        try #require(try await UnpackedZips.plan(folder, keeping: keptItems))
    }

    /// Writes `files` (path to text) into `folder`, making folders on the way.
    private func write(_ files: [String: String], in folder: URL) throws {
        for (path, text) in files {
            let url = folder.appending(path: path)
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try Data(text.utf8).write(to: url)
        }
    }

    /// Dates every item in `folder`, at any depth, two hours back, the folder's contents before it.
    private func settleEverything(in folder: URL) throws {
        let paths = FileManager.default.enumerator(atPath: folder.path(percentEncoded: false))?.allObjects as? [String] ?? []
        // Deepest first, so a folder's own date is set after what is inside it.
        let urls = paths.sorted { $0.count(where: { $0 == "/" }) > $1.count(where: { $0 == "/" }) }.map { folder.appending(path: $0) }
        try FileDates.settle(urls)
    }

    // MARK: - The shared fixture

    @Test func onTheFixtureExactlyTheTwoUnpackedZipsAreProposed() async throws {
        try await withFakeDownloadsFolder { fixture in
            let plan = try await plan(fixture.url)

            #expect(UnpackedZips.proposals(plan) == ["\(Names.singleFileZip) → \(Names.singleFileZipContent)", "\(Names.zipArchive) → \(Names.zipFolder)"])
            #expect(plan.skippedItems.isEmpty)
            // Their own sizes, never what they hold.
            for change in plan.changes {
                #expect(change.sizeInBytes == change.record.sizeInBytes, "\(change.record.displayName)")
            }
        }
    }

    @Test func ourListingIsZipinfosForEveryFixtureZip() async throws {
        try await withFakeDownloadsFolder { fixture in
            for name in [Names.zipArchive, Names.singleFileZip, Names.partialZipArchive, Names.lonelyZip, Names.appZip] {
                let url = fixture.url(for: name)
                let ours = try await ZipListing.read(at: url).summaries
                let theirs = try ZipTools.zipinfoListing(of: url)
                #expect(ours == theirs, "\(name)")
            }
        }
    }

    // MARK: - Real archives of every kind

    @Test func aZip64ArchiveIsReadAndProposed() async throws {
        try await withTemporaryFolderAsync { folder in
            let input = folder.appending(path: "-")
            try Data("streamed through standard input".utf8).write(to: input)
            let zip = folder.appending(path: "stream.zip")
            try ZipTools.zipStandardInput(from: input, to: zip)
            try FileDates.settle([input, zip])

            // Info-ZIP wrote a Zip64 end record and locator for the stream.
            let bytes = try Data(contentsOf: zip)
            #expect(bytes.firstRange(of: Data([0x50, 0x4b, 0x06, 0x06])) != nil)
            #expect(bytes.firstRange(of: Data([0x50, 0x4b, 0x06, 0x07])) != nil)
            let ours = try await ZipListing.read(at: zip).summaries
            #expect(ours == (try ZipTools.zipinfoListing(of: zip)))

            #expect(UnpackedZips.proposals(try await plan(folder)) == ["stream.zip → -"])
        }
    }

    @Test func aTruncatedZipIsListedAsNotChecked() async throws {
        try await withTemporaryFolderAsync { folder in
            try UnpackedZips.write(in: folder)
            let zip = folder.appending(path: UnpackedZips.projectZip)
            let handle = try FileHandle(forWritingTo: zip)
            try handle.truncate(atOffset: try handle.seekToEnd() - 10)
            try handle.close()
            try FileDates.settle([zip])

            let plan = try await plan(folder)

            #expect(UnpackedZips.proposals(plan) == ["\(UnpackedZips.contractZip) → \(UnpackedZips.contract)"])
            #expect(plan.skippedItems.map(\.url.lastPathComponent) == [UnpackedZips.projectZip])
            #expect(plan.skippedItems.map(\.reason) == [.zipUnlistable(.damaged)])
        }
    }

    @Test func anEncryptedZipWithAReadableListingIsLikeAnyOther() async throws {
        try await withTemporaryFolderAsync { folder in
            try write(["secret/plan.txt": "the secret plan", "secret/notes.txt": "notes"], in: folder)
            try ZipTools.zip(["secret"], in: folder, to: folder.appending(path: "secret.zip"), password: "pw")
            try ZipTools.zip(["secret/plan.txt"], in: folder, to: folder.appending(path: "alone.zip"), password: "pw")
            try settleEverything(in: folder)
            #expect(try await ZipListing.read(at: folder.appending(path: "secret.zip")).entries.count == 3)

            // `alone.zip` holds `secret/plan.txt`, and is unpacked to `secret` too: the one file is there.
            #expect(UnpackedZips.proposals(try await plan(folder)) == ["alone.zip → secret", "secret.zip → secret"])

            try FileManager.default.removeItem(at: folder.appending(path: "secret"))
            #expect(try await plan(folder).isEmpty)
        }
    }

    @Test func anEncryptedListingIsListedAsNotChecked() async throws {
        try await withTemporaryFolderAsync { folder in
            try write(["hidden.txt": "hidden"], in: folder)
            var bytes = ZipBytes([.file("hidden.txt", "hidden")]).bytes
            if let start = bytes.firstRange(of: [0x50, 0x4b, 0x01, 0x02])?.lowerBound {
                bytes.replaceSubrange(start..<(start + 4), with: [0x50, 0x4b, 0x06, 0x08])
            }
            try Data(bytes).write(to: folder.appending(path: "locked-list.zip"))
            try settleEverything(in: folder)

            let plan = try await plan(folder)

            #expect(plan.isEmpty)
            #expect(plan.skippedItems.map(\.reason) == [.zipUnlistable(.encryptedListing)])
        }
    }

    @Test func finderStyleZipsWithMacOSXEntriesMatchTheirPlainCopy() async throws {
        try await withTemporaryFolderAsync { folder in
            let source = folder.appending(path: "Staging/photos", directoryHint: .isDirectory)
            try write(["Staging/photos/a.jpg": "pixels a", "Staging/photos/b.jpg": "pixels b", "Staging/photos/.DS_Store": "Bud1"], in: folder)
            try ExtendedAttributes.setWhereFroms(["https://example.com/a.jpg"], on: source.appending(path: "a.jpg"))
            try ZipTools.ditto(source, to: folder.appending(path: "photos.zip"), keepParent: true, sequesteringResources: true)
            #expect(try ZipTools.zipinfoListing(of: folder.appending(path: "photos.zip")).contains { $0.path.hasPrefix("__MACOSX/") })
            // The copy, unpacked plainly: no `._` files and no `.DS_Store`.
            try write(["photos/a.jpg": "pixels a", "photos/b.jpg": "pixels b"], in: folder)
            try FileManager.default.removeItem(at: folder.appending(path: "Staging"))
            try settleEverything(in: folder)

            #expect(UnpackedZips.proposals(try await plan(folder)) == ["photos.zip → photos"])
        }
    }

    @Test func aNumberedCopyIsFoundWhenTheNameWasTaken() async throws {
        try await withTemporaryFolderAsync { folder in
            try UnpackedZips.write(in: folder)
            // `project` is now something else, and Archive Utility unpacked to `project 2`.
            let project = folder.appending(path: UnpackedZips.project)
            try FileManager.default.moveItem(at: project, to: folder.appending(path: "project 2"))
            try write(["project/other.txt": "a different project"], in: folder)
            try settleEverything(in: folder)

            #expect(UnpackedZips.proposals(try await plan(folder)) == [
                "\(UnpackedZips.contractZip) → \(UnpackedZips.contract)",
                "\(UnpackedZips.projectZip) → project 2",
            ])
        }
    }

    @Test func aLinkInTheCopyNeverStandsInForAFile() async throws {
        try await withTemporaryFolderAsync { folder in
            try UnpackedZips.write(in: folder)
            // The same bytes elsewhere, linked to from where the file was.
            let readme = folder.appending(path: "\(UnpackedZips.project)/\(UnpackedZips.readme)")
            let elsewhere = folder.appending(path: "elsewhere.md")
            try FileManager.default.moveItem(at: readme, to: elsewhere)
            try FileManager.default.createSymbolicLink(at: readme, withDestinationURL: elsewhere)
            try settleEverything(in: folder)

            #expect(UnpackedZips.proposals(try await plan(folder)) == ["\(UnpackedZips.contractZip) → \(UnpackedZips.contract)"])
        }
    }

    @Test func aCopyUnpackedInTheLastHourWaits() async throws {
        try await withTemporaryFolderAsync { folder in
            try UnpackedZips.write(in: folder)
            try FileDates.set(folder.appending(path: UnpackedZips.contract), to: Date(timeIntervalSinceNow: -5 * 60))

            #expect(UnpackedZips.proposals(try await plan(folder)) == ["\(UnpackedZips.projectZip) → \(UnpackedZips.project)"])
        }
    }

    @Test func aCopyUnpackedAgainSinceTheListWasLoadedWaits() async throws {
        try await withTemporaryFolderAsync { folder in
            try UnpackedZips.write(in: folder)
            let records = try await RelocationPlans.records(in: folder)
            // Unpacked again after the scan: the same files, but the folder arrived just now.
            let project = folder.appending(path: UnpackedZips.project)
            let again = folder.appending(path: "again")
            try FileManager.default.copyItem(at: project, to: again)
            try FileManager.default.removeItem(at: project)
            try FileManager.default.moveItem(at: again, to: project)

            let plan = try #require(
                try await CleanupPlanners.plan(.removeUnpackedZips, records: records, in: .temporary(folder), eligibility: CandidateEligibility(), keptItems: KeptItems(), installers: .testing())
            )

            #expect(UnpackedZips.proposals(plan) == ["\(UnpackedZips.contractZip) → \(UnpackedZips.contract)"])
        }
    }

    @Test func aKeptCopyStillCounts() async throws {
        try await withTemporaryFolderAsync { folder in
            try UnpackedZips.write(in: folder)
            let records = try await RelocationPlans.records(in: folder)
            let log = try await ActivityLog.open(.inMemory)
            try await log.keep(records.filter { [UnpackedZips.project, UnpackedZips.contract].contains($0.displayName) })

            let plan = try await plan(folder, keeping: try await log.keptItems(for: log.downloads(at: folder)))

            #expect(UnpackedZips.proposals(plan) == ["\(UnpackedZips.contractZip) → \(UnpackedZips.contract)", "\(UnpackedZips.projectZip) → \(UnpackedZips.project)"])
        }
    }

    @Test func aZipImplyingMoreFoldersThanTheRuleReadsIsNotChecked() async throws {
        try await withTemporaryFolderAsync { folder in
            // Within the listing's limits, but 400 names each 512 folders deep.
            let deep = String(repeating: "a/", count: 509)
            let entries = (0..<400).map { ZipBytes.Entry.file(String(format: "d%03d/", $0) + deep + "f", "x") }
            try Data(ZipBytes(entries).bytes).write(to: folder.appending(path: "deep.zip"))
            try FileDates.settle([folder.appending(path: "deep.zip")])

            let plan = try await plan(folder)

            #expect(plan.isEmpty)
            #expect(plan.skippedItems.map(\.reason) == [.zipUnlistable(.tooManyEntries)])
        }
    }

    // MARK: - Kept zips are never named

    @Test func aKeptZipIsNeverNamedEvenWhenItCannotBeRead() async throws {
        try await withTemporaryFolderAsync { folder in
            try UnpackedZips.write(in: folder)
            // One damaged, one unreadable, both Kept.
            let damaged = folder.appending(path: "damaged.zip")
            try Data("not a zip".utf8).write(to: damaged)
            let unreadable = folder.appending(path: "unreadable.zip")
            try Data("not readable by anyone".utf8).write(to: unreadable)
            try FileDates.settle([damaged, unreadable])
            try FileManager.default.setAttributes([.posixPermissions: 0o000], ofItemAtPath: unreadable.path(percentEncoded: false))
            defer { try? FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: unreadable.path(percentEncoded: false)) }

            let unkept = try await plan(folder)
            #expect(Set(unkept.skippedItems.map(\.url.lastPathComponent)) == ["damaged.zip", "unreadable.zip"])
            #expect(Set(unkept.skippedItems.map(\.reason)) == [.zipUnlistable(.damaged), .accessDenied])

            let records = try await RelocationPlans.records(in: folder)
            let log = try await ActivityLog.open(.inMemory)
            try await log.keep(records.filter { ["damaged.zip", "unreadable.zip"].contains($0.displayName) })
            let kept = try await plan(folder, keeping: try await log.keptItems(for: log.downloads(at: folder)))

            #expect(kept.skippedItems.isEmpty)
            #expect(UnpackedZips.proposals(kept) == UnpackedZips.proposals(unkept))
        }
    }

    // MARK: - Progress and cancellation

    @Test func progressCountsTheZipsFromFirstToLast() async throws {
        try await withTemporaryFolderAsync { folder in
            try UnpackedZips.write(in: folder)
            let reports = Mutex<[CleanupPlanningProgress]>([])

            _ = try await UnpackedZips.plan(folder) { progress in
                reports.withLock { $0.append(progress) }
            }

            let seen = reports.withLock { $0 }
            #expect(seen.first == CleanupPlanningProgress(itemsChecked: 0, itemsToCheck: 2))
            #expect(seen.last == CleanupPlanningProgress(itemsChecked: 2, itemsToCheck: 2))
            #expect(seen.map(\.itemsChecked) == seen.map(\.itemsChecked).sorted())
            #expect(seen.last?.fractionCompleted == 1)
        }
    }

    @Test func aCancelledPlanThrows() async throws {
        try await withTemporaryFolderAsync { folder in
            try UnpackedZips.write(in: folder)
            let records = try await RelocationPlans.records(in: folder)
            // A task of its own, cancelled before it plans: never this test's own task.
            let planning = Task { () -> CleanupPlanningError? in
                while !Task.isCancelled {
                    await Task.yield()
                }
                do throws(CleanupPlanningError) {
                    _ = try await UnpackedZipPlanner().plan(records: records, in: .temporary(folder))
                    return nil
                } catch {
                    return error
                }
            }
            planning.cancel()

            #expect(await planning.value == .cancelled)
        }
    }
}
