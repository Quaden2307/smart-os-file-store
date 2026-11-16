import FileStoreCore
import Foundation
import Testing
import UniformTypeIdentifiers

/// Archive Old Downloads' planner on records made here: which files are candidates by the age
/// marks and their settings, the names they get in the archive, and what never takes part.
@Suite("ArchivePlanner")
struct ArchivePlannerTests {
    private static let now = Date(timeIntervalSince1970: 1_800_000_000)
    private static let day: TimeInterval = 24 * 60 * 60
    private static let folder = URL(filePath: "/FakeDownloads", directoryHint: .isDirectory)
    private static let archive = ArchivePlanner.archiveURL(in: folder)
    private static let utc = TimeZone(identifier: "UTC") ?? .gmt

    /// A file added `addedDaysAgo` days ago, opened `openedDaysAgo` days ago or never.
    private func record(
        _ name: String,
        kind: FileRecord.Kind = .file,
        addedDaysAgo: Double = 100,
        openedDaysAgo: Double? = nil,
        size: Int64 = 10
    ) -> FileRecord {
        let url = Self.folder.appending(path: name)
        let added = Self.now - addedDaysAgo * Self.day
        return FileRecord(
            url: url,
            displayName: name,
            kind: kind,
            localizedTypeDescription: nil,
            contentType: UTType(filenameExtension: url.pathExtension),
            sizeInBytes: kind == .file || kind == .symlink ? size : nil,
            dateAdded: added,
            dateModified: added,
            isDownloading: FileRecord.isInProgressDownload(url),
            lastOpened: openedDaysAgo.map { Self.now - $0 * Self.day }
        )
    }

    private func plan(
        _ records: [FileRecord],
        settings: CleanupSettings = CleanupSettings(),
        eligibility: CandidateEligibility = CandidateEligibility(),
        archive: ArchiveListing = .missing,
        hashes: [FileRecord.ID: ContentHash] = [:]
    ) -> CleanupPlan {
        let planner = ArchivePlanner(eligibility: eligibility, settings: settings)
        return ArchivePlanner.makePlan(
            folderURL: Self.folder,
            candidates: planner.candidates(in: records, folderURL: Self.folder, now: Self.now),
            archive: archive,
            hashes: hashes,
            caseSensitive: false,
            timeZone: Self.utc
        )
    }

    private func names(_ plan: CleanupPlan) -> [String] {
        plan.changes.map(\.record.displayName)
    }

    // MARK: - Thresholds

    @Test(arguments: [30, 60, 90])
    func eachUnusedThresholdDecides(days: Int) {
        let settings = CleanupSettings(unusedAfterDays: days)
        let records = [
            record("just-under.pdf", addedDaysAgo: 400, openedDaysAgo: Double(days) - 0.5),
            record("just-over.pdf", addedDaysAgo: 400, openedDaysAgo: Double(days) + 0.5),
            record("never-under.pdf", addedDaysAgo: Double(days) - 0.5),
            record("never-over.pdf", addedDaysAgo: Double(days) + 0.5),
        ]
        #expect(names(plan(records, settings: settings)) == ["just-over.pdf", "never-over.pdf"])
    }

    /// The old threshold does not decide: an Old file opened yesterday stays.
    @Test func oldAloneIsNoReason() {
        let records = [record("tax-form.pdf", addedDaysAgo: 400, openedDaysAgo: 1)]
        #expect(plan(records, settings: CleanupSettings(unusedAfterDays: 30, oldAfterDays: 90)).isEmpty)
    }

    @Test func neverOpenedAndUnusedGiveTheirOwnReasons() throws {
        let result = plan([record("never.pdf", addedDaysAgo: 200), record("unused.pdf", addedDaysAgo: 300, openedDaysAgo: 50)])
        let never = try #require(result.changes.first { $0.record.displayName == "never.pdf" })
        let unused = try #require(result.changes.first { $0.record.displayName == "unused.pdf" })
        #expect(never.reason == .neverOpened(downloadedOn: Self.now - 200 * Self.day))
        #expect(unused.reason == .notOpenedSince(Self.now - 50 * Self.day))
        #expect(never.operation == .move(to: Self.archive, name: "never.pdf"))
        #expect(unused.operation == .move(to: Self.archive, name: "unused.pdf"))
        #expect(result.action == .archiveOldDownloads)
        #expect(result.bytesToFree == 0)
    }

