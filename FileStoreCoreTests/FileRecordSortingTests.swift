import FileStoreCore
import Foundation
import Testing

/// The keyed sort gives exactly the order `sorted(using:)` gives with the comparators the file table
/// uses, in both directions, with nils, ties and several keys.
@Suite("FileRecordSorting")
struct FileRecordSortingTests {
    private static let base = Date(timeIntervalSince1970: 1_800_000_000)

    /// Names Finder orders differently from plain text order (numbers, case, accents), with dates and
    /// sizes that repeat and are sometimes missing, so ties and nils are exercised.
    private static let records: [FileRecord] = {
        let names = [
            "file10.txt", "file2.txt", "File1.txt", "résumé.pdf", "resume.pdf", "Zebra.png", "apple.png",
            "file 2.txt", "file02.txt", "_notes.md", "Ärger.doc", "zeta.zip", "IMG_0010.jpg", "img_0009.jpg",
            "report (1).pdf", "report.pdf", "report (10).pdf", "report (2).pdf", "Résumé.pdf", "a", "A", "b",
        ]
        return names.enumerated().map { index, name in
            let url = URL(filePath: "/FakeDownloads").appending(path: name)
            return FileRecord(
                url: url,
                displayName: name,
                kind: index % 5 == 0 ? .folder : .file,
                localizedTypeDescription: index % 3 == 0 ? "Folder" : "Document",
                contentType: nil,
                sizeInBytes: index % 4 == 0 ? nil : Int64(index % 6) * 100,
                dateAdded: index % 7 == 0 ? nil : base.addingTimeInterval(Double((index * 37) % 9) * 60),
                dateModified: base.addingTimeInterval(Double(index % 3) * 60),
                isDownloading: false,
                lastOpened: index % 2 == 0 ? nil : base.addingTimeInterval(Double(index) * 3_600)
            )
        }
    }()

    private func names(_ records: [FileRecord]) -> [String] {
        records.map(\.displayName)
    }

    @Test(arguments: [SortOrder.forward, .reverse])
    func textMatchesFindersOrder(order: SortOrder) {
        let expected = Self.records.sorted(using: [KeyPathComparator(\FileRecord.displayName, comparator: .localizedStandard, order: order)])
        let actual = FileRecordSorting.sorted(Self.records, by: [.text(\.displayName, order: order)])
        #expect(names(actual) == names(expected))
    }

    @Test(arguments: [SortOrder.forward, .reverse])
    func optionalValuesMatchKeyPathComparator(order: SortOrder) {
        let byAdded = Self.records.sorted(using: [KeyPathComparator(\FileRecord.dateAdded, order: order)])
        #expect(names(FileRecordSorting.sorted(Self.records, by: [.value(\.dateAdded, order: order)])) == names(byAdded))

        let bySize = Self.records.sorted(using: [KeyPathComparator(\FileRecord.sizeInBytes, order: order)])
        #expect(names(FileRecordSorting.sorted(Self.records, by: [.value(\.sizeInBytes, order: order)])) == names(bySize))

        let byOpened = Self.records.sorted(using: [KeyPathComparator(\FileRecord.lastOpened, order: order)])
        #expect(names(FileRecordSorting.sorted(Self.records, by: [.value(\.lastOpened, order: order)])) == names(byOpened))
    }

    /// Nil comes first going forward and last in reverse, so "Never" sorts as the oldest.
    @Test func nilsComeFirstForward() throws {
        let forward = FileRecordSorting.sorted(Self.records, by: [.value(\.lastOpened, order: .forward)])
        let reverse = FileRecordSorting.sorted(Self.records, by: [.value(\.lastOpened, order: .reverse)])
        #expect(try #require(forward.first).lastOpened == nil)
        #expect(try #require(reverse.last).lastOpened == nil)
    }

    @Test(arguments: [SortOrder.forward, .reverse])
    func plainValuesMatchKeyPathComparator(order: SortOrder) {
        let expected = Self.records.sorted(using: [KeyPathComparator(\FileRecord.isDownloadingRank, order: order)])
        let actual = FileRecordSorting.sorted(Self.records, by: [.value(\.isDownloadingRank, order: order)])
        #expect(names(actual) == names(expected))

        let byModified = Self.records.sorted(using: [KeyPathComparator(\FileRecord.modifiedOrDistantPast, order: order)])
        #expect(names(FileRecordSorting.sorted(Self.records, by: [.value(\.modifiedOrDistantPast, order: order)])) == names(byModified))
    }

    /// Records equal on the first key are ordered by the next, then keep their input order.
    @Test func laterKeysBreakTies() {
        let expected = Self.records.sorted(using: [
            KeyPathComparator(\FileRecord.dateModified, order: .reverse),
            KeyPathComparator(\FileRecord.sizeInBytes),
        ])
        let actual = FileRecordSorting.sorted(Self.records, by: [.value(\.dateModified, order: .reverse), .value(\.sizeInBytes, order: .forward)])
        #expect(names(actual) == names(expected))
    }

    @Test func equalKeysKeepInputOrder() {
        let actual = FileRecordSorting.sorted(Self.records, by: [.value(\.isDownloadingRank, order: .forward)])
        #expect(names(actual) == names(Self.records))
        #expect(names(FileRecordSorting.sorted(Self.records, by: [])) == names(Self.records))
    }

    /// The app picks a key only for a comparator equal to one of its columns' (FileListSort), and
    /// counts on equality to tell the comparator inside apart, not only the key path and direction.
    @Test func comparatorEqualityCoversTheComparatorInside() {
        let finderOrder = KeyPathComparator(\FileRecord.displayName, comparator: String.StandardComparator.localizedStandard)
        #expect(finderOrder == KeyPathComparator(\FileRecord.displayName, comparator: String.StandardComparator.localizedStandard))
        #expect(finderOrder != KeyPathComparator(\FileRecord.displayName, comparator: String.StandardComparator.localized))
        #expect(finderOrder != KeyPathComparator(\FileRecord.displayName, comparator: String.StandardComparator.lexical))
        var reversed = finderOrder
        reversed.order = .reverse
        #expect(reversed != finderOrder)
        reversed.order = .forward
        #expect(reversed == finderOrder)
        #expect(KeyPathComparator(\FileRecord.dateAdded) != KeyPathComparator(\FileRecord.dateModified))
    }

    @Test func emptyInputGivesEmptyOutput() {
        #expect(FileRecordSorting.sorted([], by: [.text(\.displayName, order: .forward)]).isEmpty)
    }
}

private extension FileRecord {
    /// The same for every record in the test data, for ties.
    var isDownloadingRank: Int { isDownloading ? 1 : 0 }

    var modifiedOrDistantPast: Date { dateModified ?? .distantPast }
}
