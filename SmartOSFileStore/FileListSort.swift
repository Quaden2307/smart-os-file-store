import FileStoreCore
import Foundation

/// The file table's column comparators, each beside the key `FileRecordSorting` reads for it, so the
/// two are defined once. The table sorts on the main actor after every scan and every header click;
/// `FileRecordSorting` sorts 10,000 rows in about 22 ms where `sorted(using:)` takes about 150 ms
/// (Release, M1; docs/benchmarks.md and decision 0004).
@MainActor
enum FileListSort {
    /// Text columns compare in Finder's order, as `TableColumn(_:value:)` would.
    static let name = KeyPathComparator(\FileRecord.displayName, comparator: String.StandardComparator.localizedStandard)
    static let kind = KeyPathComparator(\FileRecord.kindDescription, comparator: String.StandardComparator.localizedStandard)
    static let size = KeyPathComparator(\FileRecord.sizeInBytes)
    static let dateAdded = KeyPathComparator(\FileRecord.dateAdded)
    static let dateModified = KeyPathComparator(\FileRecord.dateModified)
    /// No date (never opened, or not recorded) comes first going forward: the oldest.
    static let lastOpened = KeyPathComparator(\FileRecord.lastOpened)

    /// The order the window opens with: newest Date Added first.
    static let newestFirst: [KeyPathComparator<FileRecord>] = {
        var comparator = dateAdded
        comparator.order = .reverse
        return [comparator]
    }()

    /// `records` in `sortOrder`. Each comparator equal to a column's, in either direction, is sorted
    /// by that column's key; if any is not, the whole order falls back to `sorted(using:)`. Either way
    /// the result is the order the comparators define.
    static func sorted(_ records: [FileRecord], using sortOrder: [KeyPathComparator<FileRecord>]) -> [FileRecord] {
        let keys = sortOrder.compactMap(key(for:))
        guard keys.count == sortOrder.count else {
            return records.sorted(using: sortOrder)
        }
        return FileRecordSorting.sorted(records, by: keys)
    }

    /// The key for a column's comparator. Equality covers the key path and the comparator inside, so
    /// a column given a different comparator is never sorted by the wrong key.
    private static func key(for comparator: KeyPathComparator<FileRecord>) -> FileRecordSorting.Key? {
        var forward = comparator
        forward.order = .forward
        let order = comparator.order
        switch forward {
        case name:
            return .text(\.displayName, order: order)
        case kind:
            return .text(\.kindDescription, order: order)
        case size:
            return .value(\.sizeInBytes, order: order)
        case dateAdded:
            return .value(\.dateAdded, order: order)
        case dateModified:
            return .value(\.dateModified, order: order)
        case lastOpened:
            return .value(\.lastOpened, order: order)
        default:
            return nil
        }
    }
}
