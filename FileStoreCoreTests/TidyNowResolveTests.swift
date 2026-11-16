import FileStoreCore
import Foundation
import Testing

/// Tidy Now's priority rule, on plans built by hand: which action keeps a file two of them propose,
/// and the invariants of every combined plan, checked on generated combinations. Pure: no disk.
@Suite("Tidy Now priority rule")
struct TidyNowResolveTests {
    static let folder = LogSamples.folderURL
    static let archive = folder.appending(path: "Old downloads", directoryHint: .isDirectory)
    static let now = Date(timeIntervalSince1970: 1_800_000_000)
    static let old = Date(timeIntervalSince1970: 1_700_000_000)

    static func record(_ name: String, in parent: URL = folder, added: Date = old, downloading: Bool = false) -> FileRecord {
        FileRecord(
            url: parent.appending(path: name),
            displayName: name,
            kind: .file,
            localizedTypeDescription: nil,
            contentType: nil,
            sizeInBytes: 1_000,
            dateAdded: added,
            dateModified: added,
            isDownloading: downloading
        )
    }

    static func hash(_ byte: UInt8) -> ContentHash { ContentHash(bytes: Array(repeating: byte, count: 32)) }

    static let strongEvidence = UsedInstallerEvidence(
        strength: .strong, name: "App", version: "1.0", installedAppPath: "/Applications/App.app", bundleIdentifier: "com.example.App"
    )
    static let possibleEvidence = UsedInstallerEvidence(
        strength: .possible, name: "App", version: nil, installedAppPath: nil, bundleIdentifier: nil
    )

    static func trash(_ record: FileRecord, _ reason: ProposedChange.Reason) -> ProposedChange {
        ProposedChange(record: record, operation: .moveToTrash, reason: reason)
    }

    static func rename(_ record: FileRecord, to name: String) -> ProposedChange {
        ProposedChange(record: record, operation: .rename(to: name), reason: .messyName(MessyNameFix(fixes: [])))
    }

    static func archiveMove(_ record: FileRecord) -> ProposedChange {
        ProposedChange(record: record, operation: .move(to: archive, name: record.displayName), reason: .neverOpened(downloadedOn: old))
    }

    static func duplicates(kept: FileRecord, _ copies: [FileRecord], byte: UInt8 = 1) -> CleanupPlan {
        CleanupPlan(
            action: .findDuplicates,
            folderURL: folder,
            changes: copies.map { trash($0, .sameContent(asFileNamed: kept.displayName)) },
            duplicateGroups: [DuplicateGroup(contentHash: hash(byte), kept: kept, duplicates: copies, fileSizeInBytes: 1_000)]
        )
    }

    static func plan(_ action: CleanupAction, _ changes: [ProposedChange]) -> CleanupPlan {
        CleanupPlan(action: action, folderURL: folder, changes: changes)
    }

    static func resolve(_ plans: [CleanupPlan], kept: [FileRecord] = []) -> [CleanupAction: CleanupPlan] {
        let keptItems = KeptItems(kept.map { KeptItem(identity: nil, path: $0.keptItemPath, keptAt: old) })
        let resolved = TidyNowPlan.resolve(plans, eligibility: CandidateEligibility(keptItems: keptItems), now: now)
        return Dictionary(resolved.map { ($0.action, $0) }, uniquingKeysWith: { first, _ in first })
    }

    static func names(_ plan: CleanupPlan?) -> Set<String> {
        Set(plan?.changes.map(\.record.displayName) ?? [])
    }

    // MARK: - Each overlapping pair

    @Test func aMessyNamedDuplicateIsTrashedAndItsKeptCopyMayStillBeRenamed() {
        let kept = Self.record("notes (1).txt")
        let copy = Self.record("notes (2).txt")
        let resolved = Self.resolve([
            Self.plan(.fixMessyNames, [Self.rename(kept, to: "notes.txt"), Self.rename(copy, to: "notes 2.txt")]),
            Self.duplicates(kept: kept, [copy]),
        ])
        #expect(Self.names(resolved[.findDuplicates]) == ["notes (2).txt"])
        #expect(Self.names(resolved[.fixMessyNames]) == ["notes (1).txt"])
    }

