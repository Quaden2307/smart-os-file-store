import FileStoreCore
import Foundation
import Testing

/// The executor's moves, on small temporary folders of the test's own. A move puts a file in a
/// folder inside the scanned folder, makes that folder when it is missing, reaches it without
/// passing a symbolic link, and never replaces what is there.
@Suite("Move")
struct MoveExecutorTests {
    private let executor = CleanupExecutor()

    private func executeAll(_ plan: CleanupPlan) async -> CleanupResult {
        await executor.execute(plan: plan, confirmedChangeIDs: Set(plan.changes.map(\.id)))
    }

    private func outcome(for name: String, in result: CleanupResult) throws -> CleanupItemOutcome {
        try RelocationPlans.outcome(for: name, in: result)
    }

    private func folder(_ name: String, in parent: URL) -> URL {
        parent.appending(path: name, directoryHint: .isDirectory)
    }

    private func makeFolder(_ url: URL) throws {
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    }

    // MARK: - Moving

    /// The archive folder is missing, so the move makes it, reports it, and files the item there.
    @Test func movesIntoANewFolder() async throws {
        let temp = try TemporaryFolder.make()
        defer { temp.remove() }
        try FileDates.writeSettled(["old.pdf": "old"], in: temp.url)
        let archive = folder("Old downloads", in: temp.url)
        let inode = try #require(DiskState.inode(of: temp.url.appending(path: "old.pdf")))
        let plan = try await RelocationPlans.move([("old.pdf", archive, "old.pdf")], in: temp.url)
        #expect(plan.changes.first?.destinationPath == archive.appending(path: "old.pdf").path(percentEncoded: false))

        let result = await executeAll(plan)

        let item = try RelocationPlans.item(for: "old.pdf", in: result)
        guard case .moved(let from, let to) = item.outcome else {
            Issue.record("expected a move, got \(item.outcome)")
            return
        }
        #expect(DiskState.samePlace(from, temp.url.appending(path: "old.pdf")))
        #expect(DiskState.samePlace(to, archive.appending(path: "old.pdf")))
        #expect(item.createdFolders.count == 1)
        #expect(item.createdFolders.allSatisfy { DiskState.samePlace($0, archive) })
        #expect(result.moved.count == 1)
        #expect(DiskState.isFolder(archive))
        #expect(DiskState.entryNames(in: temp.url) == ["Old downloads"])
        #expect(DiskState.text(of: archive.appending(path: "old.pdf")) == "old")
        #expect(DiskState.inode(of: archive.appending(path: "old.pdf")) == inode)

        // The same plan again finds nothing to move.
        let again = await executeAll(plan)
        #expect(try outcome(for: "old.pdf", in: again) == .skipped(.notFound))
        #expect(again.items.first?.createdFolders == [])
    }

    @Test func movesIntoAnExistingFolderAndIntoNestedNewFolders() async throws {
        let temp = try TemporaryFolder.make()
        defer { temp.remove() }
        try FileDates.writeSettled(["a.txt": "a", "b.txt": "b"], in: temp.url)
        let existing = folder("Archive", in: temp.url)
        try makeFolder(existing)
        let outer = folder("Old downloads", in: temp.url)
        let middle = folder("2024", in: outer)
        let inner = folder("Q1", in: middle)
        let plan = try await RelocationPlans.move([("a.txt", existing, "a.txt"), ("b.txt", inner, "b renamed.txt")], in: temp.url)

        let result = await executeAll(plan)

        #expect(result.moved.count == 2, "\(result.items.map(\.outcome))")
        #expect(try RelocationPlans.item(for: "a.txt", in: result).createdFolders == [])
        let created = try RelocationPlans.item(for: "b.txt", in: result).createdFolders
        #expect(created.map(\.pathComponents) == [outer, middle, inner].map(\.pathComponents))
        #expect(DiskState.text(of: existing.appending(path: "a.txt")) == "a")
        #expect(DiskState.text(of: inner.appending(path: "b renamed.txt")) == "b")
        #expect(DiskState.entryNames(in: temp.url) == ["Archive", "Old downloads"])
    }

