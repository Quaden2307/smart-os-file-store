import Foundation
import os

/// What Tidy Now reports while it plans, from planning threads.
public enum TidyNowPlanningEvent: Sendable, Hashable {
    /// How far `action` has got. Only an action that reads files reports any.
    case progress(CleanupAction, CleanupPlanningProgress)
    /// `action` has finished, with a plan or without one (`failed`).
    case finished(CleanupAction, failed: Bool)
}

/// Runs every action's planner over one scan, together, and resolves the overlap between their
/// plans (`TidyNowPlan.resolve`). Writes nothing, like every planner.
///
/// The planners that read whole files run one after another, Find Duplicates first, sharing one
/// content-hash cache, so no file is read twice; they run alongside the others. One planner failing
/// is reported in its outcome and stops none of the rest; cancelling the task stops them all.
public struct TidyNowPlanner: Sendable {
    /// One action's planner: `CleanupPlanners.plan` with this planner's inputs. Tests replace it to
    /// make one action fail.
    public typealias PlanAction = @Sendable (
        _ action: CleanupAction,
        _ hashCache: ContentHashCache,
        _ onProgress: @escaping @Sendable (CleanupPlanningProgress) -> Void
    ) async throws -> CleanupPlan?

    /// The actions whose planners read whole files, in the order they run: Find Duplicates first,
    /// whose hashes the others then read from the cache.
    static let hashingChain: [CleanupAction] = [.findDuplicates, .reviewNearDuplicates, .fixMessyNames, .archiveOldDownloads]

    public let folderURL: URL
    /// The time the plans are judged at, the same the planners are given.
    public let now: Date
    public let eligibility: CandidateEligibility
    public let keptItems: KeptItems
    private let planAction: PlanAction
    private static let logger = Logger(subsystem: "com.quaden2307.FileStoreCore", category: "TidyNow")

    /// - Parameters: as for `CleanupPlanners.plan`, which plans each action.
    public init(
        eligibility: CandidateEligibility,
        keptItems: KeptItems,
        installers: InstallerSources,
        settings: CleanupSettings = CleanupSettings(),
        records: [FileRecord],
        folderURL: URL,
        now: Date = .now
    ) {
        self.init(folderURL: folderURL, now: now, eligibility: eligibility, keptItems: keptItems) { action, hashCache, onProgress throws(CleanupPlanningError) in
            try await CleanupPlanners.plan(
                action,
                records: records,
                in: folderURL,
                eligibility: eligibility,
                keptItems: keptItems,
                installers: installers,
                now: now,
                settings: settings,
                hashCache: hashCache,
                onProgress: onProgress
            )
        }
    }

    /// A planner with its own way of planning each action, for tests.
    public init(folderURL: URL, now: Date, eligibility: CandidateEligibility, keptItems: KeptItems, planAction: @escaping PlanAction) {
        self.folderURL = folderURL
        self.now = now
        self.eligibility = eligibility
        self.keptItems = keptItems
        self.planAction = planAction
    }

    /// Plans every action that has a planner, and resolves the overlap.
    ///
    /// - Parameters:
    ///   - hashCache: Content hashes read earlier in this session; the hashing planners add to it.
    /// - Throws: `.cancelled` when the task is cancelled. A planner failing throws nothing: its
    ///   outcome says so.
    @concurrent
    public func plan(
        hashCache: ContentHashCache = ContentHashCache(),
        onEvent: (@Sendable (TidyNowPlanningEvent) -> Void)? = nil
    ) async throws(CleanupPlanningError) -> TidyNowPlan {
        let actions = TidyNowPlan.order.filter(CleanupPlanners.hasPlanner)
        let chain = Self.hashingChain.filter(actions.contains)
        let planAction = planAction
        let outcomes = await withTaskGroup(of: [(CleanupAction, CleanupPlan?)].self) { group in
            // One task runs the hashing chain in order; each other planner has its own.
            group.addTask {
                var planned: [(CleanupAction, CleanupPlan?)] = []
                for action in chain {
                    planned.append((action, await Self.run(action, planAction, hashCache, onEvent)))
                }
                return planned
            }
            for action in actions where !chain.contains(action) {
                group.addTask { [(action, await Self.run(action, planAction, hashCache, onEvent))] }
            }
            var all: [CleanupAction: CleanupPlan?] = [:]
            for await planned in group {
                for (action, plan) in planned {
                    all[action] = plan
                }
            }
            return all
        }
        let folderURL = folderURL
        let now = now
        if Task.isCancelled {
            throw .cancelled
        }
        let plans = outcomes.values.compactMap(\.self)
        let resolved = TidyNowPlan.resolve(plans, eligibility: eligibility.keeping(keptItems), now: now)
        return TidyNowPlan(
            folderURL: folderURL,
            outcomes: actions.map { action in
                guard let plan = resolved.first(where: { $0.action == action }) else {
                    return (action, .failed)
                }
                return (action, .planned(plan))
            }
        )
    }

    /// One action's plan, or nil when its planner threw or had none.
    private static func run(
        _ action: CleanupAction,
        _ planAction: PlanAction,
        _ hashCache: ContentHashCache,
        _ onEvent: (@Sendable (TidyNowPlanningEvent) -> Void)?
    ) async -> CleanupPlan? {
        guard !Task.isCancelled else { return nil }
        let plan: CleanupPlan?
        do {
            plan = try await planAction(action, hashCache) { progress in onEvent?(.progress(action, progress)) }
        } catch {
            if !Task.isCancelled {
                logger.error("Tidy Now could not plan \(action.definition.identifier, privacy: .public): \(String(describing: error), privacy: .private)")
            }
            plan = nil
        }
        // A plan of another action would be resolved under the wrong rules.
        let checked = plan?.action == action ? plan : nil
        onEvent?(.finished(action, failed: checked == nil))
        return checked
    }
}
