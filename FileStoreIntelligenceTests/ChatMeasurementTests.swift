import FileStoreIntelligence
import Foundation
import FoundationModels
import Testing

/// What the chat costs on this Mac with the real on-device model: the room the instructions and
/// tool definitions take, how long an answer takes with and without prewarming, how big a tool's
/// output gets, how fast Stop is, and how much of the context a long conversation uses.
/// Results go to the test log as warnings starting `CHAT` and are copied by hand into the decision
/// record (docs/decisions/0020). Nothing is asserted about speed.
///
/// It needs Apple Intelligence, so it is not part of the normal test run or of CI: the default test
/// plan leaves it out and the `Benchmark` plan runs it (README.md has the command).
@Suite(
    "Chat measurements",
    .serialized,
    .timeLimit(.minutes(30)),
    .enabled(if: ProcessInfo.processInfo.environment["SMARTOS_RUN_BENCHMARK"] == "1", "runs from the Benchmark test plan only")
)
struct ChatMeasurementTests {
    private static let questions = [
        "What's taking the most space?",
        "What did I download last week and never open?",
        "How many files have I never opened?",
        "Which files are over 500 MB?",
        "How many documents do I have?",
        "What are my newest downloads?",
        "Which installers are here?",
        "How much space do videos use?",
        "Show me files from github.com.",
        "What did I download today?",
        "Which files have I kept?",
        "Are there any failed downloads?",
        "What is the oldest file here?",
        "Which images are larger than 3 MB?",
        "How many items are in this folder?",
        "What did I open most recently?",
        "Which archives have I never opened?",
        "How much have cleanups moved to the Trash?",
        "Which files are marked old?",
        "Find files with report in the name.",
    ]

    /// About seventy rows: the fixture, and fifty more shaped like ordinary downloads.
    private static let snapshot: FolderSnapshot = {
        let more = (1...50).map { index in
            Fixtures.file(
                "invoice-\(index).pdf", .pdf, megabytes: Double(index) / 10, added: index * 3,
                opened: index.isMultiple(of: 3) ? index : nil, site: index.isMultiple(of: 2) ? "billing.example.com" : nil
            )
        }
        return FolderSnapshot(files: Fixtures.files + more, bytesMovedToTrash: 3_400_000_000, now: .now)
    }()

    private static func report(_ text: String) {
        Issue.record("CHAT \(text)", severity: .warning)
    }

    private static func seconds(_ duration: Duration) -> Double {
        Double(duration.components.seconds) + Double(duration.components.attoseconds) / 1e18
    }

    /// The median and the 95th percentile (nearest rank), in seconds.
    private static func spread(_ durations: [Duration]) -> String {
        let values = durations.map(seconds).sorted()
        guard !values.isEmpty else { return "no samples" }
        let p95 = values[min(values.count - 1, Int((Double(values.count) * 0.95).rounded(.up)) - 1)]
        return String(format: "p50 %.2f s, p95 %.2f s (n=%d)", values[values.count / 2], p95, values.count)
    }

    private func engine() -> ChatEngine {
        ChatEngine(
            model: SystemLanguageModel.default, snapshot: { Self.snapshot }, findDuplicates: { _ in Fixtures.duplicates },
            cleanupActions: Fixtures.cleanupActions, proposeCleanup: Fixtures.proposal, meter: .system
        )
    }

    /// One question: how long until the first text, how long in all, and how it ended.
    private func ask(_ engine: ChatEngine, _ question: String) async -> (first: Duration?, total: Duration, turn: Turn) {
        let clock = ContinuousClock()
        let started = clock.now
        let firstText = Collected<ContinuousClock.Instant>()
        let turn = await engine.respond(to: question) { text in
            if !text.isEmpty, firstText.all.isEmpty { firstText.add(clock.now) }
        }
        return (firstText.all.first.map { $0 - started }, clock.now - started, turn)
    }

    /// The room taken before any question. A test of its own, so it can be run alone after a
    /// template or a tool changes.
    @Test func theFixedPromptStaysWithinItsShareOfTheContext() async throws {
        let model = SystemLanguageModel.default
        guard model.isAvailable else {
            Self.report("not measured: Apple Intelligence is \(model.availability) on this Mac")
            return
        }
        let fixed = try await ChatEngine.fixedPromptTokens(cleanupActions: Fixtures.cleanupActions)
        let share = Double(fixed.instructions + fixed.tools) / Double(fixed.contextSize)
        Self.report("contextSize \(fixed.contextSize) tokens; instructions \(fixed.instructions), tool definitions \(fixed.tools), together \(String(format: "%.1f", share * 100))% of the context")
        #expect(share <= ChatEngine.fixedPromptShare, "Instructions and tools take more of the context than decided (docs/decisions/0023): shorten them")
    }

