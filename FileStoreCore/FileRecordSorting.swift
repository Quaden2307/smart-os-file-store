import Foundation

/// Sorts records by keys read once per record, in the order `sorted(using:)` gives with the
/// matching comparators.
///
/// `sorted(using:)` reads two key paths through type erasure for every comparison and moves whole
/// records: about 150 ms for 10,000 records on an M1 in a Release build (docs/benchmarks.md). The
/// app sorts on the main actor after every scan and every click on a column header, so it reads each
/// record's key once here and sorts positions on those keys instead.
public enum FileRecordSorting {
    /// One level of a sort: a key read from each record, how two keys compare, and the direction.
    public struct Key {
        /// Reads every record's key, then compares records by position.
        fileprivate let comparison: ([FileRecord]) -> (Int, Int) -> ComparisonResult

        /// Text in Finder's order (`String.StandardComparator.localizedStandard`), as a column made
        /// with `TableColumn(_:value:)` orders it.
        public static func text(_ read: @escaping (FileRecord) -> String, order: SortOrder) -> Key {
            Key { records in
                let keys = records.map(read)
                return { lhs, rhs in
                    oriented(String.StandardComparator.localizedStandard.compare(keys[lhs], keys[rhs]), order)
                }
            }
        }

        /// A comparable value, as `KeyPathComparator(_:order:)` orders it.
        public static func value<Value: Comparable>(_ read: @escaping (FileRecord) -> Value, order: SortOrder) -> Key {
            Key { records in
                let keys = records.map(read)
                return { lhs, rhs in oriented(compare(keys[lhs], keys[rhs]), order) }
            }
        }

        /// An optional comparable value, as `KeyPathComparator(_:order:)` orders it: nil before any
        /// value in forward order, after every value in reverse order.
        public static func value<Value: Comparable>(_ read: @escaping (FileRecord) -> Value?, order: SortOrder) -> Key {
            Key { records in
                let keys = records.map(read)
                return { lhs, rhs in
                    let result: ComparisonResult
                    switch (keys[lhs], keys[rhs]) {
                    case let (left?, right?):
                        result = compare(left, right)
                    case (nil, nil):
                        result = .orderedSame
                    case (nil, _?):
                        result = .orderedAscending
                    case (_?, nil):
                        result = .orderedDescending
                    }
                    return oriented(result, order)
                }
            }
        }
    }

    /// `records` ordered by the first key, ties broken by the next, and so on. Records equal on every
    /// key keep their order, as with `sorted(using:)`.
    public static func sorted(_ records: [FileRecord], by keys: [Key]) -> [FileRecord] {
        let comparisons = keys.map { $0.comparison(records) }
        let positions = records.indices.sorted { lhs, rhs in
            for compare in comparisons {
                switch compare(lhs, rhs) {
                case .orderedAscending:
                    return true
                case .orderedDescending:
                    return false
                case .orderedSame:
                    continue
                }
            }
            return false
        }
        return positions.map { records[$0] }
    }

    private static func compare<Value: Comparable>(_ lhs: Value, _ rhs: Value) -> ComparisonResult {
        if lhs < rhs {
            .orderedAscending
        } else if rhs < lhs {
            .orderedDescending
        } else {
            .orderedSame
        }
    }

    private static func oriented(_ result: ComparisonResult, _ order: SortOrder) -> ComparisonResult {
        guard order == .reverse else {
            return result
        }
        switch result {
        case .orderedAscending:
            return .orderedDescending
        case .orderedDescending:
            return .orderedAscending
        case .orderedSame:
            return .orderedSame
        }
    }
}