    @Test func emptyInputIsAnEmptyPlan() {
        #expect(plan([]).isEmpty)
        #expect(plan([]).archiveProblem == nil)
    }

    // MARK: - What takes no part

    @Test func excludedKindsAndSharedRulesTakeNoPart() {
        let records = [
            record("Some Folder", kind: .folder),
            record("SomeApp.app", kind: .package),
            record("link.pdf", kind: .symlink),
            record(".hidden.pdf"),
            record("movie.mp4.crdownload"),
            record("Old downloads", kind: .folder),
            record("old-downloads-lookalike.pdf"),
        ]
        #expect(names(plan(records)) == ["old-downloads-lookalike.pdf"])
    }

    @Test func keptFilesAreNeverProposed() {
        let kept = record("kept.pdf")
        let keptItems = KeptItems([KeptItem(identity: kept.persistentIdentity, path: kept.keptItemPath, keptAt: Self.now)])
        let result = plan([kept, record("other.pdf")], eligibility: CandidateEligibility(keptItems: keptItems))
        #expect(names(result) == ["other.pdf"])
    }

    @Test func theGracePeriodApplies() {
        let fresh = FileRecord(
            url: Self.folder.appending(path: "fresh.pdf"),
            displayName: "fresh.pdf",
            kind: .file,
            localizedTypeDescription: nil,
            contentType: .pdf,
            sizeInBytes: 10,
            dateAdded: Self.now - 100 * Self.day,
            dateModified: Self.now - 60,
            isDownloading: false
        )
        #expect(plan([fresh]).isEmpty)
    }

    // MARK: - Names in the archive

    @Test func aNameTakenByADifferentFileGetsTheDateThenANumber() {
        let records = [record("report.pdf", addedDaysAgo: 200), record("notes.txt", addedDaysAgo: 200)]
        let day = (Self.now - 200 * Self.day).formatted(Date.ISO8601FormatStyle(timeZone: Self.utc).year().month().day().dateSeparator(.dash))
        let dated = "report \(day).pdf"
        let archive = ArchiveListing(entries: [ArchiveListing.Entry(name: "REPORT.pdf"), ArchiveListing.Entry(name: "Notes.txt", contentHash: ContentHash(bytes: [1]))])
        let result = plan(records, archive: archive, hashes: [records[1].id: ContentHash(bytes: [2])])
        #expect(result.changes.map(\.operation) == [
            .move(to: Self.archive, name: "notes \(day).txt"),
            .move(to: Self.archive, name: dated),
        ])

        // The dated name is taken too: " v2".
        let both = ArchiveListing(entries: [ArchiveListing.Entry(name: "report.pdf"), ArchiveListing.Entry(name: dated)])
        let again = plan([records[0]], archive: both)
        #expect(again.changes.map(\.operation) == [.move(to: Self.archive, name: "report \(day) v2.pdf")])
    }

    @Test func aNameTakenByAnIdenticalFileSendsThisCopyToTheTrash() throws {
        let manual = record("manual.pdf")
        let hash = ContentHash(bytes: [7])
        let archive = ArchiveListing(entries: [ArchiveListing.Entry(name: "Manual.pdf", contentHash: hash)])
        let change = try #require(plan([manual], archive: archive, hashes: [manual.id: hash]).changes.first)
        #expect(change.operation == .moveToTrash)
        #expect(change.reason == .alreadyArchived(copyNamed: "Manual.pdf"))
    }

    @Test func aProblemWithTheArchiveProposesNothing() {
        for problem in [ArchiveProblem.notAFolder, .symbolicLink, .unreadable] {
            let result = plan([record("old.pdf")], archive: ArchiveListing(problem: problem, entries: [ArchiveListing.Entry(name: "x")]))
            #expect(result.isEmpty)
            #expect(result.archiveProblem == problem)
        }
    }
}
