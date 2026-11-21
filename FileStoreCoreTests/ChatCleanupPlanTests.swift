import FileStoreCore
import Foundation
import Testing

/// A cleanup asked for in the chat is planned by `TidyNowPlanner` with a list of actions and,
/// when the request named files, narrowed to them. On the fake Downloads folder: the plans are the
/// planners' own, narrowing and the priority rule hold, Kept, the grace period and the archive are
/// respected, a waiting plan knows when a file changed, and a confirmed one is logged as started
/// from the chat and undone like any run. The chat module's side is in `FileStoreIntelligenceTests`.
@Suite("Cleanups planned for the chat", .serialized)
struct ChatCleanupPlanTests {
    typealias Names = FakeDownloadsFolder.Names

    static let settings = TidyNowDiskTests.settings
    static let now = Date.now

    static func planner(
        _ actions: [CleanupAction], _ fixture: FakeDownloadsFolder, records: [FileRecord], keptItems: KeptItems = KeptItems()
    ) -> TidyNowPlanner {
        TidyNowPlanner(
            actions: actions, eligibility: CandidateEligibility(), keptItems: keptItems,
            installers: .testing(applications: [fixture.applicationsURL]), settings: settings, records: records,
            folder: .temporary(fixture.url), now: now
        )
    }

    /// The planner called directly, as the Clean Up menu calls it.
    static func direct(_ action: CleanupAction, _ fixture: FakeDownloadsFolder, records: [FileRecord]) async throws -> CleanupPlan {
        try #require(try await CleanupPlanners.plan(
            action, records: records, in: .temporary(fixture.url), eligibility: CandidateEligibility(), keptItems: KeptItems(),
            installers: .testing(applications: [fixture.applicationsURL]), now: now, settings: settings
        ))
    }

    /// The scan's own URLs for `names`: a plan is keyed on those, however the folder's path is spelled.
    static func ids(_ records: [FileRecord], _ names: String...) -> Set<URL> {
        Set(records.filter { names.contains($0.displayName) }.map(\.url))
    }

    @Test(arguments: PlannersRespectKeptTests.plannedActions)
    func oneActionGivesThePlanOfItsPlannerCalledDirectly(action: CleanupAction) async throws {
        try await withFakeDownloadsFolder { fixture in
            let records = try await RelocationPlans.records(in: fixture.url)
            let plan = try await Self.planner([action], fixture, records: records).plan()
            let direct = try await Self.direct(action, fixture, records: records)
            #expect(plan.outcomes.map(\.action) == [action])
            #expect(plan.plans.first?.changes == direct.changes)
            #expect(plan.plans.first?.duplicateGroups == direct.duplicateGroups)
        }
    }

    @Test(arguments: [
        [CleanupAction.removeUsedInstallers, .findDuplicates, .fixMessyNames],
        [.archiveOldDownloads, .fixMessyNames, .reviewLargeDownloads],
        PlannersRespectKeptTests.plannedActions,
    ])
    func severalActionsGiveTheirPlannersPlansMergedByTheTidyNowRule(actions: [CleanupAction]) async throws {
        try await withFakeDownloadsFolder { fixture in
            let records = try await RelocationPlans.records(in: fixture.url)
            // Asked for in any order; planned in Tidy Now's.
            let plan = try await Self.planner(actions.reversed(), fixture, records: records).plan()
            var direct: [CleanupPlan] = []
            for action in actions {
                direct.append(try await Self.direct(action, fixture, records: records))
            }
            let merged = TidyNowPlan.resolve(direct, eligibility: CandidateEligibility(), now: Self.now)
            #expect(plan.outcomes.map(\.action) == TidyNowPlan.order.filter(actions.contains))
            #expect(plan.plans.map(\.changes) == merged.map(\.changes))
            // A file appears once.
            let all = plan.plans.flatMap { $0.changes.map(\.id) }
            #expect(Set(all).count == all.count)
            #expect(!all.isEmpty)
        }
    }

    @Test func narrowingKeepsOnlyTheNamedFilesAndRemovalStillBeatsRename() async throws {
        try await withFakeDownloadsFolder { fixture in
            let records = try await RelocationPlans.records(in: fixture.url)
            // Three files asked for: a duplicate copy, a messy name, and one no action proposes.
            let only = Self.ids(records, Names.reportCopy1, Names.numberedName, Names.taxForm)
            #expect(only.count == 3)
            let both = try await Self.planner([.findDuplicates, .fixMessyNames], fixture, records: records).plan(only: only)
            #expect(TidyNowDiskTests.names(both) == [.findDuplicates: [Names.reportCopy1], .fixMessyNames: [Names.numberedName]])
            // Its group goes on naming the copy it keeps, which the executor needs.
            #expect(both.plans.first?.duplicateGroups.map(\.kept.displayName) == [Names.reportPDF])
            #expect(both.plans.first?.duplicateGroups.first?.duplicates.map(\.displayName) == [Names.reportCopy1])
            // Narrowed, each plan is its planner's own, less the files not asked for.
            for plan in both.plans {
                let direct = try await Self.direct(plan.action, fixture, records: records)
                #expect(plan.changes == direct.changes.filter { only.contains($0.id) })
            }

            // No file asked for is no change at all: an empty set is not "every file".
            let none = try await Self.planner(PlannersRespectKeptTests.plannedActions, fixture, records: records).plan(only: [])
            #expect(none.plans.flatMap(\.changes).isEmpty)
        }
    }

    @Test func aFileTwoChosenActionsProposeGoesToTheRemovalAndToTheRenameWhenAskedAlone() async throws {
        try await withTemporaryFolderAsync { folder in
            // Two identical copies with copy numbers: both have a messy name, and one is a duplicate.
            try FileDates.writeSettled(["photo (1).jpg": "same photo", "photo (2).jpg": "same photo"], in: folder)
            let records = try await RelocationPlans.records(in: folder)
            func plan(_ actions: [CleanupAction], only: Set<URL>) async throws -> TidyNowPlan {
                try await TidyNowPlanner(
                    actions: actions, eligibility: CandidateEligibility(), keptItems: KeptItems(), installers: .testing(),
                    records: records, folder: .temporary(folder)
                ).plan(only: only)
            }
            let copy = try #require(try await plan([.findDuplicates], only: Set(records.map(\.url))).plans.first?.changes.first?.id)

            let both = try await plan([.fixMessyNames, .findDuplicates], only: [copy])
            #expect(both.plans.map { $0.changes.map(\.id) } == [[copy], []])
            #expect(both.plans.first?.changes.first?.operation == .moveToTrash)

            let alone = try await plan([.fixMessyNames], only: [copy])
            #expect(alone.plans.map { $0.changes.map(\.id) } == [[copy]])
        }
    }

    @Test func archiveBeatsRenameAmongChosenActions() {
        let file = TidyNowResolveTests.record("old report (1).pdf")
        let plans = [
            TidyNowResolveTests.plan(.fixMessyNames, [TidyNowResolveTests.rename(file, to: "old report.pdf")]),
            TidyNowResolveTests.plan(.archiveOldDownloads, [TidyNowResolveTests.archiveMove(file)]),
        ]
        let resolved = TidyNowResolveTests.resolve(plans)
        #expect(TidyNowResolveTests.names(resolved[.archiveOldDownloads]) == ["old report (1).pdf"])
        #expect(TidyNowResolveTests.names(resolved[.fixMessyNames]).isEmpty)
    }

    @Test func noPlanHoldsAKeptFileAFileInsideTheGracePeriodOrTheArchive() async throws {
        try await withFakeDownloadsFolder { fixture in
            // A copy made just now: inside the grace period.
            let fresh = fixture.url.appending(path: Names.freshReportCopy)
            try Data(FakeDownloadsFolder.reportContents.utf8).write(to: fresh)
            let records = try await RelocationPlans.records(in: fixture.url)
            let log = try await ActivityLog.open(.inMemory)
            let keptNames = [Names.reportCopy1, Names.numberedName, Names.oldReceipt, Names.usedAppZip, Names.bigVideo]
            try await log.keep(records.filter { keptNames.contains($0.displayName) })
            let kept = try await log.keptItems(for: log.downloads(at: fixture.url))
            let archive = fixture.url.appending(path: Names.archiveFolder, directoryHint: .isDirectory)

            let all = PlannersRespectKeptTests.plannedActions
            let whole = try await Self.planner(all, fixture, records: records, keptItems: kept).plan()
            let narrowed = try await Self.planner(all, fixture, records: records, keptItems: kept).plan(only: Set(records.map(\.url)))
            for plan in [whole, narrowed] {
                let changes = plan.plans.flatMap(\.changes)
                #expect(!changes.isEmpty)
                #expect(!changes.contains { kept.contains($0.record) })
                #expect(!changes.contains { $0.id == fresh })
                #expect(!changes.contains { $0.id.path.hasPrefix(archive.path) })
                // Clear Failed Downloads has its own rule for a download in progress; every other
                // shared rule holds for every change.
                #expect(!changes.contains { CandidateEligibility(keptItems: kept).refusal(for: $0.record, in: log.downloads(at: fixture.url), now: Self.now, downloads: .allowed) != nil })
            }
        }
    }

    @Test func aWaitingPlanKnowsWhichOfItsFilesChangedOnDisk() async throws {
        try await withFakeDownloadsFolder { fixture in
            let records = try await RelocationPlans.records(in: fixture.url)
            let plan = try await Self.planner([.findDuplicates, .fixMessyNames], fixture, records: records).plan()
            let plans = plan.plans
            #expect(plans.flatMap { $0.staleChangeIDs(in: records) }.isEmpty)

            // One file gets more bytes, one goes away, and a file no change names is edited.
            try Data("another report altogether".utf8).write(to: fixture.url.appending(path: Names.reportCopy1))
            try FileManager.default.removeItem(at: fixture.url.appending(path: Names.numberedName))
            try Data("new notes".utf8).write(to: fixture.url.appending(path: Names.taxForm))

            let after = try await RelocationPlans.records(in: fixture.url)
            #expect(Set(plans.flatMap { $0.staleChangeIDs(in: after) }) == Self.ids(records, Names.reportCopy1, Names.numberedName))

            // The copy a group keeps goes away: its duplicates no longer stand either, though
            // none of them changed.
            try FileManager.default.removeItem(at: fixture.url.appending(path: Names.photo))
            let withoutKept = try await RelocationPlans.records(in: fixture.url)
            let stale = Set(plans.flatMap { $0.staleChangeIDs(in: withoutKept) })
            #expect(stale.isSuperset(of: Self.ids(records, Names.photoCopy)))
            #expect(!stale.contains { $0.lastPathComponent == Names.receiptCopy })
        }
    }

    @Test func aConfirmedPlanIsLoggedAsStartedFromTheChatAndOneUndoReversesIt() async throws {
        try await withFakeDownloadsFolder { fixture in
            let before = TidyNowDiskTests.snapshot(of: fixture.url)
            let records = try await RelocationPlans.records(in: fixture.url)
            let only = Self.ids(records, Names.reportCopy1, Names.numberedName, Names.oldReceipt)
            let plan = try await Self.planner([.findDuplicates, .fixMessyNames, .archiveOldDownloads], fixture, records: records).plan(only: only)
            let ticked = TidyNowDiskTests.defaultTicks(plan)
            #expect(ticked == only)

            let log = try await ActivityLog.open(.inMemory)
            let executor = CleanupExecutor(recorder: log, applicationFolders: [fixture.applicationsURL], receipts: .fixed([]))
            let result = await executor.executeTidyNow(plans: plan.plans, confirmedChangeIDs: ticked, origin: .chat)
            let runID = try #require(result.runID)
            #expect(result.results.flatMap(\.items).filter(\.isDone).count == 3)
            let run = try #require(try await log.run(id: runID))
            #expect(run.origin == .chat)
            #expect(run.isTidyNow)
            let latest = try await log.latestCleanupRun()
            #expect(latest?.origin == .chat)

            let undo = try await UndoFixtures.undo(.run(runID), in: fixture.url, trash: .system, log: log)
            #expect(undo.notUndone.isEmpty)
            #expect(undo.undone.count == 3)
            let restored = TidyNowDiskTests.snapshot(of: fixture.url)
            #expect(restored.top == before.top)
            #expect(restored.archive == before.archive)
            // The undo is the app's own run, and the cleanup stays marked as the chat's.
            let runs = try await log.runs()
            #expect(runs.first { $0.isUndo }?.origin == .app)
            #expect(runs.first { $0.id == runID }?.origin == .chat)
        }
    }

    @Test func aRunStartedInTheAppIsNotMarkedAsFromTheChat() async throws {
        try await withFakeDownloadsFolder { fixture in
            let records = try await RelocationPlans.records(in: fixture.url)
            let plan = try await Self.planner([.fixMessyNames], fixture, records: records).plan(only: Self.ids(records, Names.numberedName))
            let log = try await ActivityLog.open(.inMemory)
            let result = await CleanupExecutor(recorder: log).executeTidyNow(plans: plan.plans, confirmedChangeIDs: TidyNowDiskTests.defaultTicks(plan))
            let run = try await log.run(id: try #require(result.runID))
            #expect(run?.origin == .app)
        }
    }
}
