import Foundation

/// What macOS recorded about an item beyond its file-system attributes: when it was last opened
/// and where it was downloaded from. Each part is nil when macOS recorded nothing usable.
public struct FileMetadata: Sendable, Hashable {
    /// When a user last opened the item, as Launch Services records it. Never the access time.
    public var lastOpened: Date?

    /// Where the item was downloaded from, and with which app.
    public var downloadSource: DownloadSource?

    /// False when the last-opened attribute could not be read at all: the volume keeps no extended
    /// attributes, permission was refused, or the item went away. A missing date then means
    /// unknown, not never opened.
    public var canReadLastOpened: Bool

    public init(lastOpened: Date? = nil, downloadSource: DownloadSource? = nil, canReadLastOpened: Bool = true) {
        self.lastOpened = lastOpened
        self.downloadSource = downloadSource
        self.canReadLastOpened = canReadLastOpened
    }
}
