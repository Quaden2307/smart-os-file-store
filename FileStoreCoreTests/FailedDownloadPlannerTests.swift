import FileStoreCore
import Foundation
import Testing

/// Clear Failed Downloads' planner on records built by hand: which partial downloads it proposes,
/// at the one-hour boundary, what it leaves alone, and the reason it gives.
@Suite("Failed download planner")
struct FailedDownloadPlannerTests {
    private static let now = Date(timeIntervalSince1970: 1_800_000_000)
    private static let hour: TimeInterval = 60 * 60
    private static let folder = URL(filePath: "/FakeDownloads", directoryHint: .isDirectory)
    private static let stale = now - 3 * 24 * hour

    private let planner = FailedDownloadPlanner()

    /// An item `age` old by both dates. A `.download` folder gets contents whose newest item is
    /// `insideAge` old (the same age by default), unless `contents` says otherwise.
    private func record(
        _ name: String,
        kind: FileRecord.Kind = .file,
        size: Int64 = 7,
        age: TimeInterval = 3 * 24 * 60 * 60,
        addedAge: TimeInterval? = nil,
        insideAge: TimeInterval? = nil,
        contents: Result<PackageContents, PackageContents.Failure>?? = .none,
        identity: PersistentFileIdentity? = nil
    ) -> FileRecord {
        let url = Self.folder.appending(path: name, directoryHint: kind == .file ? .notDirectory : .isDirectory)
        let isFolder = kind == .folder || kind == .package
        let defaultContents: Result<PackageContents, PackageContents.Failure>? = isFolder && name.lowercased().hasSuffix(".download")
            ? .success(PackageContents(itemCount: 2, totalSizeInBytes: 40, newestModificationDate: Self.now - (insideAge ?? age)))
            : nil
        return FileRecord(
            url: url,
            displayName: name,
            kind: kind,
            localizedTypeDescription: nil,
            contentType: nil,
            sizeInBytes: kind == .file || kind == .symlink ? size : nil,
            dateAdded: Self.now - (addedAge ?? age),
            dateModified: Self.now - age,
            isDownloading: FileRecord.isInProgressDownload(url),
            persistentIdentity: identity,
            packageContents: contents ?? defaultContents
        )
    }

    private func plan(_ records: [FileRecord], planner: FailedDownloadPlanner? = nil) -> CleanupPlan {
        (planner ?? self.planner).plan(records: records, in: Self.folder, now: Self.now)
    }

    private func proposedNames(_ records: [FileRecord], planner: FailedDownloadPlanner? = nil) -> [String] {
        plan(records, planner: planner).changes.map(\.record.displayName)
    }

    // MARK: - What it proposes

    @Test func staleChromeFirefoxAndSafariDownloadsAreProposedForTheTrash() throws {
        let records = [
            record("movie.mp4.crdownload"),
            record("partial.part"),
            record("presentation.key.download", kind: .package),
            // Where Safari's type is not registered, its download is a plain folder.
            record("slides.pdf.download", kind: .folder),
        ]
        let plan = plan(records)

        #expect(plan.action == .clearFailedDownloads)
        #expect(plan.folderURL == Self.folder)
        #expect(plan.changes.map(\.record.displayName) == ["movie.mp4.crdownload", "partial.part", "presentation.key.download", "slides.pdf.download"])
        #expect(plan.changes.allSatisfy { $0.operation == .moveToTrash })
        #expect(plan.duplicateGroups.isEmpty)
        #expect(plan.skippedItems.isEmpty)
        let package = try #require(plan.changes.first { $0.record.displayName == "presentation.key.download" })
        // A folder counts what is inside it, and its last change.
        #expect(package.sizeInBytes == 40)
        #expect(package.dateModified == Self.stale)
        #expect(package.isFolder)
        #expect(package.originalPath == "/FakeDownloads/presentation.key.download")
        #expect(package.reason == .failedDownload(stoppedOn: Self.stale, finishedFileName: nil))
        #expect(plan.bytesToFree == 7 + 7 + 40 + 40)
    }

    @Test func freshPartialsOfEveryKindAreLeftAlone() {
        let tenMinutes: TimeInterval = 10 * 60
        let records = [
            record("movie.mp4.crdownload", age: tenMinutes),
            record("partial.part", age: tenMinutes),
            record("presentation.key.download", kind: .package, age: tenMinutes),
            // Old by its own date, but Safari wrote to the file inside ten minutes ago.
            record("still-going.zip.download", kind: .package, insideAge: tenMinutes),
            // Old dates, but put in the folder ten minutes ago.
            record("moved-in.part", addedAge: tenMinutes),
        ]
        #expect(plan(records).isEmpty)
    }

