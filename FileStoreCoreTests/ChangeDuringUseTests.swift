import FileStoreCore
import Foundation
import Synchronization
import Testing

/// Files added, removed, renamed or rewritten while a scan, a hash or a cleanup is running. The
/// engine must neither crash nor act on stale information: a file that is gone is reported as
/// not found, a file that changed as changed, and nothing new is ever touched.
@Suite("Change during use")
struct ChangeDuringUseTests {
    private let scanner = FolderScanner()
    private let planner = DuplicatePlanner()
    private let executor = TrashExecutor()

    private static let kibibyte = 1024

    // MARK: - Helpers

    private func scan(_ folder: URL) async throws -> [FileRecord] {
        try await scanner.scan(ScanLocation(folderURL: folder, source: .launchArgument)).records
    }

    private func exists(_ url: URL) -> Bool {
        (try? FileManager.default.attributesOfItem(atPath: url.path(percentEncoded: false))) != nil
    }

    private func outcome(for name: String, in result: CleanupResult) throws -> CleanupItemOutcome {
        try #require(result.items.first { $0.change.record.displayName == name }, "no result for \(name)").outcome
    }

    /// Runs `body` the first time it is called and never again, from any thread.
    private final class Once: Sendable {
        private let done = Mutex(false)

        func run(_ body: () -> Void) {
            let first = done.withLock { done -> Bool in
                if done { return false }
                done = true
                return true
            }
            if first {
                body()
            }
        }
    }

    // MARK: - Hasher

