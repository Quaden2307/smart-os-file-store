import FileStoreCore
import Foundation
import Testing

/// Find Duplicates with files marked Kept: a Kept copy is never proposed and is the copy a group
/// keeps, whatever its name.
@Suite("Kept files and duplicates")
struct KeptDuplicatePlannerTests {
    private static let folder = URL(filePath: "/FakeDownloads", directoryHint: .isDirectory)
    private static let base = Date(timeIntervalSince1970: 1_700_000_000)

    /// Three identical copies. Without Kept, `report.pdf` is kept: the clean name, and the oldest.
    private let group: [FileRecord] = ["report.pdf", "report (1).pdf", "report copy.pdf"].enumerated().map { index, name in
        FileRecord(
            url: KeptDuplicatePlannerTests.folder.appending(path: name),
            displayName: name,
            kind: .file,
            localizedTypeDescription: nil,
            contentType: nil,
            sizeInBytes: 21,
            dateAdded: KeptDuplicatePlannerTests.base + TimeInterval(index),
            dateModified: KeptDuplicatePlannerTests.base,
            isDownloading: false,
            persistentIdentity: PersistentFileIdentity(volumeUUID: "VOLUME", fileNumber: UInt64(100 + index))
        )
    }

    private var hashes: [FileRecord.ID: ContentHash] {
        Dictionary(uniqueKeysWithValues: group.map { ($0.id, ContentHash(bytes: [UInt8](repeating: 1, count: 32))) })
    }

    private func kept(_ records: [FileRecord]) -> KeptItems {
        KeptItems(records.map { KeptItem(identity: $0.persistentIdentity, path: $0.keptItemPath, keptAt: Self.base) })
    }

    private func plan(keeping records: [FileRecord]) -> CleanupPlan {
        DuplicatePlanner.makePlan(folder: .temporary(Self.folder), records: group, hashes: hashes, keptItems: kept(records))
    }

    @Test(arguments: 0..<3)
    func aKeptCopyIsNeverProposedAndIsTheOneKept(position: Int) throws {
        let marked = group[position]
        let plan = plan(keeping: [marked])

        let onlyGroup = try #require(plan.duplicateGroups.first)
        #expect(plan.duplicateGroups.count == 1)
        #expect(onlyGroup.kept.id == marked.id)
        #expect(!plan.changes.contains { $0.id == marked.id })
        #expect(Set(plan.changes.map(\.id)) == Set(group.filter { $0.id != marked.id }.map(\.id)))
        #expect(plan.changes.allSatisfy { $0.reason == .sameContent(asFileNamed: marked.displayName) })
    }

    @Test func withTwoKeptCopiesNeitherIsProposed() throws {
        let marked = [group[1], group[2]]
        let plan = plan(keeping: marked)

        let onlyGroup = try #require(plan.duplicateGroups.first)
        // The keep rule picks among the Kept copies: the older of the two.
        #expect(onlyGroup.kept.id == group[1].id)
        #expect(plan.changes.map(\.id) == [group[0].id])
    }

    @Test func aGroupWhoseCopiesAreAllKeptProposesNothing() {
        let plan = plan(keeping: group)
        #expect(plan.isEmpty)
        #expect(plan.duplicateGroups.isEmpty)
    }

    @Test func theNormalRuleAppliesWhenNothingIsKept() throws {
        let plan = plan(keeping: [])
        #expect(try #require(plan.duplicateGroups.first).kept.id == group[0].id)
        #expect(plan.changes.count == 2)
    }

    // MARK: - On disk

    /// Three identical settled files in a fresh folder, scanned.
    private func scannedCopies(in folder: URL) async throws -> [FileRecord] {
        try FileDates.writeSettled(
            ["report.pdf": "quarterly report body", "report (1).pdf": "quarterly report body", "report copy.pdf": "quarterly report body"],
            in: folder
        )
        return try await RelocationPlans.records(in: folder)
    }

