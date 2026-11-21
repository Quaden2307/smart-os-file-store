import FileStoreCore
import Foundation
import Observation
import os

/// The activity log as the app holds it: whether it is open, the running totals, and a counter
/// that tells views when its content changed. One for the whole app, shared by the main window's
/// places and the cleanup preview. Lives
/// on the main actor; every read and write of the database runs elsewhere.
///
/// Cleanup needs a working log, so the main window offers cleanup only while `log` is set.
@MainActor
@Observable
final class ActivityLogModel {
    enum State {
        case opening
        /// The log is open and works.
        case ready(ActivityLog)
        /// The log cannot be used. Nothing is cleaned up until it works again.
        case failed(ActivityLogError)
    }

    private(set) var state: State = .opening

    /// Everything moved to the Trash and cleaned since the log began.
    private(set) var totals: ActivityTotals = .zero

    /// The newest cleanup run, which Edit > Undo undoes. Read with the totals.
    private(set) var latestCleanupRun: ActivityRun?

    /// Increases whenever the log's content may have changed, so views that show it load it again.
    private(set) var revision = 0

    /// Increases each time a log is opened: at launch, after Try Again, after Start a Fresh Log. What
    /// was read from one opening must not be mixed with the next; a fresh log numbers its runs anew.
    private(set) var openings = 0

    /// The database a fresh log replaced, kept beside it under a new name. Shown until dismissed,
    /// and kept even when opening the fresh log then failed, so its place is never lost.
    private(set) var setAsideURL: URL?

    /// True while the log is being opened again or replaced, so that is never started twice.
    private(set) var isRecovering = false

    /// Where the log lives. Nil when that could not be worked out.
    let location: ActivityLogLocation?

    /// Finds the managed folders, from the same launch arguments as the log's place.
    let folders: FolderRegistry

    /// Downloads as the open log knows it, read when that log was opened. Whatever is recorded in
    /// the log (a cleanup, a Kept mark) names this folder: a log started fresh has a new ID for it.
    /// Nil while no log is open, and when Downloads cannot be used.
    var downloads: ManagedFolder? {
        folder(at: .standard(.downloads))
    }

    /// The folders on the open log's list, found or not, in the order they were added. Read when the
    /// log opens, after every change to the list, and when the app comes back to the front or a disk
    /// is connected, so a folder on a disk that was away comes back by itself.
    private(set) var folderEntries: [FolderEntry] = []

    /// Increases whenever `folderEntries` was read again.
    private(set) var folderRevision = 0

    /// The folder at `place` as the open log knows it, when it was found. Whatever is recorded in
    /// the log names this folder. Nil while no log is open.
    func folder(at place: FolderPlace) -> ManagedFolder? {
        guard log != nil else { return nil }
        return entry(at: place)?.folder
    }

    /// The entry at `place`, found or not.
    func entry(at place: FolderPlace) -> FolderEntry? {
        folderEntries.first { FolderPlace($0) == place }
    }

    /// The folder a plan or run was made for, when it is still on the open log's list.
    func isListed(_ folder: ManagedFolder) -> Bool {
        log != nil && folderEntries.contains { $0.id == folder.id }
    }

    private var hasStartedOpening = false
    private let logger = Logger(subsystem: "com.quaden2307.SmartOSFileStore", category: "ActivityLog")

    /// The app's own identifier names the log's folder in Application Support.
    private static let fallbackAppIdentifier = "com.quaden2307.SmartOSFileStore"

    /// The registry for this copy of the app. The app's own folders are never managed: the log's,
    /// and the one disk images are read in.
    static func folderRegistry(
        arguments: [String] = ProcessInfo.processInfo.arguments,
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) -> FolderRegistry {
        let location = try? ActivityLogLocation.resolve(
            arguments: arguments,
            environment: environment,
            appIdentifier: Bundle.main.bundleIdentifier ?? fallbackAppIdentifier
        )
        return FolderRegistry.forProcess(
            arguments: arguments,
            environment: environment,
            appDataFolders: [location?.folderURL, DiskImageMounts.shared.root].compactMap(\.self)
        )
    }