    /// The grace period's boundary: an item exactly one hour unchanged is past it, one second less
    /// is not. It holds for a file's date, Date Added, and the newest date inside a folder.
    @Test func theBoundaryIsExactlyOneHour() {
        let hour = Self.hour
        for (age, expected) in [(hour - 1, false), (hour, true), (hour + 1, true)] {
            let records = [
                record("by-date.crdownload", age: age, addedAge: 2 * hour),
                record("by-added.part", age: 2 * hour, addedAge: age),
                record("by-inside.download", kind: .package, age: 2 * hour, insideAge: age),
                record("by-own-date.download", kind: .package, age: age, insideAge: 2 * hour),
            ]
            let names = proposedNames(records)
            #expect(names.count == (expected ? 4 : 0), "at \(age) s: \(names)")
        }
    }

    @Test func theGracePeriodIsTheSharedOne() {
        let records = [record("movie.mp4.crdownload", age: 10 * 60)]
        #expect(proposedNames(records).isEmpty)
        let shorter = FailedDownloadPlanner(eligibility: CandidateEligibility(gracePeriod: 5 * 60))
        #expect(proposedNames(records, planner: shorter) == ["movie.mp4.crdownload"])
    }

    @Test func aFolderStoppedWhenItsOwnDateMovedLast() throws {
        // Safari removed an item after the last write: the folder's own date is the newest.
        let package = record("presentation.key.download", kind: .package, age: 2 * Self.hour, insideAge: 5 * Self.hour)
        let change = try #require(plan([package]).changes.first)
        #expect(change.reason == .failedDownload(stoppedOn: Self.now - 2 * Self.hour, finishedFileName: nil))
        #expect(change.dateModified == Self.now - 2 * Self.hour)
    }

    @Test func anEmptyFolderCountsByItsOwnDate() {
        let empty = record(
            "empty.download",
            kind: .package,
            contents: .some(.success(PackageContents(itemCount: 0, totalSizeInBytes: 0, newestModificationDate: nil)))
        )
        #expect(proposedNames([empty]) == ["empty.download"])
    }

    // MARK: - What it leaves alone

    @Test func keptHiddenLinkedAndArchivedPartialsAreLeftAlone() {
        let kept = record("kept.crdownload", identity: PersistentFileIdentity(volumeUUID: "V", fileNumber: 1))
        let keptPackage = record("kept.download", kind: .package, identity: PersistentFileIdentity(volumeUUID: "V", fileNumber: 2))
        let keptList = KeptItems([
            KeptItem(identity: kept.persistentIdentity, path: kept.keptItemPath, keptAt: Self.now),
            KeptItem(identity: keptPackage.persistentIdentity, path: keptPackage.keptItemPath, keptAt: Self.now),
        ])
        let planner = FailedDownloadPlanner(eligibility: CandidateEligibility(keptItems: keptList))
        let records = [
            kept,
            keptPackage,
            record(".hidden.crdownload"),
            record(".hidden.download", kind: .package),
            record("link.crdownload", kind: .symlink),
            record("link.download", kind: .symlink),
            record("Old downloads", kind: .folder),
        ]
        #expect(proposedNames(records, planner: planner).isEmpty)
        #expect(plan(records, planner: planner).skippedItems.isEmpty)
        // Without the Kept list, only the two Kept ones would have been proposed.
        #expect(proposedNames(records) == ["kept.crdownload", "kept.download"])
    }

    @Test func namesThatOnlyLookLikeDownloadsAreNotMatched() {
        let records = [
            record("part"),
            record("part.txt"),
            record("download-guide.pdf"),
            record("my.download.pdf"),
            record("report.part1"),
            record("Downloads", kind: .folder),
            record("download", kind: .folder),
            record("album.crdownload", kind: .folder),
            record("film.part", kind: .package),
            record("note.download"),
        ]
        #expect(plan(records).isEmpty)
        #expect(records.allSatisfy { !planner.isCandidate($0, now: Self.now) })
    }

    @Test func extensionsMatchInAnyLetterCase() {
        let records = [
            record("Movie.MP4.CRDOWNLOAD"),
            record("Partial.Part"),
            record("Slides.KEY.Download", kind: .package),
        ]
        #expect(proposedNames(records) == ["Movie.MP4.CRDOWNLOAD", "Partial.Part", "Slides.KEY.Download"])
    }

    @Test func nothingToPlanGivesAnEmptyPlan() {
        let plan = plan([])
        #expect(plan.isEmpty)
        #expect(plan.skippedItems.isEmpty)
        #expect(plan.action == .clearFailedDownloads)
    }