    private func findDuplicates(_ records: [FileRecord], in folder: URL, keeping keptItems: KeptItems) async throws -> CleanupPlan {
        try #require(
            try await CleanupPlanners.plan(.findDuplicates, records: records, in: .temporary(folder), eligibility: CandidateEligibility(), keptItems: keptItems, installers: .testing())
        )
    }

    @Test func onDiskTheKeptCopyIsKeptAndTheOthersAreProposed() async throws {
        let temp = try TemporaryFolder.make()
        defer { temp.remove() }
        let records = try await scannedCopies(in: temp.url)
        let marked = try RelocationPlans.record(named: "report copy.pdf", in: records)
        #expect(marked.persistentIdentity != nil)

        let log = try await ActivityLog.open(.inMemory)
        try await log.keep([marked])
        let plan = try await findDuplicates(records, in: temp.url, keeping: try await log.keptItems(for: log.downloads(at: temp.url)))

        #expect(try #require(plan.duplicateGroups.first).kept.displayName == "report copy.pdf")
        #expect(Set(plan.changes.map(\.record.displayName)) == ["report.pdf", "report (1).pdf"])
    }

    @Test func aKeptFileThatCannotBeReadIsLeftOutRatherThanListedAsUnchecked() async throws {
        let temp = try TemporaryFolder.make()
        defer { temp.remove() }
        let records = try await scannedCopies(in: temp.url)
        let marked = try RelocationPlans.record(named: "report (1).pdf", in: records)
        let unreadable = temp.url.appending(path: "report (1).pdf")
        try FileManager.default.setAttributes([.posixPermissions: 0o000], ofItemAtPath: unreadable.path(percentEncoded: false))
        defer { try? FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: unreadable.path(percentEncoded: false)) }

        let plan = try await findDuplicates(records, in: temp.url, keeping: kept([marked]))

        #expect(plan.skippedItems.isEmpty)
        #expect(!plan.changes.contains { $0.id == marked.id })
        #expect(plan.duplicateGroups.allSatisfy { $0.kept.id != marked.id })
        // The two readable copies still form a group of their own.
        #expect(plan.changes.map(\.record.displayName) == ["report copy.pdf"])
    }

    @Test func aKeptFileInsideTheGracePeriodTakesNoPartAndIsNeverProposed() async throws {
        let temp = try TemporaryFolder.make()
        defer { temp.remove() }
        try FileDates.writeSettled(["report.pdf": "quarterly report body", "report (1).pdf": "quarterly report body"], in: temp.url)
        try Data("quarterly report body".utf8).write(to: temp.url.appending(path: "report copy.pdf"))
        let records = try await RelocationPlans.records(in: temp.url)
        let fresh = try RelocationPlans.record(named: "report copy.pdf", in: records)

        let plan = try await findDuplicates(records, in: temp.url, keeping: kept([fresh]))

        #expect(!plan.changes.contains { $0.id == fresh.id })
        #expect(plan.changes.map(\.record.displayName) == ["report (1).pdf"])
    }

    @Test func aKeptHardLinkKeepsEveryNameOfItsFile() async throws {
        let temp = try TemporaryFolder.make()
        defer { temp.remove() }
        try FileDates.writeSettled(["a.txt": "same bytes", "c.txt": "same bytes"], in: temp.url)
        try FileManager.default.linkItem(at: temp.url.appending(path: "a.txt"), to: temp.url.appending(path: "b.txt"))
        // The new name was just added, so all three are dated back alike, past the grace period.
        let settled = Date(timeIntervalSinceNow: -FileDates.settledAge)
        for name in ["a.txt", "b.txt", "c.txt"] {
            try FileDates.set(temp.url.appending(path: name), to: settled)
        }
        let records = try await RelocationPlans.records(in: temp.url)
        let link = try RelocationPlans.record(named: "b.txt", in: records)

        let plan = try await findDuplicates(records, in: temp.url, keeping: kept([link]))

        // Both names are the one Kept file, so only the separate copy is proposed.
        #expect(plan.changes.map(\.record.displayName) == ["c.txt"])
    }
}