    init(
        arguments: [String] = ProcessInfo.processInfo.arguments,
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) {
        folders = Self.folderRegistry(arguments: arguments, environment: environment)
        do throws(ActivityLogError) {
            location = try ActivityLogLocation.resolve(
                arguments: arguments,
                environment: environment,
                appIdentifier: Bundle.main.bundleIdentifier ?? Self.fallbackAppIdentifier
            )
        } catch {
            location = nil
            state = .failed(error)
            logger.error("The activity log's location could not be resolved: \(String(describing: error), privacy: .public)")
        }
    }

    /// The open log. Nil while it is being opened and when it cannot be used.
    var log: ActivityLog? {
        if case .ready(let log) = state {
            return log
        }
        return nil
    }

    /// The failure to show, if the log cannot be used.
    var failure: ActivityLogError? {
        if case .failed(let error) = state {
            return error
        }
        return nil
    }

    /// True when opening the log again could help: there is a place for it.
    var canRetry: Bool { location != nil }

    /// Opens the log, once. The main window calls this when it appears; later calls do nothing.
    func open() {
        guard !hasStartedOpening else { return }
        hasStartedOpening = true
        load(replacingDatabase: false)
    }

    /// Tries to open the log again after a failure.
    func retry() {
        guard failure != nil, !isRecovering else { return }
        load(replacingDatabase: false)
    }

    /// Keeps the database that cannot be used under a new name and starts a fresh log in its place.
    func startFresh() {
        guard failure != nil, !isRecovering else { return }
        load(replacingDatabase: true)
    }

    /// Called when a run has ended, from the task that ran it, whether or not its sheet is still there.
    func runFinished(_ result: CleanupResult) {
        runFinished(logFailure: result.logFailure)
    }

    /// The same, for a run of several actions' changes (Tidy Now).
    func runFinished(logFailure: CleanupLogFailure?) {
        revision += 1
        if let failure = logFailure {
            fail(failure.error)
            return
        }
        reloadTotals()
    }

    /// Called when an undo has ended, from the task that ran it, whether or not its sheet is still there.
    func undoFinished(_ result: UndoResult) {
        revision += 1
        if let failure = result.logFailure {
            fail(failure.error)
            return
        }
        reloadTotals()
    }

    /// Called when using the open log failed elsewhere: reading it in the Activity place, or reading
    /// or changing the Kept list. A log that cannot be used cannot be trusted to record a cleanup either.
    func logFailed(_ error: ActivityLogError) {
        fail(error)
    }

    func dismissSetAsideNotice() {
        setAsideURL = nil
    }

    private func load(replacingDatabase: Bool) {
        guard let location else { return }
        if failure != nil {
            isRecovering = true
        }
        Task {
            do throws(ActivityLogError) {
                if replacingDatabase, let setAside = try await ActivityLog.setAsideDatabase(at: location) {
                    // Remembered at once: if the fresh log cannot be opened, where the old one went
                    // must still be shown.
                    setAsideURL = setAside
                }
                let opened = try await ActivityLog.open(location)
                // An undo a crash interrupted is settled first, before pruning could remove the run
                // it was undoing. A row that cannot be settled stays started, in a run marked
                // interrupted, for the next launch; the log is still usable.
                do throws(ActivityLogError) {
                    _ = try await UndoReconciler().reconcile(opened, folders: folders)
                } catch {
                    logger.error("Interrupted undos could not be settled: \(String(describing: error), privacy: .public)")
                }
                // Old runs go at most once a day. A failure here leaves the log larger, not unusable.
                do throws(ActivityLogError) {
                    _ = try await opened.pruneIfDue()
                } catch {
                    logger.error("The activity log could not be pruned: \(String(describing: error), privacy: .public)")
                }
                totals = try await opened.totals()
                latestCleanupRun = try await opened.latestCleanupRun()
                if DebugSnapshot.turnsOnStandardFolders {
                    _ = try await folders.add(.desktop, to: opened)
                    _ = try await folders.add(.documents, to: opened)
                }
                folderEntries = try await folders.entries(in: opened)
                folderRevision += 1
                openings += 1
                state = .ready(opened)
            } catch {
                state = .failed(error)
                logger.error("The activity log could not be opened: \(String(describing: error), privacy: .public)")
            }
            isRecovering = false
            revision += 1
        }
    }

    // MARK: - The folder list

