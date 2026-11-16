import FileStoreCore
import Foundation
import Observation
import os

/// Window state for a cleanup action while it looks for things to change, up to the plan its
/// preview shows: one flow for every action. Lives on the main actor; reading files runs elsewhere.
@MainActor
@Observable
final class CleanupSearchModel {
    enum Phase: Equatable {
        case idle
        /// Looking, for `action`. Only an action that reads files reports progress.
        case running(CleanupAction, CleanupPlanningProgress)
    }

    /// A finished plan with an identity, so the sheet showing it keeps its content while it
    /// animates away.
    struct PresentedPlan: Identifiable, Equatable {
        let id = UUID()
        let plan: CleanupPlan
    }

    private(set) var phase: Phase = .idle

    /// The finished plan, shown in the preview sheet until it is dismissed.
    private(set) var presentedPlan: PresentedPlan?

    var isRunning: Bool {
        if case .running = phase {
            return true
        }
        return false
    }

    /// The action looking now, and how far it has got.
    var running: (action: CleanupAction, progress: CleanupPlanningProgress)? {
        if case .running(let action, let progress) = phase {
            return (action, progress)
        }
        return nil
    }

    private var searchTask: Task<Void, Never>?

    /// Increases per search, so a late report from an earlier search cannot touch the current one.
    private var generation = 0

    private let logger = Logger(subsystem: "com.quaden2307.SmartOSFileStore", category: "Cleanup")

    /// Content hashes read by searches in this session, so Review Near-Duplicates reads no file
    /// that an earlier search already read, unchanged. Tidy Now reads and adds to it too.
    let hashCache = ContentHashCache()

    // Isolated, so it may touch main-actor state: the window is gone, stop reading files for a
    // preview nobody will see.
    isolated deinit {
        searchTask?.cancel()
    }

    /// Starts `action`'s search over `records`, cancelling any that is still running. `eligibility`
    /// decides which records may take part at all; the Kept list is read from `log` first, so the
    /// search always plans with the list as it is now. If it cannot be read, nothing is planned and
    /// the failure goes to `activity`.
    func start(
        _ action: CleanupAction,
        records: [FileRecord],
        folderURL: URL,
        eligibility: CandidateEligibility,
        applicationFolders: [URL],
        log: ActivityLog,
        activity: ActivityLogModel,
        onInstallersRead: @escaping @MainActor () -> Void
    ) {
        searchTask?.cancel()
        generation += 1
        let generation = generation
        presentedPlan = nil
        phase = .running(action, CleanupPlanningProgress(itemsChecked: 0, itemsToCheck: 0))
        logger.info("Planning \(action.definition.identifier, privacy: .public) over \(records.count) records")
        let opening = activity.openings
        let hashCache = hashCache
        // The thresholds the file list marks with, read the same way, so the two never disagree.
        let settings = CleanupSettings.load(from: UserDefaults.standard)

        // Weak throughout: the task must not keep the model alive, and `deinit` cancels the task.
        searchTask = Task { [weak self] in
            let outcome: Result<CleanupPlan?, CleanupPlanningError>
            do throws(ActivityLogError) {
                let keptItems = try await log.keptItems(forFolder: folderURL)
                do throws(CleanupPlanningError) {
                    let plan = try await CleanupPlanners.plan(
                        action,
                        records: records,
                        in: folderURL,
                        eligibility: eligibility,
                        keptItems: keptItems,
                        installers: .standard(applicationFolders: applicationFolders, cache: log),
                        settings: settings,
                        hashCache: hashCache
                    ) { progress in
                        Task { @MainActor in
                            self?.report(progress, generation: generation)
                        }
                    }
                    // What was read from installers is kept, so the next search reads none of them again
                    // and the list can mark them. The planner itself writes nothing.
                    if let read = plan?.installerFactsRead, !read.isEmpty {
                        do throws(ActivityLogError) {
                            try await log.storeInstallerFacts(read)
                        } catch {
                            self?.logger.error("What was read from installers could not be kept: \(String(describing: error), privacy: .public)")
                        }
                    }
                    if action == .removeUsedInstallers {
                        onInstallersRead()
                    }
                    outcome = .success(plan)
                } catch {
                    outcome = .failure(error)
                }
            } catch {
                // Planning without the Kept list could propose a Kept file, so there is no plan.
                guard !Task.isCancelled else { return }
                // A log closed and replaced meanwhile is not the one on screen now.
                if activity.openings == opening {
                    activity.logFailed(error)
                }
                self?.finish(.failure(.cancelled), action: action, generation: generation)
                return
            }
            // A cancelled or superseded search must not overwrite the state of the current one.
            guard !Task.isCancelled else { return }
            self?.finish(outcome, action: action, generation: generation)
        }
    }

    func cancel() {
        searchTask?.cancel()
        searchTask = nil
        phase = .idle
        logger.info("Cleanup search cancelled")
    }

    func dismissPlan() {
        presentedPlan = nil
    }

    private func report(_ progress: CleanupPlanningProgress, generation: Int) {
        guard generation == self.generation, let running else { return }
        phase = .running(running.action, progress)
    }

    private func finish(_ outcome: Result<CleanupPlan?, CleanupPlanningError>, action: CleanupAction, generation: Int) {
        guard generation == self.generation else { return }
        phase = .idle
        searchTask = nil
        switch outcome {
        case .success(let plan?):
            presentedPlan = PresentedPlan(plan: plan)
            logger.info(
                "Planned \(action.definition.identifier, privacy: .public): \(plan.duplicateGroups.count) duplicate groups, \(plan.changes.count) changes, \(plan.skippedItems.count) skipped"
            )
        case .success(nil):
            logger.error("\(action.definition.identifier, privacy: .public) has no planner")
        case .failure(.cancelled):
            break
        }
    }
}
