import FileStoreCore
import FileStoreIntelligence
import Foundation

// The chat module imports none of the engine, so the app copies what the chat may know out of the
// scan, field for field (docs/decisions/0020).

extension FolderSnapshot.File {
    init(_ record: FileRecord, marks: [FileMark]) {
        self.init(
            id: record.id,
            name: record.displayName,
            contentType: record.contentType,
            sizeInBytes: record.sizeInBytes,
            dateAdded: record.dateAdded,
            lastOpened: record.lastOpened,
            recordsOpens: record.recordsLastOpened,
            sourceSite: record.downloadSource?.site,
            marks: Set(marks.map(\.chatMark))
        )
    }
}

extension FolderSnapshot {
    /// The folder as the file list has it now, with the activity log's total while the log is open.
    @MainActor
    init(files: FileListModel, activity: ActivityLogModel) {
        self.init(
            files: files.records.map { File($0, marks: files.marks(for: $0)) },
            bytesMovedToTrash: activity.log == nil ? nil : activity.totals.bytesMovedToTrash
        )
    }
}

extension FileMark {
    /// Exhaustive on purpose: a new mark does not compile until the chat knows it.
    var chatMark: FolderSnapshot.Mark {
        switch self {
        case .kept: .kept
        case .failedDownload: .failedDownload
        case .installed: .installed
        case .duplicate: .duplicate
        case .neverOpened: .neverOpened
        case .unused: .unused
        case .old: .old
        }
    }
}

extension FolderSnapshot.Mark {
    var fileMark: FileMark {
        switch self {
        case .kept: .kept
        case .failedDownload: .failedDownload
        case .installed: .installed
        case .duplicate: .duplicate
        case .neverOpened: .neverOpened
        case .unused: .unused
        case .old: .old
        }
    }
}
