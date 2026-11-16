import FileStoreCore
import Foundation

/// Real zips for the Remove Unpacked Zips tests, made in the test with the system's own tools:
/// `ditto`, which Finder's Compress uses, and Info-ZIP's `zip`.
enum ZipTools {
    /// Zips `source` as the fixture script does: like Finder's Compress, without extended
    /// attributes, resource forks or quarantine, so sizes never vary. With `keepParent`, the folder
    /// itself is the zip's one top-level item. With `sequesteringResources`, ditto puts what it
    /// keeps of extended attributes into `__MACOSX/._name` entries, as Finder's Compress does.
    static func ditto(_ source: URL, to zip: URL, keepParent: Bool, sequesteringResources: Bool = false) throws {
        let options = sequesteringResources ? ["--sequesterRsrc"] : ["--norsrc", "--noextattr", "--noqtn", "--noacl"]
        try CommandLineTool.run(
            "/usr/bin/ditto",
            ["-c", "-k"] + options + (keepParent ? ["--keepParent"] : []) + [source.path(percentEncoded: false), zip.path(percentEncoded: false)]
        )
    }

    /// Zips the regular file `input`, read as standard input: Info-ZIP writes one entry named `-`,
    /// with a Zip64 end record and locator, since it cannot know the size of a stream in advance.
    static func zipStandardInput(from input: URL, to zip: URL) throws {
        try CommandLineTool.run("/usr/bin/zip", ["-q", zip.path(percentEncoded: false), "-"], input: input)
    }

    /// Zips `names` in `folder`, recursively and stored, with Info-ZIP; with a password, its entries
    /// are encrypted (PKZip 2.0), and its list of contents is still readable.
    static func zip(_ names: [String], in folder: URL, to zip: URL, password: String? = nil) throws {
        let encryption = password.map { ["-P", $0] } ?? []
        try CommandLineTool.run("/usr/bin/zip", ["-q", "-r", "-0"] + encryption + [zip.path(percentEncoded: false)] + names, currentDirectory: folder)
    }

    /// The entries `zipinfo` lists for `zip`, with their uncompressed sizes, in the archive's order:
    /// a reader other than ours, for comparison.
    static func zipinfoListing(of zip: URL) throws -> [ZipEntrySummary] {
        let path = zip.path(percentEncoded: false)
        let names = try CommandLineTool.run("/usr/bin/zipinfo", ["-1", path]).split(separator: "\n").map(String.init)
        // Two header lines, one line per entry, one summary line. The size is the fourth column.
        let lines = try CommandLineTool.run("/usr/bin/zipinfo", ["-s", path]).split(separator: "\n").dropFirst(2).dropLast()
        let sizes = lines.compactMap { line in
            line.split(separator: " ", omittingEmptySubsequences: true).dropFirst(3).first.flatMap { Int64($0) }
        }
        guard names.count == sizes.count else {
            throw CommandLineTool.Failure(tool: "zipinfo", status: 0, output: "\(names.count) names but \(sizes.count) sizes")
        }
        return Swift.zip(names, sizes).map { ZipEntrySummary(path: $0, size: $1) }
    }

    /// The bytes of each file in `folder` by name, for `TrashedFiles` to check before it removes them.
    static func contents(of names: [String], in folder: URL) throws -> [String: Data] {
        var contents: [String: Data] = [:]
        for name in names {
            contents[name] = try Data(contentsOf: folder.appending(path: name))
        }
        return contents
    }
}

/// One entry as a listing names it: what `zipinfo` and `ZipListing` are compared on.
struct ZipEntrySummary: Hashable {
    let path: String
    let size: Int64
}

extension ZipListing {
    var summaries: [ZipEntrySummary] {
        entries.map { ZipEntrySummary(path: $0.path, size: $0.uncompressedSize) }
    }
}

/// A folder for the Remove Unpacked Zips tests, written into a temporary folder:
/// - `project.zip`, made with ditto from `project/` (`readme.md`, `src/main.swift`), which stays
///   beside it, unpacked;
/// - `contract.zip`, holding the one file `contract.docx`, which also sits beside it.
///
/// Everything is dated two hours back, in the order made. Every file holds the test's own marker,
/// so whatever a test sends to the real Trash can be told apart and removed again.
enum UnpackedZips {
    static let projectZip = "project.zip"
    static let project = "project"
    static let readme = "readme.md"
    static let source = "src"
    static let main = "main.swift"
    static let contractZip = "contract.zip"
    static let contract = "contract.docx"

    struct Contents {
        let marker: String
        /// The zips' bytes, by name.
        let zips: [String: Data]

        var readme: String { "# Project \(marker)\n" }
        var main: String { "print(\"\(marker)\")\n" }
        var contract: String { "signed contract \(marker)" }

        /// The bytes of a zip this folder holds, by its URL; nil for anything else.
        func zipData(at url: URL) -> Data? {
            zips[url.lastPathComponent]
        }
    }

    /// Writes the copies, zips them, and dates everything two hours back.
    @discardableResult
    static func write(in folder: URL, marker: String = UUID().uuidString) throws -> Contents {
        let fileManager = FileManager.default
        let projectFolder = folder.appending(path: project, directoryHint: .isDirectory)
        let sourceFolder = projectFolder.appending(path: source, directoryHint: .isDirectory)
        try fileManager.createDirectory(at: sourceFolder, withIntermediateDirectories: true)
        let partial = Contents(marker: marker, zips: [:])
        try Data(partial.readme.utf8).write(to: projectFolder.appending(path: readme))
        try Data(partial.main.utf8).write(to: sourceFolder.appending(path: main))
        try Data(partial.contract.utf8).write(to: folder.appending(path: contract))
        try ZipTools.ditto(projectFolder, to: folder.appending(path: projectZip), keepParent: true)
        try ZipTools.ditto(folder.appending(path: contract), to: folder.appending(path: contractZip), keepParent: false)
        // A folder's own date last: making what is inside it moved it.
        try FileDates.settle([
            projectFolder.appending(path: readme),
            sourceFolder.appending(path: main),
            sourceFolder,
            projectFolder,
            folder.appending(path: projectZip),
            folder.appending(path: contract),
            folder.appending(path: contractZip),
        ])
        return Contents(marker: marker, zips: try ZipTools.contents(of: [projectZip, contractZip], in: folder))
    }

    /// The Remove Unpacked Zips plan for `folder` as it is now, with the given Kept list.
    static func plan(
        _ folder: URL,
        keeping keptItems: KeptItems = KeptItems(),
        now: Date = .now,
        onProgress: (@Sendable (CleanupPlanningProgress) -> Void)? = nil
    ) async throws -> CleanupPlan? {
        let records = try await RelocationPlans.records(in: folder)
        return try await CleanupPlanners.plan(
            .removeUnpackedZips,
            records: records,
            in: folder,
            eligibility: CandidateEligibility(),
            keptItems: keptItems,
            now: now,
            onProgress: onProgress
        )
    }

    /// What the plan proposes, as "zip → copy" pairs in plan order.
    static func proposals(_ plan: CleanupPlan) -> [String] {
        plan.changes.map { change in
            guard case .unpackedZip(let copy) = change.reason else {
                return "\(change.record.displayName) → ?"
            }
            return "\(change.record.displayName) → \(copy)"
        }
    }
}
