import FileStoreCore
import Foundation
import Testing
import UniformTypeIdentifiers

/// Remove Unpacked Zips' planner on records built by hand: which zips may take part, which items
/// may be what one was unpacked to, and the plan the findings make.
@Suite("Unpacked zip planner")
struct UnpackedZipPlannerTests {
    private static let now = Date(timeIntervalSince1970: 1_800_000_000)
    private static let folder = URL(filePath: "/FakeDownloads", directoryHint: .isDirectory)
    private static let settled: TimeInterval = 2 * 60 * 60

    private let planner = UnpackedZipPlanner()

    /// An item `age` old by both dates, whose type is the one its name gives unless `type` says otherwise.
    private func record(_ name: String, kind: FileRecord.Kind = .file, age: TimeInterval = settled, type: UTType?? = .none) -> FileRecord {
        let pathExtension = URL(filePath: name, directoryHint: .notDirectory).pathExtension
        return FileRecord(
            url: Self.folder.appending(path: name, directoryHint: kind == .file ? .notDirectory : .isDirectory),
            displayName: name,
            kind: kind,
            localizedTypeDescription: nil,
            contentType: type ?? (kind == .folder ? .folder : UTType(filenameExtension: pathExtension)),
            sizeInBytes: kind == .file || kind == .symlink ? 100 : nil,
            dateAdded: Self.now - age,
            dateModified: Self.now - age,
            isDownloading: FileRecord.isInProgressDownload(name: name)
        )
    }

    private func names(_ records: [FileRecord]) -> [String] {
        records.map(\.displayName)
    }

    private func keeping(_ records: [FileRecord]) -> UnpackedZipPlanner {
        let list = KeptItems(records.map { KeptItem(identity: $0.persistentIdentity, path: $0.keptItemPath, keptAt: Self.now) })
        return UnpackedZipPlanner(eligibility: CandidateEligibility(keptItems: list))
    }

    // MARK: - Which zips take part

    @Test func aSettledZipIsACandidate() {
        #expect(names(planner.candidates(in: [record("project.zip"), record("ARCHIVE.ZIP")], folder: .temporary(Self.folder), now: Self.now)) == ["project.zip", "ARCHIVE.ZIP"])
    }

    @Test func aZipInsideTheGracePeriodIsNot() {
        let hour: TimeInterval = 60 * 60
        let records = [record("fresh.zip", age: 10 * 60), record("edge.zip", age: hour), record("almost.zip", age: hour - 1)]

        #expect(names(planner.candidates(in: records, folder: .temporary(Self.folder), now: Self.now)) == ["edge.zip"])
    }

    @Test func aKeptZipIsNot() {
        let kept = record("kept.zip")
        let planner = keeping([kept])

        #expect(names(planner.candidates(in: [kept, record("other.zip")], folder: .temporary(Self.folder), now: Self.now)) == ["other.zip"])
    }

    @Test func hiddenLinkedAndFolderZipsAreNot() {
        let records = [
            record(".hidden.zip"),
            record("link.zip", kind: .symlink),
            record("folder.zip", kind: .folder, type: .folder),
            record("Old downloads.zip"),
        ]

        #expect(names(planner.candidates(in: records, folder: .temporary(Self.folder), now: Self.now)) == ["Old downloads.zip"])
    }

    @Test func formatsBuiltOnZipAreNotZipsHere() {
        let records = [record("tool.jar"), record("contract.docx"), record("book.epub"), record("app.ipa"), record("slides.key")]

        #expect(planner.candidates(in: records, folder: .temporary(Self.folder), now: Self.now).isEmpty)
    }

    @Test func theTypeMustBeZipByTheScanAndByTheName() {
        // A zip by its scanned type alone, or by its name alone, is left out.
        let records = [record("archive", type: .zip), record("named.zip", type: .data)]

        #expect(planner.candidates(in: records, folder: .temporary(Self.folder), now: Self.now).isEmpty)
    }

    @Test func noRecordsMeansNoCandidates() {
        #expect(planner.candidates(in: [], folder: .temporary(Self.folder), now: Self.now).isEmpty)
    }

    // MARK: - What may hold an unpacked zip

    @Test func anyItemOfAnyKindMayBeTheCopy() {
        let records = [record("project", kind: .folder), record("contract.docx"), record("Report.pages", kind: .package), record("latest", kind: .symlink)]

        #expect(names(UnpackedZipPlanner.unpackedCopies(in: records, folder: .temporary(Self.folder))) == ["project", "contract.docx", "Report.pages", "latest"])
    }

    @Test func aHiddenInProgressOrArchiveItemNeverIs() {
        let records = [record(".hidden", kind: .folder), record("movie.mp4.part"), record("Old downloads", kind: .folder)]

        #expect(UnpackedZipPlanner.unpackedCopies(in: records, folder: .temporary(Self.folder)).isEmpty)
    }

    @Test func whetherACopyHasSettledIsLeftToTheDisk() {
        // The scan's dates are not trusted for this: a copy unpacked again since is new. The hour is
        // checked on the item as it is when it is read (`UnpackedZipDiskTests`).
        #expect(names(UnpackedZipPlanner.unpackedCopies(in: [record("just unpacked", kind: .folder, age: 5 * 60)], folder: .temporary(Self.folder))) == ["just unpacked"])
    }

    @Test func aZipNeverIsTheCopyOfAnotherZip() {
        let records = [record("inner.zip"), record("named-like-a-zip.zip", kind: .folder, type: .folder)]

        #expect(UnpackedZipPlanner.unpackedCopies(in: records, folder: .temporary(Self.folder)).isEmpty)
    }

    // MARK: - The plan

    @Test func thePlanListsChangesAndItemsNotCheckedInNameOrder() {
        let findings: [(record: FileRecord, finding: UnpackedZipPlanner.Finding)] = [
            (record("b.zip"), .unpacked(to: "b")),
            (record("damaged.zip"), .notChecked(.zipUnlistable(.damaged))),
            (record("A.zip"), .unpacked(to: "A 2")),
            (record("alone.zip"), .notUnpacked),
            (record("locked.zip"), .notChecked(.accessDenied)),
        ]

        let plan = UnpackedZipPlanner.makePlan(folder: .temporary(Self.folder), findings: findings)

        #expect(plan.action == .removeUnpackedZips)
        #expect(plan.folderURL == Self.folder)
        #expect(UnpackedZips.proposals(plan) == ["A.zip → A 2", "b.zip → b"])
        #expect(plan.changes.allSatisfy { $0.operation == .moveToTrash && !$0.isFolder })
        #expect(plan.skippedItems.map(\.url.lastPathComponent) == ["damaged.zip", "locked.zip"])
        #expect(plan.skippedItems.map(\.reason) == [.zipUnlistable(.damaged), .accessDenied])
        #expect(plan.duplicateGroups.isEmpty)
    }
}
