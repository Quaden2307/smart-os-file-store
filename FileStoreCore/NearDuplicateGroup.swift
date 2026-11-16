import Foundation

/// Files whose cleaned names are equal but whose content differs: `report.pdf` and `report (1).pdf`
/// with different bytes. A review group: no file in it is chosen to stay, and none is proposed
/// ticked. The executor never moves every member of one.
public struct NearDuplicateGroup: Sendable, Hashable, Identifiable {
    /// One distinct content in the group, shown by one file.
    public struct Member: Sendable, Hashable, Identifiable {
        public var id: URL { record.url }

        /// The file shown for this content: the cleanest name, then the oldest.
        public let record: FileRecord

        public let contentHash: ContentHash

        /// Other files in the group with exactly this content. They are not in the plan: identical
        /// files are Find Duplicates' business.
        public let identicalCopies: [FileRecord]

        public init(record: FileRecord, contentHash: ContentHash, identicalCopies: [FileRecord] = []) {
            self.record = record
            self.contentHash = contentHash
            self.identicalCopies = identicalCopies
        }
    }

    public var id: String { cleanedName }

    /// The name every member has once cleaned (`MessyNameCleaner`), as the first member spells it.
    public let cleanedName: String

    /// Two or more members, each with different content, sorted by name.
    public let members: [Member]

    public init(cleanedName: String, members: [Member]) {
        self.cleanedName = cleanedName
        self.members = members
    }

    /// The file that stays when a confirmation names every file of a group, which the preview never
    /// sends: the newest by modification date, then the first by name. Not a recommendation; the
    /// preview never shows it.
    static func spared(among records: [FileRecord]) -> FileRecord? {
        records.max { lhs, rhs in
            let lhsDate = lhs.dateModified ?? .distantPast
            let rhsDate = rhs.dateModified ?? .distantPast
            if lhsDate != rhsDate {
                return lhsDate < rhsDate
            }
            return lhs.displayName.localizedStandardCompare(rhs.displayName) == .orderedDescending
        }
    }
}
