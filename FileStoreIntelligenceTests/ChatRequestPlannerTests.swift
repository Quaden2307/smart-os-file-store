import FileStoreIntelligence
import Foundation
import Testing

@Suite("Chat request planner")
struct ChatRequestPlannerTests {
    private static func day(_ year: Int, _ month: Int, _ day: Int, hour: Int = 0) -> Date {
        Fixtures.calendar.date(from: DateComponents(year: year, month: month, day: day, hour: hour)) ?? .distantPast
    }

    private static func range(from: Date? = nil, before: Date? = nil) -> FileQuery.DateRange {
        FileQuery.DateRange(from: from, before: before)
    }

    private static func plan(
        _ request: ChatRequest, in snapshot: FolderSnapshot = Fixtures.snapshot, lastResult: (ids: [URL], sort: FileSort?)? = nil
    ) -> ChatRequestPlanner.Answer {
        ChatRequestPlanner.plan(request, in: snapshot, today: Fixtures.now, lastResult: lastResult, cleanupActions: Fixtures.cleanupActions)
    }

    // MARK: - Ages

    @Test func withinIsSinceTheStartOfTheDayThatFarBack() {
        let today = Fixtures.now // 18 November 2026, noon
        #expect(Age(relation: .within, amount: 3, unit: .days).range(today: today) == Self.range(from: Self.day(2026, 11, 15)))
        #expect(Age(relation: .within, amount: 2, unit: .weeks).range(today: today) == Self.range(from: Self.day(2026, 11, 4)))
        #expect(Age(relation: .within, amount: 1, unit: .months).range(today: today) == Self.range(from: Self.day(2026, 10, 18)))
        #expect(Age(relation: .within, amount: 1, unit: .years).range(today: today) == Self.range(from: Self.day(2025, 11, 18)))
        // No amount is one, no unit is days.
        #expect(Age(relation: .within).range(today: today) == Self.range(from: Self.day(2026, 11, 17)))
    }

    @Test func olderThanIsBeforeThatDay() {
        #expect(Age(relation: .olderThan, amount: 2, unit: .weeks).range(today: Fixtures.now) == Self.range(before: Self.day(2026, 11, 4)))
        #expect(Age(relation: .olderThan, amount: 6, unit: .months).range(today: Fixtures.now) == Self.range(before: Self.day(2026, 5, 18)))
    }

    @Test func onDayIsThatOneDay() {
        #expect(Age(relation: .onDay, amount: 1, unit: .days).range(today: Fixtures.now) == Self.range(from: Self.day(2026, 11, 17), before: Self.day(2026, 11, 18)))
        #expect(Age(relation: .onDay).range(today: Fixtures.now) == Self.range(from: Self.day(2026, 11, 18), before: Self.day(2026, 11, 19)))
        #expect(Age(relation: .onDay, amount: 1, unit: .weeks).range(today: Fixtures.now) == Self.range(from: Self.day(2026, 11, 11), before: Self.day(2026, 11, 12)))
    }

    @Test func betweenRunsFromTheFarDayToTheNearDayIncluded() {
        let expected = Self.range(from: Self.day(2026, 10, 14), before: Self.day(2026, 10, 29))
        #expect(Age(relation: .between, amount: 3, unit: .weeks, amountTo: 5).range(today: Fixtures.now) == expected)
        #expect(Age(relation: .between, amount: 5, unit: .weeks, amountTo: 3).range(today: Fixtures.now) == expected)
        #expect(Age(relation: .between, amount: 3, unit: .weeks).range(today: Fixtures.now) == nil)
    }

    @Test func inMonthIsTheLatestSuchMonthNotInTheFuture() {
        #expect(Age(relation: .inMonth, month: 4).range(today: Fixtures.now) == Self.range(from: Self.day(2026, 4, 1), before: Self.day(2026, 5, 1)))
        #expect(Age(relation: .inMonth, month: 11).range(today: Fixtures.now) == Self.range(from: Self.day(2026, 11, 1), before: Self.day(2026, 12, 1)))
        // December, asked in November: last year's.
        #expect(Age(relation: .inMonth, month: 12).range(today: Fixtures.now) == Self.range(from: Self.day(2025, 12, 1), before: Self.day(2026, 1, 1)))
        // At the turn of the year.
        let january = Self.day(2027, 1, 5, hour: 9)
        #expect(Age(relation: .inMonth, month: 12).range(today: january) == Self.range(from: Self.day(2026, 12, 1), before: Self.day(2027, 1, 1)))
        #expect(Age(relation: .inMonth, month: 1).range(today: january) == Self.range(from: Self.day(2027, 1, 1), before: Self.day(2027, 2, 1)))
        // A year given; February of a leap year.
        #expect(Age(relation: .inMonth, month: 2, year: 2028).range(today: Fixtures.now) == Self.range(from: Self.day(2028, 2, 1), before: Self.day(2028, 3, 1)))
        #expect(Age(relation: .inMonth).range(today: Fixtures.now) == nil)
        #expect(Age(relation: .inMonth, month: 13).range(today: Fixtures.now) == nil)
    }