    /// Reads the folder list again, for a folder that came back or went away.
    func reloadFolders() {
        guard let log else { return }
        Task {
            do throws(ActivityLogError) {
                let entries = try await folders.entries(in: log)
                // Unchanged: no view needs to redraw, and no list is read again.
                guard entries.map(\.signature) != folderEntries.map(\.signature) else { return }
                folderEntries = entries
                folderRevision += 1
            } catch {
                fail(error)
            }
        }
    }

    /// Turns on Desktop or Documents. Reading it, which is when macOS asks, is the list's job.
    func turnOn(_ kind: ManagedFolder.Kind) async -> FolderLocationError? {
        await change { log, folders throws(ActivityLogError) in
            try await folders.add(kind, to: log).failure
        }
    }

    /// Adds a folder the user chose. Nil when it was added; otherwise why not.
    func addFolder(at url: URL) async -> FolderLocationError? {
        await change { log, folders throws(ActivityLogError) in
            try await folders.add(customFolderAt: url, to: log).failure
        }
    }

    /// Gives a custom folder a new name in the app. Nothing on disk changes.
    func setDisplayName(of id: ManagedFolder.ID, to name: String) async {
        _ = await change { log, folders throws(ActivityLogError) in
            try await folders.setDisplayName(of: id, to: name, in: log)
            return nil
        }
    }

    /// Keeps a folder's own rules; nil goes back to its kind's defaults. Nothing on disk changes,
    /// and nothing goes in the activity log's history.
    func setRules(_ rules: FolderRules?, of id: ManagedFolder.ID) async {
        _ = await change { log, folders throws(ActivityLogError) in
            try await folders.setRules(rules, of: id, in: log)
            return nil
        }
    }

    /// Takes a folder off the list. Nothing on disk changes, and its runs stay in Activity.
    func remove(_ entry: FolderEntry) async {
        _ = await change { log, folders throws(ActivityLogError) in
            try await folders.remove(folderID: entry.id, from: log)
            return nil
        }
    }

    private func change(
        _ operation: @Sendable (ActivityLog, FolderRegistry) async throws(ActivityLogError) -> FolderLocationError?
    ) async -> FolderLocationError? {
        guard let log else { return nil }
        do throws(ActivityLogError) {
            let refusal = try await operation(log, folders)
            folderEntries = try await folders.entries(in: log)
            folderRevision += 1
            revision += 1
            return refusal
        } catch {
            fail(error)
            return nil
        }
    }

    private func reloadTotals() {
        guard let log else { return }
        Task {
            do throws(ActivityLogError) {
                totals = try await log.totals()
                latestCleanupRun = try await log.latestCleanupRun()
            } catch {
                fail(error)
            }
        }
    }

    /// The log stopped working while it was open. It is closed, so nothing can go on using it, and
    /// cleanup is off until it has been opened again or replaced. A log that has already failed
    /// keeps its first failure.
    private func fail(_ error: ActivityLogError) {
        guard let log else { return }
        logger.error("The activity log failed: \(String(describing: error), privacy: .public)")
        state = .failed(error)
        let logger = logger
        Task {
            do throws(ActivityLogError) {
                try await log.close()
            } catch {
                logger.error("The failed activity log could not be closed: \(String(describing: error), privacy: .public)")
            }
        }
    }
}

/// Where in the sidebar a folder sits: one of the standard folders, which has one place whatever
/// its ID, or a custom folder by its ID.
enum FolderPlace: Hashable {
    case standard(ManagedFolder.Kind)
    case custom(ManagedFolder.ID)

    init(_ entry: FolderEntry) {
        self = entry.kind == .custom ? .custom(entry.id) : .standard(entry.kind)
    }

    /// The standard folders, in the sidebar's order.
    static let standardPlaces: [FolderPlace] = [.standard(.downloads), .standard(.desktop), .standard(.documents)]
}

private extension Result {
    var failure: Failure? {
        if case .failure(let error) = self { error } else { nil }
    }
}

private extension FolderEntry {
    /// What the sidebar shows of an entry, to tell whether a fresh read changed anything.
    var signature: String {
        "\(id)|\(storedName ?? "")|\(folder?.url.path(percentEncoded: false) ?? "-")|\(folder?.displayName ?? "")"
    }
}
