import FileStoreCore
import Foundation
import Testing

/// Review Near-Duplicates' planner on records built by hand, with made-up hashes: which files share
/// a cleaned name, how identical content is folded together, and what takes no part. Nothing here
/// reads the disk.
@Suite("Near-duplicate planner")
struct NearDuplicatePlannerTests {
    private static let now = Date(timeIntervalSince1970: 1_800_000_000)
    private static let day: TimeInterval = 24 * 60 * 60
    private static let folder = URL(filePath: "/FakeDownloads", directoryHint: .isDirectory)

    private func record(_ name: String, kind: FileRecord.Kind = .file, size: Int64 = 10, age: TimeInterval = 2 * day) -> FileRecord {
        let url = Self.folder.appending(path: name, directoryHint: kind == .file ? .notDirectory : .isDirectory)
        return FileRecord(
            url: url,
            displayName: name,
            kind: kind,
            localizedTypeDescription: nil,
            contentType: nil,
            sizeInBytes: kind == .file ? size : nil,
            dateAdded: Self.now - age,
            dateModified: Self.now - age,
            isDownloading: FileRecord.isInProgressDownload(url)
        )
    }

    private func hash(_ byte: UInt8) -> ContentHash {
        ContentHash(bytes: Array(repeating: byte, count: 32))
    }

    /// The plan for `contents` (name to a content number), with the candidates `planner` allows.
    private func plan(
        _ records: [FileRecord],
        contents: [String: UInt8],
        planner: NearDuplicatePlanner = NearDuplicatePlanner()
    ) -> CleanupPlan {
        let candidates = planner.candidates(in: records, folder: .temporary(Self.folder), now: Self.now)
        var hashes: [FileRecord.ID: ContentHash] = [:]
        for record in candidates {
            if let byte = contents[record.displayName] {
                hashes[record.id] = hash(byte)
            }
        }
        return NearDuplicatePlanner.makePlan(
            folder: .temporary(Self.folder),
            nameGroups: NearDuplicatePlanner.nameGroups(of: candidates, caseSensitive: false),
            hashes: hashes
        )
    }

    private func memberNames(_ plan: CleanupPlan) -> [[String]] {
        plan.nearDuplicateGroups.map { $0.members.map(\.record.displayName) }
    }

    @Test func filesWithTheSameCleanedNameAndDifferentContentFormAGroup() {
        let records = [record("report.pdf"), record("report (1).pdf"), record("other.pdf")]
        let plan = plan(records, contents: ["report.pdf": 1, "report (1).pdf": 2, "other.pdf": 3])

        #expect(plan.action == .reviewNearDuplicates)
        #expect(memberNames(plan) == [["report (1).pdf", "report.pdf"]])
        #expect(plan.nearDuplicateGroups.first?.cleanedName == "report.pdf")
        #expect(plan.duplicateGroups.isEmpty)
        #expect(plan.changes.map(\.record.displayName) == ["report (1).pdf", "report.pdf"])
        #expect(plan.changes.allSatisfy { $0.operation == .moveToTrash })
        #expect(plan.changes.map(\.reason) == [.nearDuplicate(sameNameAs: "report.pdf"), .nearDuplicate(sameNameAs: "report (1).pdf")])
    }

    @Test func nothingIsPreselectedOrChosenToStay() {
        let plan = plan([record("a.txt"), record("a copy.txt"), record("a (2).txt")], contents: ["a.txt": 1, "a copy.txt": 2, "a (2).txt": 3])

        #expect(plan.changes.count == 3)
        #expect(plan.changes.allSatisfy { $0.reason.isReviewOnly })
        #expect(plan.changes.allSatisfy { !$0.reason.isPossibleMatch })
        #expect(plan.duplicateGroups.isEmpty, "no kept file is chosen")
    }

    @Test func differentExtensionsNeverMatch() {
        let records = [record("todo.txt"), record("todo (1).md"), record("photo.jpg"), record("photo (1).jpeg")]
        let plan = plan(records, contents: ["todo.txt": 1, "todo (1).md": 2, "photo.jpg": 3, "photo (1).jpeg": 4])

        #expect(plan.isEmpty)
        #expect(plan.nearDuplicateGroups.isEmpty)
    }

    @Test func namesMatchInAnyLetterCaseOnACaseInsensitiveVolume() {
        let records = [record("Report.PDF"), record("report (1).PDF")]
        let candidates = NearDuplicatePlanner().candidates(in: records, folder: .temporary(Self.folder), now: Self.now)

        #expect(NearDuplicatePlanner.nameGroups(of: candidates, caseSensitive: false).count == 1)
        #expect(NearDuplicatePlanner.nameGroups(of: candidates, caseSensitive: true).isEmpty)
    }

