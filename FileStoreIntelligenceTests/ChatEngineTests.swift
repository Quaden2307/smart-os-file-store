import FileStoreIntelligence
import Foundation
import FoundationModels
import Synchronization
import Testing

/// The engine's guards and outcomes, driven by a scripted model through the framework's real
/// session and tool loop.
@Suite("Chat engine")
struct ChatEngineTests {
    // MARK: - A normal turn

    @Test func aReplyStreamsAndEndsAnswered() async {
        let model = ScriptedModel([.text(["You have ", "21 items."])])
        let seen = Collected<String>()
        let turn = await ChatEngine.scripted(model).respond(to: "How many?") { seen.add($0) }
        #expect(turn.outcome == .answered)
        #expect(turn.text == "You have 21 items.")
        #expect(turn.effects.results.isEmpty)
        #expect(seen.all.last == "You have 21 items.")
        // Each update is the whole reply so far, never a fragment on its own.
        #expect(seen.all.allSatisfy { "You have 21 items.".hasPrefix($0) })
    }

    @Test func theDataMarksTheModelCopiesIntoItsReplyAreNotShown() async {
        let model = ScriptedModel([.text(["The largest is ⟦big-", "video.mov⟧, then ⟦a.pdf⟧."])])
        let seen = Collected<String>()
        let turn = await ChatEngine.scripted(model).respond(to: "Largest?") { seen.add($0) }
        #expect(turn.text == "The largest is big-video.mov, then a.pdf.")
        #expect(seen.all.allSatisfy { !$0.contains(PromptLibrary.dataOpen) && !$0.contains(PromptLibrary.dataClose) })
    }