    @Test func neverReplacesAFileInTheDestination() async throws {
        let temp = try TemporaryFolder.make()
        defer { temp.remove() }
        try FileDates.writeSettled(["a.txt": "mine", "b.txt": "mine too"], in: temp.url)
        let archive = folder("Archive", in: temp.url)
        try makeFolder(archive)
        try Data("theirs".utf8).write(to: archive.appending(path: "a.txt"))
        try Data("theirs too".utf8).write(to: archive.appending(path: "B.TXT"))
        let caseSensitive = pathconf(archive.path(percentEncoded: false), _PC_CASE_SENSITIVE) == 1
        let plan = try await RelocationPlans.move([("a.txt", archive, "a.txt"), ("b.txt", archive, "b.txt")], in: temp.url)

        let result = await executeAll(plan)

        #expect(try outcome(for: "a.txt", in: result) == .skipped(.destinationExists(name: "a.txt")))
        #expect(DiskState.text(of: archive.appending(path: "a.txt")) == "theirs")
        #expect(DiskState.text(of: temp.url.appending(path: "a.txt")) == "mine")
        // "B.TXT" is the same name as "b.txt" on a case-insensitive volume, the usual kind.
        #expect(DiskState.text(of: archive.appending(path: "B.TXT")) == "theirs too")
        if caseSensitive {
            #expect(result.moved.map(\.change.record.displayName) == ["b.txt"])
        } else {
            #expect(try outcome(for: "b.txt", in: result) == .skipped(.destinationExists(name: "b.txt")))
            #expect(DiskState.text(of: temp.url.appending(path: "b.txt")) == "mine too")
        }
    }

    // MARK: - Destinations that are refused

    @Test func destinationsOutsideTheFolderAreRefused() async throws {
        let temp = try TemporaryFolder.make()
        defer { temp.remove() }
        let scanned = folder("Downloads", in: temp.url)
        let elsewhere = folder("Elsewhere", in: temp.url)
        try makeFolder(scanned)
        try makeFolder(elsewhere)
        try FileDates.writeSettled(["a.txt": "a", "b.txt": "b", "c.txt": "c", "d.txt": "d"], in: scanned)
        // Beside the folder, through "..", the folder itself, and the folder that holds it.
        let plan = try await RelocationPlans.move(
            [
                ("a.txt", elsewhere, "a.txt"),
                ("b.txt", scanned.appending(path: "../Elsewhere", directoryHint: .isDirectory), "b.txt"),
                ("c.txt", scanned, "c moved.txt"),
                ("d.txt", temp.url, "d.txt"),
            ],
            in: scanned
        )
        let before = DiskState.snapshot(of: scanned)

        let result = await executeAll(plan)

        for name in ["a.txt", "b.txt", "c.txt", "d.txt"] {
            #expect(try outcome(for: name, in: result) == .skipped(.destinationOutsideFolder), "\(name)")
        }
        #expect(DiskState.snapshot(of: scanned) == before)
        #expect(DiskState.entryNames(in: elsewhere).isEmpty)
        #expect(DiskState.entryNames(in: temp.url) == ["Downloads", "Elsewhere"])
    }

