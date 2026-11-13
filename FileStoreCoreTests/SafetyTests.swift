import FileStoreCore
import Foundation
import Testing

/// Properties the whole app rests on, kept as tests so a later change cannot quietly break them:
/// production code has exactly one way to remove a file and it is the Trash; scanning and planning
/// write nothing; and the folders the tests use live under the temporary directory.
@Suite("Safety")
struct SafetyTests {
    private let scanner = FolderScanner()
    private let planner = DuplicatePlanner()

    // MARK: - Source scan

    /// A Swift source file of a production target, with comments removed so that a word in a doc
    /// comment never counts as a call.
    private struct Source {
        let target: String
        let name: String
        let code: String

        var label: String { "\(target)/\(name)" }

        func contains(_ pattern: Regex<AnyRegexOutput>) -> Bool {
            code.firstMatch(of: pattern) != nil
        }

        func count(of pattern: Regex<AnyRegexOutput>) -> Int {
            code.matches(of: pattern).count
        }
    }

    private enum SourceScanError: Error {
        case projectRootNotFound
        case noSourcesFound(target: String)
    }

    /// Calls and flags that change files. None may appear in production code: the engine removes
    /// files through `trashItem` alone, and the app only calls the engine.
    private static let fileChangingPatterns = [
        #"\bremoveItem\s*\("#, #"\bunlink\s*\("#, #"\brmdir\s*\("#, #"\brename\s*\("#,
        #"\bftruncate\s*\("#, #"\btruncate\s*\("#,
        #"\bmoveItem\s*\("#, #"\breplaceItem\s*\("#, #"\bcopyItem\s*\("#, #"\blinkItem\s*\("#,
        #"\bcreateFile\s*\("#, #"\bcreateDirectory\s*\("#, #"\bcreateSymbolicLink\s*\("#,
        #"\bwrite\s*\(\s*to"#, #"\bsetAttributes\s*\("#,
        #"\bFileHandle\s*\(\s*forWritingTo"#, #"\bFileHandle\s*\(\s*forUpdating"#,
        #"\bO_WRONLY\b"#, #"\bO_RDWR\b"#, #"\bO_TRUNC\b"#, #"\bO_CREAT\b"#,
    ]

    /// Constructs that crash or bypass the type checker. Forbidden anywhere near user files.
    private static let forcedPathPatterns = [
        #"\btry!"#, #"\bfatalError\s*\("#, #"\bprecondition\s*\("#, #"\bpreconditionFailure\s*\("#,
        #"\bas!"#, #"@unchecked\s+Sendable"#, #"nonisolated\s*\(\s*unsafe\s*\)"#,
    ]

