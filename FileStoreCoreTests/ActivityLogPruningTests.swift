import FileStoreCore
import Foundation
import Testing

/// Pruning: runs that started more than 90 days ago go, with their changes, at most once a day;
/// the totals stay exactly as they were; and the file gets smaller.
@Suite("Activity log pruning")
struct ActivityLogPruningTests {
    private let now = Date(timeIntervalSince1970: 1_800_000_000)
    private let day: TimeInterval = 24 * 60 * 60

    @Test func theRetentionIsNinetyDaysAndPruningIsDaily() {
        #expect(ActivityLog.retention == 90 * 24 * 60 * 60)
        #expect(ActivityLog.pruneInterval == 24 * 60 * 60)
    }

    @Test func runsOlderThanNinetyDaysGoAndTheTotalsStay() async throws {
        let log = try await ActivityLog.open(.inMemory, now: now)
        // Either side of the boundary, to the second.
        let justTooOld = try LogSamples.writeRun(to: log, startedAt: now.addingTimeInterval(-90 * day - 1), count: 2, size: 100, namePrefix: "too-old")
        let exactlyNinety = try LogSamples.writeRun(to: log, startedAt: now.addingTimeInterval(-90 * day), count: 3, size: 100, namePrefix: "ninety")
        let justInside = try LogSamples.writeRun(to: log, startedAt: now.addingTimeInterval(-90 * day + 1), count: 1, size: 100, namePrefix: "inside")
        let ancient = try LogSamples.writeRun(to: log, startedAt: now.addingTimeInterval(-400 * day), count: 4, size: 100, namePrefix: "ancient")
        let today = try LogSamples.writeRun(to: log, startedAt: now, count: 1, size: 100, namePrefix: "today")
        let totalsBefore = try await log.totals()
        #expect(totalsBefore == ActivityTotals(bytesMovedToTrash: 1_100, filesCleaned: 11))

        let result = try await log.pruneIfDue(now: now)

        #expect(result.wasDue)
        #expect(result.runsRemoved == 2)
        // Newest first: the two old runs are gone, the run exactly ninety days old stays.
        #expect(try await log.runs().map(\.id) == [today, justInside, exactlyNinety])
        #expect(try await log.changes(inRun: justTooOld).isEmpty)
        #expect(try await log.changes(inRun: ancient).isEmpty)
        #expect(try await log.changes(inRun: exactlyNinety).count == 3)
        #expect(try await log.changes(inRun: justInside).count == 1)
        // Pruning forgets the runs, not what they added up to.
        #expect(try await log.totals() == totalsBefore)
    }

    @Test func pruningHappensAtMostOnceADay() async throws {
        let log = try await ActivityLog.open(.inMemory, now: now)
        #expect(try await log.pruneIfDue(now: now) == ActivityPruneResult(wasDue: true, runsRemoved: 0, didCompact: false))
        // An old run that turns up later the same day waits for the next day's pruning.
        let old = try LogSamples.writeRun(to: log, startedAt: now.addingTimeInterval(-200 * day), count: 1)

        let sameDay = try await log.pruneIfDue(now: now.addingTimeInterval(day - 1))

        #expect(sameDay == ActivityPruneResult(wasDue: false, runsRemoved: 0, didCompact: false))
        #expect(try await log.runs().map(\.id) == [old])

        let nextDay = try await log.pruneIfDue(now: now.addingTimeInterval(day))

        #expect(nextDay.wasDue)
        #expect(nextDay.runsRemoved == 1)
        #expect(try await log.runs().isEmpty)
        #expect(try await log.totals().filesCleaned == 1)
    }

    @Test func aClockSetBackDoesNotPutPruningOffForever() async throws {
        let log = try await ActivityLog.open(.inMemory, now: now)
        _ = try await log.pruneIfDue(now: now.addingTimeInterval(365 * day))

        // The last pruning now lies in the future. Waiting for it to pass could take a year.
        let result = try await log.pruneIfDue(now: now)

        #expect(result.wasDue)
    }

    @Test func theFileShrinksAfterPruningAndTheTotalsStay() async throws {
        try await withLogSandbox { sandbox in
            let location = try sandbox.realLocation()
            let databaseURL = try #require(location.databaseURL)
            let log = try await ActivityLog.open(location, now: now)
            try LogSamples.writeRun(to: log, startedAt: now.addingTimeInterval(-120 * day), count: 2_000, size: 4_096, namePrefix: "A report with a name of ordinary length")
            let kept = try LogSamples.writeRun(to: log, startedAt: now.addingTimeInterval(-day), count: 10, size: 4_096)
            let sizeBefore = FileFacts.databaseSize(at: databaseURL)
            let totalsBefore = try await log.totals()
            #expect(totalsBefore.filesCleaned == 2_010)

            let result = try await log.pruneIfDue(now: now)

            let sizeAfter = FileFacts.databaseSize(at: databaseURL)
            #expect(result == ActivityPruneResult(wasDue: true, runsRemoved: 1, didCompact: true))
            #expect(sizeAfter < sizeBefore / 4, "\(sizeBefore) bytes before, \(sizeAfter) after")
            #expect(try await log.runs().map(\.id) == [kept])
            #expect(try await log.changes(inRun: kept).count == 10)
            #expect(try await log.totals() == totalsBefore)
            // Still a sound database after being rebuilt: it opens again, and opening checks it.
            try await log.close()
            let reopened = try await ActivityLog.open(location, now: now)
            #expect(try await reopened.totals() == totalsBefore)
        }
    }
}
