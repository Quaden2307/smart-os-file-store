import Foundation
import FoundationModels

/// Which files a tool looks at, as the model writes it. Every field is optional. A guide is advice
/// to the model and is not enforced when arguments arrive, so `validated` checks every field in
/// code and owns the message the model gets back. The guides are short on purpose: the model reads
/// a tool's whole definition again in every turn, out of a context of 4,096 tokens.
@Generable
public struct FileFilter: Sendable, Equatable {
    @Guide(description: "Text in the name.")
    public var nameContains: String?

    @Guide(description: "Kind of file.", .anyOf(["documents", "images", "installers", "archives", "video", "audio", "other"]))
    public var typeGroup: String?

    @Guide(description: "Added on or after this day.")
    public var addedOnOrAfter: String?

    @Guide(description: "Added on or before this day.")
    public var addedOnOrBefore: String?

    @Guide(description: "Last opened on or after this day.")
    public var openedOnOrAfter: String?

    @Guide(description: "Last opened on or before this day.")
    public var openedOnOrBefore: String?

    @Guide(description: "true for files never opened.")
    public var neverOpened: Bool?

    @Guide(description: "Only files of this many MB or more.")
    public var largerThanMB: Double?

    @Guide(description: "Only files of this many MB or less.")
    public var smallerThanMB: Double?

    @Guide(description: "Site it was downloaded from.")
    public var sourceSite: String?

    @Guide(description: "A mark the app gave it.", .anyOf(["kept", "failedDownload", "installed", "duplicate", "neverOpened", "unused", "old"]))
    public var mark: String?

    public init(
        nameContains: String? = nil, typeGroup: String? = nil, addedOnOrAfter: String? = nil,
        addedOnOrBefore: String? = nil, openedOnOrAfter: String? = nil, openedOnOrBefore: String? = nil,
        neverOpened: Bool? = nil, largerThanMB: Double? = nil, smallerThanMB: Double? = nil,
        sourceSite: String? = nil, mark: String? = nil
    ) {
        self.nameContains = nameContains
        self.typeGroup = typeGroup
        self.addedOnOrAfter = addedOnOrAfter
        self.addedOnOrBefore = addedOnOrBefore
        self.openedOnOrAfter = openedOnOrAfter
        self.openedOnOrBefore = openedOnOrBefore
        self.neverOpened = neverOpened
        self.largerThanMB = largerThanMB
        self.smallerThanMB = smallerThanMB
        self.sourceSite = sourceSite
        self.mark = mark
    }
}

/// Why a filter, a sort or a limit was refused, worded so the model can fix its next call.
public struct FilterError: Error, Sendable, Equatable {
    public let message: String
}

extension FileFilter {
    /// A megabyte as Finder and the app's settings count it.
    static let bytesPerMegabyte = 1_000_000.0

    /// The filter with every field read and checked, or the first problem found.
    public func validated(now: Date) throws(FilterError) -> FileQuery {
        let calendar = DayText.calendar
        var query = FileQuery()
        query.nameContains = nameContains.flatMap { $0.isEmpty ? nil : $0 }
        query.typeGroup = try Self.choice(typeGroup, named: "typeGroup")
        query.mark = try Self.choice(mark, named: "mark")
        query.sourceSite = sourceSite.flatMap(Self.site)

        func day(_ text: String?, named name: String) throws(FilterError) -> Date? {
            guard let text else { return nil }
            guard let date = DayText.startOfDay(text, now: now) else {
                throw FilterError(message: "\(name) \(Self.echo(text)) is not a day. Use YYYY-MM-DD or a number of days back such as \"7 days ago\".")
            }
            return date
        }
        /// Both ends of a range of days, the last day counted in full.
        func days(after: (String?, String), before: (String?, String)) throws(FilterError) -> FileQuery.DateRange {
            let from = try day(after.0, named: after.1)
            let last = try day(before.0, named: before.1)
            if let from, let last, from > last {
                throw FilterError(message: "\(after.1) is later than \(before.1). Swap them or drop one.")
            }
            return FileQuery.DateRange(from: from, before: last.flatMap { calendar.date(byAdding: .day, value: 1, to: $0) })
        }
        query.added = try days(after: (addedOnOrAfter, "addedOnOrAfter"), before: (addedOnOrBefore, "addedOnOrBefore"))
        query.opened = try days(after: (openedOnOrAfter, "openedOnOrAfter"), before: (openedOnOrBefore, "openedOnOrBefore"))
        // Only `true` narrows. A model that writes `false` for "not asked" must not hide every
        // file that was never opened.
        query.neverOpened = neverOpened == true
        if query.neverOpened, !query.opened.isOpen {
            throw FilterError(message: "neverOpened is true, so openedOnOrAfter and openedOnOrBefore cannot be used with it. Drop one.")
        }

        func bytes(_ megabytes: Double?, named name: String) throws(FilterError) -> Int64? {
            guard let megabytes else { return nil }
            // The upper bound keeps the conversion to Int64 from trapping on a nonsense number.
            guard megabytes >= 0, megabytes <= 1e12 else {
                throw FilterError(message: "\(name) must be a size in megabytes, 0 or more.")
            }
            return Int64(megabytes * Self.bytesPerMegabyte)
        }
        // "0 MB or more" is every file, so it narrows nothing (and must not drop folders, which have no size).
        query.minBytes = try bytes(largerThanMB, named: "largerThanMB").flatMap { $0 == 0 ? nil : $0 }
        query.maxBytes = try bytes(smallerThanMB, named: "smallerThanMB")
        if let min = query.minBytes, let max = query.maxBytes, min > max {
            throw FilterError(message: "largerThanMB is above smallerThanMB, so no file can match. Swap them or drop one.")
        }
        return query
    }

