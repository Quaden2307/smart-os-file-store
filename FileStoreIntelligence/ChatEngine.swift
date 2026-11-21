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
    /// True when the first try overflowed or failed, so the question was asked again in a fresh
    /// conversation that remembers only the last two questions.
    public var startedOver = false
    /// What the model was shown before it began, in tokens: instructions, tools, the earlier turns
    /// it was shown, the app's note and the question. Counted with the longest note the turn could
    /// have carried, so it is at most this many. Nil when not counted.
    public var tokensBeforeReply: Int?
}

/// How the engine measures what the model will read, to keep a conversation inside its context.
public struct ContextMeter: Sendable {
    public let contextSize: Int
    /// The tokens in a transcript's entries. The instructions entry counts its tool definitions too.
    public let count: @Sendable ([Transcript.Entry]) async throws -> Int

    public init(contextSize: Int, count: @escaping @Sendable ([Transcript.Entry]) async throws -> Int) {
        self.contextSize = contextSize
        self.count = count
    }

    /// The on-device model's own count.
    public static let system = ContextMeter(contextSize: SystemLanguageModel.default.contextSize) { entries in
        try await SystemLanguageModel.default.tokenCount(for: entries)
    }
}

/// One chat conversation with the on-device model. It can look things up through three read-only
/// tools and ask the app to plan a cleanup through a fourth, and nothing else: this module imports
/// no code that changes files (docs/decisions/0020, 0023).
/// The conversation lives in memory only, and nothing the user types is logged.
public actor ChatEngine {
    public static let toolCallLimit = 4
    public static let turnLimit: Duration = .seconds(30)
    /// The share of the context that the instructions, the tools, the earlier turns and the question
    /// may take before a turn starts. The rest is for the turn's lookups and reply: four lookups at
    /// the output cap and a reply come to about a third of 4,096 tokens (docs/decisions/0021).
    public static let historyShare = 0.6
    /// The most of the context the instructions and the tool definitions may take, which the model
    /// reads again in every turn (docs/decisions/0023; a quarter before `proposeCleanup`).
    public static let fixedPromptShare = 0.42
    /// The earlier turns a fresh conversation keeps when the old one is too full to go on.
    static let turnsKeptOnStartingOver = 2

    private static let logger = Logger(subsystem: "com.quaden2307.FileStoreIntelligence", category: "ChatEngine")

    private struct Conversation {
        let session: LanguageModelSession
        let recorder: TurnRecorder
        /// The day its instructions call today.
        let day: String
    }

    private let model: any LanguageModel
    private let tools: Tools
    private let availability: @Sendable () -> IntelligenceAvailability
    private let turnLimit: Duration
    private let now: @Sendable () -> Date
    /// Nil shows the model every earlier turn (still cut short): for tests that are not about length.
    private let meter: ContextMeter?
    private var conversation: Conversation?
    /// What is remembered whatever becomes of the session (docs/decisions/0022).
    private var memory = ChatMemory()

    /// What the app hands the tools: its view of the folder, a way to run Find Duplicates, and
    /// its cleanup actions with a way to plan them.
    private struct Tools {
        let snapshot: @Sendable () async -> FolderSnapshot
        let findDuplicates: @Sendable (FolderScope) async -> DuplicateScan?
        let cleanupActions: [String]
        let proposeCleanup: ProposeCleanup

        func context(_ recorder: TurnRecorder) -> ToolContext {
            ToolContext(
                snapshot: snapshot, findDuplicates: findDuplicates, cleanupActions: cleanupActions,
                proposeCleanup: proposeCleanup, recorder: recorder
            )
        }
    }

    /// The size from which the app calls a file large: what "big" means in a follow-up, so the
    /// number is the app's and not the model's.
    private let largeFileMegabytes: @Sendable () -> Int

    /// The engine the app uses: the on-device system model, and never any other.
    ///
    /// - Parameters:
    ///   - cleanupActions: The names of the app's cleanup actions, which `proposeCleanup` offers.
    ///   - proposeCleanup: Plans a cleanup in the app, which keeps the plan.
    public init(
        snapshot: @escaping @Sendable () async -> FolderSnapshot,
        findDuplicates: @escaping @Sendable (FolderScope) async -> DuplicateScan?,
        cleanupActions: [String],
        proposeCleanup: @escaping ProposeCleanup,
        largeFileMegabytes: @escaping @Sendable () -> Int
    ) {
        self.init(
            model: SystemLanguageModel.default,
            snapshot: snapshot,
            findDuplicates: findDuplicates,
            cleanupActions: cleanupActions,
            proposeCleanup: proposeCleanup,
            largeFileMegabytes: largeFileMegabytes,
            availability: {
                // Unset counts as on, as in Settings.
                let enabled = UserDefaults.standard.object(forKey: IntelligenceAvailability.enabledKey) as? Bool ?? true
                return .current(enabledInSettings: enabled)
            },
            meter: .system
        )
    }

    /// For tests and measurements: any model, a short time limit, a clock, a context meter.
    public init(
        model: some LanguageModel,
        snapshot: @escaping @Sendable () async -> FolderSnapshot,
        findDuplicates: @escaping @Sendable (FolderScope) async -> DuplicateScan? = { _ in nil },
        cleanupActions: [String] = [],
        proposeCleanup: @escaping ProposeCleanup = { _, _ in nil },
        largeFileMegabytes: @escaping @Sendable () -> Int = { 500 },
        availability: @escaping @Sendable () -> IntelligenceAvailability = { .available },
        turnLimit: Duration = ChatEngine.turnLimit,
        now: @escaping @Sendable () -> Date = { .now },
        meter: ContextMeter? = nil
    ) {
        self.model = model
        self.tools = Tools(
            snapshot: snapshot, findDuplicates: findDuplicates, cleanupActions: cleanupActions, proposeCleanup: proposeCleanup
        )
        self.largeFileMegabytes = largeFileMegabytes
        self.availability = availability
        self.turnLimit = turnLimit
        self.now = now
        self.meter = meter
    }

    /// Loads the model ahead of the first question. Called when the chat bar gets focus.
    public func prewarm() {
        guard availability() == .available else { return }
        currentConversation().session.prewarm()
    }

    /// Asks one question. `onText` gets the reply so far each time it changes, on no particular
    /// actor; it starts again from empty when the question is asked again in a fresh conversation.
    /// Cancelling the calling task is Stop: the turn ends as `.stopped` with what had arrived.
    /// "Continue" after a stopped question asks that question again.
    public func respond(to message: String, onText: @escaping @Sendable (String) -> Void) async -> Turn {
        let available = availability()
        guard available == .available else {
            return Turn(text: "", outcome: .unavailable(available), effects: TurnEffects())
        }
        let text = memory.question(for: message)
        let started = ContinuousClock.now
        var attempt = await ask(text, in: currentConversation(), within: turnLimit, onText: onText)
        var startedOver = false
        // A conversation too full to go on, or an error nobody recognised (which may be the same
        // under another name), is not the user's to fix: the question is asked again, once, in a
        // fresh conversation that keeps the last two questions.
        let remaining = turnLimit - (ContinuousClock.now - started)
        if attempt.outcome == .contextFull || attempt.outcome == .failed, !Task.isCancelled, remaining > .zero {
            startedOver = true
            onText("")
            let fresh = makeConversation(history: ChatHistory.lastTurns(attempt.history, Self.turnsKeptOnStartingOver))
            attempt = await ask(text, in: fresh, within: remaining, onText: onText)
        }

        switch attempt.outcome {
        case .answered, .toolLimitReached, .refused, .unavailable:
            // The session put its transcript back as it was before a turn that threw.
            self.conversation = attempt.conversation
        case .contextFull, .failed:
            // Not mended by asking again: the next question starts with nothing carried over.
            self.conversation = nil
        case .stopped, .timedOut:
            // The abandoned reply may still be running behind the session and calling tools, which
            // would spend the next turn's budget and confuse its answer (seen with the real model).
            // A new session made from the history before this turn remembers the same conversation
            // and shares nothing with the old one.
            self.conversation = makeConversation(history: attempt.history)
        }
        memory.record(text, outcome: attempt.outcome, effects: attempt.effects)
        Self.logger.info("""
            Turn ended: \(String(describing: attempt.outcome), privacy: .public), \
            \(attempt.effects.results.count) tool results, \(startedOver ? "started over, " : "", privacy: .public)\
            \((ContinuousClock.now - started).formatted(), privacy: .public)
            """)
        var turn = Turn(text: attempt.text, outcome: attempt.outcome, effects: attempt.effects)
        turn.startedOver = startedOver
        turn.tokensBeforeReply = attempt.tokensBeforeReply
        return turn
    }

    /// One try at a question in `conversation`, ended by the reply, an error, Stop or `limit`.
    private struct Attempt {
        let conversation: Conversation
        /// The transcript before the question.
        let history: [Transcript.Entry]
        let text: String
        let outcome: TurnOutcome
        let effects: TurnEffects
        let tokensBeforeReply: Int?
    }

    private func ask(
        _ text: String, in conversation: Conversation, within limit: Duration, onText: @escaping @Sendable (String) -> Void
    ) async -> Attempt {
        let session = conversation.session
        let history = Array(session.transcript)
        let fit = await earlierTurnsThatFit(history, question: text, shownLastTime: conversation.recorder.earlierTurnsShown)
        conversation.recorder.begin(showingEarlierTurns: fit.turns, note: fit.note, previous: memory.lastResult)
        let reply = Mutex("")

        enum Ending {
            case finished
            case threw(any Error)
            case outOfTime
            case cancelled
        }
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
        return Attempt(
            conversation: conversation, history: history, text: reply.withLock { $0 }, outcome: outcome,
            effects: conversation.recorder.effects, tokensBeforeReply: fit.tokens
        )
    }

    /// How many of the turns in `history` the model can be shown with `question` and the note of
    /// what the app remembers, cut short as `ChatHistory` does, inside `historyShare` of the
    /// context. Counted before every turn, so a long conversation drops its oldest turns before it
    /// overflows, never after. It starts from one more than the last turn showed, so a turn takes
    /// one or two counts however long the conversation is.
    private func earlierTurnsThatFit(
        _ history: [Transcript.Entry], question: String, shownLastTime: Int
    ) async -> (turns: Int, tokens: Int?, note: String?) {
        let earlier = ChatHistory.turnCount(history)
        let memory = memory
        let large = largeFileMegabytes()
        // The fewer turns shown, the more of them the note has a line for. Counting is done with
        // the note at its longest, so dropping a turn never makes the count grow and a turn still
        // takes one or two counts.
        let note = { (turns: Int?) in memory.note(showingTurns: turns, asking: question, largeMegabytes: large) }
        let longestNote = note(nil)
        guard let meter else { return (earlier, nil, note(earlier)) }
        let budget = Int(Double(meter.contextSize) * Self.historyShare)
        let prompt = Transcript.Entry.prompt(Transcript.Prompt(segments: [.text(Transcript.TextSegment(content: question))]))
        // The transcript starts with the instructions, whose count includes the tool definitions.
        let shownWith = { (turns: Int) in
            try await meter.count(ChatHistory.compacted(history + [prompt], keepingEarlierTurns: turns, note: longestNote))
        }
        var shown = shownLastTime == .max ? earlier : min(earlier, shownLastTime + 1)
        do {
            var tokens = try await shownWith(shown)
            while tokens > budget, shown > 0 {
                shown -= 1
                tokens = try await shownWith(shown)
            }
            Self.logger.info("Showing \(shown) of \(earlier) earlier turns, \(tokens) of \(meter.contextSize) tokens before the reply")
            return (shown, tokens, note(shown))
        } catch {
            // Without a count, as much as a fresh conversation keeps.
            shown = min(shown, Self.turnsKeptOnStartingOver)
            Self.logger.notice("Could not count tokens (\(String(reflecting: type(of: error)), privacy: .public)); showing \(shown) earlier turns")
            return (shown, nil, note(shown))
        }
    }

    /// What the on-device model must read before any question, in tokens: the instructions and the
    /// tool definitions, with `cleanupActions` as the actions `proposeCleanup` offers. Together they
    /// should stay under `fixedPromptShare` of `contextSize`; the numbers are recorded in
    /// docs/decisions/0023 and measured again whenever a template or a tool changes.
    public static func fixedPromptTokens(cleanupActions: [String]) async throws -> (instructions: Int, tools: Int, contextSize: Int) {
        let model = SystemLanguageModel.default
        let tools = tools(ToolContext(
            snapshot: { FolderSnapshot(files: []) }, findDuplicates: { _ in nil }, cleanupActions: cleanupActions, recorder: TurnRecorder()
        ))
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
        Self.makeConversation(model: model, tools: tools, history: history, today: now())
    }

    /// Every tool the model may call. Three only read; the fourth asks the app for a plan, which
    /// only the user's Confirm carries out.
    private static func tools(_ context: ToolContext) -> [any Tool] {
        let lookups: [any Tool] = [SearchFilesTool(context: context), FolderSummaryTool(context: context), FindDuplicatesTool(context: context)]
        guard let cleanup = ProposeCleanupTool(context: context) else {
            if !context.cleanupActions.isEmpty { logger.error("proposeCleanup is not offered: its actions made no schema") }
            return lookups
        }
        return lookups + [cleanup]
    }

    /// Static, so the tool-call hook does not inherit the engine's isolation and wait for it.
    private static func makeConversation(model: any LanguageModel, tools app: Tools, history: [Transcript.Entry], today: Date) -> Conversation {
        // The new session brings its own instructions; the old ones are not part of what was said.
        let history = history.filter { entry in
            if case .instructions = entry { false } else { true }
        }
        let recorder = TurnRecorder()
        let tools = tools(app.context(recorder))
        let registered = Set(tools.map(\.name))
        let instructions = PromptLibrary.chatInstructions(today: today)
        let profile = LanguageModelSession.Profile {
            Instructions(instructions)
            tools
        }
        .model(model)
        .samplingMode(.greedy)
        .transcriptErrorHandlingPolicy(.revertTranscript)
        // What the model reads; the session keeps the whole transcript. Measured with the real
        // model: overflow is judged on this, not on the transcript (docs/decisions/0021).
        .historyTransform { entries in
            let shown = recorder.shown
            return ChatHistory.compacted(entries, keepingEarlierTurns: shown.earlierTurns, note: shown.note)
        }
        // Runs before each tool; a throw stops that tool and ends the turn (measured: 0020).
        .onToolCall { call in
            // The name only, never the arguments: they can quote the question or a file name.
            logger.info("Tool call: \(call.toolName, privacy: .public)")
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