    /// A folder on the way that is a symbolic link is refused, wherever it points: the move never
    /// follows a link, so it can never be sent out of the folder through one.
    @Test func symbolicLinkOnTheWayIsRefused() async throws {
        let temp = try TemporaryFolder.make()
        defer { temp.remove() }
        let scanned = folder("Downloads", in: temp.url)
        let elsewhere = folder("Elsewhere", in: temp.url)
        try makeFolder(scanned)
        try makeFolder(elsewhere)
        try FileDates.writeSettled(["a.txt": "a", "b.txt": "b", "c.txt": "c"], in: scanned)
        let fileManager = FileManager.default
        // Out of the folder, inside it, and one level down.
        let outward = scanned.appending(path: "Archive")
        try fileManager.createSymbolicLink(at: outward, withDestinationURL: elsewhere)
        let real = folder("Real", in: scanned)
        try makeFolder(real)
        let inward = scanned.appending(path: "Alias")
        try fileManager.createSymbolicLink(atPath: inward.path(percentEncoded: false), withDestinationPath: "Real")
        let nested = folder("Nested", in: scanned)
        try makeFolder(nested)
        try fileManager.createSymbolicLink(at: nested.appending(path: "Sub"), withDestinationURL: elsewhere)
        let plan = try await RelocationPlans.move(
            [
                ("a.txt", folder("Archive", in: scanned), "a.txt"),
                ("b.txt", folder("Alias", in: scanned), "b.txt"),
                ("c.txt", folder("Sub", in: nested), "c.txt"),
            ],
            in: scanned
        )

        let result = await executeAll(plan)

        for name in ["a.txt", "b.txt", "c.txt"] {
            #expect(try outcome(for: name, in: result) == .skipped(.destinationOutsideFolder), "\(name)")
            #expect(DiskState.text(of: scanned.appending(path: name)) == name.replacingOccurrences(of: ".txt", with: ""))
        }
        #expect(result.items.allSatisfy { $0.createdFolders.isEmpty })
        #expect(DiskState.entryNames(in: elsewhere).isEmpty)
        #expect(DiskState.entryNames(in: real).isEmpty)
        #expect(DiskState.isSymbolicLink(outward) && DiskState.isSymbolicLink(inward))
    }

    @Test func destinationThatIsNotAFolderIsRefused() async throws {
        let temp = try TemporaryFolder.make()
        defer { temp.remove() }
        try FileDates.writeSettled(["a.txt": "a", "b.txt": "b", "c.txt": "c", "d.txt": "d", "Archive": "a file"], in: temp.url)
        let plan = try await RelocationPlans.move(
            [
                ("a.txt", folder("Archive", in: temp.url), "a.txt"),
                ("b.txt", folder("Tools.app", in: temp.url), "b.txt"),
                ("c.txt", folder(".stash", in: temp.url), "c.txt"),
                ("d.txt", folder("Old downloads", in: temp.url), ".d.txt"),
            ],
            in: temp.url
        )
        let before = DiskState.snapshot(of: temp.url)

        let result = await executeAll(plan)

        #expect(try outcome(for: "a.txt", in: result) == .skipped(.destinationNotAFolder))
        #expect(try outcome(for: "b.txt", in: result) == .skipped(.destinationNotAFolder))
        #expect(try outcome(for: "c.txt", in: result) == .skipped(.invalidName))
        #expect(try outcome(for: "d.txt", in: result) == .skipped(.invalidName))
        #expect(DiskState.snapshot(of: temp.url) == before)
    }

    /// A folder hidden by flag would hide the file too, like a folder name starting with a dot.
    @Test func hiddenDestinationFolderIsRefused() async throws {
        let temp = try TemporaryFolder.make()
        defer { temp.remove() }
        try FileDates.writeSettled(["a.txt": "a"], in: temp.url)
        var archive = folder("Old downloads", in: temp.url)
        try makeFolder(archive)
        var values = URLResourceValues()
        values.isHidden = true
        try archive.setResourceValues(values)
        let plan = try await RelocationPlans.move([("a.txt", archive, "a.txt")], in: temp.url)

        let result = await executeAll(plan)

        #expect(try outcome(for: "a.txt", in: result) == .skipped(.destinationHidden))
        #expect(DiskState.entryNames(in: archive).isEmpty)
        #expect(DiskState.text(of: temp.url.appending(path: "a.txt")) == "a")
    }

    // MARK: - Races and failures

