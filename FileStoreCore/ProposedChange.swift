import Foundation

/// One change a cleanup action proposes. Nothing happens to the file until the user confirms it.
public struct ProposedChange: Sendable, Hashable, Identifiable {
    /// What would be done to the file.
    public enum Operation: Sendable, Hashable {
        /// Move the file to the Trash with `FileManager.trashItem`. Never a permanent delete.
        case moveToTrash
    }

    /// Why the action proposes the change. Typed, so the app can put it into words in the user's
    /// language; the engine has no String Catalog.
    public enum Reason: Sendable, Hashable {
        /// The file has exactly the same bytes as the named file, which is kept.
        case sameContent(asFileNamed: String)
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

    public init(record: FileRecord, operation: Operation, reason: Reason) {
        self.record = record
        self.operation = operation
        self.reason = reason
        self.sizeInBytes = record.sizeInBytes ?? 0
        self.dateModified = record.dateModified
        self.originalPath = record.url.path(percentEncoded: false)
    }
}
