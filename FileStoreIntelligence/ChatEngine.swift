import Foundation
import FoundationModels
import Synchronization
import os

/// How a turn ended. The app puts each case into one plain sentence.
public enum TurnOutcome: Sendable, Equatable {
    case answered
    case stopped
    case timedOut
    case toolLimitReached
    /// The model or Apple's content filter declined.
    case refused
    /// The conversation outgrew the model's memory. The next turn starts a fresh one.
    case contextFull
    case unavailable(IntelligenceAvailability)
    /// Anything else. The next turn starts a fresh conversation too.
    case failed
}

/// One question and what came of it.
public struct Turn: Sendable {
    /// The reply as far as it got: complete for `.answered`, partial after Stop or the time limit.
    public var text: String
    public var outcome: TurnOutcome
    public var effects: TurnEffects
}

/// One chat conversation with the on-device model. It can look things up through two read-only
/// tools and nothing else: this module imports no code that changes files (docs/decisions/0020).
/// The conversation lives in memory only, and nothing the user types is logged.
public actor ChatEngine {
    public static let toolCallLimit = 4
    public static let turnLimit: Duration = .seconds(30)

    private static let logger = Logger(subsystem: "com.quaden2307.FileStoreIntelligence", category: "ChatEngine")

    private struct Conversation {
        let session: LanguageModelSession
        let recorder: TurnRecorder
        /// The day its instructions call today.
        let day: String
    }

    private let model: any LanguageModel
    private let snapshot: @Sendable () async -> FolderSnapshot
    private let availability: @Sendable () -> IntelligenceAvailability
    private let turnLimit: Duration
    private let now: @Sendable () -> Date
    private var conversation: Conversation?

    /// The engine the app uses: the on-device system model, and never any other.
    public init(snapshot: @escaping @Sendable () async -> FolderSnapshot) {
        self.init(
            model: SystemLanguageModel.default,
            snapshot: snapshot,
            availability: {
                // Unset counts as on, as in Settings.
                let enabled = UserDefaults.standard.object(forKey: IntelligenceAvailability.enabledKey) as? Bool ?? true
                return .current(enabledInSettings: enabled)
            }
        )
    }

    /// For tests and measurements: any model, a short time limit, a clock.
    public init(
        model: some LanguageModel,
        snapshot: @escaping @Sendable () async -> FolderSnapshot,
        availability: @escaping @Sendable () -> IntelligenceAvailability = { .available },
        turnLimit: Duration = ChatEngine.turnLimit,
        now: @escaping @Sendable () -> Date = { .now }
    ) {
        self.model = model
        self.snapshot = snapshot
        self.availability = availability
        self.turnLimit = turnLimit
        self.now = now
    }

    /// Loads the model ahead of the first question. Called when the chat bar gets focus.
    public func prewarm() {
        guard availability() == .available else { return }
        currentConversation().session.prewarm()
    }

    /// Asks one question. `onText` gets the reply so far each time it grows, on no particular
    /// actor. Cancelling the calling task is Stop: the turn ends as `.stopped` with what had arrived.
    public func respond(to text: String, onText: @escaping @Sendable (String) -> Void) async -> Turn {
        let available = availability()
        guard available == .available else {
            return Turn(text: "", outcome: .unavailable(available), effects: TurnEffects())
        }
        let conversation = currentConversation()
        let session = conversation.session
        conversation.recorder.begin()
        let history = Array(session.transcript)
        let started = ContinuousClock.now
        let reply = Mutex("")

        enum Ending {
            case finished
            case threw(any Error)
            case outOfTime
            case cancelled
        }
        let limit = turnLimit
        let ending = await withTaskGroup(of: Ending.self) { group in
            group.addTask {
                do {
                    for try await snapshot in session.streamResponse(to: text) {
                        // The model often copies the data marks around a name into its sentence.
                        // They mean something to it and nothing to the user.
                        let content = snapshot.content.filter { $0 != PromptLibrary.dataOpen && $0 != PromptLibrary.dataClose }
                        reply.withLock { $0 = content }
                        onText(content)
                    }
                    // A cancelled stream ends without an error (measured: docs/decisions/0020).
                    return Task.isCancelled ? .cancelled : .finished
                } catch {
                    return .threw(error)
                }
            }
            group.addTask {
                do {
                    try await Task.sleep(for: limit)
                    return .outOfTime
                } catch {
                    return .cancelled
                }
            }
            let first = await group.next() ?? .cancelled
            group.cancelAll()
            return first
        }

        // A reply that finished is an answer even when Stop lands a moment later: calling it
        // stopped would also make the model forget an answer the user can read.
        let outcome: TurnOutcome = switch ending {
        case .finished: .answered
        case .cancelled: .stopped
        case .outOfTime: Task.isCancelled ? .stopped : .timedOut
        case .threw(let error): Task.isCancelled ? .stopped : self.outcome(for: error)
        }
        switch outcome {
        case .answered, .toolLimitReached, .refused, .unavailable:
            // The session put its transcript back as it was before a turn that threw.
            break
        case .contextFull, .failed:
            // A full context fails every later turn too, and an error nobody recognised may be one
            // under another name: either way the next question starts a fresh conversation.
            self.conversation = nil
        case .stopped, .timedOut:
            // The abandoned reply may still be running behind the session and calling tools, which
            // would spend the next turn's budget and confuse its answer (seen with the real model).
            // A new session made from the history before this turn remembers the same conversation
            // and shares nothing with the old one.
            self.conversation = makeConversation(history: history)
        }
        let elapsed = ContinuousClock.now - started
        Self.logger.info("""
            Turn ended: \(String(describing: outcome), privacy: .public), \
            \(conversation.recorder.effects.results.count) tool results, \(elapsed.formatted(), privacy: .public)
            """)
        return Turn(text: reply.withLock { $0 }, outcome: outcome, effects: conversation.recorder.effects)
    }

    /// What the on-device model must read before any question, in tokens: the instructions and the
    /// tool definitions. Together they should stay under a quarter of `contextSize`; the numbers are
    /// recorded in docs/decisions/0020 and measured again whenever a template or a tool changes.
    public static func fixedPromptTokens() async throws -> (instructions: Int, tools: Int, contextSize: Int) {
        let model = SystemLanguageModel.default
        let tools = tools(ToolContext(snapshot: { FolderSnapshot(files: []) }, recorder: TurnRecorder()))
        return (
            try await model.tokenCount(for: Instructions(PromptLibrary.chatInstructions(today: .now))),
            try await model.tokenCount(for: tools),
            model.contextSize
        )
    }

    /// The conversation to ask in. On a new day it moves to a session whose instructions name
    /// that day, with the same history: an app left open overnight must not tell the model that
    /// today is yesterday.
    private func currentConversation() -> Conversation {
        if let conversation, conversation.day == DayText.string(from: now()) { return conversation }
        let made = makeConversation(history: conversation.map { Array($0.session.transcript) } ?? [])
        conversation = made
        return made
    }

    private func makeConversation(history: [Transcript.Entry]) -> Conversation {
        Self.makeConversation(model: model, snapshot: snapshot, history: history, today: now())
    }

    /// Every tool the model may call. All of them only read the snapshot.
    private static func tools(_ context: ToolContext) -> [any Tool] {
        [SearchFilesTool(context: context), FolderSummaryTool(context: context)]
    }

    /// Static, so the tool-call hook does not inherit the engine's isolation and wait for it.
    private static func makeConversation(
        model: any LanguageModel, snapshot: @escaping @Sendable () async -> FolderSnapshot, history: [Transcript.Entry],
        today: Date
    ) -> Conversation {
        // The new session brings its own instructions; the old ones are not part of what was said.
        let history = history.filter { entry in
            if case .instructions = entry { false } else { true }
        }
        let recorder = TurnRecorder()
        let tools = tools(ToolContext(snapshot: snapshot, recorder: recorder))
        let registered = Set(tools.map(\.name))
        let instructions = PromptLibrary.chatInstructions(today: today)
        let profile = LanguageModelSession.Profile {
            Instructions(instructions)
            tools
        }
        .model(model)
        .samplingMode(.greedy)
        .transcriptErrorHandlingPolicy(.revertTranscript)
        // Runs before each tool; a throw stops that tool and ends the turn (measured: 0020).
        .onToolCall { call in
            try recorder.admit(call.toolName, registered: registered, limit: toolCallLimit)
        }
        return Conversation(
            session: LanguageModelSession(profile: profile, history: history), recorder: recorder,
            day: DayText.string(from: today)
        )
    }

    private func outcome(for error: any Error) -> TurnOutcome {
        let outcome = Self.outcome(for: error)
        // Only the kind of error and its number are logged: its text could quote the question or a file name.
        let code = (error as NSError).code
        Self.logger.notice("Turn threw \(String(reflecting: type(of: error)), privacy: .public) (\(code)): \(String(describing: outcome), privacy: .public)")
        // Whatever the error says, a model that has gone away is the reason worth showing.
        let available = availability()
        return available == .available ? outcome : .unavailable(available)
    }

    private static func outcome(for error: any Error) -> TurnOutcome {
        // In the tool loop, macOS 27.2 lets the model's own "too many tokens" error through where a
        // plain session throws `contextSizeExceeded`. The type is private, so it is known by its
        // domain and code (measured: docs/decisions/0020).
        let bridged = error as NSError
        if bridged.domain == "com.apple.GenerativeFunctionsFoundation.GenerativeError", bridged.code == 4_050_000 {
            return .contextFull
        }
        switch error {
        case let error as LanguageModelSession.ToolCallError:
            return error.underlyingError as? ToolRefusal == .overLimit ? .toolLimitReached : .failed
        case let error as LanguageModelError:
            return switch error {
            case .contextSizeExceeded: .contextFull
            case .guardrailViolation, .refusal: .refused
            case .unsupportedLanguageOrLocale: .unavailable(.languageNotSupported)
            case .timeout: .timedOut
            default: .failed
            }
        case is SystemLanguageModel.Error:
            // Its one case: the model's files are not on the Mac (any more).
            return .unavailable(.modelDownloading)
        default:
            // Includes a call to a tool that does not exist, which the session refuses by itself.
            return .failed
        }
    }
}
