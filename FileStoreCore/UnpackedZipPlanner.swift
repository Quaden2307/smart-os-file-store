import Foundation
import UniformTypeIdentifiers

/// Plans Remove Unpacked Zips: the zips at the top level of the folder whose every entry already sits
/// next to them, unpacked, at the same size, proposed for the Trash. What they were unpacked to is
/// never touched (decision record 0011).
///
/// Where to look follows Archive Utility. A zip holding one item unpacks it beside itself, a zip
/// holding several unpacks them into a folder named after itself, and a name already taken gets a
/// number (`project 2`). Every entry is compared by its path and size: a matching name alone never
/// counts.
///
/// The rule is pure: `expectation(for:zipName:)`, `candidateNames(for:among:)` and
/// `matches(_:_:)` work on values alone. Only `plan(records:in:now:onProgress:)` reads the disk,
/// and it only reads.
public struct UnpackedZipPlanner: Sendable {
    /// Where a zip would have been unpacked to, and what must be there.
    public struct Expectation: Sendable, Hashable {
        /// The name of the item beside the zip that would hold its entries: the one item's own
        /// name, or, for several items, the zip's name without its extension.
        public let name: String

        /// What must be at that name.
        public let tree: UnpackedTree

        public init(name: String, tree: UnpackedTree) {
            self.name = name
            self.tree = tree
        }
    }

    /// Why a zip can never count as unpacked, whatever is beside it.
    public enum Unmatchable: Error, Sendable, Hashable {
        /// Once the system's own entries are left out, it holds no file or link: nothing to compare.
        case empty
        /// It holds an `.app` somewhere: an installer, which Remove Used Installers decides about.
        case holdsAnApp
        /// An entry's path is absolute, climbs out with `..`, or has an empty or `.` part. Paths are
        /// only ever compared, but such a path names no place beside the zip.
        case unsafePath
        /// One path is given twice, other than a folder, or a file is also the folder of others.
        /// Unpacking either keeps one of the two or fails, so the other is beside nothing.
        case conflictingEntries
        /// Its entries and the folders their paths imply are more than `maximumTreeItems`, or their
        /// paths longer than `maximumTreePathBytes` together: too much to check.
        case tooLarge
    }

    /// What one zip turned out to be.
    public enum Finding: Sendable, Hashable {
        /// Every entry is beside it, in the item `to`.
        case unpacked(to: String)
        case notUnpacked
        /// The zip itself could not be read or listed.
        case notChecked(CleanupSkipReason)
    }

    /// The most items a zip's expected tree may hold, its entries and the folders their paths
    /// imply together. Paths can imply far more folders than there are entries (a name of 1,024
    /// bytes can be 512 folders deep), so the tree has a limit of its own.
    public static let maximumTreeItems = 2 * ZipListing.Limits.standard.maximumEntryCount

    /// The most bytes the expected tree's paths may take together.
    public static let maximumTreePathBytes = ZipListing.Limits.standard.maximumDirectorySize

    /// The rules every action shares, with the Kept list.
    public let eligibility: CandidateEligibility

    public init(eligibility: CandidateEligibility = CandidateEligibility()) {
        self.eligibility = eligibility
    }

    // MARK: - Which items take part

    /// True when `name`'s extension gives it exactly the zip type. The executor can read only the
    /// name again without a cached value, so the planner requires it as well as the scan's type.
    public static func isZipName(_ name: String) -> Bool {
        let pathExtension = URL(filePath: name, directoryHint: .notDirectory).pathExtension
        return !pathExtension.isEmpty && UTType(filenameExtension: pathExtension) == .zip
    }

    /// The zips that may be proposed at `now`: regular files of exactly the zip type, as the scan
    /// read it and as the name gives it, that the shared rules allow (not hidden, not the archive,
    /// not still downloading, past the grace period, not Kept). `.jar`, `.docx` and other formats
    /// built on zip are not zips here; links and folders never are.
    public func candidates(in records: [FileRecord], now: Date) -> [FileRecord] {
        records.filter { record in
            record.kind == .file
                && record.contentType == .zip
                && Self.isZipName(record.displayName)
                && eligibility.allows(record, now: now)
        }
    }

