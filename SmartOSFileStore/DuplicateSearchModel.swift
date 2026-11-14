import FileStoreCore
import Foundation
import Observation
import os

/// Window state for Find Duplicates. Lives on the main actor; hashing runs elsewhere.
@MainActor
@Observable
final class DuplicateSearchModel {
    enum Phase: Equatable {
        case idle
        case running(DuplicateScanProgress)
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

    var progress: DuplicateScanProgress? {
        if case .running(let progress) = phase {
            return progress
        }
        return nil
    }

    private var searchTask: Task<Void, Never>?

    /// Increases per search, so a late report from an earlier search cannot touch the current one.
    private var generation = 0

    private let logger = Logger(subsystem: "com.quaden2307.SmartOSFileStore", category: "Duplicates")

    // Isolated, so it may touch main-actor state: the window is gone, stop reading files for a
    // preview nobody will see.
    isolated deinit {
        searchTask?.cancel()
    }

    /// Starts a search over `records`, cancelling any that is still running. `eligibility` decides
    /// which records may take part at all.
    func start(records: [FileRecord], folderURL: URL, eligibility: CandidateEligibility) {
        searchTask?.cancel()
        generation += 1
        let generation = generation
        presentedPlan = nil
        phase = .running(DuplicateScanProgress(filesHashed: 0, filesToHash: 0, bytesHashed: 0, bytesToHash: 0))
        logger.info("Finding duplicates among \(records.count) records")

        let planner = DuplicatePlanner(eligibility: eligibility)
        // Weak throughout: the task must not keep the model alive, and `deinit` cancels the task.
        searchTask = Task { [weak self] in
            let outcome: Result<CleanupPlan, DuplicatePlanError>
            do throws(DuplicatePlanError) {
                let plan = try await planner.plan(records: records, in: folderURL) { progress in
                    Task { @MainActor in
                        self?.report(progress, generation: generation)
                    }
                }
                outcome = .success(plan)
            } catch {
                outcome = .failure(error)
            }
            // A cancelled or superseded search must not overwrite the state of the current one.
            guard !Task.isCancelled else { return }
            self?.finish(outcome, generation: generation)
        }
    }

    func cancel() {
        searchTask?.cancel()
        searchTask = nil
        phase = .idle
        logger.info("Duplicate search cancelled")
    }

    func dismissPlan() {
        presentedPlan = nil
    }

    private func report(_ progress: DuplicateScanProgress, generation: Int) {
        guard generation == self.generation, isRunning else { return }
        phase = .running(progress)
    }

    private func finish(_ outcome: Result<CleanupPlan, DuplicatePlanError>, generation: Int) {
        guard generation == self.generation else { return }
        phase = .idle
        searchTask = nil
        switch outcome {
        case .success(let plan):
            presentedPlan = PresentedPlan(plan: plan)
            logger.info(
                "Found \(plan.duplicateGroups.count) duplicate groups, \(plan.changes.count) files to trash, \(plan.skippedItems.count) skipped"
            )
        case .failure(.cancelled):
            break
        }
    }
}
