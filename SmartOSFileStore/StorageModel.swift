import FileStoreCore
import FileStoreIntelligence
import Foundation
import Observation
import os

/// The storage view's numbers for every folder's list: what is taking space, read from the list as
/// it is, and what each cleanup would get back, planned in the background once per scan and kept
/// until the folder is read again. Nothing is cleaned from here.
@MainActor
@Observable
final class StorageModel {
    /// One folder's numbers.
    struct Folder: Identifiable {
        let place: FolderPlace
        let name: String
        let total: StorageReport.Total
        let byType: [FileTypeGroup: StorageReport.Total]
        let largest: [FileRecord]
        /// Why it cannot be measured, when it cannot.
        let failure: ScanFailure?

        var id: FolderPlace { place }
    }

    private(set) var folders: [Folder] = []

    /// What each folder could get back, by folder, once planned.
    private(set) var reclaimable: [FolderPlace: ReclaimableSpace] = [:]

    /// Folders whose cleanups are being planned now.
    private(set) var planning: Set<FolderPlace> = []

    /// The scan each folder's reclaimable space was planned from.
    private var plannedGeneration: [FolderPlace: Int] = [:]
    private var tasks: [FolderPlace: Task<Void, Never>] = [:]
    private let logger = Logger(subsystem: "com.quaden2307.SmartOSFileStore", category: "Storage")

    /// Reads every list again, and plans what each folder could get back where its list changed
    /// since. A plan for a list that is reading again is stopped.
    func refresh(lists: FolderListsModel, activity: ActivityLogModel, hashCache: ContentHashCache) {
        folders = lists.all.map { list in
            Folder(
                place: list.place,
                name: list.displayName,
                total: StorageReport.total(of: list.records),
                byType: StorageReport.totals(of: list.records) { FileTypeGroup(contentType: $0.contentType) },
                largest: StorageReport.largest(list.records),
                failure: list.failure
            )
        }
        let places = Set(folders.map(\.place))
        for place in Set(tasks.keys).subtracting(places) {
            tasks[place]?.cancel()
            tasks[place] = nil
        }
        reclaimable = reclaimable.filter { places.contains($0.key) }
        guard let log = activity.log else { return }
        for list in lists.all where list.isSettled {
            guard let folder = list.logFolder, plannedGeneration[list.place] != list.scanGeneration || reclaimable[list.place] == nil else { continue }
            plan(list, folder: folder, log: log, hashCache: hashCache)
        }
    }

    private func plan(_ list: FileListModel, folder: ManagedFolder, log: ActivityLog, hashCache: ContentHashCache) {
        let place = list.place
        let generation = list.scanGeneration
        let records = list.records
        let eligibility = list.eligibility
        let installers = InstallerSources.standard(applicationFolders: list.applicationFolders, cache: log)
        let settings = CleanupSettings.load(from: UserDefaults.standard)
        let logger = logger
        tasks[place]?.cancel()
        planning.insert(place)
        tasks[place] = Task {
            do {
                let kept = try await log.keptItems(for: folder)
                let space = try await ReclaimableSpace.plan(
                    records: records, in: folder, eligibility: eligibility, keptItems: kept, installers: installers,
                    settings: settings, hashCache: hashCache
                )
                guard !Task.isCancelled else { return }
                reclaimable[place] = space
                plannedGeneration[place] = generation
            } catch {
                // The kind only: its text could hold a path.
                logger.notice("What a folder could get back was not planned: \(String(reflecting: type(of: error)), privacy: .public)")
            }
            if !Task.isCancelled {
                planning.remove(place)
            }
        }
    }
}
