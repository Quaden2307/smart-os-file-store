import FileStoreCore
import Foundation
import Testing

/// The pure half of the planner: grouping, the keep rule and the plan's contents, with no disk.
@Suite("DuplicatePlanner (pure)")
struct DuplicatePlannerTests {
    private static let folder = URL(filePath: "/FakeDownloads", directoryHint: .isDirectory)
    private static let base = Date(timeIntervalSince1970: 1_700_000_000)

    private let planner = DuplicatePlanner()

    private func record(
        _ name: String,
        size: Int64? = 21,
        kind: FileRecord.Kind = .file,
        added: Date? = DuplicatePlannerTests.base,
        modified: Date? = DuplicatePlannerTests.base,
        downloading: Bool = false
    ) -> FileRecord {
        FileRecord(
            url: Self.folder.appending(path: name),
            displayName: name,
            kind: kind,
            localizedTypeDescription: nil,
            contentType: nil,
            sizeInBytes: size,
            dateAdded: added,
            dateModified: modified,
            isDownloading: downloading
        )
    }

    private func hash(_ value: UInt8) -> ContentHash {
        ContentHash(bytes: [UInt8](repeating: value, count: 32))
    }

    private func hashes(_ records: [FileRecord], _ value: UInt8 = 1) -> [FileRecord.ID: ContentHash] {
        Dictionary(records.map { ($0.id, hash(value)) }, uniquingKeysWith: { first, _ in first })
    }

    private func makePlan(_ records: [FileRecord], hashes: [FileRecord.ID: ContentHash]) -> CleanupPlan {
        DuplicatePlanner.makePlan(folder: .temporary(Self.folder), records: records, hashes: hashes, keptItems: KeptItems())
    }

    private func permutations<T>(of items: [T]) -> [[T]] {
        guard items.count > 1 else { return [items] }
        return items.indices.flatMap { index -> [[T]] in
            var rest = items
            let item = rest.remove(at: index)
            return permutations(of: rest).map { [item] + $0 }
        }
    }

    // MARK: Keep rule

    @Test func keepsCleanNameInEveryInputOrder() {
        // The clean name is the newest, to show that the name beats age.
        let group = [
            record("report.pdf", added: Self.base + 30),
            record("report (1).pdf", added: Self.base),
            record("report (2).pdf", added: Self.base + 10),
            record("report copy.pdf", added: Self.base + 20),
        ]
        let allHashes = hashes(group)
        let orders = permutations(of: group)
        #expect(orders.count == 24)
        for order in orders {
            #expect(DuplicatePlanner.keptFile(among: order)?.displayName == "report.pdf")
            let plan = makePlan(order, hashes: allHashes)
            #expect(plan.duplicateGroups.count == 1)
            #expect(plan.duplicateGroups.first?.kept.displayName == "report.pdf")
            #expect(plan.changes.count == 3)
            #expect(plan.changes.allSatisfy { $0.reason == .sameContent(asFileNamed: "report.pdf") })
            #expect(!plan.changes.contains { $0.record.displayName == "report.pdf" })
        }
    }

    @Test func allSuffixedGroupKeepsOldestDateAdded() {
        let group = [
            record("report (1).pdf", added: Self.base + 20),
            record("report (2).pdf", added: Self.base),
            record("report copy.pdf", added: Self.base + 10),
        ]
        for order in permutations(of: group) {
            #expect(DuplicatePlanner.keptFile(among: order)?.displayName == "report (2).pdf")
        }
    }

    @Test func dateTieFallsBackToName() {
        let group = [record("IMG_4021.jpg"), record("beach.jpg")]
        for order in permutations(of: group) {
            #expect(DuplicatePlanner.keptFile(among: order)?.displayName == "beach.jpg")
        }
    }

    @Test func missingDateAddedUsesDateModified() {
        let undatedButOld = record("scan.pdf", added: nil, modified: Self.base)
        let dated = record("photo.pdf", added: Self.base + 10, modified: Self.base + 10)
        for order in permutations(of: [undatedButOld, dated]) {
            #expect(DuplicatePlanner.keptFile(among: order)?.displayName == "scan.pdf")
        }

        let undatedButNew = record("scan.pdf", added: nil, modified: Self.base + 20)
        for order in permutations(of: [undatedButNew, dated]) {
            #expect(DuplicatePlanner.keptFile(among: order)?.displayName == "photo.pdf")
        }
    }

    @Test func missingBothDatesSortsLast() {
        let undated = record("a.pdf", added: nil, modified: nil)
        let dated = record("z.pdf", added: Self.base + 100, modified: Self.base + 100)
        for order in permutations(of: [undated, dated]) {
            #expect(DuplicatePlanner.keptFile(among: order)?.displayName == "z.pdf")
        }

        let otherUndated = record("b.pdf", added: nil, modified: nil)
        for order in permutations(of: [otherUndated, undated]) {
            #expect(DuplicatePlanner.keptFile(among: order)?.displayName == "a.pdf")
        }
    }

    // MARK: Grouping

    @Test func singleFileAndEmptyInputGiveEmptyPlan() {
        let single = [record("report.pdf")]
        let plan = makePlan(single, hashes: hashes(single))
        #expect(plan.isEmpty)
        #expect(plan.duplicateGroups.isEmpty)
        #expect(plan.bytesToFree == 0)

        let empty = makePlan([], hashes: [:])
        #expect(empty.isEmpty)
        #expect(empty.duplicateGroups.isEmpty)
        #expect(empty.action == .findDuplicates)
        #expect(DuplicatePlanner.keptFile(among: []) == nil)
    }

