import Foundation
import os

/// The rules that decide whether an item may take part in a cleanup action at all, before the
/// action's own rules look at it. Every planner filters with `allows`, and the executor applies
/// `refusal` again with dates read from disk right before acting, so the rules live in one place.
///
/// The current time is always a parameter, never read here, so tests decide what "now" is.
public struct CandidateEligibility: Sendable, Equatable {
    /// Which shared rule keeps an item out.
    public enum Refusal: Sendable, Equatable {
        /// A hidden name or the archive folder's name.
        case excludedName
        /// A download still in progress.
        case downloadInProgress
        /// Added or modified within the grace period, or its modification date is unknown.
        case insideGracePeriod
    }

    /// An item added or modified more recently than this is left alone: it may still be
    /// downloading, being unpacked or being looked at for the first time.
    public static let defaultGracePeriod: TimeInterval = 60 * 60

    /// The archive: a folder with this name at the top level of the scanned folder. Neither it nor
    /// anything in it is ever a candidate. Names are compared case-insensitively.
    public static let archiveFolderName = "Old downloads"

    /// Debug-only launch argument that sets the grace period. The next argument is a whole number
    /// of seconds, 0 or more, so hand testing can use files made moments ago. Release builds ignore it.
    public static let gracePeriodArgumentName = "-GracePeriodSeconds"

    /// How long after it was added or last modified an item becomes a candidate.
    public let gracePeriod: TimeInterval

    /// A negative grace period counts as none. A value that is not a number gets the default, so a
    /// mistake never makes the rule looser.
    public init(gracePeriod: TimeInterval = Self.defaultGracePeriod) {
        self.gracePeriod = gracePeriod.isNaN ? Self.defaultGracePeriod : max(0, gracePeriod)
    }

    /// The rules for this run: the default grace period, or in a debug build the one given with
    /// `-GracePeriodSeconds`. A missing or unusable value is logged and the default applies, so a
    /// mistake never makes the rule looser.
    ///
    /// - Parameter arguments: The process arguments. Defaults to the current process's arguments.
    public static func resolve(arguments: [String] = ProcessInfo.processInfo.arguments) -> CandidateEligibility {
        #if DEBUG
        if let override = debugOverride(arguments: arguments) {
            return override
        }
        #endif
        return CandidateEligibility()
    }

    /// True when the item is past the grace period at `now`: modified at least `gracePeriod` before
    /// it, and added to its folder at least that long before it. An unknown modification date counts
    /// as not settled. An unknown Date Added (some volumes do not record it) leaves the modification
    /// date to decide alone.
    public func isSettled(dateAdded: Date?, dateModified: Date?, now: Date) -> Bool {
        guard let dateModified, now.timeIntervalSince(dateModified) >= gracePeriod else {
            return false
        }
        guard let dateAdded else {
            return true
        }
        return now.timeIntervalSince(dateAdded) >= gracePeriod
    }

    /// True for names no action may treat as a candidate: a hidden name (leading dot) and the
    /// archive folder's name, in any letter case.
    public static func isExcludedName(_ name: String) -> Bool {
        name.hasPrefix(".") || name.compare(archiveFolderName, options: .caseInsensitive) == .orderedSame
    }

    /// The rules every action shares, for an item described by its name, whether it is a download
    /// still in progress, and its dates: nil when the item may take part, otherwise the first rule
    /// that keeps it out. Planners pass a scan's record (`allows`); the executor passes what it
    /// reads from disk right before acting, so both apply exactly the same rules.
    public func refusal(name: String, isDownloading: Bool, dateAdded: Date?, dateModified: Date?, now: Date) -> Refusal? {
        if Self.isExcludedName(name) {
            return .excludedName
        }
        if isDownloading {
            return .downloadInProgress
        }
        if !isSettled(dateAdded: dateAdded, dateModified: dateModified, now: now) {
            return .insideGracePeriod
        }
        return nil
    }

    /// True when the shared rules let `record` take part at `now`. Each action adds its own rules
    /// on top, such as which kinds of item it handles. An action with its own rule for downloads in
    /// progress combines `isExcludedName` and `isSettled` itself.
    public func allows(_ record: FileRecord, now: Date) -> Bool {
        refusal(
            name: record.displayName,
            isDownloading: record.isDownloading,
            dateAdded: record.dateAdded,
            dateModified: record.dateModified,
            now: now
        ) == nil
    }

    #if DEBUG
    private static let logger = Logger(subsystem: "com.quaden2307.FileStoreCore", category: "CandidateEligibility")

    private static func debugOverride(arguments: [String]) -> CandidateEligibility? {
        guard let flagIndex = arguments.firstIndex(of: gracePeriodArgumentName) else {
            return nil
        }
        let valueIndex = arguments.index(after: flagIndex)
        guard valueIndex < arguments.endIndex, let seconds = Int(arguments[valueIndex]), seconds >= 0 else {
            logger.error(
                "Ignoring \(gracePeriodArgumentName, privacy: .public): expected a whole number of seconds, 0 or more. The default of \(Int(defaultGracePeriod)) s applies."
            )
            return nil
        }
        logger.notice("Grace period set to \(seconds) s by \(gracePeriodArgumentName, privacy: .public) (debug builds only)")
        return CandidateEligibility(gracePeriod: TimeInterval(seconds))
    }
    #endif
}
