import FileStoreIntelligence
import Foundation
import FoundationModels
import Testing
import UniformTypeIdentifiers

/// Which folder the real on-device model asks about for folder wording ("on my desktop", "in
/// docs", "everywhere", no folder at all), over three folders with Downloads on screen. Each
/// question is asked in a fresh conversation. Results go to the test log as `CHAT EVAL FOLDER`
/// warnings with the pass rate; a wrong folder or tool also fails the test. Evals plan only.
@Suite(
    "Chat folder evals",
    .serialized,
    .timeLimit(.minutes(20)),
    .enabled(if: ProcessInfo.processInfo.environment["SMARTOS_RUN_EVALS"] == "1", "runs from the Evals test plan only")
)
struct FolderChatEvalTests {
    struct Case: Sendable, CustomStringConvertible {
        let question: String
        /// The tool the answer must come from.
        let tool: String
        /// The folder it must be about: a name, or "all".
        let folder: String
        var description: String { question }
    }

    static let cases: [Case] = [
        Case(question: "How many files are on my Desktop?", tool: "lookup", folder: "Desktop"),
        Case(question: "What's on the desktop?", tool: "lookup", folder: "Desktop"),
        Case(question: "What are my biggest files everywhere?", tool: "lookup", folder: "all"),
        Case(question: "Show the biggest files in all my folders", tool: "lookup", folder: "all"),
        Case(question: "How many files do I have?", tool: "lookup", folder: "Downloads"),
        Case(question: "What's taking the most space?", tool: "lookup", folder: "Downloads"),
        Case(question: "Which installers are here?", tool: "lookup", folder: "Downloads"),
        Case(question: "Which PDFs are in Documents?", tool: "lookup", folder: "Documents"),
        Case(question: "How much space does my Documents folder use?", tool: "lookup", folder: "Documents"),
        Case(question: "Show me large files in docs", tool: "lookup", folder: "Documents"),
        Case(question: "List the files in every folder", tool: "lookup", folder: "all"),
        Case(question: "Any duplicates on my Desktop?", tool: "findDuplicates", folder: "Desktop"),
        Case(question: "Find copies in docs", tool: "findDuplicates", folder: "Documents"),
        Case(question: "Clean up the duplicates on my Desktop", tool: "proposeCleanup", folder: "Desktop"),
        Case(question: "Clean up duplicates everywhere", tool: "proposeCleanup", folder: "all"),
        Case(question: "Tidy up my desktop", tool: "proposeCleanup", folder: "Desktop"),
    ]

    private static func file(_ name: String, in folder: String, megabytes: Double) -> FolderSnapshot.File {
        FolderSnapshot.File(
            id: URL(filePath: "/tmp/Home/\(folder)/\(name)"), name: name, contentType: .pdf,
            sizeInBytes: Int64(megabytes * 1_000_000), dateAdded: Fixtures.daysAgo(10), folder: folder
        )
    }

    static let snapshot: FolderSnapshot = {
        let downloads = Fixtures.files.map { file in
            var copy = file
            copy.folder = "Downloads"
            return copy
        }
        return FolderSnapshot(
            files: downloads + [
                file("Screenshot 2026-11-02.png", in: "Desktop", megabytes: 2), file("draft.pdf", in: "Desktop", megabytes: 1),
                file("report-final.pdf", in: "Documents", megabytes: 3), file("report-final-v2.pdf", in: "Documents", megabytes: 3),
            ],
            folders: [.init(name: "Downloads", isCurrent: true), .init(name: "Desktop"), .init(name: "Documents")],
            now: Fixtures.now
        )
    }()

    private static func report(_ text: String) {
        Issue.record("CHAT EVAL FOLDER \(text)", severity: .warning)
    }

    private static let passes = Collected<Bool>()

    /// What the turn looked up, as (tool, folder).
    private static func lookups(_ turn: Turn, scopes: [FolderScope]) -> [(String, String)] {
        func name(_ scope: FolderScope?) -> String {
            switch scope {
            case .folder(let name): name
            case .all: "all"
            case nil: "?"
            }
        }
        var found: [(String, String)] = turn.effects.results.compactMap { result in
            switch result {
            case .search(let search): ("lookup", name(search.scope))
            case .summary(let summary): ("lookup", name(summary.scope))
            case .duplicates: nil
            case .cleanup(let proposal): ("proposeCleanup", proposal.request.folder ?? "?")
            }
        }
        found += scopes.map { ("findDuplicates", name($0)) }
        // A cleanup everywhere is one card per folder: it counts as all.
        if found.filter({ $0.0 == "proposeCleanup" }).count == 3 {
            found = found.filter { $0.0 != "proposeCleanup" } + [("proposeCleanup", "all")]
        }
        return found
    }

