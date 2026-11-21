import Foundation
internal import GRDB

/// One day's cleanups for one action in one folder: what went to the Trash, and how many files
/// were trashed and tidied (renamed or moved). An undo lowers the day it was undone on.
public struct DailyCleanup: Sendable, Hashable {
    /// YYYY-MM-DD in the calendar the log was read with.
    public let day: String
    public let action: CleanupAction?
    public let folderID: ManagedFolder.ID?
    public var bytesMovedToTrash: Int64
    public var filesTrashed: Int
    public var filesTidied: Int

    public init(day: String, action: CleanupAction?, folderID: ManagedFolder.ID?, bytesMovedToTrash: Int64 = 0, filesTrashed: Int = 0, filesTidied: Int = 0) {
        self.day = day
        self.action = action
        self.folderID = folderID
        self.bytesMovedToTrash = bytesMovedToTrash
        self.filesTrashed = filesTrashed
        self.filesTidied = filesTidied
    }

    /// The day in `calendar` as YYYY-MM-DD.
    public static func day(of date: Date, in calendar: Calendar) -> String {
        let parts = calendar.dateComponents([.year, .month, .day], from: date)
        return String(format: "%04d-%02d-%02d", parts.year ?? 0, parts.month ?? 0, parts.day ?? 0)
    }

    /// The start of a YYYY-MM-DD day in `calendar`.
    public static func date(ofDay day: String, in calendar: Calendar) -> Date? {
        let parts = day.split(separator: "-").compactMap { Int($0) }
        guard parts.count == 3 else { return nil }
        return calendar.date(from: DateComponents(year: parts[0], month: parts[1], day: parts[2]))
    }
}

/// Reading the history as daily numbers, for the insights. Reads only.
extension ActivityLog {
    /// Every day with cleanups, per action and folder: the rows pruning rolled up, and the changes
    /// still in the log. A change in a Tidy Now run counts for the action its reason belongs to.
    @concurrent
    public func dailyCleanups(calendar: Calendar = .current) async throws(ActivityLogError) -> [DailyCleanup] {
        try read { db in
            var days: [Key: DailyCleanup] = [:]
            for row in try Row.fetchAll(db, sql: "SELECT * FROM dailyTotals") {
                let entry = DailyCleanup(
                    day: row["day"], action: CleanupAction(logCode: row["action"]), folderID: UUID(uuidString: row["folderID"]),
                    bytesMovedToTrash: row["bytesMovedToTrash"], filesTrashed: row["filesTrashed"], filesTidied: row["filesTidied"]
                )
                days[Key(entry), default: entry.empty].add(entry)
            }
            for change in try Self.doneChanges(db, where: "1") {
                change.apply(to: &days, calendar: calendar)
            }
            return Array(days.values)
        }
    }

    /// Rolls the changes of the runs that started before `cutoff` into `dailyTotals`, inside the
    /// pruning's transaction, before those runs are removed.
    static func rollUp(_ db: Database, runsBefore cutoff: Double, calendar: Calendar) throws {
        var days: [Key: DailyCleanup] = [:]
        for change in try doneChanges(db, where: "r.startedAt < ?", arguments: [cutoff]) {
            change.apply(to: &days, calendar: calendar)
        }
        for entry in days.values {
            try db.execute(
                sql: """
                    INSERT INTO dailyTotals (day, action, folderID, bytesMovedToTrash, filesTrashed, filesTidied)
                    VALUES (?, ?, ?, ?, ?, ?)
                    ON CONFLICT (day, action, folderID) DO UPDATE SET
                        bytesMovedToTrash = bytesMovedToTrash + excluded.bytesMovedToTrash,
                        filesTrashed = filesTrashed + excluded.filesTrashed,
                        filesTidied = filesTidied + excluded.filesTidied
                    """,
                arguments: [entry.day, entry.action?.logCode ?? "", entry.folderID?.uuidString ?? "", entry.bytesMovedToTrash, entry.filesTrashed, entry.filesTidied]
            )
        }
    }

    private struct Key: Hashable {
        let day: String
        let action: CleanupAction?
        let folderID: ManagedFolder.ID?

        init(_ entry: DailyCleanup) {
            day = entry.day
            action = entry.action
            folderID = entry.folderID
        }
    }

    /// A change that was carried out, with what it needs to be counted.
    private struct DoneChange {
        let action: CleanupAction?
        let folderID: ManagedFolder.ID?
        let isTrash: Bool
        let bytes: Int64
        let attemptedAt: Double
        let undoneAt: Double?

        func apply(to days: inout [Key: DailyCleanup], calendar: Calendar) {
            add(at: attemptedAt, sign: 1, to: &days, calendar: calendar)
            if let undoneAt {
                add(at: undoneAt, sign: -1, to: &days, calendar: calendar)
            }
        }

        private func add(at moment: Double, sign: Int, to days: inout [Key: DailyCleanup], calendar: Calendar) {
            let entry = DailyCleanup(
                day: DailyCleanup.day(of: Date(timeIntervalSinceReferenceDate: moment), in: calendar), action: action, folderID: folderID,
                bytesMovedToTrash: isTrash ? Int64(sign) * bytes : 0, filesTrashed: isTrash ? sign : 0, filesTidied: isTrash ? 0 : sign
            )
            days[Key(entry), default: entry.empty].add(entry)
        }
    }

    private static func doneChanges(_ db: Database, where condition: String, arguments: StatementArguments = []) throws -> [DoneChange] {
        try Row.fetchAll(
            db,
            sql: """
                SELECT r.action AS runAction, r.folderID, c.outcome, c.sizeInBytes, c.reasonCode, c.attemptedAt, c.undoneAt
                FROM changes c JOIN runs r ON r.id = c.runID
                WHERE r.action != '\(ActivityRun.undoActionCode)' AND c.outcome IN ('trashed', 'renamed', 'moved') AND \(condition)
                """,
            arguments: arguments
        ).map { row in
            let runAction: String = row["runAction"]
            let folderID: String? = row["folderID"]
            return DoneChange(
                action: CleanupAction(logCode: runAction) ?? CleanupAction(reasonCode: row["reasonCode"]),
                folderID: folderID.flatMap(UUID.init(uuidString:)),
                isTrash: (row["outcome"] as String) == "trashed",
                bytes: row["sizeInBytes"],
                attemptedAt: row["attemptedAt"],
                undoneAt: row["undoneAt"]
            )
        }
    }
}

private extension DailyCleanup {
    var empty: DailyCleanup { DailyCleanup(day: day, action: action, folderID: folderID) }

    mutating func add(_ other: DailyCleanup) {
        bytesMovedToTrash += other.bytesMovedToTrash
        filesTrashed += other.filesTrashed
        filesTidied += other.filesTidied
    }
}

private extension CleanupAction {
    /// The action whose reason a change in a Tidy Now run carries.
    init?(reasonCode: String) {
        switch reasonCode {
        case "sameContent": self = .findDuplicates
        case "messyName": self = .fixMessyNames
        case "notOpenedSince", "neverOpened", "alreadyArchived": self = .archiveOldDownloads
        case "failedDownload": self = .clearFailedDownloads
        case "unpackedZip": self = .removeUnpackedZips
        case "usedInstaller": self = .removeUsedInstallers
        case "nearDuplicate": self = .reviewNearDuplicates
        case "largeDownload": self = .reviewLargeDownloads
        case "emptyFolder": self = .removeEmptyFolders
        default: return nil
        }
    }
}
