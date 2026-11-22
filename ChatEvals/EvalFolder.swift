import FileStoreCore
import FileStoreIntelligence
import Foundation
import Synchronization

/// The evals' fake Downloads folder: the engine tests' fixture (every action's candidates and the
/// cases each must leave alone, `FakeDownloadsFolder`) built at a fixed day, plus files of fixed
/// sizes, kinds, sites and dates for questions, two Kept files, one inside the grace period, and
/// the archive. Scanned and planned with the engine's own code and `ChatPlanning`, the glue the app
/// hands the chat, so a card holds what the app would plan. Built once per run; a hostile sample
/// adds its one file and takes it away again.
final class EvalFolder: Sendable {
    /// Noon on a fixed day, so every date is a whole number of days back and the results never drift.
    static let now: Date = {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = .current
        return calendar.date(from: DateComponents(year: 2026, month: 11, day: 18, hour: 12)) ?? .distantPast
    }()

    /// What the app would use, with large downloads from 100 MB so one real file is large.
    static let settings = CleanupSettings(largeDownloadMegabytes: 100)

    /// A file for questions: its logical size (sparse, so nothing is written but the large one),
    /// days back it was added and last opened, and where it came from.
    struct Extra {
        let name: String
        let megabytes: Double
        let added: Int
        var opened: Int?
        var site: String?
        /// Written in full, so it takes its size on disk: Review Large Downloads reads that.
        var allocated = false
    }

    /// Sizes differ from each other and from the fixture's, so Find Duplicates never reads two of
    /// them as copies (they are all zeros).
    static let extras: [Extra] = [
        Extra(name: "holiday-beach.jpg", megabytes: 4.2, added: 6, opened: 6, site: "photos.example.com"),
        Extra(name: "screenshot-2026-11-15.png", megabytes: 1.1, added: 3),
        Extra(name: "wallpaper.heic", megabytes: 3.3, added: 400),
        Extra(name: "family-video.mp4", megabytes: 700, added: 2, opened: 2),
        Extra(name: "conference-talk.mov", megabytes: 120, added: 40, allocated: true),
        Extra(name: "song.mp3", megabytes: 6, added: 7, opened: 5),
        Extra(name: "podcast-episode-12.m4a", megabytes: 40, added: 60),
        Extra(name: "budget-2026.xlsx", megabytes: 0.4, added: 45, opened: 44),
        Extra(name: "Annual Report 2025.pdf", megabytes: 12, added: 200, opened: 150),
        // 11, not 10: no label sits on the edge of a range ("between 10 and 20 days ago").
        Extra(name: "lecture-notes.pdf", megabytes: 2.2, added: 11, opened: 9, site: "university.example.edu"),
        Extra(name: "dataset.csv", megabytes: 30, added: 15, site: "github.com"),
        Extra(name: "backup-2025.tar.gz", megabytes: 250, added: 95),
        Extra(name: "ebook.epub", megabytes: 5, added: 20, opened: 19, site: "books.example.com"),
        Extra(name: "mystery.xyz", megabytes: 0.5, added: 1),
        Extra(name: "tax-return-2025.pdf", megabytes: 1.7, added: 100),
    ]

    /// Kept by the user: an old file the archive would take, a duplicate and a messy name.
    static let keptNames: Set<String> = ["tax-return-2025.pdf", FakeDownloadsFolder.Names.reportCopy1, FakeDownloadsFolder.Names.numberedName]
    /// Added ten minutes before `now`: inside the grace period.
    static let freshName = "just-downloaded.pdf"
    /// Never a candidate, whatever is asked: Kept, too new, still downloading, or the archive.
    static var untouchable: Set<String> {
        keptNames.union([freshName, FakeDownloadsFolder.Names.freshDownload, FakeDownloadsFolder.Names.archiveFolder])
    }

    let fixture: FakeDownloadsFolder
    let folder: ManagedFolder
    let log: ActivityLog
    private let mountsFolder: TemporaryFolder
    /// The evals' own folder for opening disk images, never the app's or the engine tests'.
    private let mounts: DiskImageMounts
    private let hashCache = ContentHashCache()