    @Test func aFolderWhoseContentsCouldNotBeReadIsNotCheckedAndSaysWhy() {
        let records = [
            record("locked-away.download", kind: .package, contents: .some(.failure(.accessDenied))),
            record("in-icloud.download", kind: .package, contents: .some(.failure(.notDownloaded))),
            record("broken.download", kind: .package, contents: .some(.failure(.unreadable(reason: "I/O error")))),
            // Far too big to be a download: not reported as one.
            record("huge.download", kind: .package, contents: .some(.failure(.tooManyItems))),
            // Hidden ones are never mentioned, nor one changed in the last hour: it may simply be
            // downloading.
            record(".secret.download", kind: .package, contents: .some(.failure(.accessDenied))),
            record("busy.download", kind: .package, age: 10 * 60, contents: .some(.failure(.unreadable(reason: "gone")))),
        ]
        let plan = plan(records)
        #expect(plan.changes.isEmpty)
        #expect(plan.skippedItems.map(\.url.lastPathComponent) == ["broken.download", "in-icloud.download", "locked-away.download"])
        #expect(plan.skippedItems.map(\.reason) == [.unreadable(reason: "I/O error"), .notDownloaded, .accessDenied])
    }

    // MARK: - The reason

    @Test func aFinishedFileBesideThePartialIsNamedInTheReason() throws {
        let records = [
            record("movie.mp4.crdownload"),
            record("movie.mp4", size: 1_000, age: Self.hour * 2),
            record("Song.MP3.part"),
            record("song.mp3", size: 500),
            record("presentation.key.download", kind: .package),
            record("presentation.key", kind: .package),
            // Firefox makes an empty file under the final name when a download starts.
            record("photo.jpg.part"),
            record("photo.jpg", size: 0),
            // A plain folder is not a finished download.
            record("project.zip.crdownload"),
            record("project.zip", kind: .folder),
            record("Unconfirmed 48213.crdownload"),
        ]
        let reasons = Dictionary(uniqueKeysWithValues: plan(records).changes.map { ($0.record.displayName, $0.reason) })
        #expect(reasons["movie.mp4.crdownload"] == .failedDownload(stoppedOn: Self.stale, finishedFileName: "movie.mp4"))
        #expect(reasons["Song.MP3.part"] == .failedDownload(stoppedOn: Self.stale, finishedFileName: "song.mp3"))
        #expect(reasons["presentation.key.download"] == .failedDownload(stoppedOn: Self.stale, finishedFileName: "presentation.key"))
        #expect(reasons["photo.jpg.part"] == .failedDownload(stoppedOn: Self.stale, finishedFileName: nil))
        #expect(reasons["project.zip.crdownload"] == .failedDownload(stoppedOn: Self.stale, finishedFileName: nil))
        #expect(reasons["Unconfirmed 48213.crdownload"] == .failedDownload(stoppedOn: Self.stale, finishedFileName: nil))
        #expect(reasons.count == 6)
    }

    @Test func theShapeOfAPartialComesFromItsName() {
        #expect(FailedDownloadPlanner.partialShape(ofName: "a.crdownload") == .file)
        #expect(FailedDownloadPlanner.partialShape(ofName: "a.PART") == .file)
        #expect(FailedDownloadPlanner.partialShape(ofName: "a.key.download") == .folder)
        #expect(FailedDownloadPlanner.partialShape(ofName: "download") == nil)
        #expect(FailedDownloadPlanner.partialShape(ofName: "a.download.pdf") == nil)
    }

    // MARK: - Idempotence and the mark

    @Test func planningWhatIsLeftAfterTheTrashProposesNothing() {
        let records = [record("movie.mp4.crdownload"), record("movie.mp4", size: 1_000), record("setup.dmg.crdownload", age: 60)]
        let first = plan(records)
        #expect(first.changes.map(\.record.displayName) == ["movie.mp4.crdownload"])
        let proposed = Set(first.changes.map(\.id))
        #expect(plan(records.filter { !proposed.contains($0.id) }).isEmpty)
    }

    @Test func theFailedDownloadMarkIsExactlyWhatThePlannerProposes() {
        let records = [
            record("movie.mp4.crdownload"),
            record("setup.dmg.crdownload", age: 60),
            record("presentation.key.download", kind: .package),
            record("huge.download", kind: .package, contents: .some(.failure(.tooManyItems))),
            record("report.pdf"),
        ]
        let proposed = Set(plan(records).changes.map(\.record.displayName))
        for item in records {
            let marks = FileMarker.marks(for: item, now: Self.now, settings: CleanupSettings())
            #expect(marks.contains(.failedDownload) == proposed.contains(item.displayName), "\(item.displayName): \(marks)")
        }
        #expect(proposed == ["movie.mp4.crdownload", "presentation.key.download"])
    }

    @Test func aKeptPartialIsMarkedKeptOnly() {
        let partial = record("movie.mp4.crdownload", identity: PersistentFileIdentity(volumeUUID: "V", fileNumber: 9))
        let list = KeptItems([KeptItem(identity: partial.persistentIdentity, path: partial.keptItemPath, keptAt: Self.now)])
        let marks = FileMarker.marks(for: partial, now: Self.now, settings: CleanupSettings(), eligibility: CandidateEligibility(keptItems: list))
        #expect(marks == [.kept])
    }
}