    /// The repository root: the folder holding `project.yml`, found from this file's own path.
    private static func projectRoot() throws -> URL {
        var folder = URL(filePath: #filePath).deletingLastPathComponent()
        for _ in 0..<5 {
            let marker = folder.appending(path: "project.yml").path(percentEncoded: false)
            if FileManager.default.fileExists(atPath: marker) {
                return folder
            }
            folder.deleteLastPathComponent()
        }
        throw SourceScanError.projectRootNotFound
    }

    private static func sources(of target: String) throws -> [Source] {
        let folder = try projectRoot().appending(path: target, directoryHint: .isDirectory)
        let names = try FileManager.default.contentsOfDirectory(atPath: folder.path(percentEncoded: false))
            .filter { $0.hasSuffix(".swift") }
            .sorted()
        guard !names.isEmpty else {
            throw SourceScanError.noSourcesFound(target: target)
        }
        return try names.map { name in
            let text = try String(contentsOf: folder.appending(path: name), encoding: .utf8)
            return Source(target: target, name: name, code: stripComments(text))
        }
    }

    private static func productionSources() throws -> [Source] {
        try sources(of: "FileStoreCore") + sources(of: "SmartOSFileStore")
    }

    /// `\b` with simple word boundaries. Under the default Unicode rules `default.trashItem` is one
    /// word, so no boundary would sit before the call.
    private static func regex(_ pattern: String) throws -> Regex<AnyRegexOutput> {
        try Regex(pattern).wordBoundaryKind(.simple)
    }

    /// Removes `//` comments, `///` doc comments included. The production code uses no `/* */`
    /// comments and no string literal that contains `//`.
    private static func stripComments(_ text: String) -> String {
        text.split(separator: "\n", omittingEmptySubsequences: false)
            .map { line -> Substring in
                if let range = line.range(of: "//") {
                    return line[..<range.lowerBound]
                }
                return line
            }
            .joined(separator: "\n")
    }

    @Test func productionCodeRemovesFilesOnlyThroughTheTrash() throws {
        let engine = try Self.sources(of: "FileStoreCore")
        let app = try Self.sources(of: "SmartOSFileStore")
        #expect(engine.count >= 10)
        #expect(app.count >= 10)

        for source in engine + app {
            for pattern in Self.fileChangingPatterns {
                let regex = try Self.regex(pattern)
                #expect(!source.contains(regex), "\(source.label) matches \(pattern)")
            }
        }

        // The one removal call in the engine, and it is a move to the Trash.
        let trashCall = try Self.regex(#"\btrashItem\s*\("#)
        let callers = engine.filter { $0.count(of: trashCall) > 0 }
        #expect(callers.map(\.name) == ["TrashExecutor.swift"])
        #expect(callers.first?.count(of: trashCall) == 1)

        // The app never touches the Trash itself; it hands a confirmed plan to the engine.
        let recycleCall = try Self.regex(#"\brecycle\s*\("#)
        for source in app {
            #expect(!source.contains(trashCall), "\(source.label) must call the engine, not trashItem")
            #expect(!source.contains(recycleCall), "\(source.label) must call the engine, not recycle")
        }
    }

    @Test func productionCodeHasNoForcedPaths() throws {
        let sources = try Self.productionSources()
        #expect(sources.count >= 20)
        for source in sources {
            for pattern in Self.forcedPathPatterns {
                let regex = try Self.regex(pattern)
                #expect(!source.contains(regex), "\(source.label) matches \(pattern)")
            }
        }
    }

    // MARK: - Read-only phases

    /// What `lstat` says about one entry: enough to notice any write, rename or attribute change.
    private struct Entry: Hashable {
        let name: String
        let size: Int64
        let modifiedSeconds: Int
        let modifiedNanoseconds: Int
        let inode: UInt64
        let mode: UInt16
        let flags: UInt32
    }

    private enum SnapshotError: Error {
        case statFailed(name: String)
    }

    /// Every entry of `folder`, hidden ones included, plus the folder itself.
    private static func snapshot(of folder: URL) throws -> Set<Entry> {
        var entries: Set<Entry> = []
        func add(_ name: String, at url: URL) throws {
            var status = stat()
            guard lstat(url.path(percentEncoded: false), &status) == 0 else {
                throw SnapshotError.statFailed(name: name)
            }
            entries.insert(
                Entry(
                    name: name,
                    size: Int64(status.st_size),
                    modifiedSeconds: status.st_mtimespec.tv_sec,
                    modifiedNanoseconds: status.st_mtimespec.tv_nsec,
                    inode: status.st_ino,
                    mode: status.st_mode,
                    flags: status.st_flags
                )
            )
        }
        try add(".", at: folder)
        for name in try FileManager.default.contentsOfDirectory(atPath: folder.path(percentEncoded: false)) {
            try add(name, at: folder.appending(path: name))
        }
        return entries
    }

    @Test func scanningAndPlanningChangeNothingOnDisk() async throws {
        try await withFakeDownloadsFolder { fixture in
            let before = try Self.snapshot(of: fixture.url)
            // Every listed item, the hidden file and the folder itself.
            #expect(before.count == FakeDownloadsFolder.expectedTopLevelNames.count + 2)

            let records = try await scanner.scan(ScanLocation(folderURL: fixture.url, source: .launchArgument)).records
            let plan = try await planner.plan(records: records, in: fixture.url)
            #expect(plan.changes.count == 5)

            let after = try Self.snapshot(of: fixture.url)
            #expect(after == before)
        }
    }

    // MARK: - Where the tests work

    @Test func testFoldersLiveUnderTheTemporaryDirectory() throws {
        let temporary = canonicalPath(FileManager.default.temporaryDirectory)
        let home = canonicalPath(FileManager.default.homeDirectoryForCurrentUser)
        let fixture = try FakeDownloadsFolder.make()
        defer { fixture.remove() }
        let plain = try TemporaryFolder.make()
        defer { plain.remove() }

        for url in [fixture.url, plain.url] {
            let path = canonicalPath(url)
            #expect(path.hasPrefix(temporary + "/"), "\(path) is not under the temporary directory")
            for name in ["Downloads", "Desktop", "Documents"] {
                #expect(!path.hasPrefix(home + "/" + name), "\(path) is inside the user's \(name) folder")
            }
        }
    }
}
