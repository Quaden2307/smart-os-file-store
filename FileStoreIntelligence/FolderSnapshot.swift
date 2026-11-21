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
        /// True for a download still in progress, which cannot have been opened yet.
        public var isDownloading: Bool
        /// The site the file was downloaded from, without "www.".
        public var sourceSite: String?
        public var marks: Set<Mark>
        /// The managed folder the file is in, by the name the app shows. Nil in a snapshot of one folder.
        public var folder: String?

        public init(
            id: URL, name: String, contentType: UTType? = nil, sizeInBytes: Int64? = nil,
            dateAdded: Date? = nil, lastOpened: Date? = nil, recordsOpens: Bool = true,
            isDownloading: Bool = false, sourceSite: String? = nil, marks: Set<Mark> = [], folder: String? = nil
        ) {
            self.folder = folder
            self.id = id
            self.name = name
            self.contentType = contentType
            self.sizeInBytes = sizeInBytes
            self.dateAdded = dateAdded
            self.lastOpened = lastOpened
            self.recordsOpens = recordsOpens
            self.isDownloading = isDownloading
            self.sourceSite = sourceSite
            self.marks = marks
        }
    }

    /// A folder the app manages, by the name it shows, and whether the chat can read it.
    public struct Folder: Sendable, Equatable {
        public enum State: Sendable, Equatable {
            case available
            /// macOS has not allowed the app to read it.
            case permissionNeeded
            /// It cannot be found now: a disk that is not connected, or it was deleted.
            case unavailable
        }

        public var name: String
        public var state: State
        /// The folder on screen, which a question without a folder is about.
        public var isCurrent: Bool

        public init(name: String, state: State = .available, isCurrent: Bool = false) {
            self.name = name
            self.state = state
            self.isCurrent = isCurrent
        }
    }

    public var files: [File]
    /// The folders the app manages and the user turned on. Empty for a snapshot of one folder.
    public var folders: [Folder]
    /// The activity log's running total. Nil while the log is not open.
    public var bytesMovedToTrash: Int64?
    public var now: Date

    public init(files: [File], folders: [Folder] = [], bytesMovedToTrash: Int64? = nil, now: Date = .now) {
        self.files = files
        self.folders = folders
        self.bytesMovedToTrash = bytesMovedToTrash
        self.now = now
    }
}