    @Test func sameSizeDifferentHashIsNotGrouped() {
        let a = record("same-size-a.bin", size: 4)
        let b = record("same-size-b.bin", size: 4)
        let plan = makePlan([a, b], hashes: [a.id: hash(1), b.id: hash(2)])
        #expect(plan.isEmpty)
        #expect(plan.duplicateGroups.isEmpty)
    }

    @Test func sameNamePatternDifferentHashIsNotGrouped() {
        let notes = record("notes.txt", size: 9)
        let edited = record("notes (1).txt", size: 17)
        #expect(makePlan([notes, edited], hashes: [notes.id: hash(1), edited.id: hash(2)]).isEmpty)

        let sameSizeEdit = record("notes (1).txt", size: 9)
        #expect(makePlan([notes, sameSizeEdit], hashes: [notes.id: hash(1), sameSizeEdit.id: hash(2)]).isEmpty)
    }

    @Test func candidatesExcludeNonFilesDownloadsEmptyFreshAndArchive() {
        // Two hours after every record's default dates, so only the dates set below are recent.
        let now = Self.base + 2 * 3_600
        let hour = CandidateEligibility.defaultGracePeriod
        let records = [
            record("Folder", size: nil, kind: .folder),
            record("App.app", size: nil, kind: .package),
            record("link.pdf", size: 10, kind: .symlink),
            record("movie.mp4.crdownload", downloading: true),
            record("empty.txt", size: 0),
            record("sizeless.txt", size: nil),
            record("modified-recently.pdf", modified: now - (hour - 0.5)),
            record("added-recently.pdf", added: now - 60),
            record("undated.pdf", modified: nil),
            record(".hidden.pdf"),
            record("Old downloads"),
            record("settled.pdf", modified: now - (hour + 0.5)),
            record("boundary.pdf", added: now - hour, modified: now - hour),
            record("no-date-added.pdf", added: nil),
        ]
        let names = Set(planner.candidates(in: records, folder: .temporary(Self.folder), now: now).map(\.displayName))
        #expect(names == ["settled.pdf", "boundary.pdf", "no-date-added.pdf"])
    }

    @Test func candidatesFollowTheConfiguredGracePeriod() {
        let now = Self.base + 2 * 3_600
        let fresh = record("fresh.pdf", added: now - 5, modified: now - 5)
        let shortened = DuplicatePlanner(eligibility: CandidateEligibility(gracePeriod: 0))
        #expect(planner.candidates(in: [fresh], folder: .temporary(Self.folder), now: now).isEmpty)
        #expect(shortened.candidates(in: [fresh], folder: .temporary(Self.folder), now: now).map(\.displayName) == ["fresh.pdf"])
    }

    @Test func sizeGroupsOnlyKeepSharedSizes() {
        let records = [
            record("one.bin", size: 1),
            record("two-a.bin", size: 2), record("two-b.bin", size: 2),
            record("three-a.bin", size: 3), record("three-b.bin", size: 3), record("three-c.bin", size: 3),
            record("four.bin", size: 4),
            record("Folder", size: nil, kind: .folder),
        ]
        let groups = DuplicatePlanner.sizeGroups(of: records)
        #expect(groups.map(\.count) == [2, 3])
        #expect(groups.map { $0.first?.sizeInBytes } == [2, 3])
    }

    // MARK: Plan contents

    @Test func planRecordsReasonSizeDateAndOriginalPath() throws {
        let kept = record("report.pdf", added: Self.base, modified: Self.base - 5)
        let copy = record("report (1).pdf", added: Self.base + 1, modified: Self.base - 3)
        let plan = makePlan([copy, kept], hashes: hashes([kept, copy]))

        #expect(plan.action == .findDuplicates)
        #expect(plan.folderURL == Self.folder)
        #expect(plan.skippedItems.isEmpty)
        #expect(plan.changes.count == 1)
        let change = try #require(plan.changes.first)
        #expect(change.record == copy)
        #expect(change.id == copy.url)
        #expect(change.operation == .moveToTrash)
        #expect(change.reason == .sameContent(asFileNamed: "report.pdf"))
        #expect(change.sizeInBytes == 21)
        #expect(change.dateModified == Self.base - 3)
        #expect(change.originalPath == "/FakeDownloads/report (1).pdf")
        #expect(plan.bytesToFree == 21)

        let group = plan.duplicateGroups.first
        #expect(group?.kept == kept)
        #expect(group?.duplicates == [copy])
        #expect(group?.fileSizeInBytes == 21)
        #expect(group?.reclaimableBytes == 21)
        #expect(group?.id == hash(1))
    }

    @Test func groupsOrderedByReclaimableBytesAndChangesFlattened() {
        let groupA = [record("a.pdf", size: 5), record("a (1).pdf", size: 5)]
        let groupB = [record("b.pdf", size: 4), record("b (2).pdf", size: 4), record("b (1).pdf", size: 4)]
        var allHashes = hashes(groupA, 1)
        allHashes.merge(hashes(groupB, 2), uniquingKeysWith: { first, _ in first })

        let plan = makePlan(groupB + groupA, hashes: allHashes)

        #expect(plan.duplicateGroups.map(\.kept.displayName) == ["b.pdf", "a.pdf"])
        #expect(plan.duplicateGroups.map(\.reclaimableBytes) == [8, 5])
        #expect(plan.duplicateGroups.first?.duplicates.map(\.displayName) == ["b (1).pdf", "b (2).pdf"])
        #expect(plan.changes.map(\.record.displayName) == ["b (1).pdf", "b (2).pdf", "a (1).pdf"])
        #expect(plan.bytesToFree == 13)
    }
}