    /// The items whose names may be a zip's unpacked copy: never hidden, the archive or a download
    /// in progress, and never a zip, which this action could move to the Trash too. A Kept item
    /// counts, since a copy is never changed. Whether the copy has settled is decided from the disk
    /// as it is when it is read (`checkCopy`), never from the scan: a copy unpacked again since,
    /// under the same name, is new.
    public static func unpackedCopies(in records: [FileRecord]) -> [FileRecord] {
        records.filter { record in
            !CandidateEligibility.isExcludedName(record.displayName)
                && !record.isDownloading
                && record.contentType != .zip
                && !isZipName(record.displayName)
        }
    }

    /// True for a name a plan may give as a zip's copy, or a path may have as one part: one plain
    /// name of an item, never a path, by the rule every name the executor uses must pass.
    static func isPlainName(_ name: String) -> Bool {
        FileNameRules.isSingleName(name, maximumLength: FileNameRules.defaultMaximumLength)
    }

    // MARK: - The rule

    /// Where a zip holding `entries`, called `zipName`, would have been unpacked to, and what must
    /// be there, or why no place can ever hold it.
    ///
    /// The system's own entries are left out first: the `__MACOSX` folder Finder's Compress adds,
    /// `.DS_Store`, and AppleDouble files (`._name`). They carry what an unpacked item keeps in its
    /// extended attributes, or nothing at all, and Archive Utility does not unpack them as files.
    ///
    /// Two passes over the entries, so no entry's parts are kept beyond the step that reads them,
    /// and the tree stops at `maximumTreeItems` and `maximumTreePathBytes`.
    public static func expectation(for entries: [ZipEntry], zipName: String) -> Result<Expectation, Unmatchable> {
        var topLevel: Set<String> = []
        var holdsContent = false
        var holdsApp = false
        for entry in entries {
            let parts = parts(of: entry)
            if isSystemEntry(parts) {
                continue
            }
            // Absolute paths, `..`, `.`, empty parts and NUL never name a place beside the zip.
            guard parts.allSatisfy(isPlainName) else {
                return .failure(.unsafePath)
            }
            holdsContent = holdsContent || entry.kind == .file || entry.kind == .symbolicLink
            holdsApp = holdsApp || holdsAnApp(parts, kind: entry.kind)
            topLevel.insert(parts[0])
        }
        guard holdsContent else {
            return .failure(.empty)
        }
        if holdsApp {
            return .failure(.holdsAnApp)
        }

        let single = topLevel.count == 1 ? topLevel.first : nil
        let name = single ?? URL(filePath: zipName, directoryHint: .notDirectory).deletingPathExtension().lastPathComponent
        var builder = TreeBuilder(rootIsFolder: single == nil)
        for entry in entries {
            let parts = parts(of: entry)
            if isSystemEntry(parts) {
                continue
            }
            if let refusal = builder.add(UnpackedTree.Item(entry), at: single == nil ? parts[...] : parts.dropFirst()) {
                return .failure(refusal)
            }
        }
        return .success(Expectation(name: name, tree: builder.tree))
    }

    /// The names among `names` that a zip expected at `name` may have been unpacked to, in the order
    /// they are tried: `name` itself, then Archive Utility's numbered names from 2 up. Each comes as
    /// `names` spells it.
    public static func candidateNames(for name: String, among names: [String]) -> [String] {
        let forms = NumberedNames(of: name)
        var exact: [String] = []
        var numbered: [(number: Int, name: String)] = []
        for candidate in names {
            if candidate == name {
                exact.append(candidate)
            } else if let number = forms.number(of: candidate) {
                numbered.append((number, candidate))
            }
        }
        numbered.sort { ($0.number, $0.name) < ($1.number, $1.name) }
        return exact + numbered.map(\.name)
    }