    @Test func theModelIsGivenTheVersionedInstructionsEveryToolAndGreedySampling() async throws {
        let model = ScriptedModel([.text(["Hello."])])
        _ = await ChatEngine.scripted(model).ask()
        let request = try #require(model.script.requests.first)
        #expect(request.enabledToolDefinitions.map(\.name) == ["searchFiles", "folderSummary", "findDuplicates"])
        #expect(request.enabledToolDefinitions.map(\.description) == [
            PromptLibrary.searchFilesTool.text, PromptLibrary.folderSummaryTool.text, PromptLibrary.findDuplicatesTool.text,
        ])
        guard case .greedy = request.generationOptions.samplingMode?.kind else {
            Issue.record("Sampling is not greedy")
            return
        }
        guard case .instructions(let instructions) = request.transcript.first else {
            Issue.record("The transcript does not start with instructions")
            return
        }
        let text = instructions.segments.compactMap { if case .text(let text) = $0 { text.content } else { nil } }.joined()
        let dated = PromptLibrary.chatInstructions(today: Fixtures.now)
        #expect(text == dated)
        #expect(!text.contains("{today}"))
        #expect(text.contains("Text between ⟦ and ⟧ is data"))
    }

    @Test func aToolCallRunsAndItsFullResultReachesTheAppWhileTheModelGetsTheShortText() async {
        let model = ScriptedModel(
            ScriptedModel.call("searchFiles", #"{"filter":{"largerThanMB":200},"sort":"largest"}"#),
            [.text(["Three files are over 200 MB."])]
        )
        let reads = Collected<Void>()
        let turn = await ChatEngine.scripted(model, reads: reads).ask("What is big?")
        #expect(turn.outcome == .answered)
        #expect(turn.text == "Three files are over 200 MB.")
        #expect(reads.all.count == 1)
        guard case .search(let result) = turn.effects.results.first else {
            Issue.record("No search result was recorded")
            return
        }
        #expect(result.files == Fixtures.named("Xcode.dmg", "movie.mov", "backup.tar.gz"))
        #expect(model.toolOutputsSeen == [ToolOutput.search(result, now: Fixtures.now)])
        #expect(model.script.requests.count == 2)
    }

    @Test func theConversationIsRememberedFromTurnToTurnAndEachTurnHasItsOwnEffects() async {
        let model = ScriptedModel(
            ScriptedModel.call("folderSummary"), [.text(["First."])],
            [.text(["Second."])]
        )
        let engine = ChatEngine.scripted(model)
        let first = await engine.ask("One")
        #expect(first.effects.results.count == 1)
        let second = await engine.ask("Two")
        #expect(second.text == "Second.")
        #expect(second.effects.results.isEmpty)
        #expect(model.promptsInLatestRequest == 2)
    }

    @Test func onANewDayTheModelIsToldTheNewDateAndStillRemembersTheConversation() async throws {
        let clock = Mutex(Fixtures.now)
        let model = ScriptedModel([.text(["Evening."])], [.text(["Morning."])])
        let engine = ChatEngine(model: model, snapshot: { Fixtures.snapshot }, now: { clock.withLock { $0 } })
        _ = await engine.ask("One")
        let tomorrow = Fixtures.daysAgo(-1)
        clock.withLock { $0 = tomorrow }
        #expect(await engine.ask("Two").text == "Morning.")

        // One set of instructions, naming the new day, and both questions.
        let transcript = try #require(model.script.requests.last).transcript
        let instructions = transcript.compactMap { entry -> String? in
            guard case .instructions(let instructions) = entry else { return nil }
            return instructions.segments.compactMap { if case .text(let text) = $0 { text.content } else { nil } }.joined()
        }
        #expect(instructions == [PromptLibrary.chatInstructions(today: tomorrow)])
        #expect(model.promptsInLatestRequest == 2)
    }

    // MARK: - Repeated lookups

    @Test func theSameLookupAgainInOneTurnRunsOnceAndTheModelIsToldItHasTheResult() async {
        // What the owner saw: the model looked the same thing up three times, and each lookup drew
        // its own "All items" line above the answer.
        let model = ScriptedModel(
            ScriptedModel.call("folderSummary"), ScriptedModel.call("folderSummary"), ScriptedModel.call("folderSummary"),
            [.text(["You have 21 items."])]
        )
        let reads = Collected<Void>()
        let turn = await ChatEngine.scripted(model, reads: reads).ask("How many files do I have?")
        #expect(turn.outcome == .answered)
        #expect(turn.effects.results.count == 1)
        #expect(reads.all.count == 1)
        let outputs = model.toolOutputsSeen
        #expect(outputs.count == 3)
        #expect(outputs.dropFirst().allSatisfy { $0 == ToolOutput.repeated })
    }

    @Test func anIdenticalSearchIsRecordedOnceAndADifferentOneStillRuns() async {
        let images = #"{"filter":{"typeGroup":"images"},"sort":"largest"}"#
        // Seen with the real model: everything, then everything again with a limit of 1.
        let imagesFirstOne = #"{"filter":{"typeGroup":"images"},"sort":"largest","limit":1}"#
        let model = ScriptedModel(
            ScriptedModel.call("searchFiles", images), ScriptedModel.call("searchFiles", imagesFirstOne),
            ScriptedModel.call("searchFiles", #"{"filter":{"typeGroup":"audio"}}"#),
            [.text(["Done."])]
        )
        let turn = await ChatEngine.scripted(model).ask()
        #expect(turn.outcome == .answered)
        #expect(turn.effects.results.count == 2)
        #expect(model.toolOutputsSeen[1] == ToolOutput.repeated)
    }

    @Test func aSearchForMoreOfTheSameFilesRunsAndTakesTheEarlierOnesPlace() async {
        let model = ScriptedModel(
            ScriptedModel.call("searchFiles", #"{"filter":{"typeGroup":"images"},"limit":1}"#),
            ScriptedModel.call("searchFiles", #"{"filter":{"typeGroup":"images"},"sort":"largest"}"#),
            [.text(["Three images."])]
        )
        let turn = await ChatEngine.scripted(model).ask()
        #expect(model.toolOutputsSeen.allSatisfy { $0 != ToolOutput.repeated })
        // One line for the images, with all three listed in the second search's order.
        guard case .search(let images) = turn.effects.results.first, turn.effects.results.count == 1 else {
            Issue.record("Not one search recorded")
            return
        }
        #expect(images.files.map(\.name) == ["holiday.jpg", "old-photo.heic", "screenshot.png"])
    }

    @Test func aDuplicateScanThatCouldNotRunMayBeTriedAgainInTheSameTurn() async {
        let tries = Collected<Void>()
        let model = ScriptedModel(ScriptedModel.call("findDuplicates"), ScriptedModel.call("findDuplicates"), [.text(["Found one."])])
        let turn = await ChatEngine.scripted(model, duplicates: {
            tries.add(())
            return tries.all.count == 1 ? nil : Fixtures.duplicates
        }).ask()
        #expect(model.toolOutputsSeen == [ToolOutput.duplicatesUnavailable, ToolOutput.duplicates(Fixtures.duplicates)])
        #expect(turn.effects.results == [.duplicates(Fixtures.duplicates)])
    }

    // MARK: - Long conversations

    @Test func aLongConversationCountsItsTokensOnceOrTwiceATurn() async {
        let counts = Collected<Void>()
        let meter = ContextMeter(contextSize: 3_000) { entries in
            counts.add(())
            return ScriptedModel.size(of: entries)
        }
        let rounds = (1...20).flatMap { index in
            [ScriptedModel.call("searchFiles", #"{"sort":"largest","limit":\#(80 + index)}"#), [.text(["Answer \(index)."])]]
        }
        let engine = ChatEngine.scripted(ScriptedModel(rounds: rounds, contextLimit: 3_000), meter: meter)
        var perTurn: [Int] = []
        for index in 1...20 {
            let before = counts.all.count
            #expect(await engine.ask("Question \(index) about my files?").outcome == .answered)
            perTurn.append(counts.all.count - before)
        }
        // Each turn starts from one more turn than the last showed: once old turns drop out, that
        // is one count that is over the budget and one that fits, however long the conversation.
        #expect(perTurn.allSatisfy { $0 <= 2 }, "\(perTurn)")
    }

    @Test func anEarlierTurnsLookupsReachTheModelAsTheirFirstLineOnly() async throws {
        let model = ScriptedModel(
            ScriptedModel.call("searchFiles", #"{"filter":{"typeGroup":"images"}}"#), [.text(["Three images."])],
            ScriptedModel.call("folderSummary"), [.text(["Here is the folder."])]
        )
        let engine = ChatEngine.scripted(model)
        let first = await engine.ask("Which images?")
        let second = await engine.ask("And the folder?")
        guard case .search(let images) = first.effects.results.first, case .summary(let summary) = second.effects.results.first else {
            Issue.record("A lookup was not recorded")
            return
        }
        let search = ToolOutput.search(images, now: Fixtures.now)
        #expect(search.contains("\n"))
        // The app drew the first turn's full list when it arrived; the model keeps what was found,
        // and still reads the turn in progress whole.
        #expect(model.toolOutputsSeen == [String(search.prefix { $0 != "\n" }), ToolOutput.summary(summary)])
        #expect(model.promptsInLatestRequest == 2)
    }

    @Test func twentyQuestionsInARowAllFitWithoutStartingOver() async throws {
        // Each question makes a lookup whose output is near the cap. Kept in full, three or four
        // of them fill the scripted context, as three questions filled the real one.
        let rounds = (1...20).flatMap { index in
            [ScriptedModel.call("searchFiles", #"{"sort":"largest","limit":\#(80 + index)}"#), [.text(["Answer \(index)."])]]
        }
        let model = ScriptedModel(rounds: rounds, contextLimit: 3_000)
        let engine = ChatEngine.scripted(model, meter: .characters(3_000))
        for index in 1...20 {
            let turn = await engine.ask("Question \(index) about my files?")
            #expect(turn.outcome == .answered, "question \(index)")
            #expect(turn.text == "Answer \(index).", "question \(index)")
            #expect(turn.effects.results.count == 1, "question \(index)")
            #expect(!turn.startedOver, "question \(index)")
        }
        // The model still has the latest questions in front of it, the oldest no longer.
        let prompts = try #require(model.script.requests.last).transcript.compactMap { entry -> String? in
            guard case .prompt(let prompt) = entry else { return nil }
            return prompt.segments.compactMap { if case .text(let text) = $0 { text.content } else { nil } }.joined()
        }
        let latest = try #require(model.script.requests.last).transcript
        guard case .instructions = latest.first else {
            Issue.record("The instructions were dropped")
            return
        }
        #expect(prompts.count >= 3)
        #expect(prompts.last == "Question 20 about my files?")
        #expect(!prompts.contains("Question 1 about my files?"))
    }

    // MARK: - Guards

    @Test func aFifthToolCallInATurnNeverRuns() async {
        // Five different lookups: the same one again runs only once anyway.
        let model = ScriptedModel(
            rounds: ["report", "photo", "song", "clip", "notes"].map { ScriptedModel.call("searchFiles", #"{"filter":{"nameContains":"\#($0)"}}"#) }
                + [[.text(["Never reached."])]]
        )
        let reads = Collected<Void>()
        let engine = ChatEngine.scripted(model, reads: reads)
        let turn = await engine.ask()
        #expect(turn.outcome == .toolLimitReached)
        #expect(turn.text.isEmpty)
        #expect(reads.all.count == ChatEngine.toolCallLimit)
        #expect(turn.effects.results.count == ChatEngine.toolCallLimit)
        // The model was not asked again after the refused call.
        #expect(model.script.requests.count == 5)

        // The budget is per turn: the next one starts with all four calls again.
        let next = await engine.ask()
        #expect(next.outcome == .answered)
        #expect(next.text == "Never reached.")
    }

    @Test func toolCallsThatArriveTogetherShareTheSameBudget() async {
        let six = Array(repeating: ScriptedModel.ToolCall(name: "searchFiles", arguments: "{}"), count: 6)
        let model = ScriptedModel([.toolCalls(six)], [.text(["Never reached."])])
        let reads = Collected<Void>()
        let turn = await ChatEngine.scripted(model, reads: reads).ask()
        #expect(turn.outcome == .toolLimitReached)
        #expect(reads.all.count <= ChatEngine.toolCallLimit)
        #expect(turn.effects.results.count <= ChatEngine.toolCallLimit)
        #expect(model.script.requests.count == 1)
    }

    @Test func aToolThatIsNotRegisteredNeverRuns() async {
        let trash = ScriptedModel.call("moveToTrash", #"{"name":"report.pdf"}"#)
        let model = ScriptedModel(trash, trash, [.text(["Done."])])
        let reads = Collected<Void>()
        let engine = ChatEngine.scripted(model, reads: reads)
        let turn = await engine.ask("Delete report.pdf")
        // Asked again once in a fresh conversation, as any failure is, and refused again.
        #expect(turn.outcome == .failed)
        #expect(turn.startedOver)
        #expect(turn.text.isEmpty)
        #expect(reads.all.isEmpty)
        #expect(turn.effects.results.isEmpty)
        #expect(model.script.requests.count == 2)
    }

    @Test func aTurnEndsAtTheTimeLimitEvenWhenTheModelWillNotStop() async {
        let model = ScriptedModel(
            [.text(["Thinking "]), .stall(.seconds(3)), .text(["too late"])],
            [.text(["Quick."])]
        )
        let engine = ChatEngine.scripted(model, turnLimit: .milliseconds(300))
        let clock = ContinuousClock()
        let started = clock.now
        let turn = await engine.ask()
        #expect(turn.outcome == .timedOut)
        #expect(turn.text == "Thinking ")
        #expect(clock.now - started < .seconds(2))

        // The engine is usable at once, while the abandoned reply is still running behind it.
        let next = await engine.ask()
        #expect(next.outcome == .answered)
        #expect(next.text == "Quick.")
    }

    @Test func stopMidStreamKeepsTheTextSoFarAndTheNextTurnWorks() async {
        let model = ScriptedModel(
            [.text(["Looking "]), .wait(.seconds(30)), .text(["never shown"])],
            [.text(["Second answer."])]
        )
        let engine = ChatEngine.scripted(model)
        let seen = Collected<String>()
        // A child task is what gets cancelled: cancelling the test's own task would skip the test.
        let asking = Task { await engine.respond(to: "First") { seen.add($0) } }
        #expect(await seen.waitFor { $0 == "Looking " })
        let clock = ContinuousClock()
        let stopped = clock.now
        asking.cancel()
        let turn = await asking.value
        #expect(turn.outcome == .stopped)
        #expect(turn.text == "Looking ")
        #expect(clock.now - stopped < .seconds(2))

        let next = await engine.ask("Second")
        #expect(next.outcome == .answered)
        #expect(next.text == "Second answer.")
        // The stopped question is not part of what the model remembers.
        #expect(model.promptsInLatestRequest == 1)
    }

    // MARK: - Typed outcomes

    @Test func aGuardrailRefusalIsAnOutcomeAndLeavesTheConversationAsItWas() async {
        let model = ScriptedModel(
            [.text(["First."])],
            [.text(["I "]), .fail(LanguageModelError.guardrailViolation(.init(debugDescription: "scripted")))],
            [.text(["Third."])]
        )
        let engine = ChatEngine.scripted(model)
        _ = await engine.ask("One")
        let refused = await engine.ask("Two")
        #expect(refused.outcome == .refused)
        let third = await engine.ask("Three")
        #expect(third.outcome == .answered)
        // The model remembers turns one and three, not the refused one.
        #expect(model.promptsInLatestRequest == 2)
    }

    @Test func aRefusalByTheModelIsTheSameOutcome() async {
        let refusal = LanguageModelError.refusal(.init(explanation: "No.", debugDescription: "scripted"))
        let turn = await ChatEngine.scripted(ScriptedModel([.fail(refusal)])).ask()
        #expect(turn.outcome == .refused)
    }

    private static let full = LanguageModelError.contextSizeExceeded(.init(contextSize: 4096, tokenCount: 5000, debugDescription: "scripted"))

    @Test func aFullContextAsksTheSameQuestionAgainInAFreshConversationThatKeepsTheLastTwo() async {
        let model = ScriptedModel(
            [.text(["First."])], [.text(["Second."])], [.text(["Third."])],
            [.text(["Half "]), .fail(Self.full)], [.text(["Retried."])],
            [.text(["Fine."])]
        )
        let engine = ChatEngine.scripted(model)
        for question in ["One", "Two", "Three"] { _ = await engine.ask(question) }
        let seen = Collected<String>()
        let turn = await engine.respond(to: "Four") { seen.add($0) }
        // Answered in the same turn: the user never has to ask again.
        #expect(turn.outcome == .answered)
        #expect(turn.text == "Retried.")
        #expect(turn.startedOver)
        // The text so far was cleared before the second try began.
        #expect(seen.all.contains(""))
        #expect(seen.all.last == "Retried.")
        // "Two", "Three" and the question itself.
        #expect(model.promptsInLatestRequest == 3)
        // The fresh conversation goes on from there.
        let next = await engine.ask("Five")
        #expect(next.text == "Fine.")
        #expect(!next.startedOver)
        #expect(model.promptsInLatestRequest == 4)
    }

    @Test func aContextStillFullOnTheSecondTryIsAnOutcomeAndTheNextTurnStartsFresh() async {
        let model = ScriptedModel([.text(["First."])], [.fail(Self.full)], [.fail(Self.full)], [.text(["Fresh."])])
        let engine = ChatEngine.scripted(model)
        _ = await engine.ask("One")
        let overflowed = await engine.ask("Two")
        #expect(overflowed.outcome == .contextFull)
        #expect(overflowed.startedOver)
        let next = await engine.ask("Three")
        #expect(next.outcome == .answered)
        #expect(next.text == "Fresh.")
        #expect(model.promptsInLatestRequest == 1)
    }

    @Test(arguments: [
        IntelligenceAvailability.turnedOffInSystemSettings, .modelDownloading, .deviceNotEligible,
        .languageNotSupported, .turnedOffInSettings,
    ])
    func anUnavailableModelIsNeverAsked(state: IntelligenceAvailability) async {
        let model = ScriptedModel([.text(["Should not be said."])])
        let engine = ChatEngine.scripted(model, availability: { state })
        await engine.prewarm()
        let turn = await engine.ask()
        #expect(turn.outcome == .unavailable(state))
        #expect(turn.text.isEmpty)
        #expect(model.script.requests.isEmpty)
    }

    @Test func aModelThatGoesAwayMidTurnIsReportedAsUnavailable() async {
        let gone = SystemLanguageModel.Error.assetsUnavailable(.init(debugDescription: "scripted"))
        let turn = await ChatEngine.scripted(ScriptedModel([.text(["Half "]), .fail(gone)])).ask()
        #expect(turn.outcome == .unavailable(.modelDownloading))

        // Turned off in System Settings while a reply was on its way: whatever the error, that is the reason.
        let checks = Mutex(0)
        let engine = ChatEngine.scripted(
            ScriptedModel([.fail(CancellationError())]),
            availability: {
                checks.withLock { $0 += 1 }
                return checks.withLock { $0 } == 1 ? .available : .turnedOffInSystemSettings
            }
        )
        let second = await engine.ask()
        #expect(second.outcome == .unavailable(.turnedOffInSystemSettings))
    }

    @Test func aFullContextInTheToolLoopIsRecognisedByThePrivateErrorTheSystemThrowsThere() async {
        // What macOS 27.2 throws when a tool's output no longer fits, in place of `contextSizeExceeded`.
        let full = NSError(domain: "com.apple.GenerativeFunctionsFoundation.GenerativeError", code: 4_050_000)
        let model = ScriptedModel(
            [.text(["First."])], ScriptedModel.call("folderSummary"), [.fail(full)], [.fail(full)], [.text(["Fresh."])]
        )
        let engine = ChatEngine.scripted(model)
        _ = await engine.ask("One")
        let overflowed = await engine.ask("Two")
        #expect(overflowed.outcome == .contextFull)
        #expect(overflowed.startedOver)
        #expect(await engine.ask("Three").text == "Fresh.")
        #expect(model.promptsInLatestRequest == 1)
    }

    @Test func anyOtherErrorIsAskedAgainOnceAndThenAPlainFailure() async {
        struct Odd: Error {}
        // An error nobody recognised may be a full context under another name, which would fail
        // every later turn: the question is asked again in a fresh conversation.
        let once = ScriptedModel([.text(["First."])], [.fail(Odd())], [.text(["Fine."])])
        let recovered = await {
            let engine = ChatEngine.scripted(once)
            _ = await engine.ask("One")
            return await engine.ask("Two")
        }()
        #expect(recovered.outcome == .answered)
        #expect(recovered.text == "Fine.")
        #expect(recovered.startedOver)

        let twice = ScriptedModel([.text(["First."])], [.fail(Odd())], [.fail(Odd())], [.text(["Fresh."])])
        let engine = ChatEngine.scripted(twice)
        _ = await engine.ask("One")
        #expect(await engine.ask("Two").outcome == .failed)
        #expect(await engine.ask("Three").text == "Fresh.")
        #expect(twice.promptsInLatestRequest == 1)
    }
}
