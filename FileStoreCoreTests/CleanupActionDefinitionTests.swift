import FileStoreCore
import Testing

/// Each action's definition: the identifiers the activity log stores never change and never repeat,
/// and each action allows only the operation its definition states.
@Suite("Cleanup action definitions")
struct CleanupActionDefinitionTests {
    @Test func identifiersAreExactlyTheOnesTheLogHasAlwaysStored() {
        let identifiers = CleanupAction.allCases.map(\.definition.identifier)
        #expect(identifiers == ["findDuplicates", "clearFailedDownloads", "removeUnpackedZips", "removeUsedInstallers", "fixMessyNames", "archiveOldDownloads"])
        #expect(Set(identifiers).count == identifiers.count)
    }

    @Test func eachActionMakesOneKindOfPlan() {
        #expect(CleanupAction.findDuplicates.definition.operation == .moveToTrash)
        #expect(CleanupAction.clearFailedDownloads.definition.operation == .moveToTrash)
        #expect(CleanupAction.removeUnpackedZips.definition.operation == .moveToTrash)
        #expect(CleanupAction.removeUsedInstallers.definition.operation == .moveToTrash)
        #expect(CleanupAction.fixMessyNames.definition.operation == .rename)
        #expect(CleanupAction.archiveOldDownloads.definition.operation == .move)
    }
}
