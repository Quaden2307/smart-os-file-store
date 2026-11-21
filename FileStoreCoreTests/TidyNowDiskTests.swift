import FileStoreCore
import Foundation
import Synchronization
import Testing

/// Tidy Now on the fake Downloads folder: what it finds, carrying all of it out as one run, finding
/// nothing more afterwards, and one Undo restoring the folder file by file. Also a planner that
/// throws, and cancelling mid-scan.
@Suite("Tidy Now on disk", .serialized)
struct TidyNowDiskTests {
    /// As every planner's test: a large download from 1 MB, so the fixture's `big-video.mov` is one.
    static let settings = CleanupSettings(largeDownloadMegabytes: 1)

    typealias Names = FakeDownloadsFolder.Names

    static func planner(_ fixture: FakeDownloadsFolder, records: [FileRecord], keptItems: KeptItems = KeptItems()) -> TidyNowPlanner {
        TidyNowPlanner(
            eligibility: CandidateEligibility(),
            keptItems: keptItems,
            installers: .testing(applications: [fixture.applicationsURL]),
            settings: settings,
            records: records,
            folder: .temporary(fixture.url)
        )
    }

    static func names(_ plan: TidyNowPlan) -> [CleanupAction: Set<String>] {
        Dictionary(plan.plans.map { ($0.action, Set($0.changes.map(\.record.displayName))) }, uniquingKeysWith: { first, _ in first })
    }

    /// What the preview ticks by itself: everything but review lists and possible matches.
    static func defaultTicks(_ plan: TidyNowPlan) -> Set<ProposedChange.ID> {
        Set(plan.plans.flatMap(\.changes).filter { !$0.reason.isReviewOnly && !$0.reason.isPossibleMatch }.map(\.id))
    }

    /// The top level of `folder`, with the archive folder's own date left out (moving files in and
    /// out of it changes it), plus the archive's entries.
    static func snapshot(of folder: URL) -> (top: Set<DiskState.Entry>, archive: Set<DiskState.Entry>) {
        let archiveName = Array(Names.archiveFolder.utf8)
        let top = DiskState.snapshot(of: folder).filter { $0.name != archiveName }
        return (top, DiskState.snapshot(of: folder.appending(path: Names.archiveFolder)))
    }

    @Test func findsTheExpectedCategoriesThenTidiesUpAsOneRunThatOneUndoReverses() async throws {
        try await withFakeDownloadsFolder { fixture in
            let before = Self.snapshot(of: fixture.url)
            let records = try await RelocationPlans.records(in: fixture.url)
            let plan = try await Self.planner(fixture, records: records).plan()

            // Each file in one category, by priority: the duplicate copies are not renamed, and the
            // possible installer match and the large download wait for review.
            #expect(plan.outcomes.allSatisfy { $0.outcome != .failed })
            #expect(Self.names(plan) == [
                .clearFailedDownloads: [Names.chromeDownload, Names.partialDownload, Names.safariDownload],
                .removeUsedInstallers: [Names.usedAppZip, Names.package],
                .removeUnpackedZips: [Names.zipArchive, Names.singleFileZip],
                .findDuplicates: [Names.reportCopy1, Names.reportCopy2, Names.lockedReportCopy, Names.reportCopyWord, Names.photoCopy, Names.receiptCopy],
                .removeEmptyFolders: [Names.emptyFolder, Names.dsStoreFolder],
                .archiveOldDownloads: [Names.oldReceipt, Names.oldManual],
                .fixMessyNames: [
                    Names.numberedName, Names.copyWordName, Names.percentEncodedName, Names.queryLeftoverName,
                    Names.doubledExtensionName, Names.invoiceCopy, Names.agendaNumbered, Names.agendaCopyWord, Names.notesEdited,
                ],
                .reviewNearDuplicates: [],
                .reviewLargeDownloads: [Names.bigVideo],
            ])
            #expect(plan.duplicateURLs == Set(plan.plans.first { $0.action == .findDuplicates }?.changes.map(\.id) ?? []))

            // Everything ticked by default: 14 to the Trash, 2 archived, 9 renamed; the possible
            // match and the large download stay unticked.
            let ticked = Self.defaultTicks(plan)
            let tickedChanges = plan.plans.flatMap(\.changes).filter { ticked.contains($0.id) }
            #expect(tickedChanges.filter { $0.operation == .moveToTrash }.count == 14)
            #expect(tickedChanges.filter { if case .move = $0.operation { true } else { false } }.count == 2)
            #expect(tickedChanges.filter { if case .rename = $0.operation { true } else { false } }.count == 9)
            #expect(!ticked.contains(fixture.url.appending(path: Names.package)))
            #expect(!ticked.contains(fixture.url.appending(path: Names.bigVideo)))

            let log = try await ActivityLog.open(.inMemory)
            let executor = CleanupExecutor(recorder: log, applicationFolders: [fixture.applicationsURL], receipts: .fixed([]))
            let result = await executor.executeTidyNow(plans: plan.plans, confirmedChangeIDs: ticked)
            let runID = try #require(result.runID)
            #expect(result.logFailure == nil)
            #expect(result.results.allSatisfy { $0.runID == runID })
            let failed = result.results.flatMap(\.failed).map(\.change.record.displayName)
            let skipped = result.results.flatMap(\.skipped).map(\.change.record.displayName)
            // Only the locked copy fails; nothing renamed after its duplicate went was mistaken for changed.
            #expect(failed == [Names.lockedReportCopy])
            #expect(skipped.isEmpty)
            #expect(try await log.runs().filter { !$0.isUndo }.count == 1)
            let run = try #require(try await log.run(id: runID))
            #expect(run.isTidyNow)
            #expect(try await log.changes(inRun: runID).count == ticked.count)

