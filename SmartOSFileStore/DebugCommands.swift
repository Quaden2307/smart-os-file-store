#if DEBUG
import FileStoreCore
import SwiftUI

extension FocusedValues {
    /// The frontmost window's search model, whose preview sheet shows the samples. Debug builds only.
    @Entry var cleanupSearch: CleanupSearchModel?
}

/// The Debug menu, in debug builds only: made-up plans of renames and moves, so the preview of
/// plans without groups can be looked at before any action proposes them.
struct DebugCommands: Commands {
    @FocusedValue(\.cleanupSearch) private var search

    var body: some Commands {
        CommandMenu("Debug") {
            Button("Show Sample Messy Names Plan") {
                search?.presentSample(SamplePlans.messyNames)
            }
            .disabled(!(search?.canPresentSample ?? false))
            Button("Show Sample Old Downloads Plan") {
                search?.presentSample(SamplePlans.oldDownloads)
            }
            .disabled(!(search?.canPresentSample ?? false))
        }
    }
}
#endif