    @Test func codeTicksNeitherReviewOnlyChangesNorPossibleMatches() {
        let byHand: [ProposedChange.Reason] = [
            .nearDuplicate(sameNameAs: "a.txt"),
            .largeDownload(sizeOnDisk: 1, lastOpened: nil, opensRecorded: true),
            .usedInstaller(Self.possibleEvidence),
        ]
        let byCode: [ProposedChange.Reason] = [
            .sameContent(asFileNamed: "a.txt"), .usedInstaller(Self.strongEvidence), .unpackedZip(unpackedTo: "a"),
            .emptyFolder, .failedDownload(stoppedOn: Self.old, finishedFileName: nil), .neverOpened(downloadedOn: Self.old),
        ]
        #expect(byHand.allSatisfy { !$0.isTickedByCode })
        #expect(byCode.allSatisfy { $0.isTickedByCode })
    }

    @Test func aZipsOnlyUnpackedCopyIsNeverTrashedInTheSameRun() {
        let zip = Self.record("report.zip")
        let unpacked = Self.record("report.pdf")
        let app = Self.record("App.app")
        let appZip = Self.record("App.zip")
        let other = Self.record("report (1).pdf")
        let resolved = Self.resolve([
            Self.plan(.reviewNearDuplicates, [
                Self.trash(unpacked, .nearDuplicate(sameNameAs: other.displayName)),
                Self.trash(other, .nearDuplicate(sameNameAs: unpacked.displayName)),
            ]),
            Self.plan(.reviewLargeDownloads, [Self.trash(app, .largeDownload(sizeOnDisk: 1_000, lastOpened: nil, opensRecorded: false))]),
            Self.plan(.removeUnpackedZips, [
                Self.trash(zip, .unpackedZip(unpackedTo: unpacked.displayName)),
                Self.trash(appZip, .unpackedZip(unpackedTo: app.displayName)),
            ]),
        ])
        #expect(Self.names(resolved[.removeUnpackedZips]) == ["report.zip", "App.zip"])
        #expect(!Self.names(resolved[.reviewNearDuplicates]).contains("report.pdf"))
        #expect(Self.names(resolved[.reviewLargeDownloads]).isEmpty)
    }

    @Test func anOldInstallerGoesToTheTrashRatherThanTheArchive() {
        let installer = Self.record("App-1.0.dmg")
        let resolved = Self.resolve([
            Self.plan(.archiveOldDownloads, [Self.archiveMove(installer)]),
            Self.plan(.removeUsedInstallers, [Self.trash(installer, .usedInstaller(Self.strongEvidence))]),
        ])
        #expect(Self.names(resolved[.removeUsedInstallers]) == ["App-1.0.dmg"])
        #expect(Self.names(resolved[.archiveOldDownloads]).isEmpty)
    }

    @Test func anOldUnpackedZipGoesToTheTrashRatherThanTheArchive() {
        let zip = Self.record("project.zip")
        let resolved = Self.resolve([
            Self.plan(.archiveOldDownloads, [Self.archiveMove(zip)]),
            Self.plan(.removeUnpackedZips, [Self.trash(zip, .unpackedZip(unpackedTo: "project"))]),
        ])
        #expect(Self.names(resolved[.removeUnpackedZips]) == ["project.zip"])
        #expect(Self.names(resolved[.archiveOldDownloads]).isEmpty)
    }

    @Test func aStalePartialDownloadThatIsAlsoLargeIsAFailedDownload() {
        let partial = Self.record("movie.mp4.crdownload", downloading: true)
        let resolved = Self.resolve([
            Self.plan(.reviewLargeDownloads, [Self.trash(partial, .largeDownload(sizeOnDisk: 1_000, lastOpened: nil, opensRecorded: true))]),
            Self.plan(.clearFailedDownloads, [Self.trash(partial, .failedDownload(stoppedOn: Self.old, finishedFileName: nil))]),
        ])
        #expect(Self.names(resolved[.clearFailedDownloads]) == ["movie.mp4.crdownload"])
        #expect(Self.names(resolved[.reviewLargeDownloads]).isEmpty)
    }