            // Again: nothing left to tidy but the file that could not be moved, and the review lists.
            let after = try await RelocationPlans.records(in: fixture.url)
            let again = try await Self.planner(fixture, records: after).plan()
            let againTicked = again.plans.flatMap(\.changes).filter { Self.defaultTicks(again).contains($0.id) }
            #expect(againTicked.map(\.record.displayName) == [Names.lockedReportCopy])
            #expect(Self.names(again)[.removeUsedInstallers] == [Names.package])
            #expect(Self.names(again)[.reviewLargeDownloads] == [Names.bigVideo])

            // One Undo of the run puts every file back exactly as it was.
            let undo = try await UndoFixtures.undo(.run(runID), in: fixture.url, trash: .system, log: log)
            #expect(undo.notUndone.isEmpty)
            #expect(undo.undone.count == ticked.count - 1)
            let restored = Self.snapshot(of: fixture.url)
            #expect(restored.top == before.top)
            #expect(restored.archive == before.archive)
        }
    }

    @Test func aFileRenamedAfterItsDuplicateWasTrashedIsStillRecognised() async throws {
        try await withTemporaryFolderAsync { folder in
            // Two identical copies, both with copy numbers: one is kept and renamed, the other trashed.
            try FileDates.writeSettled(["photo (1).jpg": "same photo", "photo (2).jpg": "same photo"], in: folder)
            let records = try await RelocationPlans.records(in: folder)
            let planner = TidyNowPlanner(
                eligibility: CandidateEligibility(),
                keptItems: KeptItems(),
                installers: .testing(),
                records: records,
                folder: .temporary(folder)
            )
            let plan = try await planner.plan()
            let duplicates = try #require(plan.plans.first { $0.action == .findDuplicates })
            let renames = try #require(plan.plans.first { $0.action == .fixMessyNames })
            #expect(duplicates.changes.count == 1)
            #expect(renames.changes.map(\.operation) == [.rename(to: "photo.jpg")])
            #expect(renames.changes.first?.id == duplicates.duplicateGroups.first?.kept.url)

            let log = try await ActivityLog.open(.inMemory)
            let result = await CleanupExecutor(recorder: log).executeTidyNow(plans: plan.plans, confirmedChangeIDs: Self.defaultTicks(plan))
            let items = result.results.flatMap(\.items)
            #expect(items.count == 2)
            #expect(items.allSatisfy { $0.isDone })
            #expect(DiskState.entryNames(in: folder) == ["photo.jpg"])
        }
    }

    @Test func onePlannerThrowingDoesNotStopTheOthers() async throws {
        struct Broken: Error {}
        try await withFakeDownloadsFolder { fixture in
            let records = try await RelocationPlans.records(in: fixture.url)
            let installers = InstallerSources.testing(applications: [fixture.applicationsURL])
            let planner = TidyNowPlanner(folder: .temporary(fixture.url), now: .now, eligibility: CandidateEligibility(), keptItems: KeptItems()) { action, cache, progress in
                if action == .removeUnpackedZips {
                    throw Broken()
                }
                return try await CleanupPlanners.plan(
                    action, records: records, in: .temporary(fixture.url), eligibility: CandidateEligibility(), keptItems: KeptItems(),
                    installers: installers, settings: Self.settings, hashCache: cache, onProgress: progress
                )
            }
            let events = Events()
            let plan = try await planner.plan { events.append($0) }
            #expect(plan.outcomes.first { $0.action == .removeUnpackedZips }?.outcome == .failed)
            #expect(plan.plans.count == TidyNowPlan.order.count - 1)
            #expect(Self.names(plan)[.findDuplicates]?.isEmpty == false)
            #expect(events.finished == Set(TidyNowPlan.order))
            #expect(events.failed == [.removeUnpackedZips])
        }
    }

    @Test func cancellingMidScanChangesNothing() async throws {
        try await withFakeDownloadsFolder { fixture in
            let before = DiskState.snapshot(of: fixture.url)
            let records = try await RelocationPlans.records(in: fixture.url)
            let installers = InstallerSources.testing(applications: [fixture.applicationsURL])
            let (started, signal) = AsyncStream.makeStream(of: Void.self)
            let planner = TidyNowPlanner(folder: .temporary(fixture.url), now: .now, eligibility: CandidateEligibility(), keptItems: KeptItems()) { action, cache, progress in
                if action == .findDuplicates {
                    // Still reading when the user cancels.
                    signal.yield()
                    try await Task.sleep(for: .seconds(60))
                }
                return try await CleanupPlanners.plan(
                    action, records: records, in: .temporary(fixture.url), eligibility: CandidateEligibility(), keptItems: KeptItems(),
                    installers: installers, settings: Self.settings, hashCache: cache, onProgress: progress
                )
            }
            let task = Task { try await planner.plan() }
            for await _ in started {
                break
            }
            task.cancel()
            await #expect(throws: CleanupPlanningError.cancelled) {
                try await task.value
            }
            #expect(DiskState.snapshot(of: fixture.url) == before)
        }
    }
}

/// The events a Tidy Now planner reported, from any thread.
private final class Events: Sendable {
    private let state = Mutex<(finished: Set<CleanupAction>, failed: Set<CleanupAction>)>(([], []))

    func append(_ event: TidyNowPlanningEvent) {
        if case .finished(let action, let failed) = event {
            state.withLock { state in
                state.finished.insert(action)
                if failed {
                    state.failed.insert(action)
                }
            }
        }
    }

    var finished: Set<CleanupAction> { state.withLock { $0.finished } }
    var failed: Set<CleanupAction> { state.withLock { $0.failed } }
}
