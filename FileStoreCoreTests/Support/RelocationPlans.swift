import Darwin
import FileStoreCore
import Foundation
import Testing

/// Plans of renames and moves for the executor tests, built from a real scan of a temporary folder
/// the way Fix messy names and Archive old downloads build them.
enum RelocationPlans {
    /// The reason every move these plans make gives: a file never opened since 2025-01-01.
    static let archiveReason = ProposedChange.Reason.neverOpened(downloadedOn: Date(timeIntervalSince1970: 1_735_722_000))

    static func records(in folder: URL) async throws -> [FileRecord] {
        try await FolderScanner().scan(ScanLocation(folderURL: folder, source: .launchArgument)).records
    }

    static func record(named name: String, in records: [FileRecord]) throws -> FileRecord {
        try #require(records.first { $0.displayName == name }, "no record for \(name)")
    }

    /// A Fix messy names plan renaming each file to its new name, in the order given.
    static func rename(_ renames: [(name: String, newName: String)], in folder: URL) async throws -> CleanupPlan {
        let records = try await records(in: folder)
        let changes = try renames.map { rename in
            ProposedChange(record: try record(named: rename.name, in: records), operation: .rename(to: rename.newName), reason: .messyName(MessyNameFix(fixes: [])))
        }
        return CleanupPlan(action: .fixMessyNames, folderURL: folder, changes: changes)
    }

    /// An Archive old downloads plan moving each file into its folder under its new name, in the
    /// order given.
    static func move(_ moves: [(name: String, to: URL, newName: String)], in folder: URL) async throws -> CleanupPlan {
        let records = try await records(in: folder)
        let changes = try moves.map { move in
            ProposedChange(
                record: try record(named: move.name, in: records),
                operation: .move(to: move.to, name: move.newName),
                reason: archiveReason
            )
        }
        return CleanupPlan(action: .archiveOldDownloads, folderURL: folder, changes: changes)
    }

    static func outcome(for name: String, in result: CleanupResult) throws -> CleanupItemOutcome {
        try #require(result.items.first { $0.change.record.displayName == name }, "no result for \(name)").outcome
    }

    static func item(for name: String, in result: CleanupResult) throws -> CleanupItemResult {
        try #require(result.items.first { $0.change.record.displayName == name }, "no result for \(name)")
    }
}

/// What the rename and move tests read back from disk, with `lstat` and `readdir` so that a link is
/// never followed and a name comes back in the exact bytes the volume stores.
enum DiskState {
    /// One entry of a folder, enough to notice any rename, write or replacement.
    struct Entry: Hashable {
        let name: [UInt8]
        let inode: UInt64
        let size: Int64
        let modifiedSeconds: Int
        let modifiedNanoseconds: Int
    }

    static func exists(_ url: URL) -> Bool {
        var status = stat()
        return lstat(url.path(percentEncoded: false), &status) == 0
    }

    static func isSymbolicLink(_ url: URL) -> Bool {
        var status = stat()
        return lstat(url.path(percentEncoded: false), &status) == 0 && status.st_mode & S_IFMT == S_IFLNK
    }

    static func isFolder(_ url: URL) -> Bool {
        var status = stat()
        return lstat(url.path(percentEncoded: false), &status) == 0 && status.st_mode & S_IFMT == S_IFDIR
    }

    static func inode(of url: URL) -> UInt64? {
        var status = stat()
        return lstat(url.path(percentEncoded: false), &status) == 0 ? status.st_ino : nil
    }

    static func text(of url: URL) -> String? {
        guard !isSymbolicLink(url), let data = try? Data(contentsOf: url) else {
            return nil
        }
        return String(decoding: data, as: UTF8.self)
    }

    /// The names in `folder` exactly as stored, sorted by their bytes, `.` and `..` left out.
    static func entryNames(in folder: URL) -> [String] {
        guard let directory = opendir(folder.path(percentEncoded: false)) else {
            return []
        }
        defer { closedir(directory) }
        var names: [String] = []
        while let entry = readdir(directory) {
            let length = Int(entry.pointee.d_namlen)
            let name = withUnsafeBytes(of: entry.pointee.d_name) { buffer in
                String(decoding: buffer.prefix(length), as: UTF8.self)
            }
            if name != "." && name != ".." {
                names.append(name)
            }
        }
        return names.sorted { Array($0.utf8).lexicographicallyPrecedes(Array($1.utf8)) }
    }

    /// Every entry of `folder`, so a test can show that nothing in it changed.
    static func snapshot(of folder: URL) -> Set<Entry> {
        var entries: Set<Entry> = []
        for name in entryNames(in: folder) {
            var status = stat()
            guard lstat(folder.appending(path: name).path(percentEncoded: false), &status) == 0 else {
                continue
            }
            entries.insert(
                Entry(
                    name: Array(name.utf8),
                    inode: status.st_ino,
                    size: Int64(status.st_size),
                    modifiedSeconds: status.st_mtimespec.tv_sec,
                    modifiedNanoseconds: status.st_mtimespec.tv_nsec
                )
            )
        }
        return entries
    }

    /// Writes `text` to a new file called `name` in `folder`, with the name's bytes exactly as
    /// given. Foundation's file URLs store names decomposed (NFD), so a precomposed (NFC) name on
    /// disk can only be made this way.
    static func writeExactName(_ text: String, named name: String, in folder: URL) throws {
        let path = folder.path(percentEncoded: false) + (folder.path(percentEncoded: false).hasSuffix("/") ? "" : "/") + name
        let descriptor = open(path, O_CREAT | O_EXCL | O_WRONLY | O_CLOEXEC, 0o644)
        guard descriptor >= 0 else {
            throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
        }
        defer { close(descriptor) }
        let bytes = Array(text.utf8)
        guard write(descriptor, bytes, bytes.count) == bytes.count else {
            throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
        }
    }

    /// True when two URLs name the same place, whatever their trailing slash.
    static func samePlace(_ first: URL, _ second: URL) -> Bool {
        first.pathComponents == second.pathComponents
    }
}
