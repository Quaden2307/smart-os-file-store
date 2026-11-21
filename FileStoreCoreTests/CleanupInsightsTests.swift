import FileStoreCore
import Foundation
import Testing

/// What the app has cleaned, over time (decision record 0031): daily numbers from the log, kept
/// through pruning, lowered by undo on the day it happened, and charted by week across week,
/// month and daylight saving boundaries.
@Suite("Cleanup insights")
struct CleanupInsightsTests {
    /// New York: daylight saving ends on 1 November 2026 and starts on 8 March 2026.
    private static let calendar: Calendar = {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "America/New_York") ?? .gmt
        calendar.firstWeekday = 1
        return calendar
    }()

    private static func date(_ year: Int, _ month: Int, _ day: Int, hour: Int = 12) -> Date {
        calendar.date(from: DateComponents(year: year, month: month, day: day, hour: hour)) ?? .distantPast
    }

    private static func day(_ year: Int, _ month: Int, _ day: Int, bytes: Int64, action: CleanupAction = .findDuplicates) -> DailyCleanup {
        DailyCleanup(day: DailyCleanup.day(of: date(year, month, day), in: calendar), action: action, folderID: nil, bytesMovedToTrash: bytes, filesTrashed: 1)
    }

    @Test func daysFallInTheirWeekAcrossAWeekBoundaryAndADaylightSavingChange() {
        // Saturday 31 October and Sunday 1 November 2026 (clocks go back that night): two weeks.
        let now = Self.date(2026, 11, 5)
        let insights = CleanupInsights(
            days: [Self.day(2026, 10, 31, bytes: 100), Self.day(2026, 11, 1, bytes: 10, action: .fixMessyNames), Self.day(2026, 11, 1, bytes: 1)],
            now: now, calendar: Self.calendar
        )
        #expect(insights.weeks.count == CleanupInsights.weekCount)
        let last = insights.weeks[CleanupInsights.weekCount - 1]
        let before = insights.weeks[CleanupInsights.weekCount - 2]
        #expect(last.total.bytesMovedToTrash == 11)
        #expect(last.byAction[.fixMessyNames]?.bytesMovedToTrash == 10)
        #expect(before.total.bytesMovedToTrash == 100)
        #expect(last.cumulative.bytesMovedToTrash == 111)
        // Week starts are each a Sunday, whatever the hours in between.
        #expect(insights.weeks.allSatisfy { Self.calendar.component(.weekday, from: $0.start) == 1 })
    }

    @Test func springForwardStaysInItsWeek() {
        // Sunday 8 March 2026: a 23-hour day that starts its week.
        let insights = CleanupInsights(days: [Self.day(2026, 3, 8, bytes: 5), Self.day(2026, 3, 7, bytes: 7)], now: Self.date(2026, 3, 9), calendar: Self.calendar)
        #expect(insights.weeks.last?.total.bytesMovedToTrash == 5)
        #expect(insights.weeks.dropLast().last?.total.bytesMovedToTrash == 7)
    }

    @Test func thisMonthEndsAtTheMonthBoundaryAndOlderWeeksStillCountAllTime() {
        let now = Self.date(2026, 12, 1)
        let days = [Self.day(2026, 11, 30, bytes: 30), Self.day(2026, 12, 1, bytes: 1), Self.day(2025, 1, 1, bytes: 1_000)]
        let insights = CleanupInsights(days: days, now: now, calendar: Self.calendar)
        #expect(insights.thisMonth.bytesMovedToTrash == 1)
        #expect(insights.allTime.bytesMovedToTrash == 1_031)
        #expect(insights.allTime.filesTidied == 3)
        // Before the twelve weeks, still in the running total.
        #expect(insights.weeks.first?.cumulative.bytesMovedToTrash == 1_000)
        #expect(insights.weeks.last?.cumulative.bytesMovedToTrash == 1_031)
        #expect(!insights.isEmpty)
        #expect(CleanupInsights(days: [], now: now, calendar: Self.calendar).isEmpty)
    }

    @Test func totalsAreTheSameBeforeAndAfterPruning() async throws {
        let log = try await ActivityLog.open(.inMemory)
        let now = Self.date(2026, 11, 20)
        try LogSamples.writeRun(to: log, startedAt: now.addingTimeInterval(-120 * 86_400), count: 3, size: 1_000, namePrefix: "old")
        try LogSamples.writeRun(to: log, startedAt: now.addingTimeInterval(-10 * 86_400), count: 2, size: 500, namePrefix: "new")
        let before = try await log.dailyCleanups(calendar: Self.calendar)
        let insightsBefore = CleanupInsights(days: before, now: now, calendar: Self.calendar)

        let pruned = try await log.pruneIfDue(now: now, calendar: Self.calendar)
        #expect(pruned.runsRemoved == 1)
        let after = try await log.dailyCleanups(calendar: Self.calendar)
        #expect(Set(after) == Set(before))
        #expect(CleanupInsights(days: after, now: now, calendar: Self.calendar) == insightsBefore)
        #expect(insightsBefore.allTime == CleanupInsights.Figures(bytesMovedToTrash: 4_000, filesTidied: 5))
        // The status bar's counter and the insights come from the same log and agree.
        let totals = try await log.totals()
        #expect(totals.bytesMovedToTrash == insightsBefore.allTime.bytesMovedToTrash)
        #expect(totals.filesCleaned == insightsBefore.allTime.filesTidied)
        // Pruning again adds nothing twice.
        _ = try await log.pruneIfDue(now: now.addingTimeInterval(2 * 86_400), calendar: Self.calendar)
        #expect(Set(try await log.dailyCleanups(calendar: Self.calendar)) == Set(before))
    }

    @Test func undoingACleanupLowersTheDayItWasUndone() async throws {
        let folder = try TemporaryFolder.make()
        defer { folder.remove() }
        let trash = try FakeTrash.make()
        defer { trash.remove() }
        let log = try await ActivityLog.open(.inMemory)
        try UndoFixtures.write(["a.txt": "ten bytes!", "b.txt": "twenty bytes, twenty"], in: folder.url)
        let (runID, _) = try await UndoFixtures.trashRun(["a.txt", "b.txt"], in: folder.url, to: trash, log: log)
        let calendar = Calendar.current
        let ranOn = DailyCleanup.day(of: UndoFixtures.now, in: calendar)
        let a = try await UndoFixtures.change(named: "a.txt", inRun: runID, log: log)
        _ = try await UndoFixtures.undo(.change(a.id), in: folder.url, trash: trash.locator, log: log)

        let days = try await log.dailyCleanups(calendar: calendar)
        let today = DailyCleanup.day(of: .now, in: calendar)
        #expect(days.first { $0.day == ranOn }?.bytesMovedToTrash == 30)
        #expect(days.first { $0.day == today }?.bytesMovedToTrash == -10)
        let insights = CleanupInsights(days: days, now: .now, calendar: calendar)
        #expect(insights.allTime.bytesMovedToTrash == 20)
        #expect(insights.weeks.last?.total.bytesMovedToTrash == -10)
        let totals = try await log.totals()
        #expect(totals.bytesMovedToTrash == insights.allTime.bytesMovedToTrash)
        #expect(totals.filesCleaned == insights.allTime.filesTidied)
    }

    @Test func tenThousandChangesAreReadQuickly() async throws {
        let log = try await ActivityLog.open(.inMemory)
        let now = Self.date(2026, 11, 20)
        for run in 0..<10 {
            try LogSamples.writeRun(to: log, startedAt: now.addingTimeInterval(Double(-run) * 86_400), count: 1_000, namePrefix: "r\(run)")
        }
        let clock = ContinuousClock()
        let start = clock.now
        let days = try await log.dailyCleanups(calendar: Self.calendar)
        let insights = CleanupInsights(days: days, now: now, calendar: Self.calendar)
        #expect(insights.allTime.filesTidied == 10_000)
        #expect(clock.now - start < .seconds(2))
    }
}