    /// One of an enum's raw values, or a message listing them.
    static func choice<Value: RawRepresentable & CaseIterable>(
        _ text: String?, named name: String
    ) throws(FilterError) -> Value? where Value.RawValue == String {
        guard let text else { return nil }
        if let value = Value.allCases.first(where: { $0.rawValue.caseInsensitiveCompare(text) == .orderedSame }) {
            return value
        }
        let allowed = Value.allCases.map(\.rawValue).joined(separator: ", ")
        throw FilterError(message: "\(name) \(echo(text)) is not one of: \(allowed).")
    }

    /// The model's own text, quoted back short and clean: it may have copied it from a file name.
    private static func echo(_ text: String) -> String {
        "\"\(ToolOutput.cleaned(text, limit: 40))\""
    }

    /// A site as the scan stores it: lower case, no scheme, path or "www.".
    private static func site(_ text: String) -> String? {
        var site = text.trimmingCharacters(in: .whitespaces).lowercased()
        // A whole address has a host; a bare site reads as a path, cut at its first slash.
        site = URLComponents(string: site)?.host ?? String(site.prefix { $0 != "/" })
        if site.hasPrefix("www.") { site.removeFirst(4) }
        return site.isEmpty ? nil : site
    }
}

/// A checked filter. An unset field matches every file.
public struct FileQuery: Sendable, Equatable {
    /// `from` is included, `before` is not.
    public struct DateRange: Sendable, Equatable {
        public var from: Date?
        public var before: Date?

        public init(from: Date? = nil, before: Date? = nil) {
            self.from = from
            self.before = before
        }

        var isOpen: Bool { from == nil && before == nil }

        /// A file with no date is outside every range that has an end.
        func contains(_ date: Date?) -> Bool {
            guard !isOpen else { return true }
            guard let date else { return false }
            return (from.map { date >= $0 } ?? true) && (before.map { date < $0 } ?? true)
        }
    }

    public var nameContains: String?
    public var typeGroup: FileTypeGroup?
    public var added = DateRange()
    public var opened = DateRange()
    /// True for only the files with no recorded open, where macOS would have recorded one.
    public var neverOpened = false
    public var minBytes: Int64?
    public var maxBytes: Int64?
    public var sourceSite: String?
    public var mark: FolderSnapshot.Mark?

    public init() {}

    public func matches(_ file: FolderSnapshot.File) -> Bool {
        if let nameContains, !file.name.localizedStandardContains(nameContains) { return false }
        if let typeGroup, FileTypeGroup(contentType: file.contentType) != typeGroup { return false }
        if !added.contains(file.dateAdded) || !opened.contains(file.lastOpened) { return false }
        if neverOpened, file.lastOpened != nil || !file.recordsOpens { return false }
        if minBytes != nil || maxBytes != nil {
            guard let size = file.sizeInBytes, size >= minBytes ?? 0, size <= maxBytes ?? .max else { return false }
        }
        if let sourceSite {
            guard let site = file.sourceSite else { return false }
            // A whole site matches itself and its subdomains. A bare name, as people say it
            // ("github"), matches any part of the site's name.
            let matches = sourceSite.contains(".")
                ? site == sourceSite || site.hasSuffix("." + sourceSite)
                : site.split(separator: ".").contains { $0 == sourceSite }
            guard matches else { return false }
        }
        if let mark, !file.marks.contains(mark) { return false }
        return true
    }
}

/// The order of a list of files. A file without the value sorted on comes last, and ties go by name.
public enum FileSort: String, Sendable, CaseIterable {
    // Not "oldest": with that value on offer, the model's guardrail refused "What is the oldest
    // file here?" every time, and answered it with "earliest" (measured: docs/decisions/0020).
    case largest, smallest, newest, earliest, recentlyOpened, leastRecentlyOpened, name

    public func sorted(_ files: [FolderSnapshot.File]) -> [FolderSnapshot.File] {
        func byName(_ a: FolderSnapshot.File, _ b: FolderSnapshot.File) -> Bool {
            let order = a.name.localizedStandardCompare(b.name)
            return order == .orderedSame ? a.id.path < b.id.path : order == .orderedAscending
        }
        func by<Value: Comparable>(_ value: (FolderSnapshot.File) -> Value?, descending: Bool) -> [FolderSnapshot.File] {
            files.sorted { a, b in
                switch (value(a), value(b)) {
                case let (x?, y?) where x != y: descending ? x > y : x < y
                case (_?, nil): true
                case (nil, _?): false
                default: byName(a, b)
                }
            }
        }
        return switch self {
        case .largest: by(\.sizeInBytes, descending: true)
        case .smallest: by(\.sizeInBytes, descending: false)
        case .newest: by(\.dateAdded, descending: true)
        case .earliest: by(\.dateAdded, descending: false)
        case .recentlyOpened: by(\.lastOpened, descending: true)
        case .leastRecentlyOpened: by(\.lastOpened, descending: false)
        case .name: files.sorted(by: byName)
        }
    }
}
