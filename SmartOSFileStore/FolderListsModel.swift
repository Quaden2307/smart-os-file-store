import FileStoreCore
import Foundation
import Observation

/// One file list per managed folder, each keeping its own rows, sort, filter and marks while the
/// app runs. Downloads' list exists from launch, before the activity log opens; the others are made
/// when the log finds their folder, and dropped when the folder leaves the list.
@MainActor
@Observable
final class FolderListsModel {
    let downloads = FileListModel()

    private(set) var others: [FolderPlace: FileListModel] = [:]

    private weak var activity: ActivityLogModel?

    func connect(to activity: ActivityLogModel) {
        self.activity = activity
        downloads.connect(to: activity)
    }

    /// The list at `place`, when its folder is managed and was found.
    func list(at place: FolderPlace) -> FileListModel? {
        place == .standard(.downloads) ? downloads : others[place]
    }

    /// Every list there is.
    var all: [FileListModel] { [downloads] + others.values }

    /// Follows the activity log's folder list: a list for each folder that was found, read at once,
    /// and none for a folder that was taken off the list or cannot be found now. A custom folder
    /// found at a new place is read there.
    func sync(readingNew: Bool) {
        guard let activity else { return }
        var kept: [FolderPlace: FileListModel] = [:]
        for entry in activity.folderEntries where entry.kind != .downloads {
            let place = FolderPlace(entry)
            guard let folder = entry.folder else { continue }
            if let existing = others[place] {
                existing.relocate(to: folder)
                kept[place] = existing
            } else {
                let list = FileListModel(folder: folder, place: place, activity: activity)
                kept[place] = list
                if readingNew {
                    list.refresh()
                }
            }
        }
        others = kept
    }
}
