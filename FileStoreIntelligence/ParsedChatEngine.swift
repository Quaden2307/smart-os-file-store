import Foundation
import FoundationModels
import os

/// What the chat bar needs of an engine. `ChatEngine` (the tool loop) and `ParsedChatEngine` both
/// answer it; `ChatEngines.make` picks one.
public protocol ChatResponding: Actor {
    /// Loads the model ahead of the first question. Called when the chat bar gets focus.
    func prewarm()
    /// Asks one question. Cancelling the calling task is Stop.
    func respond(to message: String, onText: @escaping @Sendable (String) -> Void) async -> Turn
    /// The files the conversation's last result holds: what "those" means next. Nil before one.
    var lastResultIDs: [URL]? { get }
}

extension ChatEngine: ChatResponding {}

/// One chat conversation answered by code: the parser reads the message into a `ChatRequest`
/// (one guided generation), `ChatRequestPlanner` turns it into a lookup or a cleanup request,
/// the app's own functions run it, and `ReplyComposer` words the reply. The model calls no tool
/// and writes no reply but an overview's one sentence (docs/decisions/0036). Like `ChatEngine`, it
/// can ask the app for a plan and never carry one out, and keeps the conversation in memory only.
public actor ParsedChatEngine: ChatResponding {
    private static let logger = Logger(subsystem: "com.quaden2307.FileStoreIntelligence", category: "ParsedChatEngine")

    /// What the app hands the engine, and the model the parser and the overview use.
    private struct Tools: Sendable {
        let model: any LanguageModel
        let snapshot: @Sendable () async -> FolderSnapshot
        let findDuplicates: @Sendable (FolderScope) async -> DuplicateScan?
        let cleanupActions: [String]
        let proposeCleanup: ProposeCleanup
    }

    private let tools: Tools
    private let parser: ChatParser
    private let availability: @Sendable () -> IntelligenceAvailability
    private let turnLimit: Duration
    private let now: @Sendable () -> Date
    /// What is remembered between turns: the last result and a stopped question (`ChatMemory`).
    private var memory = ChatMemory()
    /// A parser session made and prewarmed ahead of the message; the next parse uses it once.
    private var prewarmed: LanguageModelSession?

    /// The engine the app uses: the on-device system model, and never any other.
    public init(
        snapshot: @escaping @Sendable () async -> FolderSnapshot,
        findDuplicates: @escaping @Sendable (FolderScope) async -> DuplicateScan?,
        cleanupActions: [String],
        proposeCleanup: @escaping ProposeCleanup
    ) {
        self.init(
            model: SystemLanguageModel.default, snapshot: snapshot, findDuplicates: findDuplicates,
            cleanupActions: cleanupActions, proposeCleanup: proposeCleanup,
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
        findDuplicates: @escaping @Sendable (FolderScope) async -> DuplicateScan? = { _ in nil },
        cleanupActions: [String] = [],
        proposeCleanup: @escaping ProposeCleanup = { _, _ in nil },
        availability: @escaping @Sendable () -> IntelligenceAvailability = { .available },
        turnLimit: Duration = ChatEngine.turnLimit,
        now: @escaping @Sendable () -> Date = { .now }
    ) {
        tools = Tools(model: model, snapshot: snapshot, findDuplicates: findDuplicates, cleanupActions: cleanupActions, proposeCleanup: proposeCleanup)
        parser = ChatParser(model: model, cleanupActions: cleanupActions, timeLimit: turnLimit)
        self.availability = availability
        self.turnLimit = turnLimit
        self.now = now
    }

    public var lastResultIDs: [URL]? { memory.lastResult?.ids }

    /// Makes the parser's session for the next message and loads the model for it.
    public func prewarm() {
        guard availability() == .available, prewarmed == nil else { return }
        let session = parser.makeSession()
        session.prewarm()
        prewarmed = session
    }

    /// Asks one question. `onText` gets the reply once, when it is ready. Cancelling the calling
    /// task is Stop. "Continue" after a stopped question asks that question again.
    public func respond(to message: String, onText: @escaping @Sendable (String) -> Void) async -> Turn {
        let available = availability()
        guard available == .available else {
            return Turn(text: "", outcome: .unavailable(available), effects: TurnEffects())
        }
        let text = memory.question(for: message)
        let session = prewarmed ?? parser.makeSession()
        prewarmed = nil
        let started = ContinuousClock.now
        let last = memory.lastResult.map { (ids: $0.ids, sort: $0.sort) }
        let (tools, parser, limit, today) = (tools, parser, turnLimit, now())

        enum Ending {
            case answered(Answered)
            case threw(any Error)
            case outOfTime
            case cancelled
        }
        let ending = await withTaskGroup(of: Ending.self) { group in
            group.addTask {
                do {
                    return .answered(try await Self.answer(
                        text, session: session, parser: parser, tools: tools, lastResult: last, today: today, deadline: started + limit
                    ))
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

        var turn: Turn
        switch ending {
        case .answered(let answered):
            turn = Turn(text: answered.text, outcome: .answered, effects: answered.effects)
            turn.request = answered.request
            onText(turn.text)
        case .cancelled:
            turn = Turn(text: "", outcome: .stopped, effects: TurnEffects())
        case .outOfTime:
            turn = Turn(text: "", outcome: Task.isCancelled ? .stopped : .timedOut, effects: TurnEffects())
        case .threw(let error):
            turn = Turn(text: "", outcome: Task.isCancelled ? .stopped : outcome(for: error), effects: TurnEffects())
        }
        memory.record(text, outcome: turn.outcome, effects: turn.effects)
        Self.logger.info("""
            Turn ended: \(String(describing: turn.outcome), privacy: .public), \
            \(turn.effects.results.count) results, \((ContinuousClock.now - started).formatted(), privacy: .public)
            """)
        return turn
    }

    private func outcome(for error: any Error) -> TurnOutcome {
        if error as? ChatParser.ParseError == .timedOut { return .timedOut }
        // Only the kind of error and its number are logged: its text could quote the question.
        Self.logger.notice("Turn threw \(String(reflecting: type(of: error)), privacy: .public) (\((error as NSError).code))")
        let available = availability()
        return available == .available ? ChatEngine.outcome(for: error) : .unavailable(available)
    }

    /// What one answered turn came to.
    private struct Answered: Sendable {
        var request: ChatRequest
        var effects = TurnEffects()
        var text = ""
    }

    /// Parses, plans and runs one message, before `deadline`. Static, so it runs off the engine's actor.
    private static func answer(
        _ message: String, session: LanguageModelSession, parser: ChatParser, tools: Tools,
        lastResult: (ids: [URL], sort: FileSort?)?, today: Date, deadline: ContinuousClock.Instant
    ) async throws -> Answered {
        let snapshot = await tools.snapshot()
        let request = try await parser.parse(message, in: snapshot, lastResult: lastResult?.ids, session: session)
        var answered = Answered(request: request)
        let plan = ChatRequestPlanner.plan(request, in: snapshot, today: today, lastResult: lastResult, cleanupActions: tools.cleanupActions)
        let folderScope = { (scope: FolderScope) in snapshot.folders.isEmpty ? nil : scope }
        switch plan {
        case let .search(query, sort, limit, scope, count):
            let result = FileSearchResult(query: query, sort: sort, limit: limit, in: snapshot.narrowed(to: scope), scope: folderScope(scope))
            answered.effects.results.append(.search(result))
            answered.text = ReplyComposer.search(result, count: count)
        case let .cleanup(asked, scope):
            var proposals: [CleanupProposal] = []
            var unplanned = 0
            for (request, ids) in asked.perFolder(scope, in: snapshot) {
                // No file matches, so no planner needs to read any.
                if ids?.isEmpty == true {
                    proposals.append(CleanupProposal(request: request, rows: [], sampleNames: []))
                    continue
                }
                guard let proposal = await tools.proposeCleanup(request, ids) else {
                    unplanned += 1
                    continue
                }
                proposals.append(proposal)
                if !proposal.rows.isEmpty { answered.effects.results.append(.cleanup(proposal)) }
            }
            let unreadable = scope == .all ? snapshot.unreadableFolders.count : 0
            let named = request.cleanups.map { !$0.isEmpty && !$0.contains(.everything) } ?? false
            answered.text = ReplyComposer.cleanup(proposals, unplanned: unplanned, unreadable: unreadable, named: named)
        case .duplicates(let scope):
            let scan = await tools.findDuplicates(scope)
            if let scan { answered.effects.results.append(.duplicates(scan)) }
            answered.text = ReplyComposer.duplicates(scan)
        case .overview(let scope):
            let summary = FolderSummary(snapshot.narrowed(to: scope), scope: folderScope(scope))
            answered.effects.results.append(.summary(summary))
            let facts = ReplyComposer.overviewFacts(summary, scope: folderScope(scope))
            // A second before the turn's end, so a slow sentence leaves time for the reply in code.
            let sentence = await overviewSentence(facts, model: tools.model, within: deadline - ContinuousClock.now - .seconds(1))
            answered.text = ReplyComposer.overview(summary)
            if let sentence {
                // Numbers shown come from code: the sentence may only repeat the facts' own. A name
                // no folder has is not shown either, as in the tool-calling chat (docs/decisions/0033).
                if !Self.numbers(in: sentence).isSubset(of: Self.numbers(in: facts)) || !ReplyNames(snapshot, question: message).unknown(in: sentence).isEmpty {
                    logger.notice("The overview sentence was not shown: a number or a name not in its facts")
                } else {
                    answered.text = sentence
                }
            }
        case .cannotDo(let reason):
            answered.text = ReplyComposer.cannotDo(reason)
        case .chat:
            answered.text = ReplyComposer.chat
        case .needsMore(let missing):
            answered.text = ReplyComposer.needsMore(missing)
        }
        return answered
    }

    /// Every number written in `text`, as written.
    static func numbers(in text: String) -> Set<String> {
        Set(text.matches(of: /\d+(?:\.\d+)?/).map { String($0.output) })
    }

    /// The model's one sentence over `facts`, or nil when it gave none within `limit`: the reply
    /// in code is shown instead.
    private static func overviewSentence(_ facts: String, model: any LanguageModel, within limit: Duration) async -> String? {
        guard limit > .zero else { return nil }
        let profile = LanguageModelSession.Profile { Instructions(PromptLibrary.overviewReply.text) }
            .model(model)
            .samplingMode(.greedy)
        let session = LanguageModelSession(profile: profile)
        do {
            let reply = try await withThrowingTaskGroup(of: String?.self) { group in
                group.addTask { try await session.respond(to: facts).content }
                group.addTask {
                    try await Task.sleep(for: limit)
                    return nil
                }
                defer { group.cancelAll() }
                return try await group.next() ?? nil
            }
            guard let reply else { return nil }
            // The model often copies the data marks around a name into its sentence.
            let sentence = reply.filter { $0 != PromptLibrary.dataOpen && $0 != PromptLibrary.dataClose }
                .trimmingCharacters(in: .whitespacesAndNewlines)
            return sentence.isEmpty ? nil : sentence
        } catch {
            // A Stop is a Stop, not a reply in code.
            if Task.isCancelled { return nil }
            logger.notice("No overview sentence: \(String(reflecting: type(of: error)), privacy: .public)")
            return nil
        }
    }
}

/// The one place the chat's engine is chosen. The tool loop stays the default; the hidden
/// defaults key `UseParsedChat` turns the parsed chat on (docs/decisions/0036). No setting shows it.
public enum ChatEngines {
    public static let useParsedChatKey = "UseParsedChat"

    public static func make(
        snapshot: @escaping @Sendable () async -> FolderSnapshot,
        findDuplicates: @escaping @Sendable (FolderScope) async -> DuplicateScan?,
        cleanupActions: [String],
        proposeCleanup: @escaping ProposeCleanup,
        largeFileMegabytes: @escaping @Sendable () -> Int,
        defaults: UserDefaults = .standard
    ) -> any ChatResponding {
        if defaults.bool(forKey: useParsedChatKey) {
            return ParsedChatEngine(snapshot: snapshot, findDuplicates: findDuplicates, cleanupActions: cleanupActions, proposeCleanup: proposeCleanup)
        }
        return ChatEngine(
            snapshot: snapshot, findDuplicates: findDuplicates, cleanupActions: cleanupActions,
            proposeCleanup: proposeCleanup, largeFileMegabytes: largeFileMegabytes
        )
    }
}
