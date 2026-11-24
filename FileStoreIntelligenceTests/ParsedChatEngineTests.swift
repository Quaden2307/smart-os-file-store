import FileStoreIntelligence
import Foundation
import FoundationModels
import Testing

extension ParsedChatEngine {
    /// An engine over the fixture folder.
    static func scripted(
        _ model: ScriptedModel, turnLimit: Duration = .seconds(10),
        availability: @escaping @Sendable () -> IntelligenceAvailability = { .available },
        cleanup: @escaping ProposeCleanup = Fixtures.proposal,
        asked: Collected<Set<URL>?>? = nil
    ) -> ParsedChatEngine {
        ParsedChatEngine(
            model: model,
            snapshot: { Fixtures.snapshot },
            findDuplicates: { _ in Fixtures.duplicates },
            cleanupActions: Fixtures.cleanupActions,
            proposeCleanup: { request, ids in
                asked?.add(ids)
                return await cleanup(request, ids)
            },
            availability: availability,
            turnLimit: turnLimit,
            now: { Fixtures.now }
        )
    }

    func ask(_ question: String = "A question") async -> Turn {
        await respond(to: question) { _ in }
    }
}

@Suite("Parsed chat engine")
struct ParsedChatEngineTests {
    private struct NoSentence: Error {}

    private static func parse(_ json: String) -> [ScriptedModel.Step] {
        [.text([json])]
    }

