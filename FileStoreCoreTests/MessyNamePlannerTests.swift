import FileStoreCore
import Foundation
import Testing

/// Fix Messy Names' planner on records built by hand: which files it proposes, how it settles a
/// clean name that is taken, and what it leaves alone. Nothing here reads the disk.
@Suite("Messy name planner")
struct MessyNamePlannerTests {
    private static let now = Date(timeIntervalSince1970: 1_800_000_000) // 2027-01-15 08:00 UTC
    private static let day: TimeInterval = 24 * 60 * 60
    private static let folder = URL(filePath: "/FakeDownloads", directoryHint: .isDirectory)
    private static let utc = TimeZone(identifier: "UTC") ?? .gmt

    private let planner = MessyNamePlanner()

    /// A file `age` old by both dates (two days, so dated 2027-01-13), `size` bytes long.
    private func record(
        _ name: String,
        kind: FileRecord.Kind = .file,
        size: Int64 = 10,
        age: TimeInterval = 2 * day,
        hasDateAdded: Bool = true,
        in folder: URL = Self.folder
    ) -> FileRecord {
        let url = folder.appending(path: name, directoryHint: kind == .file || kind == .symlink ? .notDirectory : .isDirectory)
        return FileRecord(
            url: url,
            displayName: name,
            kind: kind,
            localizedTypeDescription: nil,
            contentType: nil,
            sizeInBytes: kind == .file || kind == .symlink ? size : nil,
            dateAdded: hasDateAdded ? Self.now - age : nil,
            dateModified: Self.now - age,
            isDownloading: FileRecord.isInProgressDownload(url)
        )
    }

    private func plan(
        _ records: [FileRecord],
        identical: Set<String> = [],
        caseSensitive: Bool = false,
        planner: MessyNamePlanner? = nil
    ) -> CleanupPlan {
        let planner = planner ?? self.planner
        return MessyNamePlanner.makePlan(
            folder: .temporary(Self.folder),
            records: records,
            candidates: planner.candidates(in: records, folder: .temporary(Self.folder), now: Self.now),
            identicalTakers: Set(records.filter { identical.contains($0.displayName) }.map(\.id)),
            caseSensitive: caseSensitive,
            timeZone: Self.utc
        )
    }

    /// Each proposed rename, old name to new name.
    private func renames(_ plan: CleanupPlan) -> [String: String] {
        var renames: [String: String] = [:]
        for change in plan.changes {
            if case .rename(to: let newName) = change.operation {
                renames[change.record.displayName] = newName
            }
        }
        return renames
    }

    private func renames(
        _ records: [FileRecord],
        identical: Set<String> = [],
        caseSensitive: Bool = false
    ) -> [String: String] {
        renames(plan(records, identical: identical, caseSensitive: caseSensitive))
    }

    // MARK: - Where the clean name goes

    @Test func aFreeCleanNameIsProposed() throws {
        let plan = plan([record("manual (2).pdf"), record("other.pdf")])
        #expect(renames(plan) == ["manual (2).pdf": "manual.pdf"])
        let change = try #require(plan.changes.first)
        #expect(change.reason == .messyName(MessyNameFix(fixes: [.removedCopySuffix(" (2)")])))
        #expect(plan.action == .fixMessyNames)
        #expect(plan.skippedItems.isEmpty)
    }

    @Test func aCleanNameHeldByAnIdenticalFileProposesNothing() {
        let records = [record("receipt.pdf"), record("receipt (1).pdf")]
        #expect(renames(records, identical: ["receipt (1).pdf"]).isEmpty)
    }

    @Test func aCleanNameHeldByADifferentFileGetsTheDateAdded() throws {
        let plan = plan([record("invoice.pdf"), record("invoice (1).pdf")])
        #expect(renames(plan) == ["invoice (1).pdf": "invoice 2027-01-13.pdf"])
        let change = try #require(plan.changes.first)
        #expect(change.reason == .messyName(MessyNameFix(fixes: [.removedCopySuffix(" (1)")], takenName: "invoice.pdf")))
    }

    @Test func whenTheDatedNameIsTakenTooANumberIsAdded() {
        let records = [record("invoice.pdf"), record("invoice 2027-01-13.pdf"), record("invoice (1).pdf")]
        #expect(renames(records) == ["invoice (1).pdf": "invoice 2027-01-13 v2.pdf"])
        let more = records + [record("invoice 2027-01-13 v2.pdf"), record("INVOICE 2027-01-13 V3.PDF")]
        #expect(renames(more) == ["invoice (1).pdf": "invoice 2027-01-13 v4.pdf"])
    }

