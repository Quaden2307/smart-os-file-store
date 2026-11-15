import FileStoreCore
import Foundation
import Testing
import UniformTypeIdentifiers

/// The Kept list as a value: how it recognises an item, and where the shared rules, the marks and
/// the preview use it. No disk.
@Suite("Kept items")
struct KeptItemsTests {
    private static let folder = URL(filePath: "/FakeDownloads", directoryHint: .isDirectory)
    private static let now = Date(timeIntervalSince1970: 1_800_000_000)
    private static let settled = now.addingTimeInterval(-2 * 60 * 60)
    private static let volume = "11111111-2222-3333-4444-555555555555"

    private func identity(_ number: UInt64, volume: String = KeptItemsTests.volume) -> PersistentFileIdentity {
        PersistentFileIdentity(volumeUUID: volume, fileNumber: number)
    }

    private func record(
        _ name: String,
        identity: PersistentFileIdentity?,
        kind: FileRecord.Kind = .file,
        contentType: UTType? = nil,
        added: Date = KeptItemsTests.settled
    ) -> FileRecord {
        FileRecord(
            url: Self.folder.appending(path: name),
            displayName: name,
            kind: kind,
            localizedTypeDescription: nil,
            contentType: contentType,
            sizeInBytes: kind == .file ? 21 : nil,
            dateAdded: added,
            dateModified: added,
            isDownloading: false,
            persistentIdentity: identity
        )
    }

    private func kept(_ records: FileRecord...) -> KeptItems {
        KeptItems(records.map { KeptItem(identity: $0.persistentIdentity, path: $0.keptItemPath, keptAt: Self.now) })
    }

    // MARK: - Recognising an item

    @Test func anItemIsKeptByItsIdentityWhateverItIsCalledNow() {
        let marked = record("report.pdf", identity: identity(7))
        let list = kept(marked)
        #expect(list.contains(marked))
        // Renamed: same file, new name.
        #expect(list.contains(record("quarterly.pdf", identity: identity(7))))
    }

    @Test func anotherFileThatTakesTheNameIsNotKept() {
        let list = kept(record("report.pdf", identity: identity(7)))
        #expect(!list.contains(record("report.pdf", identity: identity(8))))
        // The same number on another volume is another file.
        #expect(!list.contains(record("report.pdf", identity: identity(7, volume: "OTHER"))))
    }

    @Test func anEntryMadeWithoutAnIdentityKeepsWhateverIsAtItsPath() {
        let list = kept(record("notes.txt", identity: nil))
        #expect(list.contains(record("notes.txt", identity: nil)))
        #expect(list.contains(record("notes.txt", identity: identity(9))))
        #expect(!list.contains(record("other.txt", identity: nil)))
    }

    @Test func anItemWithoutAnIdentityIsComparedByPathAgainstEveryEntry() {
        // When the app cannot tell which file it is, it protects what sits where a Kept item was.
        let list = kept(record("report.pdf", identity: identity(7)))
        #expect(list.contains(record("report.pdf", identity: nil)))
        #expect(!list.contains(record("other.pdf", identity: nil)))
    }

    @Test func anEmptyListKeepsNothing() {
        let list = KeptItems()
        #expect(list.isEmpty)
        #expect(list.count == 0)
        #expect(!list.contains(record("report.pdf", identity: identity(7))))
        #expect(!list.contains(record("report.pdf", identity: nil)))
    }

    // MARK: - The shared rules

    @Test func aKeptItemIsNeverAllowedAndKeptIsTheLastRefusal() {
        let marked = record("report.pdf", identity: identity(7))
        let fresh = record("fresh.pdf", identity: identity(8), added: Self.now)
        let eligibility = CandidateEligibility().keeping(kept(marked, fresh))

        #expect(eligibility.refusal(for: marked, now: Self.now) == .kept)
        #expect(!eligibility.allows(marked, now: Self.now))
        // Another rule that keeps it out is named first.
        #expect(eligibility.refusal(for: fresh, now: Self.now) == .insideGracePeriod)
        // An item that is not Kept is unaffected.
        #expect(eligibility.allows(record("other.pdf", identity: identity(9)), now: Self.now))
    }

    @Test func keepingChangesOnlyTheList() {
        let rules = CandidateEligibility(gracePeriod: 42)
        let list = kept(record("report.pdf", identity: identity(7)))
        let keeping = rules.keeping(list)
        #expect(keeping.gracePeriod == 42)
        #expect(keeping.keptItems == list)
        #expect(rules.keptItems.isEmpty)
    }

    // MARK: - Marks

    @Test func anyItemCanCarryTheKeptMarkAndItComesFirst() {
        let settings = CleanupSettings()
        let old = record("old-manual.pdf", identity: identity(1), added: Self.now.addingTimeInterval(-200 * 24 * 60 * 60))
        let folder = record("Project", identity: identity(2), kind: .folder)
        let app = record("Tool.app", identity: identity(3), kind: .package, contentType: .applicationBundle)
        let list = kept(old, folder, app)

        #expect(FileMarker.marks(for: old, now: Self.now, settings: settings, eligibility: CandidateEligibility(keptItems: list)) == [.kept, .neverOpened, .old])
        #expect(FileMarker.marks(for: folder, now: Self.now, settings: settings, eligibility: CandidateEligibility(keptItems: list)) == [.kept])
        #expect(FileMarker.marks(for: app, now: Self.now, settings: settings, eligibility: CandidateEligibility(keptItems: list)) == [.kept])
        #expect(FileMarker.marks(for: old, now: Self.now, settings: settings) == [.neverOpened, .old])
        #expect(FileMark.allCases.first == .kept)
    }

    // MARK: - Taking changes out of a plan

    @Test func removingAChangeTakesItOutOfItsGroupAndDropsAnEmptyGroup() {
        let kept = record("report.pdf", identity: identity(1))
        let copy = record("report (1).pdf", identity: identity(2))
        let other = record("report copy.pdf", identity: identity(3))
        let photo = record("IMG_4021.jpg", identity: identity(4))
        let photoCopy = record("beach.jpg", identity: identity(5))
        let reports = DuplicateGroup(contentHash: ContentHash(bytes: [1]), kept: kept, duplicates: [copy, other], fileSizeInBytes: 21)
        let photos = DuplicateGroup(contentHash: ContentHash(bytes: [2]), kept: photo, duplicates: [photoCopy], fileSizeInBytes: 21)
        let skipped = CleanupPlan.SkippedItem(url: Self.folder.appending(path: "locked.txt"), reason: .accessDenied)
        let plan = CleanupPlan(
            action: .findDuplicates,
            folderURL: Self.folder,
            changes: [copy, other, photoCopy].map {
                ProposedChange(record: $0, operation: .moveToTrash, reason: .sameContent(asFileNamed: "x"))
            },
            duplicateGroups: [reports, photos],
            skippedItems: [skipped]
        )

        let smaller = plan.removing([copy.id, photoCopy.id])
        #expect(smaller.changes.map(\.id) == [other.id])
        #expect(smaller.duplicateGroups.map(\.kept.id) == [kept.id])
        #expect(smaller.duplicateGroups.first?.duplicates.map(\.id) == [other.id])
        #expect(smaller.skippedItems == [skipped])
        #expect(smaller.action == plan.action)
        #expect(smaller.folderURL == plan.folderURL)

        #expect(plan.removing([]) == plan)
        #expect(plan.removing([copy.id, other.id, photoCopy.id]).isEmpty)
        #expect(plan.removing([copy.id, other.id, photoCopy.id]).duplicateGroups.isEmpty)
    }
}
