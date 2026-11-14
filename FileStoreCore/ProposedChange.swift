import Foundation

/// One change a cleanup action proposes. Nothing happens to the file until the user confirms it.
public struct ProposedChange: Sendable, Hashable, Identifiable {
    /// What would be done to the file. Every operation is one an undo can reverse; nothing is
    /// ever deleted and nothing is ever overwritten.
    public enum Operation: Sendable, Hashable {
        /// Move the file to the Trash with `FileManager.trashItem`. Never a permanent delete.
        case moveToTrash

        /// Give the file a new name in the same folder. `to` is one file name, not a path. Fails,
        /// rather than overwrites, when the name is taken.
        case rename(to: String)

        /// Move the file into `to`, a folder inside the scanned folder (made if it is missing),
        /// under `name`. Fails, rather than overwrites, when the name is taken there.
        case move(to: URL, name: String)
    }

    /// Why the action proposes the change. Typed, so the app can put it into words in the user's
    /// language; the engine has no String Catalog.
    public enum Reason: Sendable, Hashable {
        /// The file has exactly the same bytes as the named file, which is kept.
        case sameContent(asFileNamed: String)

        /// The name has copy numbers or leftover junk that the new name drops.
        case messyName

        /// The file is an old download, filed into the archive.
        case oldDownload
    }

    public var id: URL { record.url }

    /// The file as the scan saw it.
    public let record: FileRecord

    public let operation: Operation

    public let reason: Reason

    /// Size at scan time. Execution rechecks it right before acting.
    public let sizeInBytes: Int64

    /// Modification date at scan time. Execution rechecks it right before acting.
    public let dateModified: Date?

    /// Where the file was, so a later undo can put it back.
    public let originalPath: String

    /// Where the file would be after a rename or a move, so a later undo can find it there. Nil for
    /// the Trash, which picks the place itself; the result reports where the file went.
    public let destinationPath: String?

    public init(record: FileRecord, operation: Operation, reason: Reason) {
        self.record = record
        self.operation = operation
        self.reason = reason
        self.sizeInBytes = record.sizeInBytes ?? 0
        self.dateModified = record.dateModified
        self.originalPath = record.url.path(percentEncoded: false)
        switch operation {
        case .moveToTrash:
            self.destinationPath = nil
        case .rename(to: let newName):
            self.destinationPath = record.url.deletingLastPathComponent().appending(path: newName).path(percentEncoded: false)
        case .move(to: let folder, name: let name):
            self.destinationPath = folder.appending(path: name).path(percentEncoded: false)
        }
    }
}