    @Test func monthsAndYearsAreTheCalendarsAtMonthEndsLeapDaysAndTheTurnOfTheYear() {
        // A month back from 31 March is the last day of February.
        #expect(Age(relation: .within, amount: 1, unit: .months).range(today: Self.day(2026, 3, 31, hour: 12)) == Self.range(from: Self.day(2026, 2, 28)))
        #expect(Age(relation: .within, amount: 1, unit: .months).range(today: Self.day(2028, 3, 31, hour: 12)) == Self.range(from: Self.day(2028, 2, 29)))
        // A year back from a leap day.
        #expect(Age(relation: .olderThan, amount: 1, unit: .years).range(today: Self.day(2028, 2, 29, hour: 12)) == Self.range(before: Self.day(2027, 2, 28)))
        // Across the new year.
        #expect(Age(relation: .within, amount: 2, unit: .weeks).range(today: Self.day(2027, 1, 5, hour: 12)) == Self.range(from: Self.day(2026, 12, 22)))
        #expect(Age(relation: .within, amount: 1, unit: .months).range(today: Self.day(2027, 1, 31, hour: 12)) == Self.range(from: Self.day(2026, 12, 31)))
        #expect(Age(relation: .within, amount: 10, unit: .days).range(today: Self.day(2027, 1, 3, hour: 12)) == Self.range(from: Self.day(2026, 12, 24)))
        #expect(Age(relation: .within, amount: -1).range(today: Fixtures.now) == nil)
    }

    // MARK: - Requests

    @Test func aCleanupIsNarrowedOnlyByTheSlotsGiven() {
        #expect(Self.plan(ChatRequest(kind: .cleanup, cleanups: [.exactCopies])) == .cleanup(CleanupRequest(actions: ["findDuplicates"]), scope: .all))
        let narrowed = Self.plan(ChatRequest(
            kind: .cleanup, cleanups: [.oldFiles], files: FileSlots(kind: "images", added: Age(relation: .olderThan, amount: 8, unit: .months))
        ))
        var query = FileQuery()
        query.typeGroup = .images
        query.added = Self.range(before: Self.day(2026, 3, 18))
        #expect(narrowed == .cleanup(CleanupRequest(actions: ["archiveOldDownloads"], query: query), scope: .all))
        // "everything" is every action, in the app's order.
        #expect(Self.plan(ChatRequest(kind: .cleanup, cleanups: [.everything])) == .cleanup(CleanupRequest(actions: Fixtures.cleanupActions), scope: .all))
    }

    @Test func aCleanupWithNothingNamedAsksAndOneWithOnlyFilesIsEveryCleanupOnThem() {
        #expect(Self.plan(ChatRequest(kind: .cleanup)) == .needsMore(.cleanup))
        #expect(Self.plan(ChatRequest(kind: .cleanup, cleanups: [])) == .needsMore(.cleanup))
        var query = FileQuery()
        query.typeGroup = .documents
        #expect(Self.plan(ChatRequest(kind: .cleanup, files: FileSlots(kind: "documents"))) == .cleanup(CleanupRequest(actions: Fixtures.cleanupActions, query: query), scope: .all))
    }