    @Test func fileGrowingDuringHashIsChangedSinceScan() async throws {
        let temp = try TemporaryFolder.make()
        defer { temp.remove() }
        let url = temp.url.appending(path: "growing.bin")
        let size = Int64(8 * Self.kibibyte)
        try Data(count: Int(size)).write(to: url)
        let hasher = ContentHasher(chunkSize: Self.kibibyte)
        let once = Once()
        let failures = ConcurrentLog<String>()

        await #expect(throws: ContentHashError.changedSinceScan(url)) {
            try await hasher.hash(contentsOf: url, expectedSizeInBytes: size) { _ in
                once.run {
                    do {
                        let handle = try FileHandle(forWritingTo: url)
                        try handle.seekToEnd()
                        try handle.write(contentsOf: Data(count: Self.kibibyte))
                        try handle.close()
                    } catch {
                        failures.append(String(describing: error))
                    }
                }
            }
        }
        #expect(failures.values.isEmpty)
    }

    @Test func fileShrinkingDuringHashIsChangedSinceScan() async throws {
        let temp = try TemporaryFolder.make()
        defer { temp.remove() }
        let url = temp.url.appending(path: "shrinking.bin")
        let size = Int64(8 * Self.kibibyte)
        try Data(count: Int(size)).write(to: url)
        let hasher = ContentHasher(chunkSize: Self.kibibyte)
        let once = Once()
        let failures = ConcurrentLog<String>()

        await #expect(throws: ContentHashError.changedSinceScan(url)) {
            try await hasher.hash(contentsOf: url, expectedSizeInBytes: size) { _ in
                once.run {
                    do {
                        let handle = try FileHandle(forWritingTo: url)
                        try handle.truncate(atOffset: UInt64(4 * Self.kibibyte))
                        try handle.close()
                    } catch {
                        failures.append(String(describing: error))
                    }
                }
            }
        }
        #expect(failures.values.isEmpty)
    }

    // MARK: - Planner

    /// The first progress report arrives before any file is opened, so a change made from there
    /// is a change between the scan and the hash: the file is reported, never guessed about, and
    /// the final progress still accounts for every byte the scan promised.
    @Test func plannerReportsFileRewrittenBeforeItsHashAndKeepsProgressComplete() async throws {
        let temp = try TemporaryFolder.make()
        defer { temp.remove() }
        try FileDates.writeSettled(["x.bin": "xxxxxxxx", "x (1).bin": "xxxxxxxx", "y.bin": "yy", "y (1).bin": "yy"], in: temp.url)
        let records = try await scan(temp.url)
        let planner = DuplicatePlanner(hasher: ContentHasher(chunkSize: Self.kibibyte))
        let once = Once()
        let failures = ConcurrentLog<String>()
        let last = Mutex<DuplicateScanProgress?>(nil)
        let grown = temp.url.appending(path: "x (1).bin")

        let plan = try await planner.plan(records: records, in: temp.url) { progress in
            last.withLock { $0 = progress }
            once.run {
                do {
                    let handle = try FileHandle(forWritingTo: grown)
                    try handle.seekToEnd()
                    try handle.write(contentsOf: Data("more".utf8))
                    try handle.close()
                } catch {
                    failures.append(String(describing: error))
                }
            }
        }

        #expect(failures.values.isEmpty)
        #expect(plan.skippedItems.map(\.url.lastPathComponent) == ["x (1).bin"])
        #expect(plan.skippedItems.map(\.reason) == [.changedSinceScan])
        #expect(plan.changes.map(\.record.displayName) == ["y (1).bin"])
        let final = try #require(last.withLock { $0 })
        #expect(final.filesHashed == final.filesToHash)
        #expect(final.bytesHashed == final.bytesToHash)
        #expect(final.filesToHash == 4)
    }

    @Test func plannerToleratesFilesRemovedRenamedAndAddedWhileHashing() async throws {
        let temp = try TemporaryFolder.make()
        defer { temp.remove() }
        try FileDates.writeSettled(
            [
                "a.txt": "alpha", "a (1).txt": "alpha", "a (2).txt": "alpha",
                "b.txt": "bravo", "b (1).txt": "bravo",
                "c.txt": "charlie", "c (1).txt": "charlie",
            ],
            in: temp.url
        )
        let records = try await scan(temp.url)
        #expect(records.count == 7)
        let once = Once()
        let failures = ConcurrentLog<String>()
        let folder = temp.url

        let plan = try await planner.plan(records: records, in: folder) { _ in
            once.run {
                do {
                    let fileManager = FileManager.default
                    try fileManager.removeItem(at: folder.appending(path: "a (2).txt"))
                    try fileManager.moveItem(at: folder.appending(path: "b (1).txt"), to: folder.appending(path: "b-renamed.txt"))
                    try Data("alpha".utf8).write(to: folder.appending(path: "a (3).txt"))
                    try Data("delta".utf8).write(to: folder.appending(path: "d.txt"))
                } catch {
                    failures.append(String(describing: error))
                }
            }
        }

        #expect(failures.values.isEmpty)
        // The removed and the renamed file are reported; the renamed file's new name and the two
        // added files were never scanned, so they are nowhere in the plan.
        #expect(Set(plan.skippedItems.map(\.url.lastPathComponent)) == ["a (2).txt", "b (1).txt"])
        #expect(plan.skippedItems.allSatisfy { $0.reason == .notFound })
        #expect(Set(plan.changes.map(\.record.displayName)) == ["a (1).txt", "c (1).txt"])
        let mentioned = Set(plan.duplicateGroups.flatMap { [$0.kept.displayName] + $0.duplicates.map(\.displayName) })
        #expect(mentioned == ["a.txt", "a (1).txt", "c.txt", "c (1).txt"])
        #expect(exists(folder.appending(path: "b-renamed.txt")))
        #expect(exists(folder.appending(path: "a (3).txt")))
    }

    // MARK: - Scanner

    /// A scan that runs while the folder changes underneath it returns only names that existed at
    /// some point, never crashes, and a scan after the changes stop shows exactly the final state.
    /// (A directory listing taken during renames may legitimately show an entry twice or not at
    /// all, so counts are bounded rather than exact while the changes run.)
    @Test func scanToleratesConcurrentAddsRemovesAndRenames() async throws {
        let temp = try TemporaryFolder.make()
        defer { temp.remove() }
        let folder = temp.url
        let initialCount = 2_000
        var names: Set<String> = []
        for index in 0..<initialCount {
            let name = String(format: "f-%04d.txt", index)
            try Data("\(index)".utf8).write(to: folder.appending(path: name))
            names.insert(name)
        }

        // A fixed list of operations, so the run is the same every time. Each one is applied to the
        // expected set here and to the folder by the mutator below.
        enum Operation { case add(String), remove(String), rename(String, String) }
        var operations: [Operation] = []
        var expected = names
        var universe = names
        var seed: UInt64 = 0x9E37_79B9_7F4A_7C15
        func next(_ bound: Int) -> Int {
            seed = seed &* 6_364_136_223_846_793_005 &+ 1_442_695_040_888_963_407
            return Int((seed >> 33) % UInt64(bound))
        }
        for step in 0..<300 {
            let existing = expected.sorted()
            switch step % 3 {
            case 0:
                let name = String(format: "n-%04d.txt", step)
                operations.append(.add(name))
                expected.insert(name)
                universe.insert(name)
            case 1:
                let victim = existing[next(existing.count)]
                operations.append(.remove(victim))
                expected.remove(victim)
            default:
                let old = existing[next(existing.count)]
                let new = String(format: "r-%04d.txt", step)
                operations.append(.rename(old, new))
                expected.remove(old)
                expected.insert(new)
                universe.insert(new)
            }
        }
        let plannedOperations = operations
        let finished = Mutex(false)
        let mutatorFailures = ConcurrentLog<String>()
        let mutator = Task.detached {
            let fileManager = FileManager.default
            for operation in plannedOperations {
                do {
                    switch operation {
                    case .add(let name):
                        try Data(name.utf8).write(to: folder.appending(path: name))
                    case .remove(let name):
                        try fileManager.removeItem(at: folder.appending(path: name))
                    case .rename(let old, let new):
                        try fileManager.moveItem(at: folder.appending(path: old), to: folder.appending(path: new))
                    }
                } catch {
                    mutatorFailures.append(String(describing: error))
                }
            }
            finished.withLock { $0 = true }
        }

        var scansDuringChanges = 0
        repeat {
            let result = try await scanner.scan(ScanLocation(folderURL: folder, source: .launchArgument))
            let seen = result.records.map(\.displayName) + result.skippedItems.map(\.url.lastPathComponent)
            #expect(Set(seen).isSubset(of: universe))
            #expect(result.records.count <= universe.count)
            scansDuringChanges += 1
        } while !finished.withLock({ $0 }) && scansDuringChanges < 200
        await mutator.value

        #expect(mutatorFailures.values.isEmpty)
        #expect(scansDuringChanges >= 1)
        let settled = try await scanner.scan(ScanLocation(folderURL: folder, source: .launchArgument))
        #expect(settled.skippedItems.isEmpty)
        #expect(Set(settled.records.map(\.displayName)) == expected)
    }

    // MARK: - Executor

    /// Between two items the folder changes: a duplicate is renamed, one is deleted, a new copy
    /// appears and a kept file is renamed. Each is reported; only the file that was still exactly
    /// as planned moves.
    @Test func executorToleratesChangesBetweenItems() async throws {
        let temp = try TemporaryFolder.make()
        defer { temp.remove() }
        let folder = temp.url
        try FileDates.writeSettled(
            [
                "a.txt": "alpha", "a (1).txt": "alpha", "a (2).txt": "alpha", "a (3).txt": "alpha",
                "b.txt": "bravo", "b (1).txt": "bravo",
            ],
            in: folder
        )
        let plan = try await planner.plan(records: scan(folder), in: folder)
        // The larger group comes first, its duplicates in name order.
        #expect(plan.changes.map(\.record.displayName) == ["a (1).txt", "a (2).txt", "a (3).txt", "b (1).txt"])
        let once = Once()
        let failures = ConcurrentLog<String>()

        let result = await executor.execute(plan: plan, confirmedChangeIDs: Set(plan.changes.map(\.id))) { progress in
            guard progress.itemsCompleted == 1 else { return }
            once.run {
                do {
                    let fileManager = FileManager.default
                    try fileManager.moveItem(at: folder.appending(path: "a (2).txt"), to: folder.appending(path: "a (2) moved.txt"))
                    try fileManager.removeItem(at: folder.appending(path: "a (3).txt"))
                    try Data("alpha".utf8).write(to: folder.appending(path: "a (4).txt"))
                    try fileManager.moveItem(at: folder.appending(path: "b.txt"), to: folder.appending(path: "b-kept.txt"))
                } catch {
                    failures.append(String(describing: error))
                }
            }
        }
        defer { TrashedFiles.remove(result) { _ in Data("alpha".utf8) } }

        #expect(failures.values.isEmpty)
        #expect(result.trashed.map(\.change.record.displayName) == ["a (1).txt"])
        let renamedOutcome = try outcome(for: "a (2).txt", in: result)
        let deletedOutcome = try outcome(for: "a (3).txt", in: result)
        let orphanedOutcome = try outcome(for: "b (1).txt", in: result)
        #expect(renamedOutcome == .skipped(.notFound))
        #expect(deletedOutcome == .skipped(.notFound))
        #expect(orphanedOutcome == .skipped(.keptFileMissing(name: "b.txt")))
        #expect(!result.wasCancelled)
        #expect(exists(folder.appending(path: "a.txt")))
        #expect(exists(folder.appending(path: "a (2) moved.txt")))
        #expect(exists(folder.appending(path: "a (4).txt")))
        #expect(exists(folder.appending(path: "b (1).txt")))
        #expect(exists(folder.appending(path: "b-kept.txt")))
    }

    @Test func executorStopsWhenFolderIsRenamedBetweenItems() async throws {
        let temp = try TemporaryFolder.make()
        defer { temp.remove() }
        let folder = temp.url.appending(path: "Work", directoryHint: .isDirectory)
        let renamed = temp.url.appending(path: "Work-renamed", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: false)
        try FileDates.writeSettled(["a.txt": "alpha", "a (1).txt": "alpha", "a (2).txt": "alpha"], in: folder)
        let plan = try await planner.plan(records: scan(folder), in: folder)
        #expect(plan.changes.count == 2)
        let once = Once()
        let failures = ConcurrentLog<String>()

        let result = await executor.execute(plan: plan, confirmedChangeIDs: Set(plan.changes.map(\.id))) { progress in
            guard progress.itemsCompleted == 1 else { return }
            once.run {
                do {
                    try FileManager.default.moveItem(at: folder, to: renamed)
                } catch {
                    failures.append(String(describing: error))
                }
            }
        }
        defer { TrashedFiles.remove(result) { _ in Data("alpha".utf8) } }

        #expect(failures.values.isEmpty)
        #expect(result.trashed.map(\.change.record.displayName) == ["a (1).txt"])
        #expect(try outcome(for: "a (2).txt", in: result) == .skipped(.folderUnavailable))
        #expect(exists(renamed.appending(path: "a.txt")))
        #expect(exists(renamed.appending(path: "a (2).txt")))
    }
}
