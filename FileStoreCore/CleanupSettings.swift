import Foundation
import os

/// The thresholds behind the age marks and Review Large Downloads, kept in `UserDefaults`. The
/// Settings window offers a few values; any whole number can be set with
/// `defaults write com.quaden2307.SmartOSFileStore CleanupUnusedAfterDays -int 7`, or for one launch
/// with the argument `-CleanupUnusedAfterDays 7`.
public struct CleanupSettings: Sendable, Equatable {
    public static let defaultUnusedAfterDays = 30
    public static let defaultOldAfterDays = 90
    public static let defaultLargeDownloadMegabytes = 500

    public static let unusedAfterDaysKey = "CleanupUnusedAfterDays"
    public static let oldAfterDaysKey = "CleanupOldAfterDays"
    public static let largeDownloadMegabytesKey = "CleanupLargeDownloadMegabytes"

    /// A megabyte as Finder counts one: a million bytes.
    static let bytesPerMegabyte: Int64 = 1_000_000

    /// A day is counted as 24 hours, whatever the calendar and daylight saving do.
    static let secondsPerDay: TimeInterval = 24 * 60 * 60

    /// An item last opened more than this many days ago is Unused; one never opened and added more
    /// than this many days ago is Never opened.
    public let unusedAfterDays: Int

    /// An item added more than this many days ago is Old.
    public let oldAfterDays: Int

    /// A file or package taking at least this many megabytes on disk is listed by Review Large Downloads.
    public let largeDownloadMegabytes: Int

    private static let logger = Logger(subsystem: "com.quaden2307.FileStoreCore", category: "CleanupSettings")

    /// A threshold below one day, or one megabyte, gets its default, so a mistake never marks or
    /// lists everything.
    public init(
        unusedAfterDays: Int = Self.defaultUnusedAfterDays,
        oldAfterDays: Int = Self.defaultOldAfterDays,
        largeDownloadMegabytes: Int = Self.defaultLargeDownloadMegabytes
    ) {
        self.unusedAfterDays = unusedAfterDays >= 1 ? unusedAfterDays : Self.defaultUnusedAfterDays
        self.oldAfterDays = oldAfterDays >= 1 ? oldAfterDays : Self.defaultOldAfterDays
        // Capped so the byte count cannot overflow: a petabyte lists nothing anyway.
        self.largeDownloadMegabytes = largeDownloadMegabytes >= 1
            ? min(largeDownloadMegabytes, 1_000_000_000) : Self.defaultLargeDownloadMegabytes
    }

    /// The smallest space on disk, in bytes, that Review Large Downloads lists.
    public var largeDownloadThreshold: Int64 { Int64(largeDownloadMegabytes) * Self.bytesPerMegabyte }

    public var unusedAfter: TimeInterval { TimeInterval(unusedAfterDays) * Self.secondsPerDay }

    public var oldAfter: TimeInterval { TimeInterval(oldAfterDays) * Self.secondsPerDay }

    /// The settings kept in `store`. A missing value gets its default, and so does an unusable one
    /// (not a whole number, or below one), which is logged.
    public static func load(from store: any SettingsStore) -> CleanupSettings {
        CleanupSettings(
            unusedAfterDays: wholeNumber(forKey: unusedAfterDaysKey, in: store) ?? defaultUnusedAfterDays,
            oldAfterDays: wholeNumber(forKey: oldAfterDaysKey, in: store) ?? defaultOldAfterDays,
            largeDownloadMegabytes: wholeNumber(forKey: largeDownloadMegabytesKey, in: store) ?? defaultLargeDownloadMegabytes
        )
    }

    public func save(to store: any SettingsStore) {
        store.set(unusedAfterDays, forKey: Self.unusedAfterDaysKey)
        store.set(oldAfterDays, forKey: Self.oldAfterDaysKey)
        store.set(largeDownloadMegabytes, forKey: Self.largeDownloadMegabytesKey)
    }

    /// A whole number, 1 or more (days, or for the large-download threshold, megabytes): a stored
    /// integer, or the text of one, which is how a launch argument arrives. Nil when the value is
    /// missing or unusable.
    private static func wholeNumber(forKey key: String, in store: any SettingsStore) -> Int? {
        guard let value = store.object(forKey: key) else {
            return nil
        }
        let whole: Int?
        switch value {
        case let number as NSNumber where CFGetTypeID(number) != CFBooleanGetTypeID():
            whole = Int(exactly: number.doubleValue)
        case let text as String:
            whole = Int(text.trimmingCharacters(in: .whitespaces))
        default:
            whole = nil
        }
        guard let whole, whole >= 1 else {
            // A notice, not an error: it is the user's setting, read again on every refresh.
            logger.notice("Ignoring \(key, privacy: .public): expected a whole number, 1 or more. The default applies.")
            return nil
        }
        return whole
    }
}