    /// N when `candidate` is the name Archive Utility gives a copy of `name` when `name` is taken.
    static func copyNumber(of candidate: String, for name: String) -> Int? {
        NumberedNames(of: name).number(of: candidate)
    }

    /// True when `found` holds everything `expected` does. A file needs a file of the same size, a
    /// link a link of the same size, never followed, and a folder a folder; anything else never
    /// matches. Every expected path must be found, and anything extra in `found` is fine.
    public static func matches(_ expected: UnpackedTree, _ found: UnpackedTree) -> Bool {
        fits(expected.root, found.root)
            && expected.contents.allSatisfy { path, item in
                found.contents[path].map { fits(item, $0) } ?? false
            }
    }

    // MARK: - The plan

    /// The plan from each zip's finding, for `folderURL`. Changes and items not checked are in name
    /// order. Pure: nothing here touches the disk.
    public static func makePlan(folderURL: URL, findings: [(record: FileRecord, finding: Finding)]) -> CleanupPlan {
        var changes: [ProposedChange] = []
        var skippedItems: [CleanupPlan.SkippedItem] = []
        for (record, finding) in findings {
            switch finding {
            case .unpacked(let name):
                changes.append(ProposedChange(record: record, operation: .moveToTrash, reason: .unpackedZip(unpackedTo: name)))
            case .notUnpacked:
                break
            case .notChecked(let reason):
                skippedItems.append(CleanupPlan.SkippedItem(url: record.url, reason: reason))
            }
        }
        changes.sort { isOrderedBefore($0.record.displayName, $1.record.displayName) }
        skippedItems.sort { isOrderedBefore($0.url.lastPathComponent, $1.url.lastPathComponent) }
        return CleanupPlan(action: .removeUnpackedZips, folderURL: folderURL, changes: changes, skippedItems: skippedItems)
    }

    static func isOrderedBefore(_ first: String, _ second: String) -> Bool {
        first.localizedStandardCompare(second) == .orderedAscending
    }

    // MARK: - Helpers

    /// The parts of an entry's path. A folder's name may end in `/`: its mark, not an empty part.
    private static func parts(of entry: ZipEntry) -> [String] {
        let path = entry.kind == .folder && entry.path.hasSuffix("/") ? String(entry.path.dropLast()) : entry.path
        return path.split(separator: "/", omittingEmptySubsequences: false).map(String.init)
    }

    private static func isSystemEntry(_ parts: [String]) -> Bool {
        guard let last = parts.last else {
            return false
        }
        return parts.contains("__MACOSX") || last == ".DS_Store" || last.hasPrefix("._")
    }

    /// True when a folder on the entry's path, the entry itself included if it is a folder, is an
    /// app (`.app`, in any letter case).
    private static func holdsAnApp(_ parts: [String], kind: ZipEntry.Kind) -> Bool {
        let folders = kind == .folder ? parts[...] : parts.dropLast()
        return folders.contains { $0.lowercased().hasSuffix(".app") }
    }

    private static func fits(_ expected: UnpackedTree.Item, _ found: UnpackedTree.Item) -> Bool {
        switch (expected, found) {
        case (.file(let size), .file(let foundSize)), (.symbolicLink(let size), .symbolicLink(let foundSize)):
            size == foundSize
        case (.folder, .folder):
            true
        case (.file, _), (.symbolicLink, _), (.folder, _), (.other, _):
            false
        }
    }

    /// The names Archive Utility gives a copy of one name when it is taken, worked out once for
    /// that name and then tried against any number of others: `"name N"`, and for a name with an
    /// extension `"base N.ext"`, with N a plain number of 2 or more.
    private struct NumberedNames {
        private let plain: String
        private let withExtension: (prefix: String, suffix: String)?

        init(of name: String) {
            plain = name + " "
            let url = URL(filePath: name, directoryHint: .notDirectory)
            withExtension = url.pathExtension.isEmpty ? nil : (url.deletingPathExtension().lastPathComponent + " ", "." + url.pathExtension)
        }

