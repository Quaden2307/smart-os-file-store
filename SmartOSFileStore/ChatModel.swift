import FileStoreIntelligence
import Foundation
import Observation
import os

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

    private var engine: ChatEngine?
    private weak var files: FileListModel?
    private var task: Task<Void, Never>?
    private let logger = Logger(subsystem: "com.quaden2307.SmartOSFileStore", category: "Chat")

    // Isolated, so it may touch main-actor state: a reply still arriving stops with the model.
    isolated deinit {
        task?.cancel()
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

    /// Gives the chat its only view of the folder: a copy of the list's rows, made when a lookup asks.
    func connect(files: FileListModel, activity: ActivityLogModel) {
        guard engine == nil else { return }
        self.files = files
        engine = ChatEngine { [weak files, weak activity] in
            await MainActor.run {
                guard let files, let activity else { return FolderSnapshot(files: []) }
                return FolderSnapshot(files: files, activity: activity)
            }
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
        // Weak throughout: the task must not keep the model alive, and deinit cancels the task.
        task = Task { [weak self] in
            let turn = await engine.respond(to: question) { [weak self] text in
                Task { @MainActor [weak self] in self?.show(text, in: replyID) }
            }
            self?.finish(replyID, with: turn)
        }
    }

    /// Stop: the reply ends with what had arrived.
    func stop() {
        task?.cancel()
    }

    private func show(_ text: String, in id: ChatMessage.ID) {
        // Each update crosses to the main actor on its own, so two can arrive out of order, and one
        // can arrive after the reply ended. The reply only ever grows: an older text is shorter.
        guard let index = messages.firstIndex(where: { $0.id == id }), messages[index].turn == nil,
              text.count >= messages[index].text.count else { return }
        messages[index].text = text
    }

    private func finish(_ id: ChatMessage.ID, with turn: Turn) {
        isResponding = false
        task = nil
        logger.info("Reply ended: \(String(describing: turn.outcome), privacy: .public)")
        guard let index = messages.firstIndex(where: { $0.id == id }) else { return }
        messages[index].text = turn.text
        messages[index].turn = turn
    }
}