    @Test func thoseNeedALastResultAndOnlyNarrowToIt() {
        let ids = Fixtures.named("report.pdf", "movie.mov").map(\.id)
        #expect(Self.plan(ChatRequest(kind: .list, aboutLastResult: true)) == .needsMore(.lastResult))
        #expect(Self.plan(ChatRequest(kind: .cleanup, cleanups: [.messyNames], aboutLastResult: true)) == .needsMore(.lastResult))
        var query = FileQuery()
        query.withinIDs = Set(ids)
        query.minBytes = 100_000_000
        // The last result's order is kept.
        #expect(Self.plan(ChatRequest(kind: .list, files: FileSlots(minMB: 100), aboutLastResult: true), lastResult: (ids, .largest))
            == .search(query, .largest, limit: 20, scope: .all, count: false))
        query.minBytes = nil
        #expect(Self.plan(ChatRequest(kind: .cleanup, cleanups: [.messyNames], aboutLastResult: true), lastResult: (ids, nil))
            == .cleanup(CleanupRequest(actions: ["fixMessyNames"], query: query), scope: .all))
        // A question about the folder as a whole is not about the last result.
        #expect(Self.plan(ChatRequest(kind: .overview, aboutLastResult: true)) == .overview(.all))
        // The tool's "lastResult" mark is not the user's word for those.
        #expect(Self.plan(ChatRequest(kind: .list, files: FileSlots(mark: "lastResult"))) == .search(FileQuery(), .newest, limit: 20, scope: .all, count: false))
    }

    @Test func aSearchTakesItsSortCountAndALimitInRange() {
        var query = FileQuery()
        query.typeGroup = .documents
        #expect(Self.plan(ChatRequest(kind: .count, files: FileSlots(kind: "documents"))) == .search(query, .newest, limit: 20, scope: .all, count: true))
        #expect(Self.plan(ChatRequest(kind: .list, sort: "smallest", limit: 3)) == .search(FileQuery(), .smallest, limit: 3, scope: .all, count: false))
        #expect(Self.plan(ChatRequest(kind: .list, sort: "sideways", limit: 500)) == .search(FileQuery(), .newest, limit: 100, scope: .all, count: false))
        #expect(Self.plan(ChatRequest(kind: .list, limit: 0)) == .search(FileQuery(), .newest, limit: 1, scope: .all, count: false))
    }

    @Test func slotsThatCannotBeReadAreAskedAbout() {
        #expect(Self.plan(ChatRequest(kind: .cleanup, cleanups: [.oldFiles], files: FileSlots(added: Age(relation: .inMonth)))) == .needsMore(.when))
        #expect(Self.plan(ChatRequest(kind: .list, files: FileSlots(minMB: 50, maxMB: 10))) == .needsMore(.files))
        #expect(Self.plan(ChatRequest(kind: .list, files: FileSlots(kind: "spreadsheets"))) == .needsMore(.files))
    }

    @Test func cannotDoChatDuplicatesAndOverview() {
        #expect(Self.plan(ChatRequest(kind: .cannotDo)) == .cannotDo(.asked(.other)))
        #expect(Self.plan(ChatRequest(kind: .cannotDo, cleanups: [.everything], cannotDo: .move)) == .cannotDo(.asked(.move)))
        #expect(Self.plan(ChatRequest(kind: .chat)) == .chat)
        #expect(Self.plan(ChatRequest(kind: .duplicates)) == .duplicates(.all))
        #expect(Self.plan(ChatRequest(kind: .overview)) == .overview(.all))
    }

    @Test func aFolderIsTheOneOnScreenOneNamedAllOrOneTheAppCannotRead() {
        let snapshot = FolderSnapshot(
            files: [],
            folders: [
                FolderSnapshot.Folder(name: "Downloads", isCurrent: true),
                FolderSnapshot.Folder(name: "Desktop", state: .permissionNeeded),
                FolderSnapshot.Folder(name: "Backup", state: .unavailable),
                FolderSnapshot.Folder(name: "Documents"),
                FolderSnapshot.Folder(name: "Client deliverables for the 2026 spring campaign"),
            ],
            now: Fixtures.now
        )
        #expect(Self.plan(ChatRequest(kind: .duplicates), in: snapshot) == .duplicates(.folder("Downloads")))
        #expect(Self.plan(ChatRequest(kind: .duplicates, folder: "documents"), in: snapshot) == .duplicates(.folder("Documents")))
        #expect(Self.plan(ChatRequest(kind: .overview, folder: "all"), in: snapshot) == .overview(.all))
        #expect(Self.plan(ChatRequest(kind: .list, folder: "Desktop"), in: snapshot) == .cannotDo(.folder("Desktop", .permissionNeeded)))
        #expect(Self.plan(ChatRequest(kind: .list, folder: "Backup"), in: snapshot) == .cannotDo(.folder("Backup", .unavailable)))
        #expect(Self.plan(ChatRequest(kind: .list, folder: "Music"), in: snapshot) == .needsMore(.folder))
        // The parser was offered the name cut to 40 characters, which no prefix match finds.
        #expect(Self.plan(ChatRequest(kind: .overview, folder: "Client deliverables for the 2026 spring…"), in: snapshot)
            == .overview(.folder("Client deliverables for the 2026 spring campaign")))
    }
}