    /// The parser's instructions and schema, with three folders for the longest schema. The
    /// segment's bound, 1,600 tokens, leaves the message and the reply most of the context (0035).
    @Test func theParserPromptStaysUnder1600Tokens() async throws {
        let model = SystemLanguageModel.default
        guard model.isAvailable else {
            Self.report("not measured: Apple Intelligence is \(model.availability) on this Mac")
            return
        }
        let fixed = try await ChatParser.fixedPromptTokens(cleanupActions: Fixtures.cleanupActions, folders: ["Downloads", "Desktop", "Documents"])
        Self.report("parser: instructions \(fixed.instructions), schema \(fixed.schema), together \(fixed.instructions + fixed.schema) tokens")
        #expect(fixed.instructions + fixed.schema < 1_600, "The parser's fixed prompt is over its bound (docs/decisions/0035): shorten it")
    }

    @Test func measureTheChatOnThisMac() async throws {
        let model = SystemLanguageModel.default
        guard model.isAvailable else {
            Self.report("not measured: Apple Intelligence is \(model.availability) on this Mac")
            return
        }

        // 2. The largest text a tool can hand the model, and an ordinary one.
        let flood = FolderSnapshot(
            files: (0..<500).map { Fixtures.file(String(repeating: "W", count: 80) + "\($0).pdf", .pdf, megabytes: Double($0), added: $0, site: String(repeating: "m", count: 80)) },
            now: .now
        )
        let worst = ToolOutput.search(FileSearchResult(query: FileQuery(), sort: .largest, limit: 100, in: flood), now: .now)
        let usual = ToolOutput.search(FileSearchResult(query: FileQuery(), sort: .largest, limit: 20, in: Self.snapshot), now: .now)
        let summary = ToolOutput.summary(FolderSummary(Self.snapshot))
        Self.report("tool output tokens: longest search \(try await model.tokenCount(for: worst)) (\(worst.count) characters), usual search \(try await model.tokenCount(for: usual)) (\(usual.count)), summary \(try await model.tokenCount(for: summary)) (\(summary.count))")

        // 3. Twenty questions, each in a fresh conversation: first without prewarming, then with.
        var cold: (first: [Duration], total: [Duration]) = ([], [])
        var warm: (first: [Duration], total: [Duration]) = ([], [])
        for (index, question) in Self.questions.enumerated() {
            let unwarmed = await ask(engine(), question)
            cold.total.append(unwarmed.total)
            if let first = unwarmed.first { cold.first.append(first) }

            let prewarmed = engine()
            await prewarmed.prewarm()
            // Apple's note: prewarming needs at least a second before the request to be of use.
            try await Task.sleep(for: .seconds(2))
            let warmed = await ask(prewarmed, question)
            warm.total.append(warmed.total)
            if let first = warmed.first { warm.first.append(first) }

            Self.report(String(
                format: "q%02d cold %.2f s (first text %.2f), prewarmed %.2f s (first text %.2f), %@, %d lookups, %d characters",
                index + 1, Self.seconds(unwarmed.total), unwarmed.first.map(Self.seconds) ?? -1,
                Self.seconds(warmed.total), warmed.first.map(Self.seconds) ?? -1,
                String(describing: warmed.turn.outcome), warmed.turn.effects.results.count, warmed.turn.text.count
            ))
        }
        Self.report("time to first text, cold: \(Self.spread(cold.first)); prewarmed: \(Self.spread(warm.first))")
        Self.report("full turn, cold: \(Self.spread(cold.total)); prewarmed: \(Self.spread(warm.total))")

        // 4. Stop, one second into a reply: how long until the turn is over, and the next question.
        let stopping = engine()
        let clock = ContinuousClock()
        let asking = Task { await stopping.respond(to: "What's taking the most space?") { _ in } }
        try await Task.sleep(for: .seconds(1))
        let stopAt = clock.now
        asking.cancel()
        let stopped = await asking.value
        let stopTook = clock.now - stopAt
        let afterStop = await ask(stopping, "How many items are in this folder?")
        Self.report(String(
            format: "Stop returned in %.4f s as %@; the next question ended %@ in %.2f s",
            Self.seconds(stopTook), String(describing: stopped.outcome), String(describing: afterStop.turn.outcome), Self.seconds(afterStop.total)
        ))

        // 5. One long conversation: does every question fit without starting over, and how much of
        // the context was the model shown before each reply (docs/decisions/0021).
        let long = engine()
        var outcomes: [TurnOutcome] = []
        var startedOver = 0
        var tokens: [Int] = []
        for index in 0..<30 {
            let turn = await ask(long, Self.questions[index % Self.questions.count]).turn
            outcomes.append(turn.outcome)
            if turn.startedOver { startedOver += 1 }
            if let shown = turn.tokensBeforeReply { tokens.append(shown) }
        }
        let others = outcomes.filter { $0 != .answered }.map { String(describing: $0) }
        Self.report("""
            30 questions in one conversation: \(outcomes.count - others.count) answered \(others.isEmpty ? "" : "(others: \(others.joined(separator: ", ")))"), \
            \(startedOver) started over; tokens before the reply: first \(tokens.first ?? -1), largest \(tokens.max() ?? -1), \
            last \(tokens.last ?? -1), of \(model.contextSize)
            """)
        #expect(startedOver == 0)
        #expect(!outcomes.contains(.contextFull))
    }
}
