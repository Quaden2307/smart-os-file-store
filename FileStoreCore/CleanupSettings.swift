import Foundation
import os

/// The thresholds behind the age marks, kept in `UserDefaults`. There is no settings window yet;
/// a value can be set with `defaults write com.quaden2307.SmartOSFileStore CleanupUnusedAfterDays -int 7`,
/// or for one launch with the argument `-CleanupUnusedAfterDays 7`.
public struct CleanupSettings: Sendable, Equatable {
    public static let defaultUnusedAfterDays = 30
    public static let defaultOldAfterDays = 90

    public static let unusedAfterDaysKey = "CleanupUnusedAfterDays"
    public static let oldAfterDaysKey = "CleanupOldAfterDays"

    /// A day is counted as 24 hours, whatever the calendar and daylight saving do.
    static let secondsPerDay: TimeInterval = 24 * 60 * 60

    /// An item last opened more than this many days ago is Unused; one never opened and added more
    /// than this many days ago is Never opened.
    public let unusedAfterDays: Int

    /// An item added more than this many days ago is Old.
    public let oldAfterDays: Int

    private static let logger = Logger(subsystem: "com.quaden2307.FileStoreCore", category: "CleanupSettings")

    /// A threshold below one day gets its default, so a mistake never marks everything.
    public init(unusedAfterDays: Int = Self.defaultUnusedAfterDays, oldAfterDays: Int = Self.defaultOldAfterDays) {
        self.unusedAfterDays = unusedAfterDays >= 1 ? unusedAfterDays : Self.defaultUnusedAfterDays
        self.oldAfterDays = oldAfterDays >= 1 ? oldAfterDays : Self.defaultOldAfterDays
    }

    public var unusedAfter: TimeInterval { TimeInterval(unusedAfterDays) * Self.secondsPerDay }

    public var oldAfter: TimeInterval { TimeInterval(oldAfterDays) * Self.secondsPerDay }

    /// The settings kept in `store`. A missing value gets its default, and so does an unusable one
    /// (not a whole number, or below one), which is logged.
    public static func load(from store: any SettingsStore) -> CleanupSettings {
        CleanupSettings(
            unusedAfterDays: days(forKey: unusedAfterDaysKey, in: store) ?? defaultUnusedAfterDays,
            oldAfterDays: days(forKey: oldAfterDaysKey, in: store) ?? defaultOldAfterDays
        )
    }

    public func save(to store: any SettingsStore) {
        store.set(unusedAfterDays, forKey: Self.unusedAfterDaysKey)
        store.set(oldAfterDays, forKey: Self.oldAfterDaysKey)
    }

    /// A whole number of days, 1 or more: a stored integer, or the text of one, which is how a
    /// launch argument arrives. Nil when the value is missing or unusable.
    private static func days(forKey key: String, in store: any SettingsStore) -> Int? {
        guard let value = store.object(forKey: key) else {
            return nil
        }
        let days: Int?
        switch value {
        case let number as NSNumber where CFGetTypeID(number) != CFBooleanGetTypeID():
            days = Int(exactly: number.doubleValue)
        case let text as String:
            days = Int(text.trimmingCharacters(in: .whitespaces))
        default:
            days = nil
        }
        guard let days, days >= 1 else {
            // A notice, not an error: it is the user's setting, read again on every refresh.
            logger.notice("Ignoring \(key, privacy: .public): expected a whole number of days, 1 or more. The default applies.")
            return nil
        }
        return days
    }
}
