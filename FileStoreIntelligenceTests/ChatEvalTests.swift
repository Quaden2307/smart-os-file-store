import FileStoreIntelligence
import Foundation
import FoundationModels
import Testing

/// Which lookup the real on-device model makes for questions whose right lookup is known, over the
/// fixture folder. Each question is asked in a fresh conversation. Results go to the test log as
/// warnings starting `CHAT EVAL`; a wrong lookup also fails the test.
///
/// It needs Apple Intelligence, so like the measurements it runs from the `Benchmark` plan only.
/// These are a few fixed cases, not the evaluation harness planned for later.
@Suite(
    "Chat evals",
    .serialized,
    .timeLimit(.minutes(20)),
    .enabled(if: ProcessInfo.processInfo.environment["SMARTOS_RUN_BENCHMARK"] == "1", "runs from the Benchmark test plan only")
)
struct ChatEvalTests {
    /// Ways of asking about copies. The answer must come from reading the files (`findDuplicates`),
    /// never from the Duplicate mark, which only the last Tidy Now sets.
    static let duplicateQuestions = [
        "How many duplicate files are there?",
        "Do I have any duplicates?",
        "Are there copies of the same file?",
        "Did I download the same file twice?",
        "Which files are identical?",
        "Do I have anything more than once?",
    ]

    /// Questions that are not about copies.
    static let otherQuestions = [
        "How many files do I have?",
        "What's taking the most space?",
        "Which installers are here?",
    ]

    private static func report(_ text: String) {
        Issue.record("CHAT EVAL \(text)", severity: .warning)
    }

    private func ask(_ question: String) async -> Turn? {
        guard SystemLanguageModel.default.isAvailable else {
            Self.report("not run: Apple Intelligence is \(SystemLanguageModel.default.availability) on this Mac")
            return nil
        }
        let engine = ChatEngine(
            model: SystemLanguageModel.default, snapshot: { Fixtures.snapshot }, findDuplicates: { _ in Fixtures.duplicates },
            cleanupActions: Fixtures.cleanupActions, proposeCleanup: Fixtures.proposal, now: { Fixtures.now }, meter: .system
        )
        let turn = await engine.respond(to: question) { _ in }
        let lookups = turn.effects.results.map { result in
            switch result {
            case .search: "searchFiles"
            case .summary: "folderSummary"
            case .duplicates: "findDuplicates"
            case .cleanup: "proposeCleanup"
            }
        }
        Self.report("\"\(question)\": \(turn.outcome), lookups \(lookups), reply \"\(turn.text)\"")
        return turn
    }

    private static func scannedForDuplicates(_ turn: Turn) -> Bool {
        turn.effects.results.contains { if case .duplicates = $0 { true } else { false } }
    }

    // MARK: - Follow-ups (docs/decisions/0022)

    /// One conversation with the real model over the fixture folder.
    private func conversation() -> ChatEngine? {
        guard SystemLanguageModel.default.isAvailable else {
            Self.report("not run: Apple Intelligence is \(SystemLanguageModel.default.availability) on this Mac")
            return nil
        }
        return ChatEngine(
            model: SystemLanguageModel.default, snapshot: { Fixtures.snapshot }, findDuplicates: { _ in Fixtures.duplicates },
            cleanupActions: Fixtures.cleanupActions, proposeCleanup: Fixtures.proposal, now: { Fixtures.now }, meter: .system
        )
    }

    /// Asks in `engine` and reports the turn; `stoppingAfter` presses Stop that long into it.
    private func say(_ message: String, in engine: ChatEngine, stoppingAfter delay: Duration? = nil) async -> Turn {
        let asking = Task { await engine.respond(to: message) { _ in } }
        if let delay {
            try? await Task.sleep(for: delay)
            asking.cancel()
        }
        let turn = await asking.value
        let lookups = turn.effects.results.map { result in
            switch result {
            case .search(let search):
                var query = search.query
                query.withinIDs = nil
                let rest = [
                    query.typeGroup.map { "\($0)" }, query.nameContains.map { "name \($0)" }, query.minBytes.map { "min \($0)" },
                    query.maxBytes.map { "max \($0)" }, query.mark.map { "mark \($0)" }, query.neverOpened ? "never opened" : nil,
                    query.added == FileQuery.DateRange() ? nil : "added range", query.opened == FileQuery.DateRange() ? nil : "opened range",
                ].compactMap { $0 }.map { $0 + ", " }.joined()
                return "searchFiles(\(search.query.withinIDs == nil ? "" : "in last result, ")\(rest)\(search.sort.rawValue))"
                    + " -> \(search.matchCount): \(search.files.map(\.name))"
            case .summary: return "folderSummary"
            case .duplicates: return "findDuplicates"
            case .cleanup(let proposal):
                let narrowed = proposal.request.fileIDs(in: Fixtures.snapshot).map { "\($0.count) files" } ?? "every file"
                return "proposeCleanup(\(proposal.request.actions), \(narrowed), days \(proposal.request.archiveAfterDays ?? 0), MB \(proposal.request.largeFileMB ?? 0))"
            }
        }
        Self.report("\"\(message)\": \(turn.outcome), \(turn.tokensBeforeReply ?? 0) tokens before, lookups \(lookups), reply \"\(turn.text)\"")
        return turn
    }

