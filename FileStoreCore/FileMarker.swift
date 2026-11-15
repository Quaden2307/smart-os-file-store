import Foundation

/// Decides which marks an item carries. Pure: it reads only the record, the settings, the Kept list
/// and the time it is given, so tests decide what "now" is.
public enum FileMarker {
    /// The marks `record` carries at `now`, in `FileMark.allCases` order.
    ///
    /// - Kept: `keptItems` contains it. Any item can be Kept, folders and apps included, so this mark
    ///   comes before every rule below.
    /// - Never opened: no last-opened date, and added more than `settings.unusedAfter` ago.
    /// - Unused: last opened more than `settings.unusedAfter` ago.
    /// - Old: added more than `settings.oldAfter` ago, opened or not, so it can join either of the two.
    ///
    /// "More than" is strict: an item exactly at a threshold is not marked. Folders, apps, symbolic
    /// links and Finder aliases get no age marks, because macOS does not record when they are opened,
    /// and nor does an item whose date could not be read (`FileRecord.recordsLastOpened`); nor do
    /// hidden items, the archive folder's name, or downloads still in progress. Without a Date Added
    /// (some volumes do not record one), how long an item has been in the folder is unknown, so it is
    /// never Never opened or Old.
    public static func marks(
        for record: FileRecord,
        now: Date,
        settings: CleanupSettings,
        keptItems: KeptItems = KeptItems()
    ) -> [FileMark] {
        var marks: [FileMark] = keptItems.contains(record) ? [.kept] : []
        guard record.recordsLastOpened,
              !CandidateEligibility.isExcludedName(record.displayName),
              !record.isDownloading
        else {
            return marks
        }

        if let lastOpened = record.lastOpened {
            if now.timeIntervalSince(lastOpened) > settings.unusedAfter {
                marks.append(.unused)
            }
        } else if let dateAdded = record.dateAdded, now.timeIntervalSince(dateAdded) > settings.unusedAfter {
            marks.append(.neverOpened)
        }
        if let dateAdded = record.dateAdded, now.timeIntervalSince(dateAdded) > settings.oldAfter {
            marks.append(.old)
        }
        return marks
    }
}