    @Test func theDateIsDateAddedOrElseDateModified() {
        let added = FileRecord(
            url: Self.folder.appending(path: "a (1).txt"), displayName: "a (1).txt", kind: .file,
            localizedTypeDescription: nil, contentType: nil, sizeInBytes: 3,
            dateAdded: Self.now - 10 * Self.day, dateModified: Self.now - 2 * Self.day, isDownloading: false
        )
        #expect(renames([record("a.txt"), added]) == ["a (1).txt": "a 2027-01-05.txt"])
        #expect(renames([record("b.txt"), record("b (1).txt", hasDateAdded: false)]) == ["b (1).txt": "b 2027-01-13.txt"])
    }

    @Test func aFileWithoutAnyDateWhoseCleanNameIsTakenIsReportedNotRenamed() {
        let undated = FileRecord(
            url: Self.folder.appending(path: "a (1).txt"), displayName: "a (1).txt", kind: .file,
            localizedTypeDescription: nil, contentType: nil, sizeInBytes: 3,
            dateAdded: nil, dateModified: nil, isDownloading: false
        )
        let candidates = MessyNameCleaner.clean(undated.displayName).map { [MessyNamePlanner.Candidate(record: undated, cleaned: $0)] } ?? []
        let plan = MessyNamePlanner.makePlan(
            folder: .temporary(Self.folder), records: [record("a.txt"), undated], candidates: candidates, caseSensitive: false, timeZone: Self.utc
        )
        #expect(plan.isEmpty)
        #expect(plan.skippedItems == [CleanupPlan.SkippedItem(url: undated.url, reason: .invalidName)])
    }

    @Test func aDatedNameTooLongForTheDiskIsNeverProposed() {
        let stem = String(repeating: "a", count: 247)
        let copy = record(stem + " (1).pdf", size: 11)
        let plan = plan([record(stem + ".pdf"), copy])
        #expect(plan.isEmpty)
        #expect(plan.skippedItems == [CleanupPlan.SkippedItem(url: copy.url, reason: .invalidName)])
    }

    // MARK: - Several files wanting one name

    @Test func theOlderOfTwoFilesWantingOneNameGetsIt() {
        let older = record("agenda (1).docx", age: 3 * Self.day)
        let newer = record("agenda copy.docx", size: 12, age: 2 * Self.day)
        let expected = ["agenda (1).docx": "agenda.docx", "agenda copy.docx": "agenda 2027-01-13.docx"]
        #expect(renames([older, newer]) == expected)
        #expect(renames([newer, older]) == expected)
    }

    @Test func threeFilesWantingOneNameAddedTheSameDayAllGetTheirOwn() {
        let records = [record("a (2).txt", age: 2 * Self.day - 60), record("a (1).txt"), record("a copy.txt", age: 2 * Self.day - 120)]
        #expect(renames(records) == ["a (1).txt": "a.txt", "a (2).txt": "a 2027-01-13.txt", "a copy.txt": "a 2027-01-13 v2.txt"])
    }

    @Test func noTwoChangesShareADestination() {
        var records: [FileRecord] = [record("x.txt"), record("x 2027-01-13.txt")]
        for (index, name) in ["x (1).txt", "X (2).txt", "x copy.txt", "x copy 2.txt", "x%20.txt.txt", "x (3).txt", "X COPY.TXT"].enumerated() {
            records.append(record(name, size: Int64(20 + index), age: 2 * Self.day - Double(index)))
        }
        let destinations = renames(records).values.map { MessyNamePlanner.comparisonKey($0, caseSensitive: false) }
        #expect(destinations.count == 7)
        #expect(Set(destinations).count == destinations.count)
        // None of them is a name already in the folder either.
        let existing = Set(records.map { MessyNamePlanner.comparisonKey($0.displayName, caseSensitive: false) })
        #expect(Set(destinations).isDisjoint(with: existing))
    }

    // MARK: - How names are compared

    @Test func aCaseOnlyClashCountsOnACaseInsensitiveVolume() {
        let records = [record("report.pdf"), record("Report (1).pdf")]
        #expect(renames(records, caseSensitive: false) == ["Report (1).pdf": "Report 2027-01-13.pdf"])
        #expect(renames(records, caseSensitive: true) == ["Report (1).pdf": "Report.pdf"])
    }

