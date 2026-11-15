import Foundation
import os

/// The rules that decide whether an item may take part in a cleanup action at all, before the
/// action's own rules look at it. Every planner filters with `allows`, and the executor applies
/// `refusal` again with dates read from disk right before acting, so the rules live in one place.
/// The Kept list is one of them: planners match records against the list given here, and the
/// executor reads the list from the activity log again before each change.
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
        /// The user marked it Kept. Checked last, so an action that compares files can tell a Kept
        /// item that would otherwise take part from one the other rules keep out.
        case kept
    }

    /// How the rules treat a download still in progress.
    public enum DownloadsInProgress: Sendable, Equatable {
        /// Never a candidate: every action but Clear Failed Downloads.
        case refused
        /// May take part: Clear Failed Downloads, whose own rule decides which are failed and which
        /// still in progress. The other rules still apply, the grace period included.
        case allowed
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

    /// The items the user marked Kept, as read from the activity log before planning. No plan ever
    /// proposes a change to one of them.
    public let keptItems: KeptItems

    /// A negative grace period counts as none. A value that is not a number gets the default, so a
    /// mistake never makes the rule looser.
    public init(gracePeriod: TimeInterval = Self.defaultGracePeriod, keptItems: KeptItems = KeptItems()) {
        self.gracePeriod = gracePeriod.isNaN ? Self.defaultGracePeriod : max(0, gracePeriod)
        self.keptItems = keptItems
    }

    /// These rules with `keptItems` as the Kept list: what a planner is given once the list has
    /// been read.
    public func keeping(_ keptItems: KeptItems) -> CandidateEligibility {
        CandidateEligibility(gracePeriod: gracePeriod, keptItems: keptItems)
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
    ///
    /// - Parameters:
    ///   - dateModified: When the item last changed: for a folder whose contents were read, its
    ///     last change (`FileRecord.lastChange`).
    ///   - downloads: Whether a download still in progress may take part. Only Clear Failed
    ///     Downloads passes `.allowed`.
    public func refusal(
        name: String,
        isDownloading: Bool,
        dateAdded: Date?,
        dateModified: Date?,
        now: Date,
        downloads: DownloadsInProgress = .refused
    ) -> Refusal? {
        if Self.isExcludedName(name) {
            return .excludedName
        }
        if isDownloading, downloads == .refused {
            return .downloadInProgress
        }
        if !isSettled(dateAdded: dateAdded, dateModified: dateModified, now: now) {
            return .insideGracePeriod
        }
        return nil
    }

    /// The rules every action shares, for `record` as the scan saw it: nil when it may be proposed
    /// for a change at `now`, otherwise the first rule that keeps it out, with Kept last. The grace
    /// period counts from the record's last change, which is its modification date for everything
    /// but a `.download` folder whose contents were read.
    public func refusal(for record: FileRecord, now: Date, downloads: DownloadsInProgress = .refused) -> Refusal? {
        if let refusal = refusal(
            name: record.displayName,
            isDownloading: record.isDownloading,
            dateAdded: record.dateAdded,
            dateModified: record.lastChange,
            now: now,
            downloads: downloads
        ) {
            return refusal
        }
        return keptItems.contains(record) ? .kept : nil
    }

    /// True when the shared rules let `record` be proposed for a change at `now`: it is not hidden,
    /// not the archive, not still downloading, past the grace period, and not Kept. Each action adds
    /// its own rules on top, such as which kinds of item it handles. Clear Failed Downloads, the one
    /// action with its own rule for downloads in progress, passes `.allowed` to the rules above.
    public func allows(_ record: FileRecord, now: Date) -> Bool {
        refusal(for: record, now: now) == nil
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