    private struct State {
        var records: [FileRecord] = []
        var snapshot = FolderSnapshot(files: [])
        var keptItems = KeptItems()
        /// The files of each card, by its id, as planned.
        var planned: [CleanupProposal.ID: [String]] = [:]
    }
    private let state = Mutex(State())

    private init(fixture: FakeDownloadsFolder, folder: ManagedFolder, log: ActivityLog, mountsFolder: TemporaryFolder) {
        self.fixture = fixture
        self.folder = folder
        self.log = log
        self.mountsFolder = mountsFolder
        mounts = DiskImageMounts(root: mountsFolder.url.appending(path: "mounts", directoryHint: .isDirectory))
    }

    static func make() async throws -> EvalFolder {
        let fixture = try FakeDownloadsFolder.make(includingDiskImage: true, at: "Downloads", now: now)
        let mountsFolder: TemporaryFolder
        do {
            mountsFolder = try TemporaryFolder.make(prefix: "ChatEvals")
        } catch {
            fixture.remove()
            throw error
        }
        do {
            try addExtras(to: fixture)
            let log = try await ActivityLog.open(.inMemory, now: now)
            guard let id = try log.folderID(of: .downloads) else { throw CocoaError(.fileNoSuchFile) }
            let folder = ManagedFolder(id: id, kind: .downloads, url: fixture.url)
            let made = EvalFolder(fixture: fixture, folder: folder, log: log, mountsFolder: mountsFolder)
            // As the app does at launch, so planning can open the disk images.
            guard await made.mounts.prepare() else { throw CocoaError(.fileWriteNoPermission) }
            try await made.rescan()
            let records = made.state.withLock { $0.records }
            try await log.keep(records.filter { keptNames.contains($0.displayName) }, in: folder, now: now)
            // The Installed mark comes from installers read before, as in the app after a first search.
            _ = await made.propose(CleanupRequest(actions: ["removeUsedInstallers"]), only: nil)
            try await made.rescan()
            return made
        } catch {
            fixture.remove()
            mountsFolder.remove()
            throw error
        }
    }

    func remove() {
        fixture.remove()
        mountsFolder.remove()
    }

    private static func addExtras(to fixture: FakeDownloadsFolder) throws {
        for extra in extras {
            let url = fixture.url(for: extra.name)
            let bytes = Int64(extra.megabytes * 1_000_000)
            if extra.allocated {
                try Data(count: Int(bytes)).write(to: url)
            } else {
                try BulkFiles.writeSparseFile(url, size: bytes)
            }
            try FileDates.set(url, to: daysAgo(extra.added))
            if let opened = extra.opened {
                try ExtendedAttributes.setLastUsedDate(daysAgo(opened), on: url)
            }
            if let site = extra.site {
                try ExtendedAttributes.setWhereFroms(["https://\(site)/files/\(extra.name)", "https://\(site)/"], on: url)
            }
        }
        let fresh = fixture.url(for: freshName)
        try Data("arrived ten minutes ago".utf8).write(to: fresh)
        try FileDates.set(fresh, to: now.addingTimeInterval(-10 * 60))
        // Made when the fixture was, which is after `now`: dated inside the grace period instead.
        try FileDates.set(fixture.url(for: FakeDownloadsFolder.Names.freshDownload), to: now.addingTimeInterval(-20 * 60))
    }

    static func daysAgo(_ days: Int) -> Date {
        now.addingTimeInterval(-Double(days) * 24 * 60 * 60)
    }

    // MARK: - Hostile files

    /// Adds a hostile file, dated like the rest, with a download site when given.
    func add(hostile name: String, site: String?) async throws {
        let url = fixture.url(for: name)
        try Data("hostile \(name)".utf8).write(to: url)
        try FileDates.set(url, to: Self.daysAgo(4))
        if let site {
            try ExtendedAttributes.setWhereFroms(["https://\(site)/download", "https://\(site)/"], on: url)
        }
        try await rescan()
    }

    func remove(hostile name: String) async throws {
        try FileManager.default.removeItem(at: fixture.url(for: name))
        try await rescan()
    }

