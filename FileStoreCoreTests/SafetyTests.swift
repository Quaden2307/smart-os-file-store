import FileStoreCore
import Foundation
import Testing

/// Properties the whole app rests on, kept as tests so a later change cannot quietly break them:
/// production code has exactly one way to remove a file and it is the Trash; every call that changes
/// the disk sits in one file; only the activity log uses the database library; scanning and planning
/// write nothing; and the folders the tests use live under the temporary directory.
@Suite("Safety")
struct SafetyTests {
    private let scanner = FolderScanner()

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

    /// Calls and flags that change files. None may appear in production code: the engine changes
    /// files only through the calls in `diskChangingCalls`, and the app only calls the engine.
    /// `rename(` is the POSIX call; the enum case `rename(to:` is always written with its label.
    private static let fileChangingPatterns = [
        #"\bremoveItem\s*\("#, #"\bunlink\s*\("#, #"\bunlinkat\s*\("#, #"\bremovefile\s*\("#,
        #"\brmdir\s*\("#, #"\brename\s*\((?!\s*to\s*:)"#, #"\brenameat\s*\("#, #"\brenamex_np\s*\("#,
        #"\bRENAME_SWAP\b"#, #"\bexchangedata\s*\("#,
        #"\bftruncate\s*\("#, #"\btruncate\s*\("#,
        #"\bmoveItem\s*\("#, #"\breplaceItem\s*\("#, #"\bcopyItem\s*\("#, #"\blinkItem\s*\("#,
        #"\bf?copyfile\s*\("#, #"\bf?clonefile(at)?\s*\("#, #"\blink(at)?\s*\("#, #"\bsymlink(at)?\s*\("#,
        #"\bcreateFile\s*\("#, #"\bcreateDirectory\s*\("#, #"\bcreateSymbolicLink\s*\("#, #"\bmkdir\s*\("#,
        #"\bwrite\s*\(\s*to"#, #"\bsetAttributes\s*\("#,
        #"\bFileHandle\s*\(\s*forWritingTo"#, #"\bFileHandle\s*\(\s*forUpdating"#,
        #"\bO_WRONLY\b"#, #"\bO_RDWR\b"#, #"\bO_TRUNC\b"#,
        #"\bf?setxattr\s*\("#, #"\bf?removexattr\s*\("#, #"\bf?setattrlist\s*\("#,
        #"\bf?chmod(at)?\s*\("#, #"\bf?chflags\s*\("#,
    ]

