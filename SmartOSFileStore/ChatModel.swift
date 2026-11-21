import FileStoreCore
import FileStoreIntelligence
import Foundation
import Observation
import os
import Synchronization

/// One line of the conversation: what the user asked, or the reply to it.
struct ChatMessage: Identifiable {
    enum Role {
        case question
        case reply
    }

    let id = UUID()
    let role: Role
    var text: String
    /// How a reply ended and what its lookups found. Nil for a question, and while a reply is arriving.
    var turn: Turn?
}

extension Turn {
    /// The cleanup card the reply shows, if its turn planned one and ended with its card on screen.
    var cleanupCard: CleanupProposal? {
        // Also after a reply that ran out of lookups or of time: the plan was made and is the
        // app's, whatever the model went on to do.
        guard [.answered, .stopped, .toolLimitReached, .timedOut].contains(outcome) else { return nil }
        return effects.results.lazy.compactMap { if case .cleanup(let proposal) = $0 { proposal } else { nil } }.last
    }
}

/// The chat bar's state: the conversation so far, the text being typed and the reply in progress.
/// The conversation lives here, in memory, until the app quits; nothing typed is logged or stored.
///
/// It also holds the plans of the conversation's cleanup cards. The chat module only ever gets
/// rows about a plan; the plan, and the executor that could carry it out, stay on this side, and
/// run from the user's Confirm alone (docs/decisions/0023).
@MainActor
@Observable
final class ChatModel {
    private(set) var messages: [ChatMessage] = []
    var draft = ""
    private(set) var isResponding = false

    /// True while the conversation is shown above the bar.
    var isPanelOpen = false

    /// The most of the window's height the conversation may take, set by the window as it is
    /// resized. Kept here and not in the window's state, so a resize redraws the chat only.
    var panelRoom: CGFloat = 0

    private var engine: ChatEngine?
    private weak var files: FileListModel?
    private weak var activity: ActivityLogModel?
    private var task: Task<Void, Never>?
    /// Find Duplicates as a question started it. It stops when the turn ends: a reply that was
    /// stopped or ran out of time must not go on reading files.
    private var duplicateScan: Task<CleanupPlan?, Never>?
    /// The content hashes the Clean Up menu's searches share, which a card's Refresh reads too.
    private var hashCache: ContentHashCache?
    /// Each cleanup card's plan, by the card's id: the model the Tidy Now preview works from, in
    /// review of the plan the chat asked for.
    private(set) var cleanups: [CleanupProposal.ID: TidyNowModel] = [:]
    /// Which cards may still be confirmed.
    private(set) var cards = CleanupCards()
    /// The cards being planned again by Refresh.
    private(set) var refreshing: Set<CleanupProposal.ID> = []
    /// The planning the turn's cleanup requests started. It stops when the turn ends.
    private var turnPlanning: [Task<TidyNowPlan?, Never>] = []
    /// The number of the newest update shown of the reply arriving now.
    private var shownUpdate = 0
    private let logger = Logger(subsystem: "com.quaden2307.SmartOSFileStore", category: "Chat")

    // Isolated, so it may touch main-actor state: a reply still arriving stops with the model.
    isolated deinit {
        task?.cancel()
        duplicateScan?.cancel()
        turnPlanning.forEach { $0.cancel() }
    }

    /// True while a question can be asked: no reply is arriving, and the list is settled. A lookup
    /// made while the folder is still being read, or after it could not be read, would count an
    /// empty list and show that as fact.
    var canAsk: Bool {
        !isResponding && files?.isSettled == true
    }

