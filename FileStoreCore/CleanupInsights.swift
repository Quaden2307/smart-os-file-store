import Foundation

/// What the app has cleaned, over time, from the activity log's daily numbers: all-time and
/// this-month headlines, the last twelve weeks by action, and breakdowns by action and by folder.
/// A pure value; the current time and calendar are passed in, so tests can cross a week, a month
/// and a daylight saving change.
public struct CleanupInsights: Sendable, Equatable {
    public struct Figures: Sendable, Equatable {
        public var bytesMovedToTrash: Int64 = 0
        /// Files moved to the Trash, renamed or moved.
        public var filesTidied = 0

        public init(bytesMovedToTrash: Int64 = 0, filesTidied: Int = 0) {
            self.bytesMovedToTrash = bytesMovedToTrash
            self.filesTidied = filesTidied
        }

        mutating func add(_ day: DailyCleanup) {
            bytesMovedToTrash += day.bytesMovedToTrash
            filesTidied += day.filesTrashed + day.filesTidied
        }
    }

    /// One week of the chart.
    public struct Week: Sendable, Equatable, Identifiable {
        /// Its first day, as the calendar starts weeks.
        public let start: Date
        public var byAction: [CleanupAction: Figures]
        public var total: Figures
        /// Everything up to the end of this week, the twelve weeks before it included and earlier.
        public var cumulative: Figures

        public var id: Date { start }
    }

    public static let weekCount = 12

    public let allTime: Figures
    public let thisMonth: Figures
    /// Oldest first, ending with the current week.
    public let weeks: [Week]
    public let byAction: [CleanupAction: Figures]
    public let byFolder: [ManagedFolder.ID: Figures]

    public init(days: [DailyCleanup], now: Date, calendar: Calendar) {
        var allTime = Figures()
        var thisMonth = Figures()
        var byAction: [CleanupAction: Figures] = [:]
        var byFolder: [ManagedFolder.ID: Figures] = [:]
        let month = calendar.dateInterval(of: .month, for: now)
        let currentWeek = calendar.dateInterval(of: .weekOfYear, for: now)?.start ?? now
        let starts = (0..<Self.weekCount).reversed().compactMap { calendar.date(byAdding: .weekOfYear, value: -$0, to: currentWeek) }
        var weeks = starts.map { Week(start: $0, byAction: [:], total: Figures(), cumulative: Figures()) }
        var before = Figures()
        for day in days {
            allTime.add(day)
            if let action = day.action { byAction[action, default: Figures()].add(day) }
            if let folder = day.folderID { byFolder[folder, default: Figures()].add(day) }
            guard let date = DailyCleanup.date(ofDay: day.day, in: calendar) else { continue }
            if month?.contains(date) == true { thisMonth.add(day) }
            // The week a day falls in, found by its own week start, so a short or long day
            // (daylight saving) never shifts it into the next week.
            let start = calendar.dateInterval(of: .weekOfYear, for: date)?.start
            if let index = weeks.firstIndex(where: { $0.start == start }) {
                weeks[index].total.add(day)
                if let action = day.action { weeks[index].byAction[action, default: Figures()].add(day) }
            } else if let first = starts.first, date < first {
                before.add(day)
            }
        }
        var running = before
        for index in weeks.indices {
            running.bytesMovedToTrash += weeks[index].total.bytesMovedToTrash
            running.filesTidied += weeks[index].total.filesTidied
            weeks[index].cumulative = running
        }
        self.allTime = allTime
        self.thisMonth = thisMonth
        self.weeks = weeks
        self.byAction = byAction
        self.byFolder = byFolder
    }

    /// True when nothing has been cleaned yet.
    public var isEmpty: Bool { allTime == Figures() }
}