    /// The engine's only calls that change the disk, with how often each may appear. All of them
    /// live in `DiskChange.swift` and nowhere else, in the engine or the app. `O_CREAT` is the one
    /// file the app ever makes: the activity log's empty database, before SQLite opens it.
    private static let diskChangingCalls = [
        (pattern: #"\btrashItem\s*\("#, count: 1),
        (pattern: #"\brenameatx_np\s*\("#, count: 1),
        (pattern: #"\bmkdirat\s*\("#, count: 1),
        (pattern: #"\bsetattrlistat\s*\("#, count: 1),
        (pattern: #"\bO_CREAT\b"#, count: 1),
    ]

    /// A whole `renameatx_np` call, its arguments included (one level of nested parentheses).
    private static let renameCall = #"\brenameatx_np\s*\((?:[^()]|\([^()]*\))*\)"#

    /// A whole `setattrlistat` call, its arguments included.
    private static let setAttributesCall = #"\bsetattrlistat\s*\((?:[^()]|\([^()]*\))*\)"#

    /// A whole `openat` call, its arguments included.
    private static let openatCall = #"\bopenat\s*\((?:[^()]|\([^()]*\))*\)"#

    /// The files that may ask `DiskChange` for a change: the executor's parts, for a user's files
    /// (the Trash for duplicates, for failed downloads, for unpacked zips, for used installers, for
    /// near-duplicates and for copies the archive already holds, renames and moves, and undo), the activity log's storage, for its own folder and
    /// database, and the disk image mounts, for the app's own private folder images are read in.
    private static let diskChangeCallers = [
        "FileStoreCore/ActivityLogStorage.swift",
        "FileStoreCore/CleanupExecutor+ArchivedCopies.swift",
        "FileStoreCore/CleanupExecutor+Duplicates.swift",
        "FileStoreCore/CleanupExecutor+FailedDownloads.swift",
        "FileStoreCore/CleanupExecutor+NearDuplicates.swift",
        "FileStoreCore/CleanupExecutor+Relocation.swift",
        "FileStoreCore/CleanupExecutor+Undo.swift",
        "FileStoreCore/CleanupExecutor+UnpackedZips.swift",
        "FileStoreCore/CleanupExecutor+UsedInstallers.swift",
        "FileStoreCore/DiskImageMounts.swift",
    ]

    /// Constructs that crash or bypass the type checker. Forbidden anywhere near user files.
    private static let forcedPathPatterns = [
        #"\btry!"#, #"\bfatalError\s*\("#, #"\bprecondition\s*\("#, #"\bpreconditionFailure\s*\("#,
        #"\bas!"#, #"@unchecked\s+Sendable"#, #"nonisolated\s*\(\s*unsafe\s*\)"#,
    ]

    /// The repository root: the folder holding `project.yml`, found from this file's own path.
    static func projectRoot() throws -> URL {
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

        // The engine's disk changes all sit in one file: the one removal call, a move to the Trash,
        // a rename that never replaces anything, making a folder for a move, and setting a moved
        // file's Date Added back.
        for call in Self.diskChangingCalls {
            let regex = try Self.regex(call.pattern)
            let callers = (engine + app).filter { $0.count(of: regex) > 0 }
            #expect(callers.map(\.label) == ["FileStoreCore/DiskChange.swift"], "\(call.pattern)")
            #expect(callers.first?.count(of: regex) == call.count, "\(call.pattern)")
        }
        // Every rename is exclusive, so it can never replace an item.
        let diskChange = try #require(engine.first { $0.name == "DiskChange.swift" })
        let renameCalls = diskChange.code.matches(of: try Self.regex(Self.renameCall))
        #expect(renameCalls.count == 1)
        for call in renameCalls {
            #expect(call.output[0].substring?.contains("RENAME_EXCL") == true, "\(call.output[0].substring ?? "")")
            // And never through a link, whether the source is a name in a folder or a path in the Trash.
            #expect(call.output[0].substring?.contains("RENAME_NOFOLLOW_ANY") == true, "\(call.output[0].substring ?? "")")
        }
        // The one attribute ever set is a moved file's Date Added, put back as it was, and never
        // through a link.
        let attributeCalls = diskChange.code.matches(of: try Self.regex(Self.setAttributesCall)).compactMap { $0.output[0].substring }
        #expect(attributeCalls.count == 1)
        for call in attributeCalls {
            #expect(call.contains("FSOPT_NOFOLLOW"), "\(call)")
        }
        #expect(diskChange.code.contains("request.commonattr = attrgroup_t(ATTR_CMN_ADDEDTIME)\n"))
        #expect(!diskChange.code.contains("attrgroup_t(ATTR_CMN_MODTIME)"))
        // The one file ever made is made exclusively, for its owner only, and through no link: the
        // call can neither empty nor replace a file that is already there.
        let creatingCalls = diskChange.code.matches(of: try Self.regex(Self.openatCall))
            .compactMap { $0.output[0].substring }
            .filter { $0.contains("O_CREAT") }
        #expect(creatingCalls.count == 1)
        for call in creatingCalls {
            #expect(call.contains("O_EXCL"), "\(call)")
            #expect(call.contains("O_NOFOLLOW"), "\(call)")
            #expect(call.contains("0o600"), "\(call)")
        }
        // Only the executor, the log's storage and the disk image mounts ask for a change at all.
        let diskChangeUse = try Self.regex(#"\bDiskChange\s*\."#)
        let users = (engine + app).filter { $0.contains(diskChangeUse) }.map(\.label)
        #expect(users == Self.diskChangeCallers)
        let trashCall = try Self.regex(#"\btrashItem\s*\("#)

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

    /// The database library is the engine's alone, and within the engine the activity log's alone.
    /// It is imported as it is: a `@preconcurrency` import would hide what strict concurrency checks.
    @Test func onlyTheActivityLogUsesTheDatabaseLibrary() throws {
        let engine = try Self.sources(of: "FileStoreCore")
        let app = try Self.sources(of: "SmartOSFileStore")
        let databaseImport = try Self.regex(#"\bimport\s+GRDB\b"#)
        let unqualifiedImport = try Self.regex(#"^\s*import\s+GRDB\b"#).anchorsMatchLineEndings()
        let preconcurrencyImport = try Self.regex(#"@preconcurrency\s+import\b"#)

        let importers = engine.filter { $0.contains(databaseImport) }
        #expect(!importers.isEmpty)
        for source in importers {
            #expect(source.name.hasPrefix("ActivityLog"), "\(source.label) imports GRDB")
            // `internal import`: the compiler then refuses any public declaration that names a
            // GRDB type, so the app and the tests can never come to depend on the library.
            #expect(!source.contains(unqualifiedImport), "\(source.label) must import GRDB as `internal import GRDB`")
        }
        for source in app {
            #expect(!source.contains(databaseImport), "\(source.label) must reach the database through the engine")
        }
        for source in engine + app {
            #expect(!source.contains(preconcurrencyImport), "\(source.label) uses a @preconcurrency import")
        }
    }

    // MARK: - Read-only phases

    /// What `lstat` says about one entry: enough to notice any write, rename or attribute change.
    /// The status-change time moves whenever an extended attribute is written or removed.
    private struct Entry: Hashable {
        let name: String
        let size: Int64
        let modifiedSeconds: Int
        let modifiedNanoseconds: Int
        let changedSeconds: Int
        let changedNanoseconds: Int
        let inode: UInt64
        let mode: UInt16
        let flags: UInt32
    }

    private enum SnapshotError: Error {
        case statFailed(name: String)
    }

    /// Every entry of `folder` at any depth, hidden ones included, plus the folder itself, by its
    /// path inside the folder: planning Remove Unpacked Zips reads inside the unpacked folders.
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
                    changedSeconds: status.st_ctimespec.tv_sec,
                    changedNanoseconds: status.st_ctimespec.tv_nsec,
                    inode: status.st_ino,
                    mode: status.st_mode,
                    flags: status.st_flags
                )
            )
        }
        try add(".", at: folder)
        guard let enumerator = FileManager.default.enumerator(atPath: folder.path(percentEncoded: false)) else {
            throw SnapshotError.statFailed(name: ".")
        }
        for case let path as String in enumerator {
            try add(path, at: folder.appending(path: path))
        }
        return entries
    }

    @Test func scanningAndPlanningChangeNothingOnDisk() async throws {
        try await withFakeDownloadsFolder { fixture in
            let before = try Self.snapshot(of: fixture.url)
            // Every listed item, the hidden file and the folder itself, and what is inside the folders.
            #expect(before.filter { !$0.name.contains("/") }.count == FakeDownloadsFolder.expectedTopLevelNames.count + 2)
            #expect(before.contains { $0.name == "\(FakeDownloadsFolder.Names.zipFolder)/\(FakeDownloadsFolder.Names.zipFolderFiles[0])" })

            // Every planner the app offers, each with something to propose.
            let records = try await scanner.scan(ScanLocation(folderURL: fixture.url, source: .launchArgument)).records
            var proposed: [CleanupAction: Int] = [:]
            for action in PlannersRespectKeptTests.plannedActions {
                let plan = try #require(
                    try await CleanupPlanners.plan(action, records: records, in: fixture.url, eligibility: CandidateEligibility(), keptItems: KeptItems(), installers: .testing(applications: [fixture.applicationsURL]))
                )
                proposed[action] = plan.changes.count
            }
            #expect(proposed == [.findDuplicates: 6, .clearFailedDownloads: 3, .removeUnpackedZips: 2, .removeUsedInstallers: 2, .fixMessyNames: 9, .reviewNearDuplicates: 6, .archiveOldDownloads: 2])

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