        func number(of candidate: String) -> Int? {
            if let number = Self.number(in: candidate, between: plain, and: "") {
                return number
            }
            guard let withExtension else {
                return nil
            }
            return Self.number(in: candidate, between: withExtension.prefix, and: withExtension.suffix)
        }

        /// The number between `prefix` and `suffix` in `candidate`: plain ASCII digits with no
        /// leading zero, 2 or more.
        private static func number(in candidate: String, between prefix: String, and suffix: String) -> Int? {
            guard candidate.hasPrefix(prefix), candidate.hasSuffix(suffix), candidate.count > prefix.count + suffix.count else {
                return nil
            }
            let digits = candidate.dropFirst(prefix.count).dropLast(suffix.count)
            guard let first = digits.first, first != "0", digits.allSatisfy({ $0.isASCII && $0.isNumber }),
                  let number = Int(digits), number >= 2 else {
                return nil
            }
            return number
        }
    }

    /// Builds the tree a zip expects from its entries' paths, adding the folders they imply, within
    /// `maximumTreeItems` and `maximumTreePathBytes`.
    private struct TreeBuilder {
        private var root: UnpackedTree.Item?
        private var contents: [String: UnpackedTree.Item] = [:]
        private var pathBytes = 0

        init(rootIsFolder: Bool) {
            root = rootIsFolder ? .folder : nil
        }

        var tree: UnpackedTree {
            UnpackedTree(root: root ?? .folder, contents: contents)
        }

        /// Adds `item` at `parts` below the root, with every folder on the way. Nil when it fits,
        /// otherwise why not.
        mutating func add(_ item: UnpackedTree.Item, at parts: ArraySlice<String>) -> Unmatchable? {
            guard !parts.isEmpty else {
                return Self.merge(item, into: &root) ? nil : .conflictingEntries
            }
            guard Self.merge(.folder, into: &root) else {
                return .conflictingEntries
            }
            let path = parts.joined(separator: "/")
            // The folders above it, nearest first, up to the first one already there. Every folder
            // in the tree has all of its own above it, so each folder's path is built once.
            var missing: [String] = []
            var parent = path
            while let slash = parent.lastIndex(of: "/") {
                parent = String(parent[..<slash])
                guard let existing = contents[parent] else {
                    missing.append(parent)
                    continue
                }
                guard existing == .folder else {
                    return .conflictingEntries
                }
                break
            }
            for folder in missing.reversed() {
                if let refusal = insert(.folder, at: folder) {
                    return refusal
                }
            }
            if let existing = contents[path] {
                return existing == .folder && item == .folder ? nil : .conflictingEntries
            }
            return insert(item, at: path)
        }

        private mutating func insert(_ item: UnpackedTree.Item, at path: String) -> Unmatchable? {
            pathBytes += path.utf8.count
            guard contents.count < UnpackedZipPlanner.maximumTreeItems, pathBytes <= UnpackedZipPlanner.maximumTreePathBytes else {
                return .tooLarge
            }
            contents[path] = item
            return nil
        }

        /// Puts `item` where `existing` is, or finds it already there. Only a folder may be given
        /// twice: a file listed twice is unpacked once, over itself or not at all.
        private static func merge(_ item: UnpackedTree.Item, into existing: inout UnpackedTree.Item?) -> Bool {
            guard let current = existing else {
                existing = item
                return true
            }
            return current == .folder && item == .folder
        }
    }
}

extension UnpackedTree.Item {
    /// What a zip entry would be once unpacked.
    init(_ entry: ZipEntry) {
        switch entry.kind {
        case .file:
            self = .file(sizeInBytes: entry.uncompressedSize)
        case .folder:
            self = .folder
        case .symbolicLink:
            self = .symbolicLink(sizeInBytes: entry.uncompressedSize)
        case .other:
            self = .other
        }
    }
}