    @Test func twoFilesWantingNamesThatDifferOnlyInCase() {
        let records = [record("Photo (1).jpg", age: 3 * Self.day), record("photo copy.jpg")]
        #expect(renames(records, caseSensitive: false) == ["Photo (1).jpg": "Photo.jpg", "photo copy.jpg": "photo 2027-01-13.jpg"])
        #expect(renames(records, caseSensitive: true) == ["Photo (1).jpg": "Photo.jpg", "photo copy.jpg": "photo.jpg"])
    }

    @Test func namesInAnotherUnicodeFormClashEvenOnACaseSensitiveVolume() {
        let records = [record("re\u{301}sume\u{301}.pdf"), record("r\u{E9}sum\u{E9} (1).pdf")]
        #expect(renames(records, caseSensitive: true) == ["r\u{E9}sum\u{E9} (1).pdf": "r\u{E9}sum\u{E9} 2027-01-13.pdf"])
    }

    // MARK: - What is left alone

    @Test func onlySettledRegularFilesOutsideTheSharedRulesAreProposed() {
        let records = [
            record("fresh (1).pdf", age: 10 * 60),
            record(".hidden (1).txt"),
            record("Folder (1)", kind: .folder),
            record("App (1).app", kind: .package),
            record("link (1).pdf", kind: .symlink),
            record("movie (1).mp4.crdownload"),
            record("old (1).part"),
            record("Old downloads"),
            record("elsewhere (1).pdf", in: URL(filePath: "/Elsewhere", directoryHint: .isDirectory)),
        ]
        #expect(plan(records).isEmpty)
    }

    @Test func aKeptFileIsNeverProposedButItsNameIsStillTaken() {
        let kept = record("manual (2).pdf")
        let keptList = KeptItems([KeptItem(identity: nil, path: kept.keptItemPath, keptAt: Self.now)])
        let planner = MessyNamePlanner(eligibility: CandidateEligibility(keptItems: keptList))
        #expect(plan([kept], planner: planner).isEmpty)

        let keptClean = record("invoice.pdf")
        let keepingClean = MessyNamePlanner(
            eligibility: CandidateEligibility(keptItems: KeptItems([KeptItem(identity: nil, path: keptClean.keptItemPath, keptAt: Self.now)]))
        )
        #expect(renames(plan([keptClean, record("invoice (1).pdf")], planner: keepingClean)) == ["invoice (1).pdf": "invoice 2027-01-13.pdf"])
    }

    @Test func aFreshFileStillHoldsItsName() {
        #expect(renames([record("invoice.pdf", age: 60), record("invoice (1).pdf")]) == ["invoice (1).pdf": "invoice 2027-01-13.pdf"])
    }

    @Test func aFileThatCouldNotBeComparedIsReportedNotProposed() {
        let messy = record("receipt (1).pdf")
        let plan = MessyNamePlanner.makePlan(
            folder: .temporary(Self.folder),
            records: [record("receipt.pdf"), messy],
            candidates: planner.candidates(in: [messy], folder: .temporary(Self.folder), now: Self.now),
            skippedItems: [CleanupPlan.SkippedItem(url: messy.url, reason: .accessDenied)],
            caseSensitive: false,
            timeZone: Self.utc
        )
        #expect(plan.changes.isEmpty)
        #expect(plan.skippedItems.map(\.url) == [messy.url])
    }

    @Test func nothingToPlanGivesAnEmptyPlan() {
        #expect(plan([]).isEmpty)
        #expect(plan([record("clean.pdf"), record("IMG_4021.jpg"), record("Chapter (2) notes.pdf")]).isEmpty)
    }

    /// The folder as it would be once every rename is done, planned again: nothing left to propose.
    @Test func planningAgainAfterTheRenamesProposesNothing() {
        let records = [
            record("invoice.pdf"), record("invoice (1).pdf"), record("manual (2).pdf"), record("slides.pdf.pdf"),
            record("agenda (1).docx", age: 3 * Self.day), record("agenda copy.docx", size: 12), record("receipt.pdf"),
            record("receipt (1).pdf"),
        ]
        let first = renames(records, identical: ["receipt (1).pdf"])
        let after = records.map { record(first[$0.displayName] ?? $0.displayName, size: $0.sizeInBytes ?? 0) }
        #expect(renames(after, identical: ["receipt (1).pdf"]).isEmpty)
    }

    @Test func changesAreInNameOrder() {
        let records = [record("zebra (1).txt"), record("apple (1).txt"), record("Mango copy.txt")]
        #expect(plan(records).changes.map(\.record.displayName) == ["apple (1).txt", "Mango copy.txt", "zebra (1).txt"])
    }
}