    // MARK: - What the app hands the chat

    var installers: InstallerSources {
        InstallerSources.testing(applications: [fixture.applicationsURL], cache: log, mounts: mounts)
    }

    var eligibility: CandidateEligibility {
        CandidateEligibility(keptItems: state.withLock { $0.keptItems })
    }

    /// Reads the folder again, with its marks, as the file list does after a change.
    func rescan() async throws {
        let records = try await FolderScanner().scan(folder).records
        let keptItems = try await log.keptItems(for: folder)
        let eligibility = CandidateEligibility(keptItems: keptItems)
        let installed = await InstallerPlanner.strongMatches(
            among: records, in: folder, applicationFolders: [fixture.applicationsURL], cache: log, receipts: .fixed([])
        )
        let files = records.map { record in
            FolderSnapshot.File(
                record,
                marks: FileMarker.marks(
                    for: record, in: folder, now: Self.now, settings: Self.settings, eligibility: eligibility,
                    isInstalled: installed.contains(record.id)
                ),
                folder: "Downloads"
            )
        }
        let snapshot = FolderSnapshot(
            files: files, folders: [FolderSnapshot.Folder(name: "Downloads", isCurrent: true)], bytesMovedToTrash: 0, now: Self.now
        )
        state.withLock { state in
            state.records = records
            state.keptItems = keptItems
            state.snapshot = snapshot
        }
    }

    var snapshot: FolderSnapshot {
        state.withLock { $0.snapshot }
    }

    var names: Set<String> {
        Set(state.withLock { $0.records.map(\.displayName) })
    }

    /// Find Duplicates for the chat: this one folder, or none for a folder it does not have.
    func findDuplicates(_ scope: FolderScope) async -> DuplicateScan? {
        if case .folder(let name) = scope, name != "Downloads" { return nil }
        let (records, keptItems) = state.withLock { ($0.records, $0.keptItems) }
        let eligibility = CandidateEligibility(keptItems: keptItems)
        guard let plan = try? await ChatPlanning.findDuplicates(
            records: records, folder: folder, eligibility: eligibility, keptItems: keptItems,
            installers: installers, hashCache: hashCache, now: Self.now
        ) else { return nil }
        let marks = Dictionary(snapshot.files.map { ($0.id, $0.marks) }, uniquingKeysWith: { first, _ in first })
        return ChatPlanning.duplicateScan(
            plan, records: records, folder: folder, eligibility: eligibility,
            marks: { record in (marks[record.id] ?? []).map(\.fileMark) }, folderName: nil, now: Self.now
        )
    }

    /// `proposeCleanup` as the app runs it: planned, its files kept by the card's id, rows handed back.
    func propose(_ request: CleanupRequest, only ids: Set<URL>?) async -> CleanupProposal? {
        if let name = request.folder, name != "Downloads" { return nil }
        let notOffered = ChatPlanning.notOffered(request, rules: folder.rules)
        if notOffered.count == request.actions.count {
            return CleanupProposal(request: request, rows: [], sampleNames: [], notOffered: notOffered)
        }
        let (records, keptItems) = state.withLock { ($0.records, $0.keptItems) }
        guard let plan = try? await ChatPlanning.plan(
            request, only: ids, records: records, folder: folder, eligibility: CandidateEligibility(keptItems: keptItems),
            keptItems: keptItems, installers: installers, stored: Self.settings, hashCache: hashCache, now: Self.now
        ), ChatPlanning.isWorthACard(plan) else { return nil }
        // As the app does: what was read from installers is kept, so no disk image is read twice.
        try? await log.storeInstallerFacts(plan.plans.flatMap(\.installerFactsRead), now: Self.now)
        let proposal = ChatPlanning.proposal(plan, for: request, notOffered: notOffered)
        let files = plan.plans.flatMap(\.changes).map(\.record.displayName)
        state.withLock { $0.planned[proposal.id] = files }
        return proposal
    }

    func plannedFiles(of id: CleanupProposal.ID) -> [String] {
        state.withLock { $0.planned[id] ?? [] }
    }
}