    @Test func aPossibleInstallerMatchRanksBelowEveryTickedChange() {
        let installer = Self.record("App.pkg")
        let resolved = Self.resolve([
            Self.plan(.removeUsedInstallers, [Self.trash(installer, .usedInstaller(Self.possibleEvidence))]),
            Self.plan(.archiveOldDownloads, [Self.archiveMove(installer)]),
        ])
        #expect(Self.names(resolved[.archiveOldDownloads]) == ["App.pkg"])
        #expect(Self.names(resolved[.removeUsedInstallers]).isEmpty)
    }

    @Test func aGroupWhoseKeptCopyIsTrashedHigherUpKeepsItsDuplicates() {
        // The kept zip goes as an unpacked zip; its copy then stays, and may be archived instead.
        let kept = Self.record("data.zip")
        let copy = Self.record("data (1).zip")
        let resolved = Self.resolve([
            Self.duplicates(kept: kept, [copy]),
            Self.plan(.removeUnpackedZips, [Self.trash(kept, .unpackedZip(unpackedTo: "data"))]),
            Self.plan(.archiveOldDownloads, [Self.archiveMove(copy)]),
        ])
        #expect(Self.names(resolved[.removeUnpackedZips]) == ["data.zip"])
        #expect(resolved[.findDuplicates]?.isEmpty == true)
        #expect(resolved[.findDuplicates]?.duplicateGroups.isEmpty == true)
        #expect(Self.names(resolved[.archiveOldDownloads]) == ["data (1).zip"])
    }

    @Test func theKeptCopyOfAGroupIsNeverTrashedLowerDownButMayBeArchived() {
        let kept = Self.record("video.mov")
        let copy = Self.record("video (1).mov")
        let large = Self.trash(kept, .largeDownload(sizeOnDisk: 1_000, lastOpened: nil, opensRecorded: true))
        let resolved = Self.resolve([
            Self.duplicates(kept: kept, [copy]),
            Self.plan(.reviewLargeDownloads, [large]),
            Self.plan(.archiveOldDownloads, [Self.archiveMove(kept), Self.trash(copy, .alreadyArchived(copyNamed: "video (1).mov"))]),
        ])
        #expect(Self.names(resolved[.findDuplicates]) == ["video (1).mov"])
        #expect(Self.names(resolved[.reviewLargeDownloads]).isEmpty)
        #expect(Self.names(resolved[.archiveOldDownloads]) == ["video.mov"])
    }

    @Test func twoChangesNeverShareADestination() {
        let first = Self.record("agenda (1).docx")
        let second = Self.record("agenda copy.docx")
        let resolved = Self.resolve([
            Self.plan(.fixMessyNames, [Self.rename(first, to: "agenda.docx"), Self.rename(second, to: "Agenda.docx")]),
        ])
        #expect(Self.names(resolved[.fixMessyNames]) == ["agenda (1).docx"])
    }

    @Test func keptFreshAndArchivedItemsAreDroppedWhateverAPlannerSaid() {
        let kept = Self.record("kept.pdf")
        let fresh = Self.record("fresh.pdf", added: Self.now.addingTimeInterval(-60))
        let archived = Self.record("filed.pdf", in: Self.archive)
        let fine = Self.record("fine.pdf")
        let reason = ProposedChange.Reason.emptyFolder
        let resolved = Self.resolve(
            [Self.plan(.removeEmptyFolders, [kept, fresh, archived, fine].map { Self.trash($0, reason) })],
            kept: [kept]
        )
        #expect(Self.names(resolved[.removeEmptyFolders]) == ["fine.pdf"])
    }

