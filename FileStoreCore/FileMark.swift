import Foundation

/// A label the file list shows on an item, and filters by. An item can carry several.
///
/// The declaration order is the order marks are shown in. Later segments add marks here (installed,
/// failed download, duplicate, kept), each with a title in the app's display extension; the table
/// and the filter show any mark the same way, so neither changes.
public enum FileMark: Sendable, Hashable, CaseIterable {
    /// No last-opened date, and in the folder longer than the unused threshold.
    case neverOpened
    /// Last opened longer ago than the unused threshold.
    case unused
    /// In the folder longer than the old threshold, opened or not.
    case old
}
