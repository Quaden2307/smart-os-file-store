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
            marks: Set(marks.compactMap(\.chatMark))
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

extension DuplicateScan {
    /// Find Duplicates' groups as plain rows, with the marks the list shows on each file.
    @MainActor
    init(_ plan: CleanupPlan, files: FileListModel, recentCount: Int) {
        func row(_ record: FileRecord) -> FolderSnapshot.File {
            FolderSnapshot.File(record, marks: files.marks(for: record))
        }
        self.init(
            groups: plan.duplicateGroups.map { Group(kept: row($0.kept), copies: $0.duplicates.map(row)) },
            unreadableCount: plan.skippedItems.count,
            recentCount: recentCount
        )
    }
}

extension FileMark {
    /// Exhaustive on purpose: a new mark does not compile until the chat knows it. Nil for
    /// Duplicate, which only says what the last Tidy Now found: the chat reads the files instead.
    var chatMark: FolderSnapshot.Mark? {
        switch self {
        case .kept: .kept
        case .failedDownload: .failedDownload
        case .installed: .installed
        case .duplicate: nil
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
        case .neverOpened: .neverOpened
        case .unused: .unused
        case .old: .old
        }
    }
}