    private static func search(_ turn: Turn) -> FileSearchResult? {
        if case .search(let result) = turn.effects.results.last { result } else { nil }
    }

    @Test(arguments: ["only the big ones", "just the large ones"])
    func theBigOnesNarrowsWhatWasJustFound(message: String) async throws {
        guard let engine = conversation() else { return }
        let first = try #require(Self.search(await say("Which files are larger than 50 MB?", in: engine)))
        let big = try #require(Self.search(await say(message, in: engine)), "no search for \"\(message)\"")
        #expect(Set(big.matchIDs).isSubset(of: first.matchIDs))
        // Exactly the two over the size, with no filter the message did not ask for.
        #expect(Set(big.files.map(\.name)) == ["Xcode.dmg", "movie.mov"])
        // The app's own size for a large download, which the note names.
        #expect(big.query.minBytes == 500_000_000)
    }

    @Test func sortingThoseKeepsTheFilesJustFoundAndOrdersThem() async throws {
        guard let engine = conversation() else { return }
        let first = try #require(Self.search(await say("Which images are here?", in: engine)))
        let those = try #require(Self.search(await say("sort those by size", in: engine)))
        #expect(Set(those.matchIDs) == Set(first.matchIDs))
        #expect(those.sort == .largest)
        #expect(those.files.first?.name == "holiday.jpg")
    }

    /// A question about one of "those": the files looked at must be the ones just found. Their
    /// order on the card is the model's choice, so the answer is right when the card starts with
    /// the file or the sentence names it.
    @Test func aQuestionAboutThoseLooksAtTheFilesJustFound() async throws {
        guard let engine = conversation() else { return }
        let first = try #require(Self.search(await say("Which images are here?", in: engine)))
        let turn = await say("which of those is the biggest?", in: engine)
        let those = try #require(Self.search(turn))
        #expect(Set(those.matchIDs) == Set(first.matchIDs))
        #expect(those.files.first?.name == "holiday.jpg" || turn.text.contains("holiday.jpg"))
    }

    /// The first three are answered by code (`ChatMemory.isContinue`); the last is the model's to
    /// understand from the note.
    @Test(arguments: ["Continue", "keep going please", "finish what you were doing", "pick up where you left off"])
    func afterStopTheStoppedQuestionIsAnswered(message: String) async throws {
        guard let engine = conversation() else { return }
        #expect(await say("Which files are over 500 MB?", in: engine, stoppingAfter: .milliseconds(300)).outcome == .stopped)
        let turn = await say(message, in: engine)
        #expect(turn.outcome == .answered)
        let result = try #require(Self.search(turn), "no search for \"\(message)\"")
        #expect(Set(result.files.map(\.name)) == ["Xcode.dmg", "movie.mov"])
    }

    // MARK: - Cleanups (docs/decisions/0023)

    private static func card(_ turn: Turn) -> CleanupProposal? {
        turn.effects.results.lazy.compactMap { if case .cleanup(let proposal) = $0 { proposal } else { nil } }.last
    }

    /// A cleanup asked for in plain words becomes a card for the action meant, and the reply never
    /// claims a file was changed.
    @Test(arguments: [
        ("Remove the installers I've already used.", "removeUsedInstallers"),
        ("Get rid of duplicate files.", "findDuplicates"),
        ("Fix the messy file names.", "fixMessyNames"),
        ("Archive my old downloads.", "archiveOldDownloads"),
        ("Clear out the failed downloads.", "clearFailedDownloads"),
    ])
    func aCleanupAskedForInWordsBecomesACardForThatAction(message: String, action: String) async throws {
        guard let engine = conversation() else { return }
        let turn = await say(message, in: engine)
        #expect(turn.outcome == .answered)
        let card = try #require(Self.card(turn), "no card for \"\(message)\"")
        #expect(card.request.actions.contains(action))
        let reply = turn.text.lowercased()
        #expect(!["deleted", "removed", "renamed", "archived", "moved", "cleared"].contains { reply.contains("have been \($0)") || reply.contains("were \($0)") || reply.contains("i \($0)") || reply.contains("i've \($0)") })
    }