    @Test func aListIsLookedUpAndWordedInCodeWithNoToolCall() async throws {
        let model = ScriptedModel(Self.parse(#"{"kind":"list","files":{"kind":"images"}}"#))
        let shown = Collected<String>()
        let turn = await ParsedChatEngine.scripted(model).respond(to: "Show my pictures") { shown.add($0) }
        #expect(turn.outcome == .answered)
        #expect(turn.toolCalls.isEmpty)
        #expect(turn.request == ChatRequest(kind: .list, files: FileSlots(kind: "images")))
        guard case .search(let result) = try #require(turn.effects.results.first) else {
            Issue.record("no search")
            return
        }
        #expect(Set(result.files.map(\.name)) == ["holiday.jpg", "screenshot.png", "old-photo.heic"])
        #expect(turn.text == "Found 3 files, 8.6 MB in all.")
        #expect(shown.all == [turn.text])
        // One request, and it is the parse: guided, with no tools.
        #expect(model.script.requests.count == 1)
        #expect(model.script.requests.first?.schema != nil)
    }

    @Test func aCleanupAsksTheAppForACardNarrowedOnlyByTheUsersSlots() async throws {
        let asked = Collected<Set<URL>?>()
        let engine = ParsedChatEngine.scripted(ScriptedModel(
            Self.parse(#"{"kind":"cleanup","cleanups":["exactCopies"]}"#),
            Self.parse(#"{"kind":"cleanup","cleanups":["messyNames"],"files":{"kind":"documents"}}"#)
        ), asked: asked)
        let turn = await engine.ask("Remove the duplicates")
        guard case .cleanup(let proposal) = try #require(turn.effects.results.first) else {
            Issue.record("no card")
            return
        }
        #expect(proposal.request == CleanupRequest(actions: ["findDuplicates"]))
        #expect(turn.text.hasPrefix("A preview of "))
        let narrowed = await engine.ask("Fix the names of my documents")
        guard case .cleanup(let card) = try #require(narrowed.effects.results.first) else {
            Issue.record("no card")
            return
        }
        #expect(card.request.query?.typeGroup == .documents)
        let documents = Set(Fixtures.files.filter { FileTypeGroup(contentType: $0.contentType) == .documents }.map(\.id))
        #expect(asked.all == [nil, documents])
    }

    @Test func aCleanupThatNamesNothingAsksWhichAndPlansNothing() async {
        let asked = Collected<Set<URL>?>()
        let turn = await ParsedChatEngine.scripted(ScriptedModel(Self.parse(#"{"kind":"cleanup"}"#)), asked: asked).ask("Clean up")
        #expect(turn.outcome == .answered)
        #expect(turn.effects.results.isEmpty)
        #expect(turn.text == ReplyComposer.needsMore(.cleanup))
        #expect(asked.all.isEmpty)
    }

    @Test func aFollowUpLooksInsideTheLastResultAndTheParserReadsItsLine() async throws {
        let model = ScriptedModel(
            Self.parse(#"{"kind":"list","files":{"kind":"video"}}"#),
            Self.parse(#"{"kind":"list","files":{"minMB":100},"aboutLastResult":true}"#)
        )
        let engine = ParsedChatEngine.scripted(model)
        _ = await engine.ask("Show my videos")
        let turn = await engine.ask("only the big ones")
        guard case .search(let result) = try #require(turn.effects.results.first) else {
            Issue.record("no search")
            return
        }
        #expect(result.files.map(\.name) == ["movie.mov"])
        #expect(model.latestPrompt.contains("Last result: 2 files (video)."))
        #expect(await engine.lastResultIDs == result.matchIDs)
    }

    @Test func stopThenContinueAsksTheStoppedQuestionAgain() async {
        let model = ScriptedModel([.wait(.seconds(5))], Self.parse(#"{"kind":"chat"}"#))
        let engine = ParsedChatEngine.scripted(model)
        let task = Task { await engine.ask("How are my files?") }
        try? await Task.sleep(for: .milliseconds(200))
        task.cancel()
        #expect(await task.value.outcome == .stopped)
        let turn = await engine.ask("Continue")
        #expect(turn.outcome == .answered)
        #expect(model.latestPrompt == "How are my files?")
    }

    @Test func aTurnOverItsTimeLimitTimesOut() async {
        let turn = await ParsedChatEngine.scripted(ScriptedModel([.wait(.seconds(5))]), turnLimit: .milliseconds(200)).ask()
        #expect(turn.outcome == .timedOut)
        #expect(turn.text.isEmpty && turn.effects.results.isEmpty)
    }

    @Test func noModelNoTurn() async {
        let model = ScriptedModel(Self.parse(#"{"kind":"chat"}"#))
        let turn = await ParsedChatEngine.scripted(model, availability: { .turnedOffInSettings }).ask()
        #expect(turn.outcome == .unavailable(.turnedOffInSettings))
        #expect(model.script.requests.isEmpty)
    }

    @Test func anOverviewIsTheModelsSentenceFromFactsWithNoName() async throws {
        let model = ScriptedModel(Self.parse(#"{"kind":"overview"}"#), [.text(["Your folder holds 21 items, mostly ⟦installers⟧."])])
        let turn = await ParsedChatEngine.scripted(model).ask("What's in here?")
        #expect(turn.text == "Your folder holds 21 items, mostly installers.")
        guard case .summary = try #require(turn.effects.results.first) else {
            Issue.record("no summary")
            return
        }
        let facts = model.latestPrompt
        #expect(facts.hasPrefix("The folder: 21 items"))
        for file in Fixtures.files {
            #expect(!facts.contains(file.name), "\(file.name)")
        }
        let overview = try #require(model.script.requests.last)
        #expect(overview.schema == nil && overview.enabledToolDefinitions.isEmpty)
    }

    @Test func anOverviewNamingAFileThatDoesNotExistOrANumberNotInItsFactsIsWordedInCode() async {
        for sentence in ["The biggest is invented.pdf.", "Your folder holds 25 items.", "About 77 GB of video."] {
            let model = ScriptedModel(Self.parse(#"{"kind":"overview"}"#), [.text([sentence])])
            let turn = await ParsedChatEngine.scripted(model).ask("Tell me about this folder")
            #expect(turn.outcome == .answered)
            #expect(!turn.replyWithheld)
            #expect(turn.text == ReplyComposer.overview(FolderSummary(Fixtures.snapshot)), "\(sentence)")
        }
    }

    @Test func aSlowOverviewSentenceLeavesTheReplyInCode() async {
        let model = ScriptedModel(Self.parse(#"{"kind":"overview"}"#), [.wait(.seconds(5)), .text(["Your folder holds 21 items."])])
        let turn = await ParsedChatEngine.scripted(model, turnLimit: .seconds(2)).ask("Tell me about this folder")
        #expect(turn.outcome == .answered)
        #expect(turn.text == ReplyComposer.overview(FolderSummary(Fixtures.snapshot)))
    }

    @Test func anOverviewWithNoSentenceIsWordedInCode() async {
        let model = ScriptedModel(Self.parse(#"{"kind":"overview"}"#), [.fail(NoSentence())])
        let turn = await ParsedChatEngine.scripted(model).ask("Tell me about this folder")
        #expect(turn.text == ReplyComposer.overview(FolderSummary(Fixtures.snapshot)))
    }

    @Test func cannotDoAndChatAreAnsweredInCode() async {
        let engine = ParsedChatEngine.scripted(ScriptedModel(
            Self.parse(#"{"kind":"cannotDo","cannotDo":"move"}"#), Self.parse(#"{"kind":"chat"}"#)
        ))
        #expect(await engine.ask("Move my invoices to Documents").text == ReplyComposer.cannotDo(.asked(.move)))
        #expect(await engine.ask("Thanks!").text == ReplyComposer.chat)
    }

    @Test func theDefaultEngineIsTheToolLoopAndAHiddenKeyTurnsOnTheParsedOne() throws {
        let suite = "ParsedChatEngineTests-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        func make() -> any ChatResponding {
            ChatEngines.make(
                snapshot: { Fixtures.snapshot }, findDuplicates: { _ in nil }, cleanupActions: Fixtures.cleanupActions,
                proposeCleanup: { _, _ in nil }, largeFileMegabytes: { 500 }, defaults: defaults
            )
        }
        #expect(make() is ChatEngine)
        defaults.set(true, forKey: ChatEngines.useParsedChatKey)
        #expect(make() is ParsedChatEngine)
    }
}
