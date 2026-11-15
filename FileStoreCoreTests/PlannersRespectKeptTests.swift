import FileStoreCore
import Foundation
import Testing

/// Every planner `CleanupPlanners` lists, run on the fake Downloads folder: none ever names a Kept
/// item as a change or as an unchecked file. A new planner is covered by being listed there.
@Suite("Every planner respects Kept")
struct PlannersRespectKeptTests {
    /// The actions with a planner today, in declaration order. A new one must be added here too, so
    /// that this test is seen to cover it, and it must find something to propose in the fake folder.
    static let plannedActions: [CleanupAction] = [.findDuplicates, .clearFailedDownloads]

    private func plan(_ action: CleanupAction, _ records: [FileRecord], in folder: URL, keeping keptItems: KeptItems) async throws -> CleanupPlan? {
        try await CleanupPlanners.plan(action, records: records, in: folder, eligibility: CandidateEligibility(), keptItems: keptItems)
    }

    /// The records a plan names as changing or as unchecked. A group's kept copy is neither: a Kept
    /// file may be the copy a group keeps.
    private func named(in plan: CleanupPlan, among records: [FileRecord]) -> [FileRecord] {
        let urls = Set(plan.changes.map(\.id) + plan.duplicateGroups.flatMap { $0.duplicates.map(\.id) } + plan.skippedItems.map(\.url))
        return records.filter { urls.contains($0.id) }
    }

    @Test func theListedPlannersAreTheOnesThisTestExpects() async throws {
        var planned: [CleanupAction] = []
        for action in CleanupAction.allCases where try await plan(action, [], in: FileManager.default.temporaryDirectory, keeping: KeptItems()) != nil {
            planned.append(action)
        }
        #expect(planned == Self.plannedActions)
        // The app offers exactly the actions with a planner.
        #expect(CleanupAction.allCases.filter(CleanupPlanners.hasPlanner) == Self.plannedActions)
    }

    @Test(arguments: PlannersRespectKeptTests.plannedActions)
    func noPlannerNamesAKeptItem(action: CleanupAction) async throws {
        try await withFakeDownloadsFolder { fixture in
            let records = try await RelocationPlans.records(in: fixture.url)
            let log = try await ActivityLog.open(.inMemory)

            // Without Kept the planner has something to propose, or this test would prove nothing.
            let unkept = try #require(try await plan(action, records, in: fixture.url, keeping: KeptItems()))
            let proposed = named(in: unkept, among: records)
            #expect(!unkept.changes.isEmpty)

            // Everything it proposed is now Kept: none of it may be named again.
            try await log.keep(proposed)
            let keptProposed = try await log.keptItems(forFolder: fixture.url)
            let again = try #require(try await plan(action, records, in: fixture.url, keeping: keptProposed))
            #expect(named(in: again, among: records).filter(keptProposed.contains).isEmpty)

            // Everything is Kept: nothing is proposed or named at all.
            try await log.keep(records)
            let all = try await log.keptItems(forFolder: fixture.url)
            let none = try #require(try await plan(action, records, in: fixture.url, keeping: all))
            #expect(none.isEmpty)
            #expect(named(in: none, among: records).isEmpty)
        }
    }
}
