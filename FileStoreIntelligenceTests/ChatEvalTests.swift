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
            model: SystemLanguageModel.default, snapshot: { Fixtures.snapshot }, findDuplicates: { Fixtures.duplicates },
            now: { Fixtures.now }, meter: .system
        )
        let turn = await engine.respond(to: question) { _ in }
        let lookups = turn.effects.results.map { result in
            switch result {
            case .search: "searchFiles"
            case .summary: "folderSummary"
            case .duplicates: "findDuplicates"
            }
        }
        Self.report("\"\(question)\": \(turn.outcome), lookups \(lookups), reply \"\(turn.text)\"")
        return turn
    }

    private static func scannedForDuplicates(_ turn: Turn) -> Bool {
        turn.effects.results.contains { if case .duplicates = $0 { true } else { false } }
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
