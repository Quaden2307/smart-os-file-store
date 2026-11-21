import FileStoreCore
import Foundation
import Testing

/// Each folder chooses its cleanups (decision record 0028): the defaults table, and the rules held
/// where plans are made, so no caller can plan an action a folder does not offer.
@Suite("Folder rules")
struct FolderRulesTests {
    private static let kinds: [ManagedFolder.Kind] = [.downloads, .desktop, .documents, .custom]

    @Test func theDefaultsAreTheTable() {
        let all = Set(CleanupAction.allCases)
        let downloads = FolderRules.defaults(for: .downloads)
        #expect(downloads.offered == all)
        #expect(downloads.inTidyNow == all)
        #expect(downloads.ticksByDefault)

        let desktop = FolderRules.defaults(for: .desktop)
        #expect(desktop.offered == all.subtracting([.archiveOldDownloads]))
        #expect(desktop.inTidyNow == [.findDuplicates, .fixMessyNames, .reviewNearDuplicates, .reviewLargeDownloads, .removeEmptyFolders])
        #expect(desktop.offers(.removeUsedInstallers) && desktop.offers(.removeUnpackedZips) && desktop.offers(.clearFailedDownloads))
        #expect(desktop.ticksByDefault)

        for kind in [ManagedFolder.Kind.documents, .custom] {
            let rules = FolderRules.defaults(for: kind)
            #expect(rules.offered == [.findDuplicates, .reviewNearDuplicates, .reviewLargeDownloads, .removeEmptyFolders])
            #expect(rules.inTidyNow.isEmpty)
            #expect(rules.tidyNowActions.isEmpty)
            #expect(!rules.ticksByDefault)
            // Nothing that removes a file because of its age.
            #expect(!rules.offers(.archiveOldDownloads))
        }
        // A folder gets its kind's defaults unless it says otherwise.
        #expect(ManagedFolder(kind: .documents, url: URL(filePath: "/x")).rules == .defaults(for: .documents))
    }

    @Test func aFolderThresholdReplacesOnlyItsOwnSetting() {
        var rules = FolderRules.defaults(for: .desktop)
        rules.oldAfterDays = 400
        let global = CleanupSettings(unusedAfterDays: 45, oldAfterDays: 90, largeDownloadMegabytes: 700)
        let settings = rules.settings(over: global)
        #expect(settings == CleanupSettings(unusedAfterDays: 45, oldAfterDays: 400, largeDownloadMegabytes: 700))
        #expect(FolderRules.defaults(for: .downloads).settings(over: global) == global)
    }

    @Test func rulesSurviveTheLogAndResetToDefaults() async throws {
        try await withTemporaryFolderAsync { root in
            let home = try await ManagedHome(root: root)
            var rules = FolderRules.defaults(for: .desktop)
            rules.offered.remove(.findDuplicates)
            rules.largeFileMegabytes = 50
            try await home.registry.setRules(rules, of: home.desktop.id, in: home.log)
            let found = try #require(try await home.registry.folders(in: home.log).first { $0.id == home.desktop.id })
            #expect(found.rules == rules)

            try await home.registry.setRules(nil, of: home.desktop.id, in: home.log)
            let reset = try #require(try await home.registry.folders(in: home.log).first { $0.id == home.desktop.id })
            #expect(reset.rules == .defaults(for: .desktop))
            // Rules are not history: no run was recorded.
            #expect(try await home.log.runs().isEmpty)
        }
    }

    /// One case per action per kind of folder: an action the kind does not offer has no plan,
    /// through `CleanupPlanners` and through `TidyNowPlanner` asked for it by name, as the chat asks.
    @Test(arguments: FolderRulesTests.kinds)
    func aDisabledActionCannotBePlannedFromAnyEntryPoint(kind: ManagedFolder.Kind) async throws {
        let folder = ManagedFolder(kind: kind, url: FileManager.default.temporaryDirectory)
        for action in CleanupAction.allCases where CleanupPlanners.hasPlanner(action) {
            let plan = try await CleanupPlanners.plan(
                action, records: [], in: folder, eligibility: CandidateEligibility(), keptItems: KeptItems(), installers: .testing()
            )
            #expect((plan != nil) == folder.rules.offers(action), "\(kind) \(action)")

            let tidy = TidyNowPlanner(
                actions: [action], eligibility: CandidateEligibility(), keptItems: KeptItems(), installers: .testing(),
                records: [], folder: folder
            )
            #expect(tidy.actions == (folder.rules.offers(action) ? [action] : []), "\(kind) \(action)")
            let planned = try await tidy.plan()
            #expect(planned.outcomes.map(\.action) == tidy.actions)
        }
        // Tidy Now on its own runs the folder's Tidy Now actions.
        let tidyNow = TidyNowPlanner(eligibility: CandidateEligibility(), keptItems: KeptItems(), installers: .testing(), records: [], folder: folder)
        #expect(tidyNow.actions == folder.rules.tidyNowActions)
    }

    @Test func turningAnActionOffRemovesItFromThatFolderOnly() async throws {
        var rules = FolderRules.defaults(for: .downloads)
        rules.offered.remove(.fixMessyNames)
        let off = ManagedFolder(kind: .downloads, url: FileManager.default.temporaryDirectory, rules: rules)
        let on = ManagedFolder(kind: .downloads, url: FileManager.default.temporaryDirectory)
        for (folder, expected) in [(off, false), (on, true)] {
            let plan = try await CleanupPlanners.plan(
                .fixMessyNames, records: [], in: folder, eligibility: CandidateEligibility(), keptItems: KeptItems(), installers: .testing()
            )
            #expect((plan != nil) == expected)
        }
        #expect(!rules.tidyNowActions.contains(.fixMessyNames))
    }

    /// Documents ticks nothing: every planner, run on the fake folder under rules that offer every
    /// action but tick like Documents, leaves the preview's default ticks empty, though the same
    /// plans in Downloads tick something.
    @Test(arguments: PlannersRespectKeptTests.plannedActions)
    func documentsNeverTicksAFileByDefault(action: CleanupAction) async throws {
        try await withFakeDownloadsFolder { fixture in
            let records = try await RelocationPlans.records(in: fixture.url)
            var documentsRules = FolderRules.defaults(for: .documents)
            documentsRules.offered = Set(CleanupAction.allCases)
            let documents = ManagedFolder(kind: .documents, url: fixture.url, rules: documentsRules)
            let downloads = ManagedFolder(kind: .downloads, url: fixture.url)
            var anyTicked = false
            for folder in [documents, downloads] {
                let plan = try #require(try await CleanupPlanners.plan(
                    action, records: records, in: folder, eligibility: CandidateEligibility(), keptItems: KeptItems(),
                    installers: .testing(applications: [fixture.applicationsURL]), settings: PlannersRespectKeptTests.settings
                ))
                #expect(!plan.changes.isEmpty)
                if folder.kind == .documents {
                    #expect(plan.defaultTickedIDs.isEmpty)
                } else {
                    anyTicked = anyTicked || !plan.defaultTickedIDs.isEmpty
                }
            }
            // Review-only actions tick nothing anywhere; the others tick something in Downloads.
            let reviewOnly: Set<CleanupAction> = [.reviewNearDuplicates, .reviewLargeDownloads]
            #expect(anyTicked == !reviewOnly.contains(action))
        }
    }
}