    var canSend: Bool {
        canAsk && !draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    /// Gives the chat its only view of the folder: a copy of the list's rows, made when a lookup
    /// asks, and Find Duplicates, run when a question is about copies. `hashCache` is the one the
    /// Clean Up menu's searches share.
    func connect(files: FileListModel, activity: ActivityLogModel, hashCache: ContentHashCache) {
        guard engine == nil else { return }
        self.files = files
        self.activity = activity
        self.hashCache = hashCache
        engine = ChatEngine(
            snapshot: { [weak files, weak activity] in
                await MainActor.run {
                    guard let files, let activity else { return FolderSnapshot(files: []) }
                    return FolderSnapshot(files: files, activity: activity)
                }
            },
            findDuplicates: { [weak self] in
                await self?.findDuplicates(hashCache: hashCache)
            },
            // From the action registry: an action added there is offered here with no other change.
            cleanupActions: CleanupAction.allCases.filter(CleanupPlanners.hasPlanner).map(\.definition.identifier),
            proposeCleanup: { [weak self] request, ids in
                await self?.proposeCleanup(request, only: ids, hashCache: hashCache)
            },
            // What "big" means in a follow-up: the size Review Large Downloads lists from.
            largeFileMegabytes: { CleanupSettings.load(from: UserDefaults.standard).largeDownloadMegabytes }
        )
    }

    /// Find Duplicates as the Clean Up menu runs it (the same rules, with the Kept list read first),
    /// for a question in the chat. It reads files and changes none. Nil when it cannot run: the
    /// window is gone, the log is not open, or the turn ended.
    private func findDuplicates(hashCache: ContentHashCache) async -> DuplicateScan? {
        guard let files, let log = activity?.log, let folder = activity?.downloads else { return nil }
        let records = files.records
        let eligibility = files.eligibility
        let installers = InstallerSources.standard(applicationFolders: files.applicationFolders, cache: log)
        let logger = logger
        // As the Clean Up menu's searches do: hashes of files no longer listed are forgotten.
        hashCache.keepOnly(records, in: folder)
        duplicateScan?.cancel()
        let scan = Task {
            do {
                let keptItems = try await log.keptItems(for: folder)
                return try await CleanupPlanners.plan(
                    .findDuplicates, records: records, in: folder, eligibility: eligibility, keptItems: keptItems,
                    installers: installers, hashCache: hashCache
                )
            } catch {
                // The kind of error only: its text could hold a path.
                logger.notice("Find Duplicates for the chat did not finish: \(String(reflecting: type(of: error)), privacy: .public)")
                return nil
            }
        }
        duplicateScan = scan
        guard let plan = await withTaskCancellationHandler(operation: { await scan.value }, onCancel: { scan.cancel() }) else {
            return nil
        }
        let now = Date.now
        let recent = records.filter { $0.kind == .file && eligibility.refusal(for: $0, in: folder, now: now) == .insideGracePeriod }.count
        return DuplicateScan(plan, files: files, recentCount: recent)
    }

    // MARK: - Cleanup cards

    /// Plans the cleanups a request names with the app's own planners, narrowed to `ids`, as Tidy
    /// Now plans them (the Kept list read first, the same rules for overlap). Reads files and
    /// changes none. Nil when it cannot run: the window is gone, the log is not open, the turn
    /// ended, or no action could be planned. Planning `inTurn` stops when the turn ends; a Refresh
    /// goes on, whatever is asked meanwhile.
    private func plan(
        _ request: CleanupRequest, only ids: Set<URL>?, hashCache: ContentHashCache, inTurn: Bool
    ) async -> TidyNowPlan? {
        guard let files, let log = activity?.log, let folder = activity?.downloads else { return nil }
        let actions = CleanupAction.allCases.filter { request.actions.contains($0.definition.identifier) }
        let records = files.records
        let eligibility = files.eligibility
        let installers = InstallerSources.standard(applicationFolders: files.applicationFolders, cache: log)
        let stored = CleanupSettings.load(from: UserDefaults.standard)
        // The request's own numbers stand in for the settings, for this plan only.
        let settings = CleanupSettings(
            unusedAfterDays: request.archiveAfterDays ?? stored.unusedAfterDays,
            oldAfterDays: stored.oldAfterDays,
            largeDownloadMegabytes: request.largeFileMB ?? stored.largeDownloadMegabytes
        )
        let logger = logger
        hashCache.keepOnly(records, in: folder)
        let planning = Task { () -> TidyNowPlan? in
            do {
                let keptItems = try await log.keptItems(for: folder)
                let planner = TidyNowPlanner(
                    actions: actions, eligibility: eligibility, keptItems: keptItems, installers: installers,
                    settings: settings, records: records, folder: folder
                )
                let plan = try await planner.plan(only: ids, hashCache: hashCache)
                // As Tidy Now does: what was read from installers is kept, so the next search
                // reads none of them again.
                let read = plan.plans.flatMap(\.installerFactsRead)
                if !read.isEmpty {
                    do throws(ActivityLogError) {
                        try await log.storeInstallerFacts(read)
                    } catch {
                        logger.error("What was read from installers could not be kept: \(String(describing: error), privacy: .public)")
                    }
                }
                return plan
            } catch {
                // The kind of error only: its text could hold a path.
                logger.notice("A cleanup for the chat was not planned: \(String(reflecting: type(of: error)), privacy: .public)")
                return nil
            }
        }
        if inTurn {
            turnPlanning.append(planning)
        }
        let plan = await withTaskCancellationHandler(operation: { await planning.value }, onCancel: { planning.cancel() })
        files.reloadInstalledMarks()
        // No plan when nothing was found and an action could not be checked: "nothing to clean
        // up" would then be a guess. With something found, the card says which action failed.
        guard let plan, plan.plans.contains(where: { !$0.isEmpty }) || !plan.outcomes.contains(where: { $0.outcome == .failed }) else {
            return nil
        }
        return plan
    }

    /// The card's model for `plan`, kept under `id`. Its run is the chat's in the activity log.
    private func keep(_ plan: TidyNowPlan, as id: CleanupProposal.ID) {
        guard let files, let activity, let log = activity.log else { return }
        cleanups[id] = TidyNowModel(
            showing: plan,
            origin: .chat,
            eligibility: files.eligibility,
            applicationFolders: files.applicationFolders,
            log: log,
            activity: activity,
            onExecuted: { [weak self, weak files] in
                self?.cards.executed(id)
                // Files moved, so the rows on screen are stale.
                files?.refresh()
            }
        )
    }

    /// `proposeCleanup` as the chat's tool reaches it: plans, keeps the plan for the card, and
    /// hands back rows. A plan with nothing in it is handed back with no rows and kept nowhere.
    private func proposeCleanup(_ request: CleanupRequest, only ids: Set<URL>?, hashCache: ContentHashCache) async -> CleanupProposal? {
        guard let plan = await plan(request, only: ids, hashCache: hashCache, inTurn: true) else { return nil }
        let found = plan.plans.filter { !$0.isEmpty }
        let proposal = CleanupProposal(
            request: request,
            rows: found.map { plan in
                CleanupProposal.Row(
                    action: plan.action.definition.identifier, count: plan.changes.count, bytes: plan.bytesToFree,
                    tickedCount: plan.changes.count { $0.reason.isTickedByCode }
                )
            },
            sampleNames: found.flatMap(\.changes).prefix(CleanupProposal.sampleNamesShown).map(\.record.displayName)
        )
        if !found.isEmpty {
            keep(plan, as: proposal.id)
        }
        return proposal
    }

    /// True while a card's cleanup is being carried out. Nothing else that moves files may start.
    var isCleaningUp: Bool {
        cleanups.values.contains(where: \.isExecuting)
    }

    /// True while a card waits for Confirm, so the folder is worth reading again when the window
    /// comes back from another app.
    var hasWaitingCard: Bool {
        cards.current.map(cards.canConfirm) ?? false
    }

    /// Puts out of date every waiting card with a file that is no longer as it was planned, judged
    /// against the list as just read, or that the user has marked Keep since. The executor checks
    /// each file again whatever this finds.
    func checkCards() {
        guard let files, files.isSettled else { return }
        let kept = files.keptItems
        for (id, model) in cleanups where cards.state(of: id) == .ready && model.isReviewing {
            let isStale = model.plans.values.contains { plan in
                !plan.staleChangeIDs(in: files.records).isEmpty || plan.changes.contains { kept.contains($0.record) }
            }
            if isStale {
                cards.filesChanged(id)
            }
        }
    }

    /// The card's model while it may be reviewed and confirmed: the current card, its files as
    /// planned, and no reply arriving that could put another card in its place meanwhile.
    func confirmable(_ id: CleanupProposal.ID) -> TidyNowModel? {
        checkCards()
        guard cards.canConfirm(id), canAsk else { return nil }
        cleanups[id]?.leavePreview()
        return cleanups[id]
    }

    /// True while Refresh may plan an out-of-date card again.
    func canRefresh(_ id: CleanupProposal.ID) -> Bool {
        cards.canRefresh(id) && canAsk && !refreshing.contains(id) && !isCleaningUp
    }

    /// Refresh: the same request planned again over the list as it is now, with no question to the
    /// model. The card then shows the new plan, and is the current card.
    func refresh(_ proposal: CleanupProposal) {
        let id = proposal.id
        guard canRefresh(id), let files, let activity, let hashCache else { return }
        refreshing.insert(id)
        Task { [weak self] in
            let ids = proposal.request.fileIDs(in: FolderSnapshot(files: files, activity: activity))
            let plan = await self?.plan(proposal.request, only: ids, hashCache: hashCache, inTurn: false)
            guard let self else { return }
            refreshing.remove(id)
            // Not planned (the log went away, or a question took over): the card stays out of date.
            guard let plan, cards.canRefresh(id) else { return }
            keep(plan, as: id)
            cards.show(id)
        }
    }

    /// Loads the model while the user is still typing.
    func prewarm() {
        guard let engine else { return }
        Task { await engine.prewarm() }
    }

    func send() {
        guard canSend else { return }
        let question = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        draft = ""
        ask(question)
    }

    func ask(_ question: String) {
        guard canAsk, let engine else { return }
        let reply = ChatMessage(role: .reply, text: "")
        let replyID = reply.id
        messages.append(ChatMessage(role: .question, text: question))
        messages.append(reply)
        isResponding = true
        isPanelOpen = true
        shownUpdate = 0
        // Numbered as the engine hands them over: each crosses to the main actor on its own, so two
        // can arrive out of order.
        let updates = Mutex(0)
        // Weak throughout: the task must not keep the model alive, and deinit cancels the task.
        task = Task { [weak self] in
            let turn = await engine.respond(to: question) { [weak self] text in
                let number = updates.withLock { count in
                    count += 1
                    return count
                }
                Task { @MainActor [weak self] in self?.show(text, number: number, in: replyID) }
            }
            self?.finish(replyID, with: turn)
        }
    }

    /// Stop: the reply ends with what had arrived.
    func stop() {
        task?.cancel()
    }

    private func show(_ text: String, number: Int, in id: ChatMessage.ID) {
        // An older update, or one that arrives after the reply ended, changes nothing. A newer one
        // may be shorter: the text starts again when the question is asked in a fresh conversation.
        guard number > shownUpdate, let index = messages.firstIndex(where: { $0.id == id }), messages[index].turn == nil else { return }
        shownUpdate = number
        messages[index].text = text
    }

    private func finish(_ id: ChatMessage.ID, with turn: Turn) {
        isResponding = false
        task = nil
        duplicateScan?.cancel()
        duplicateScan = nil
        turnPlanning.forEach { $0.cancel() }
        turnPlanning = []
        logger.info("Reply ended: \(String(describing: turn.outcome), privacy: .public)")
        guard let index = messages.firstIndex(where: { $0.id == id }) else { return }
        messages[index].text = turn.text
        messages[index].turn = turn
        if let card = turn.cleanupCard {
            cards.show(card.id)
        }
        // A plan whose card never came on screen (the turn failed, or planned twice) is dropped.
        let shown = Set(messages.compactMap { $0.turn?.cleanupCard?.id })
        cleanups = cleanups.filter { shown.contains($0.key) }
    }
}