    @Test(arguments: FolderChatEvalTests.cases)
    func theModelAsksAboutTheFolderTheQuestionMeans(_ evalCase: Case) async throws {
        guard SystemLanguageModel.default.isAvailable else {
            Self.report("not run: Apple Intelligence is \(SystemLanguageModel.default.availability) on this Mac")
            return
        }
        let scopes = Collected<FolderScope>()
        let engine = ChatEngine(
            model: SystemLanguageModel.default, snapshot: { Self.snapshot },
            findDuplicates: { scope in
                scopes.add(scope)
                return Fixtures.duplicates
            },
            cleanupActions: Fixtures.cleanupActions, proposeCleanup: Fixtures.proposal, now: { Fixtures.now }, meter: .system
        )
        let turn = await engine.respond(to: evalCase.question) { _ in }
        let found = Self.lookups(turn, scopes: scopes.all)
        let passed = found.contains { $0.0 == evalCase.tool && $0.1 == evalCase.folder }
        Self.passes.add(passed)
        let rate = Self.passes.all.count(where: \.self)
        Self.report("\"\(evalCase.question)\": \(passed ? "pass" : "FAIL"), looked up \(found), reply \"\(turn.text)\" (\(rate) of \(Self.passes.all.count) so far)")
        #expect(passed, "\(evalCase.question): looked up \(found)")
    }

    // MARK: - The demo home's three questions (docs/demo.md)

    /// The demo home as the chat sees it: names from scripts/make-demo-home.sh, the three
    /// installers marked Installed, Downloads on screen.
    static let demoSnapshot: FolderSnapshot = {
        func file(_ name: String, _ folder: String, _ megabytes: Double, marks: Set<FolderSnapshot.Mark> = [], type: UTType? = .pdf) -> FolderSnapshot.File {
            FolderSnapshot.File(
                id: URL(filePath: "/tmp/SmartOSDemo/Home/\(folder)/\(name)"), name: name, contentType: type,
                sizeInBytes: Int64(megabytes * 1_000_000), dateAdded: Fixtures.daysAgo(20), marks: marks, folder: folder
            )
        }
        return FolderSnapshot(
            files: [
                file("Sketchpad-3.2.dmg", "Downloads", 0.02, marks: [.installed], type: .diskImage),
                file("NoteNest-1.8-mac.zip", "Downloads", 0.01, marks: [.installed], type: .zip),
                file("Tasker-2.0.pkg", "Downloads", 0.02, marks: [.installed], type: UTType("com.apple.installer-package-archive")),
                file("Product Demo 4K.mov", "Downloads", 268, type: .quickTimeMovie),
                file("Travel Vlog Lisbon.mp4", "Downloads", 268, type: .mpeg4Movie),
                file("Quarterly Report Q3.pdf", "Downloads", 8.4),
                file("Quarterly Report Q3 (1).pdf", "Downloads", 8.4),
                file("screen-recording.mov", "Desktop", 268, type: .quickTimeMovie),
                file("Screenshot 2026-09-01 at 09.01.22.png", "Desktop", 0.1, type: .png),
                file("Screenshot 2026-09-01 at 09.01.22 copy.png", "Desktop", 0.1, type: .png),
                file("Wedding Photos Export.zip", "Documents", 8.4, type: .zip),
                file("Lease.pdf", "Documents", 8.4),
            ],
            folders: [.init(name: "Downloads", isCurrent: true), .init(name: "Desktop"), .init(name: "Documents")],
            now: Fixtures.now
        )
    }()

    @Test(arguments: [
        Case(question: "Which installers have I already used?", tool: "lookup", folder: "Downloads"),
        Case(question: "What are my biggest files everywhere?", tool: "lookup", folder: "all"),
        Case(question: "Clean up the duplicates on my Desktop", tool: "proposeCleanup", folder: "Desktop"),
    ])
    func theDemoQuestionsAnswerCleanlyThreeTimes(_ evalCase: Case) async throws {
        guard SystemLanguageModel.default.isAvailable else {
            Self.report("not run: Apple Intelligence is \(SystemLanguageModel.default.availability) on this Mac")
            return
        }
        var passes = 0
        for attempt in 1...3 {
            let scopes = Collected<FolderScope>()
            let engine = ChatEngine(
                model: SystemLanguageModel.default, snapshot: { Self.demoSnapshot },
                findDuplicates: { scope in
                    scopes.add(scope)
                    return nil
                },
                cleanupActions: Fixtures.cleanupActions, proposeCleanup: Fixtures.proposal, now: { Fixtures.now }, meter: .system
            )
            let turn = await engine.respond(to: evalCase.question) { _ in }
            let found = Self.lookups(turn, scopes: scopes.all)
            let passed = turn.outcome == .answered && found.contains { $0.0 == evalCase.tool && $0.1 == evalCase.folder }
            passes += passed ? 1 : 0
            let detail = turn.effects.results.map { result -> String in
                if case .search(let search) = result {
                    return "search(\(search.query), sort \(search.sort), \(search.matchCount) found)"
                }
                return "\(result)".prefix(80).description
            }
            Self.report("DEMO \"\(evalCase.question)\" try \(attempt): \(passed ? "pass" : "FAIL"), \(turn.outcome), looked up \(found) \(detail), reply \"\(turn.text)\"")
        }
        #expect(passes == 3, "\(evalCase.question): \(passes) of 3")
    }
}