    @Test func identicalCopiesAreShownOnceWithTheirCount() throws {
        let records = [record("report.pdf", age: 3 * Self.day), record("report (1).pdf"), record("report copy.pdf"), record("report (2).pdf")]
        let plan = plan(records, contents: ["report.pdf": 1, "report (1).pdf": 1, "report copy.pdf": 1, "report (2).pdf": 2])

        let group = try #require(plan.nearDuplicateGroups.first)
        #expect(group.members.map(\.record.displayName) == ["report (2).pdf", "report.pdf"])
        // The copy Find Duplicates would keep stands for its identical copies.
        let shown = group.members.first { $0.record.displayName == "report.pdf" }
        #expect(shown?.identicalCopies.map(\.displayName) == ["report (1).pdf", "report copy.pdf"])
        #expect(group.members.first?.identicalCopies.isEmpty == true)
        #expect(plan.changes.map(\.record.displayName) == ["report (2).pdf", "report.pdf"])
    }

    @Test func filesThatAreAllIdenticalAreNoGroup() {
        let plan = plan([record("report.pdf"), record("report (1).pdf")], contents: ["report.pdf": 1, "report (1).pdf": 1])

        #expect(plan.isEmpty)
        #expect(plan.nearDuplicateGroups.isEmpty)
    }

    @Test func aFileWhoseNameNoOtherFileSharesIsNoGroup() {
        let records = [record("report.pdf"), record("invoice.pdf"), record("invoice copy.docx")]

        #expect(NearDuplicatePlanner.nameGroups(of: records, caseSensitive: false).isEmpty)
        #expect(plan(records, contents: ["report.pdf": 1, "invoice.pdf": 2, "invoice copy.docx": 3]).isEmpty)
    }

    @Test func emptyInputGivesAnEmptyPlan() {
        let plan = plan([], contents: [:])

        #expect(plan.isEmpty)
        #expect(plan.nearDuplicateGroups.isEmpty)
        #expect(plan.skippedItems.isEmpty)
    }

    @Test func keptFilesTakeNoPart() {
        let kept = record("notes.txt")
        let records = [kept, record("notes (1).txt"), record("draft.txt"), record("draft (1).txt"), record("draft (2).txt")]
        let planner = NearDuplicatePlanner(
            eligibility: CandidateEligibility(keptItems: KeptItems([KeptItem(identity: nil, path: kept.keptItemPath, keptAt: Self.now)]))
        )

        let plan = plan(records, contents: ["notes.txt": 1, "notes (1).txt": 2, "draft.txt": 3, "draft (1).txt": 4, "draft (2).txt": 5], planner: planner)

        // With the Kept file out, its partner has no group left.
        #expect(memberNames(plan) == [["draft (1).txt", "draft (2).txt", "draft.txt"]])
        #expect(!plan.changes.contains { $0.record.displayName.hasPrefix("notes") })
    }

    @Test func foldersLinksHiddenFilesDownloadsAndNewFilesTakeNoPart() {
        let records = [
            record("photos"), record("photos (1)", kind: .folder), record("app (1).app", kind: .package), record("app.app"),
            record("link.txt"), record("link (1).txt", kind: .symlink),
            record(".secret"), record(".secret (1)"),
            record("movie.mp4.crdownload"), record("movie (1).mp4.crdownload"),
            record("fresh.txt", age: 60), record("fresh (1).txt"),
        ]
        let candidates = NearDuplicatePlanner().candidates(in: records, folder: .temporary(Self.folder), now: Self.now)

        #expect(NearDuplicatePlanner.nameGroups(of: candidates, caseSensitive: false).isEmpty)
    }

    @Test func aFileThatCouldNotBeReadIsLeftOutOfItsGroup() {
        let records = [record("a.txt"), record("a (1).txt"), record("a (2).txt")]
        // a (2).txt has no hash: the driver lists it as not checked.
        let plan = plan(records, contents: ["a.txt": 1, "a (1).txt": 2])

        #expect(memberNames(plan) == [["a (1).txt", "a.txt"]])
    }

    @Test func takingAFileOutOfAPairTakesThePairOut() throws {
        let records = [record("a.txt"), record("a (1).txt"), record("b.txt"), record("b (1).txt"), record("b (2).txt")]
        let plan = plan(records, contents: ["a.txt": 1, "a (1).txt": 2, "b.txt": 3, "b (1).txt": 4, "b (2).txt": 5])
        let aCopy = try #require(plan.changes.first { $0.record.displayName == "a (1).txt" })
        let bCopy = try #require(plan.changes.first { $0.record.displayName == "b (1).txt" })

        let left = plan.removing([aCopy.id, bCopy.id])

        #expect(left.nearDuplicateGroups.map { $0.members.map(\.record.displayName) } == [["b (2).txt", "b.txt"]])
        #expect(left.changes.map(\.record.displayName) == ["b (2).txt", "b.txt"])
    }
}
