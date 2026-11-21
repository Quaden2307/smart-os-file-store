import FileStoreCore
import FileStoreIntelligence
import Foundation

// The chat module imports none of the engine, so the app copies what the chat may know out of the
// scan, field for field (docs/decisions/0020).

extension FolderSnapshot.File {
    init(_ record: FileRecord, marks: [FileMark], folder: String? = nil) {
        self.init(
            id: record.id,
            name: record.displayName,
            contentType: record.contentType,
            sizeInBytes: record.sizeInBytes,
            dateAdded: record.dateAdded,
            lastOpened: record.lastOpened,
            recordsOpens: record.recordsLastOpened,
            isDownloading: record.isDownloading,
            sourceSite: record.downloadSource?.site,
            marks: Set(marks.compactMap(\.chatMark)),
            folder: folder
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

    /// Every folder the user turned on, each file with its folder's name, and which folder is on
    /// screen. A folder macOS has not allowed, or that cannot be found, is listed as such and never
    /// as empty. Built when a tool asks, from the lists as they are.
    @MainActor
    init(lists: FolderListsModel, current: FileListModel, activity: ActivityLogModel) {
        var files: [File] = []
        var folders: [Folder] = []
        for list in lists.all {
            let state: Folder.State = list.failure == nil ? .available : list.failure?.isPermissionDenied == true ? .permissionNeeded : .unavailable
            folders.append(Folder(name: list.displayName, state: state, isCurrent: list === current))
            files += list.records.map { File($0, marks: list.marks(for: $0), folder: list.displayName) }
        }
        // Folders on the list that cannot be found have no list.
        for entry in activity.folderEntries where entry.folder == nil {
            folders.append(Folder(name: entry.storedName ?? entry.kind.standardName, state: .unavailable))
        }
        self.init(files: files, folders: folders, bytesMovedToTrash: activity.log == nil ? nil : activity.totals.bytesMovedToTrash)
    }
}

extension DuplicateScan {
    /// Find Duplicates' groups as plain rows, with the marks the list shows on each file.
    @MainActor
    init(_ plan: CleanupPlan, files: FileListModel, recentCount: Int, folderName: String? = nil) {
        func row(_ record: FileRecord) -> FolderSnapshot.File {
            FolderSnapshot.File(record, marks: files.marks(for: record), folder: folderName)
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
