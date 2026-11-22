import FileStoreCore
import FileStoreIntelligence
import Foundation

// Built from the lists on screen; the rows themselves are `ChatPlanning`'s (docs/decisions/0020).

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