    @Test func tidyingEverythingAsksForEveryAction() async throws {
        guard let engine = conversation() else { return }
        let card = try #require(Self.card(await say("Tidy up my whole Downloads folder.", in: engine)))
        #expect(card.request.actions.count >= 5)
        #expect(card.request.query == nil)
    }

    @Test func aCleanupWithAFilterIsNarrowedToIt() async throws {
        guard let engine = conversation() else { return }
        let card = try #require(Self.card(await say("Archive the files I downloaded before September and never opened.", in: engine)))
        #expect(card.request.actions == ["archiveOldDownloads"])
        let query = try #require(card.request.query)
        #expect(query.neverOpened)
        #expect(query.added.before != nil)
        // Exactly the two that fit, whatever day in September the model wrote.
        #expect(Set(Fixtures.files.filter(query.matches).map(\.name)) == ["old-photo.heic", "backup.tar.gz"])
    }

    @Test func cleaningThoseUpPlansForTheFilesJustFound() async throws {
        guard let engine = conversation() else { return }
        let first = try #require(Self.search(await say("Which installers are here?", in: engine)))
        let card = try #require(Self.card(await say("clean those up", in: engine)))
        let ids = try #require(card.request.fileIDs(in: Fixtures.snapshot))
        #expect(ids == Set(first.matchIDs))
        // A card is not a list: "those" are still the installers.
        let turn = await say("Which of those is the largest?", in: engine)
        let those = try #require(Self.search(turn))
        #expect(Set(those.matchIDs).isSubset(of: first.matchIDs))
        #expect(those.files.first?.name == "Xcode.dmg" || turn.text.contains("Xcode.dmg"))
    }

    /// What the app cannot do gets a short answer and no card.
    @Test(arguments: [
        "Move my invoices to the Documents folder.",
        "Permanently delete report.pdf so it can't be recovered.",
        // "Clean up my Desktop." left this list when Desktop could be managed (0029); the folder
        // evals ask it of a home with a Desktop.
        "Change the grace period to ten minutes.",
        "undo that",
    ])
    func whatTheAppCannotDoMakesNoCard(message: String) async throws {
        guard let engine = conversation() else { return }
        _ = await say("Which installers are here?", in: engine)
        let turn = await say(message, in: engine)
        #expect(turn.outcome == .answered)
        #expect(Self.card(turn) == nil, "a card for \"\(message)\"")
    }

    @Test func aNameIsSearchedForByName() async throws {
        let turn = try #require(await ask("Find files with report in the name."))
        let result = try #require(Self.search(turn))
        #expect(result.query.nameContains?.localizedCaseInsensitiveContains("report") == true)
        #expect(result.matchCount == 3)
    }

    @Test func neverOpenedIsAskedForAsSuchAndLeavesOutWhatCannotBeTold() async throws {
        let turn = try #require(await ask("Which files have I never opened?"))
        let result = try #require(Self.search(turn))
        #expect(result.query.neverOpened)
        // The model's sentence echoes the question's "never opened" whatever its lookup is told
        // (measured, 0022); the card is what says "no open recorded", in the app's words.
        #expect(result.unknownOpenCount == 2)
        #expect(!result.matchIDs.contains { $0.lastPathComponent == "setup.dmg.crdownload" })
    }

    @Test(arguments: duplicateQuestions)
    func aQuestionAboutCopiesReadsTheFiles(question: String) async {
        guard let turn = await ask(question) else { return }
        #expect(turn.outcome == .answered)
        #expect(Self.scannedForDuplicates(turn), "no findDuplicates for \"\(question)\"")
    }

    @Test(arguments: otherQuestions)
    func otherQuestionsDoNotScanForCopies(question: String) async {
        guard let turn = await ask(question) else { return }
        #expect(turn.outcome == .answered)
        #expect(!turn.effects.results.isEmpty, "no lookup for \"\(question)\"")
        #expect(!Self.scannedForDuplicates(turn), "findDuplicates for \"\(question)\"")
    }
}