    @Test func aNearDuplicateGroupLeftWithOneFileGoes() {
        let first = Self.record("todo.txt")
        let second = Self.record("todo.md")
        let other = Self.record("todo (1).txt")
        let near = CleanupPlan(
            action: .reviewNearDuplicates,
            folderURL: Self.folder,
            changes: [first, second].map { Self.trash($0, .nearDuplicate(sameNameAs: "todo")) },
            nearDuplicateGroups: [NearDuplicateGroup(cleanedName: "todo", members: [
                .init(record: first, contentHash: Self.hash(1)), .init(record: second, contentHash: Self.hash(2)),
            ])]
        )
        let resolved = Self.resolve([near, Self.duplicates(kept: other, [first])])
        #expect(Self.names(resolved[.findDuplicates]) == ["todo.txt"])
        #expect(resolved[.reviewNearDuplicates]?.isEmpty == true)
        #expect(resolved[.reviewNearDuplicates]?.nearDuplicateGroups.isEmpty == true)
    }

    @Test func theTrashGoesFirstThenTheArchiveThenRenames() async throws {
        let a = Self.record("a.pdf")
        let b = Self.record("b (1).pdf")
        let c = Self.record("c.pdf")
        let d = Self.record("d.pdf")
        let spy = SpyRecorder()
        let result = await CleanupExecutor(recorder: spy).executeTidyNow(
            plans: [
                Self.plan(.fixMessyNames, [Self.rename(b, to: "b.pdf")]),
                Self.plan(.archiveOldDownloads, [Self.archiveMove(c), Self.trash(d, .alreadyArchived(copyNamed: "d.pdf"))]),
                Self.plan(.removeEmptyFolders, [Self.trash(a, .emptyFolder)]),
            ],
            confirmedChangeIDs: [a.id, b.id, c.id, d.id]
        )
        // The folder is not on this Mac, so nothing is changed, but each item is tried, and logged,
        // in order: the Trash by priority, then the archive move, then the rename, in one run.
        let logged = spy.calls.compactMap { call -> String? in
            if case .recordResult = call { call.fileName } else { nil }
        }
        #expect(logged == ["a.pdf", "d.pdf", "c.pdf", "b (1).pdf"])
        let starts = spy.calls.compactMap { call -> CleanupRunStart? in
            if case .beginRun(let start) = call { start } else { nil }
        }
        #expect(starts.map(\.logCode) == [ActivityRun.tidyNowActionCode])
        #expect(starts.first?.action == nil)
        #expect(starts.first?.confirmedCount == 4)
        #expect(result.results.map(\.action) == [.removeEmptyFolders, .archiveOldDownloads, .fixMessyNames])
        #expect(Set(result.results.map(\.runID)).count == 1)
    }

    // MARK: - Invariants on generated combinations

    /// A small deterministic generator, so a failure can be reproduced.
    struct Generator: RandomNumberGenerator {
        var state: UInt64
        mutating func next() -> UInt64 {
            state = state &* 6_364_136_223_846_793_005 &+ 1_442_695_040_888_963_407
            return state
        }
    }

