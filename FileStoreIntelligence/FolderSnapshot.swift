import Foundation
import UniformTypeIdentifiers

/// Everything the chat may know about the scanned folder: plain values the app copies from its
/// scan. This module imports none of the engine, so it can never see more than this
/// (docs/decisions/0020).
public struct FolderSnapshot: Sendable {
    /// The marks the file list shows, but Duplicate: that one only says what the last Tidy Now
    /// found, and the chat finds copies by reading the files (`findDuplicates`, docs/decisions/0021).
    /// The app maps the engine's `FileMark` with an exhaustive switch, so a new mark cannot be forgotten.
    public enum Mark: String, Sendable, Hashable, CaseIterable {
        case kept, failedDownload, installed, neverOpened, unused, old
    }

    public struct File: Sendable, Identifiable, Equatable {
        public let id: URL
        public var name: String
        public var contentType: UTType?
        /// Nil for a folder, as in the file list.
        public var sizeInBytes: Int64?
        public var dateAdded: Date?
        public var lastOpened: Date?
        /// False for the kinds macOS does not date when they are opened (folders, apps, links), so
        /// "never opened" is never claimed for them.
        public var recordsOpens: Bool
        /// The site the file was downloaded from, without "www.".
        public var sourceSite: String?
        public var marks: Set<Mark>

        public init(
            id: URL, name: String, contentType: UTType? = nil, sizeInBytes: Int64? = nil,
            dateAdded: Date? = nil, lastOpened: Date? = nil, recordsOpens: Bool = true,
            sourceSite: String? = nil, marks: Set<Mark> = []
        ) {
            self.id = id
            self.name = name
            self.contentType = contentType
            self.sizeInBytes = sizeInBytes
            self.dateAdded = dateAdded
            self.lastOpened = lastOpened
            self.recordsOpens = recordsOpens
            self.sourceSite = sourceSite
            self.marks = marks
        }
    }

    public var files: [File]
    /// The activity log's running total. Nil while the log is not open.
    public var bytesMovedToTrash: Int64?
    public var now: Date

    public init(files: [File], bytesMovedToTrash: Int64? = nil, now: Date = .now) {
        self.files = files
        self.bytesMovedToTrash = bytesMovedToTrash
        self.now = now
    }
}
