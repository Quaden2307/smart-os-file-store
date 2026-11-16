import FileStoreCore
import Testing

/// Each action's definition: the identifiers the activity log stores never change and never repeat,
/// and each action allows only the operation its definition states.
@Suite("Cleanup action definitions")
struct CleanupActionDefinitionTests {
    @Test func identifiersAreExactlyTheOnesTheLogHasAlwaysStored() {
        let identifiers = CleanupAction.allCases.map(\.definition.identifier)
        #expect(identifiers == ["findDuplicates", "clearFailedDownloads", "removeUnpackedZips", "removeUsedInstallers", "fixMessyNames", "reviewNearDuplicates", "archiveOldDownloads", "reviewLargeDownloads", "removeEmptyFolders"])
        #expect(Set(identifiers).count == identifiers.count)
        // The codes the log stores for runs that are not one action's are no action's.
        #expect(!identifiers.contains(ActivityRun.undoActionCode))
        #expect(!identifiers.contains(ActivityRun.tidyNowActionCode))
    }

    @Test func eachActionMakesOneKindOfPlan() {
        #expect(CleanupAction.findDuplicates.definition.operation == .moveToTrash)
        #expect(CleanupAction.clearFailedDownloads.definition.operation == .moveToTrash)
        #expect(CleanupAction.removeUnpackedZips.definition.operation == .moveToTrash)
        #expect(CleanupAction.removeUsedInstallers.definition.operation == .moveToTrash)
        #expect(CleanupAction.fixMessyNames.definition.operation == .rename)
        #expect(CleanupAction.reviewNearDuplicates.definition.operation == .moveToTrash)
        #expect(CleanupAction.archiveOldDownloads.definition.operation == .archive)
        #expect(CleanupAction.reviewLargeDownloads.definition.operation == .moveToTrash)
        #expect(CleanupAction.removeEmptyFolders.definition.operation == .moveToTrash)
    }
}