    /// Another app makes the folder and puts a file under the name in it after the last check, a
    /// moment before the move: the move fails rather than replacing it, and the folder, made by
    /// the other app, is not reported as made by the move.
    @Test func nameTakenRightBeforeTheMoveIsNotReplaced() async throws {
        let temp = try TemporaryFolder.make()
        defer { temp.remove() }
        try FileDates.writeSettled(["a.txt": "mine"], in: temp.url)
        let archive = folder("Archive", in: temp.url)
        let intruder = archive.appending(path: "a.txt")
        let plan = try await RelocationPlans.move([("a.txt", archive, "a.txt")], in: temp.url)
        let failures = ConcurrentLog<String>()

        let result = await executor.execute(
            plan: plan,
            confirmedChangeIDs: Set(plan.changes.map(\.id)),
            beforeChange: { _ in
                do {
                    try FileManager.default.createDirectory(at: archive, withIntermediateDirectories: false)
                    try Data("theirs".utf8).write(to: intruder, options: .withoutOverwriting)
                } catch {
                    failures.append(String(describing: error))
                }
            }
        )

        #expect(failures.values.isEmpty)
        let item = try RelocationPlans.item(for: "a.txt", in: result)
        #expect(item.outcome == .skipped(.destinationExists(name: "a.txt")))
        #expect(item.createdFolders == [])
        #expect(DiskState.text(of: intruder) == "theirs")
        #expect(DiskState.text(of: temp.url.appending(path: "a.txt")) == "mine")
    }

    /// The file changes while its folder is being made: the move is skipped, and the folder it made
    /// is still reported, since that is a change on disk too.
    @Test func folderMadeForASkippedMoveIsReported() async throws {
        let temp = try TemporaryFolder.make()
        defer { temp.remove() }
        try FileDates.writeSettled(["a.txt": "mine"], in: temp.url)
        let source = temp.url.appending(path: "a.txt")
        let archive = folder("Archive", in: temp.url)
        let plan = try await RelocationPlans.move([("a.txt", archive, "a.txt")], in: temp.url)
        let failures = ConcurrentLog<String>()

        let result = await executor.execute(
            plan: plan,
            confirmedChangeIDs: Set(plan.changes.map(\.id)),
            beforeChange: { _ in
                do {
                    let handle = try FileHandle(forWritingTo: source)
                    try handle.seekToEnd()
                    try handle.write(contentsOf: Data(" and more".utf8))
                    try handle.close()
                } catch {
                    failures.append(String(describing: error))
                }
            }
        )

        #expect(failures.values.isEmpty)
        let item = try RelocationPlans.item(for: "a.txt", in: result)
        #expect(item.outcome == .skipped(.changedSinceScan))
        #expect(item.createdFolders.map(\.pathComponents) == [archive.pathComponents])
        #expect(DiskState.isFolder(archive))
        #expect(DiskState.entryNames(in: archive).isEmpty)
        #expect(DiskState.text(of: source) == "mine and more")
    }

    @Test func lockedFileFailsAloneAndTheRestComplete() async throws {
        let temp = try TemporaryFolder.make()
        defer { temp.remove() }
        try FileDates.writeSettled(["a.txt": "a", "b.txt": "b", "c.txt": "c"], in: temp.url)
        let archive = folder("Old downloads", in: temp.url)
        let lockedPath = temp.url.appending(path: "b.txt").path(percentEncoded: false)
        let plan = try await RelocationPlans.move([("a.txt", archive, "a.txt"), ("b.txt", archive, "b.txt"), ("c.txt", archive, "c.txt")], in: temp.url)
        try FileManager.default.setAttributes([.immutable: true], ofItemAtPath: lockedPath)
        defer { try? FileManager.default.setAttributes([.immutable: false], ofItemAtPath: lockedPath) }

        let result = await executeAll(plan)

        #expect(try outcome(for: "b.txt", in: result) == .failed(.fileIsLocked))
        #expect(result.moved.map(\.change.record.displayName) == ["a.txt", "c.txt"])
        #expect(DiskState.entryNames(in: archive) == ["a.txt", "c.txt"])
        #expect(DiskState.entryNames(in: temp.url) == ["Old downloads", "b.txt"])
    }
}
