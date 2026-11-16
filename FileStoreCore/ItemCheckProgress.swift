import Foundation

/// Reports the items checked of the total, for the planners that read files one by one (zips,
/// installers): always the first and the last report, and in between at most one every 100 ms.
struct ItemCheckProgress {
    static let minimumInterval: Duration = .milliseconds(100)

    let total: Int
    let onProgress: (@Sendable (CleanupPlanningProgress) -> Void)?
    private let clock = ContinuousClock()
    private var lastReport: ContinuousClock.Instant?

    init(total: Int, onProgress: (@Sendable (CleanupPlanningProgress) -> Void)?) {
        self.total = total
        self.onProgress = onProgress
    }

    mutating func report(checked: Int) {
        guard let onProgress else { return }
        let now = clock.now
        if checked < total, let lastReport, now - lastReport < Self.minimumInterval {
            return
        }
        lastReport = now
        onProgress(CleanupPlanningProgress(itemsChecked: checked, itemsToCheck: total))
    }
}
