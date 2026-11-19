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

/// The chat bar's state: the conversation so far, the text being typed and the reply in progress.
/// The conversation lives here, in memory, until the app quits; nothing typed is logged or stored.
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
    /// The number of the newest update shown of the reply arriving now.
    private var shownUpdate = 0
    private let logger = Logger(subsystem: "com.quaden2307.SmartOSFileStore", category: "Chat")

    // Isolated, so it may touch main-actor state: a reply still arriving stops with the model.
    isolated deinit {
        task?.cancel()
        duplicateScan?.cancel()
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
            // What "big" means in a follow-up: the size Review Large Downloads lists from.
            largeFileMegabytes: { CleanupSettings.load(from: UserDefaults.standard).largeDownloadMegabytes }
        )
    }

    /// Find Duplicates as the Clean Up menu runs it (the same rules, with the Kept list read first),
    /// for a question in the chat. It reads files and changes none. Nil when it cannot run: the
    /// window is gone, the log is not open, or the turn ended.
    private func findDuplicates(hashCache: ContentHashCache) async -> DuplicateScan? {
        guard let files, let folderURL = files.location?.folderURL, let log = activity?.log else { return nil }
        let records = files.records
        let eligibility = files.eligibility
        let installers = InstallerSources.standard(applicationFolders: files.applicationFolders, cache: log)
        let logger = logger
        // As the Clean Up menu's searches do: hashes of files no longer listed are forgotten.
        hashCache.keepOnly(records)
        duplicateScan?.cancel()
        let scan = Task {
            do {
                let keptItems = try await log.keptItems(forFolder: folderURL)
                return try await CleanupPlanners.plan(
                    .findDuplicates, records: records, in: folderURL, eligibility: eligibility, keptItems: keptItems,
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
        let recent = records.filter { $0.kind == .file && eligibility.refusal(for: $0, now: now) == .insideGracePeriod }.count
        return DuplicateScan(plan, files: files, recentCount: recent)
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
        logger.info("Reply ended: \(String(describing: turn.outcome), privacy: .public)")
        guard let index = messages.firstIndex(where: { $0.id == id }) else { return }
        messages[index].text = turn.text
        messages[index].turn = turn
    }
}
