import FileStoreCore
import Foundation
import Testing
import UniformTypeIdentifiers

/// Review Large Downloads' planner, on records alone: which items are listed, in what order, and
/// that none is ticked for the user.
@Suite("LargeFilePlanner")
struct LargeFilePlannerTests {
    private let folder = URL(filePath: "/tmp/LargeFilePlannerTests", directoryHint: .isDirectory)
    private let now = Date(timeIntervalSince1970: 1_800_000_000)
    private let settings = CleanupSettings(largeDownloadMegabytes: 500)

    private func record(
        _ name: String,
        onDisk allocated: Int64?,
        kind: FileRecord.Kind = .file,
        age: TimeInterval = 2 * 60 * 60,
        lastOpened: Date? = nil,
        in parent: URL? = nil
    ) -> FileRecord {
        let date = now.addingTimeInterval(-age)
        return FileRecord(
            url: (parent ?? folder).appending(path: name, directoryHint: kind == .file || kind == .symlink ? .notDirectory : .isDirectory),
            displayName: name,
            kind: kind,
            localizedTypeDescription: nil,
            // An app: macOS records no date when one is opened.
            contentType: kind == .package ? .applicationBundle : nil,
            sizeInBytes: kind == .file ? (allocated ?? 0) + 4_096 : nil,
            dateAdded: date,
            dateModified: date,
            isDownloading: FileRecord.isInProgressDownload(name: name),
            lastOpened: lastOpened,
            allocatedSizeInBytes: allocated
        )
    }

    private func plan(_ records: [FileRecord], eligibility: CandidateEligibility = CandidateEligibility()) -> CleanupPlan {
        LargeFilePlanner(eligibility: eligibility, settings: settings).plan(records: records, in: .temporary(folder), now: now)
    }

    @Test func theThresholdItselfIsLargeAndOneByteLessIsNot() {
        let result = plan([record("at.iso", onDisk: 500_000_000), record("below.iso", onDisk: 499_999_999)])
        #expect(result.changes.map(\.record.displayName) == ["at.iso"])
        #expect(result.action == .reviewLargeDownloads)
    }

    @Test func largestFirstThenByName() {
        let result = plan([
            record("b.mov", onDisk: 600_000_000),
            record("small.zip", onDisk: 1_000),
            record("c.iso", onDisk: 2_000_000_000),
            record("a.mov", onDisk: 600_000_000),
        ])
        #expect(result.changes.map(\.record.displayName) == ["c.iso", "a.mov", "b.mov"])
    }

    @Test func theSizeIsTheSpaceOnDiskNotTheLength() {
        // A long file that takes almost nothing on disk (sparse, or a placeholder) is not large.
        var sparse = record("sparse.img", onDisk: 8_192)
        sparse = FileRecord(
            url: sparse.url, displayName: sparse.displayName, kind: .file, localizedTypeDescription: nil, contentType: nil,
            sizeInBytes: 600_000_000, dateAdded: sparse.dateAdded, dateModified: sparse.dateModified, isDownloading: false,
            allocatedSizeInBytes: 8_192
        )
        #expect(plan([sparse]).isEmpty)
    }

    @Test func aPackageCountsByItsContentsOnDisk() {
        let result = plan([record("Big.app", onDisk: 700_000_000, kind: .package)])
        #expect(result.changes.map(\.record.displayName) == ["Big.app"])
        #expect(result.changes.first?.reason == .largeDownload(sizeOnDisk: 700_000_000, lastOpened: nil, opensRecorded: false))
    }

    @Test func foldersLinksUnknownSizesAndTheSharedRulesAreLeftOut() throws {
        let big: Int64 = 900_000_000
        let kept = record("kept.iso", onDisk: big)
        let records = [
            record("folder", onDisk: big, kind: .folder),
            record("link.iso", onDisk: big, kind: .symlink),
            record("unsized.app", onDisk: nil, kind: .package),
            record(".hidden.iso", onDisk: big),
            record("Old downloads", onDisk: big, kind: .package),
            record("movie.mp4.crdownload", onDisk: big),
            record("fresh.iso", onDisk: big, age: 60),
            record("nested.iso", onDisk: big, in: folder.appending(path: "sub", directoryHint: .isDirectory)),
            kept,
            record("listed.iso", onDisk: big),
        ]
        let eligibility = CandidateEligibility().keeping(KeptItems([KeptItem(identity: nil, path: kept.keptItemPath, keptAt: now)]))
        #expect(plan(records, eligibility: eligibility).changes.map(\.record.displayName) == ["listed.iso"])
    }

    @Test func nothingIsTickedForTheUser() {
        let opened = now.addingTimeInterval(-10 * 24 * 60 * 60)
        let result = plan([record("a.iso", onDisk: 800_000_000, lastOpened: opened), record("b.iso", onDisk: 700_000_000)])
        #expect(result.changes.count == 2)
        #expect(result.changes.allSatisfy { $0.reason.isReviewOnly && !$0.reason.isPossibleMatch })
        #expect(result.changes.allSatisfy { $0.operation == .moveToTrash })
        #expect(result.changes.map(\.reason) == [
            .largeDownload(sizeOnDisk: 800_000_000, lastOpened: opened, opensRecorded: true),
            .largeDownload(sizeOnDisk: 700_000_000, lastOpened: nil, opensRecorded: true),
        ])
    }

    @Test func theFolderTotalCountsEveryTopLevelItemWithAKnownSize() {
        let result = plan([record("a.iso", onDisk: 800_000_000), record("b.txt", onDisk: 200_000_000), record("c", onDisk: nil, kind: .folder)])
        #expect(result.topLevelSizeOnDisk == 1_000_000_000)
        // Taking a change out keeps the total.
        #expect(result.removing([result.changes[0].id]).topLevelSizeOnDisk == 1_000_000_000)
    }

    @Test func noRecordsGiveAnEmptyPlan() {
        #expect(plan([]).isEmpty)
    }
}