    @Test(arguments: 0..<200)
    func everyCombinedPlanKeepsTheInvariants(seed: Int) {
        var random = Generator(state: UInt64(seed) &+ 1)
        let pool = (0..<10).map { Self.record("file-\($0).bin") }
        let fresh = Self.record("fresh.bin", added: Self.now)
        let filed = Self.record("filed.bin", in: Self.archive)
        let kept = Self.record("kept.bin")
        let all = pool + [fresh, filed, kept]
        func some(_ count: Int) -> [FileRecord] {
            Array(all.shuffled(using: &random).prefix(Int.random(in: 0...count, using: &random)))
        }
        func trashes(_ reason: ProposedChange.Reason) -> [ProposedChange] {
            some(4).map { Self.trash($0, reason) }
        }

        var plans: [CleanupPlan] = [
            Self.plan(.clearFailedDownloads, trashes(.failedDownload(stoppedOn: Self.old, finishedFileName: nil))),
            Self.plan(.removeUsedInstallers, trashes(.usedInstaller(Self.strongEvidence)) + trashes(.usedInstaller(Self.possibleEvidence))),
            Self.plan(.removeUnpackedZips, trashes(.unpackedZip(unpackedTo: "folder"))),
            Self.plan(.removeEmptyFolders, trashes(.emptyFolder)),
            Self.plan(.archiveOldDownloads, some(4).map(Self.archiveMove) + trashes(.alreadyArchived(copyNamed: "x"))),
            Self.plan(.fixMessyNames, some(4).map { Self.rename($0, to: "name-\(Int.random(in: 0..<3, using: &random)).bin") }),
            Self.plan(.reviewLargeDownloads, trashes(.largeDownload(sizeOnDisk: 1_000, lastOpened: nil, opensRecorded: true))),
        ]
        // Up to three duplicate groups, and two near-duplicate groups, over the same files.
        var groups: [DuplicateGroup] = []
        var duplicateChanges: [ProposedChange] = []
        var used: Set<URL> = []
        for byte in 1...3 {
            let members = some(4).filter { used.insert($0.id).inserted }
            guard members.count >= 2, let keptCopy = members.first else { continue }
            let copies = Array(members.dropFirst())
            groups.append(DuplicateGroup(contentHash: Self.hash(UInt8(byte)), kept: keptCopy, duplicates: copies, fileSizeInBytes: 1_000))
            duplicateChanges += copies.map { Self.trash($0, .sameContent(asFileNamed: keptCopy.displayName)) }
        }
        plans.append(CleanupPlan(action: .findDuplicates, folderURL: Self.folder, changes: duplicateChanges, duplicateGroups: groups))
        var nearGroups: [NearDuplicateGroup] = []
        var nearUsed: Set<URL> = []
        for byte in 1...2 {
            let members = some(3).filter { nearUsed.insert($0.id).inserted }
            guard members.count >= 2 else { continue }
            nearGroups.append(NearDuplicateGroup(cleanedName: "group-\(byte)", members: members.map { .init(record: $0, contentHash: Self.hash(UInt8($0.displayName.utf8.count))) }))
        }
        plans.append(CleanupPlan(
            action: .reviewNearDuplicates,
            folderURL: Self.folder,
            changes: nearGroups.flatMap { $0.members.map { Self.trash($0.record, .nearDuplicate(sameNameAs: "x")) } },
            nearDuplicateGroups: nearGroups
        ))

        let resolved = Self.resolve(plans.shuffled(using: &random), kept: [kept])
        let changes = resolved.values.flatMap(\.changes)

        // No item appears in two changes.
        #expect(Set(changes.map(\.id)).count == changes.count, "seed \(seed)")
        // Nothing Kept, in the grace period or in the archive.
        #expect(!changes.contains { [kept.id, fresh.id, filed.id].contains($0.id) }, "seed \(seed)")
        // No two changes share a destination.
        let destinations = changes.compactMap { change -> String? in
            switch change.operation {
            case .moveToTrash: nil
            case .rename(let name): name.lowercased()
            case .move(let folder, let name): folder.appending(path: name).path(percentEncoded: false).lowercased()
            }
        }
        #expect(Set(destinations).count == destinations.count, "seed \(seed)")
        // No duplicate group loses every copy: each group left has a duplicate, and its kept copy is
        // trashed by no change.
        let trashed = Set(changes.filter { $0.operation == .moveToTrash }.map(\.id))
        for group in resolved[.findDuplicates]?.duplicateGroups ?? [] {
            #expect(!group.duplicates.isEmpty, "seed \(seed)")
            #expect(!trashed.contains(group.kept.url), "seed \(seed)")
        }
        // Nor does a near-duplicate group: each has two files or more, none trashed by another action.
        let otherTrashed = Set(resolved.values.filter { $0.action != .reviewNearDuplicates }.flatMap(\.changes).map(\.id))
        for group in resolved[.reviewNearDuplicates]?.nearDuplicateGroups ?? [] {
            #expect(group.members.count >= 2, "seed \(seed)")
            #expect(!group.members.contains { otherTrashed.contains($0.id) }, "seed \(seed)")
        }
        // Each change still belongs to the plan that proposed it.
        for plan in resolved.values {
            #expect(plan.changes.allSatisfy { plan.action.allows($0.operation) })
        }
    }
}
