import Evaluations
import FileStoreIntelligence
import Foundation
import FoundationModels
import Synchronization

/// What one turn came to: everything the report counts and lists. Built by code from the turn's
/// effects and the app's plans, never from the model's sentence.
struct TurnRecord: Codable, Sendable, Equatable {
    struct Call: Codable, Sendable, Equatable {
        let tool: String
        let arguments: String
    }

    var sampleID: String
    var outcome: String
    /// Every call the model made, refused ones too.
    var calls: [Call]
    /// How many tools ran.
    var toolResults: Int
    /// The card's actions, or nil when the turn made no card.
    var cardActions: [String]?
    /// Every file the card would change, ticked or not.
    var cardFiles: [String]?
    /// The last lookup's files: a search's matches, or the copies Find Duplicates found.
    var listedFiles: [String]?
    var reply: String
    var replyWithheld: Bool
    /// Names in the reply as shown that no file, site or folder has. Must stay empty.
    var unknownNamesShown: [String]
    var trajectoryPassed: Bool
    /// What the code checks on the arguments found wrong.
    var checkProblems: [String]
    /// Kept, grace-period, in-progress or archive items on the card. Must stay empty.
    var untouchablePlanned: [String]
    var seconds: Double
    var firstText: Double?
    var tokens: Int?
    /// What the turn showed, in order: search, summary, duplicates or cleanup.
    var shown: [String] = []
    /// A follow-up's earlier turns, held to the same guarantees; only the last turn is scored.
    var earlier: [TurnRecord] = []

    /// The words of a reply that says a change was already made, which no reply beside a card may
    /// (from 0029's fixed cases). Only checked with a card: a summary may say what the app moved.
    var claimsAChange: Bool {
        let reply = reply.lowercased()
        return cardActions != nil && ["deleted", "removed", "renamed", "archived", "moved", "cleared"].contains { word in
            ["have been", "were", "i", "i've"].contains { reply.contains("\($0) \(word)") }
        }
    }

    /// What the turn ended on: the card's files, else the files listed.
    var files: Set<String>? {
        (cardFiles ?? listedFiles).map(Set.init)
    }

    var calledProposeCleanup: Bool {
        calls.contains { $0.tool == "proposeCleanup" }
    }
}

/// The chat, as the app runs it, over the eval folder: a fresh `ChatEngine` per sample with the
/// app's tools and guards and the app's planning glue (`ChatPlanning`). Only the model is chosen:
/// the on-device one for the real run, a scripted one for the harness's own check.
struct ChatEvaluation: Evaluation {
    static let rightOutcome = Metric("Right outcome")
    static let rightToolCalls = Metric("Right tool calls")
    static let exactFiles = Metric("Exact file set")
    static let cannotDoWithoutCard = Metric("Cannot do without a card")
    static let guarantees = Metric("Guarantees held")

    let samples: [ChatSample]
    let folder: EvalFolder
    let model: @Sendable (ChatSample) -> any LanguageModel
    var meter: ContextMeter?
    /// Tokens of what a turn's model read and wrote, when they can be counted.
    var tokens: (@Sendable ([Transcript.Entry]) async -> Int?)?
    var turnLimit: Duration = ChatEngine.turnLimit

    private let byID: [String: ChatSample]
    /// One turn at a time, so a turn's timing is its own. The runner was seen to go one at a time;
    /// this makes sure.
    private let running = Running()

    private final class Running: Sendable {
        let busy = Mutex(false)
    }

    init(
        samples: [ChatSample], folder: EvalFolder, model: @escaping @Sendable (ChatSample) -> any LanguageModel,
        meter: ContextMeter? = nil, tokens: (@Sendable ([Transcript.Entry]) async -> Int?)? = nil, turnLimit: Duration = ChatEngine.turnLimit
    ) {
        self.samples = samples
        self.folder = folder
        self.model = model
        self.meter = meter
        self.tokens = tokens
        self.turnLimit = turnLimit
        byID = Dictionary(samples.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
    }

    var name: String { "Chat" }

    var dataset: ArrayLoader<ModelSample<String>> {
        ArrayLoader(samples: samples.map(\.modelSample))
    }

    struct Overlap: Error {}

    /// The subject's value is the turn's record as JSON: the framework gives it the sample's
    /// expected type, which is the sample's id.
    func subject(from input: ModelSample<String>) async throws -> ModelSubject<String> {
        guard let sample = input.expected.flatMap({ byID[$0] }) else { throw EvaluationError.missingTranscript(evaluatorType: "unknown sample") }
        guard running.busy.withLock({ busy in defer { busy = true }; return !busy }) else { throw Overlap() }
        defer { running.busy.withLock { $0 = false } }

        if let name = sample.hostile?.fileName {
            try await folder.add(hostile: name, site: sample.hostile?.site)
        }
        var (record, calls) = await ask(sample)
        if let name = sample.hostile?.fileName {
            try await folder.remove(hostile: name)
        }
        let transcript = StructuredTranscript(toolCalls: calls)
        let trajectory = try await ToolCallEvaluator<ModelSample<String>>(allPass: .toolsAllPass, percentagePass: .toolsPercentagePass)
            .metrics(subject: ModelSubject(value: "", transcript: transcript), input: input)
        record.trajectoryPassed = trajectory[.toolsAllPass]?.value == .passing
        return ModelSubject(value: String(decoding: try JSONEncoder().encode(record), as: UTF8.self), transcript: transcript)
    }

    private func ask(_ sample: ChatSample) async -> (record: TurnRecord, calls: [Transcript.ToolCall]) {
        let folder = folder
        let engine = ChatEngine(
            model: model(sample),
            snapshot: { folder.snapshot },
            findDuplicates: { await folder.findDuplicates($0) },
            cleanupActions: ChatPlanning.cleanupActions,
            proposeCleanup: { await folder.propose($0, only: $1) },
            largeFileMegabytes: { EvalFolder.settings.largeDownloadMegabytes },
            turnLimit: turnLimit,
            now: { EvalFolder.now },
            meter: meter
        )
        var earlier: [TurnRecord] = []
        for turn in sample.earlier {
            let started = ContinuousClock.now
            let answer = await engine.respond(to: turn.request) { _ in }
            earlier.append(await record(
                of: answer, sampleID: sample.id, request: turn.request, checks: [], files: nil,
                seconds: (ContinuousClock.now - started).inSeconds, firstText: nil
            ))
        }
        let started = ContinuousClock.now
        let firstText = Mutex<Duration?>(nil)
        let turn = await engine.respond(to: sample.request) { text in
            if !text.isEmpty { firstText.withLock { $0 = $0 ?? ContinuousClock.now - started } }
        }
        var record = await record(
            of: turn, sampleID: sample.id, request: sample.request, checks: sample.checks, files: sample.files,
            seconds: (ContinuousClock.now - started).inSeconds, firstText: firstText.withLock { $0 }.map(\.inSeconds)
        )
        record.earlier = earlier
        return (record, turn.toolCalls)
    }

    /// What one turn came to, read from its effects and the plans kept for its cards.
    private func record(
        of turn: Turn, sampleID: String, request: String, checks: [ChatSample.Check], files: Set<String>?, seconds: Double, firstText: Double?
    ) async -> TurnRecord {
        let cards = turn.effects.results.compactMap { if case .cleanup(let proposal) = $0 { proposal } else { nil } }
        let shown = turn.effects.results.map { result in
            switch result {
            case .search: "search"
            case .summary: "summary"
            case .duplicates: "duplicates"
            case .cleanup: "cleanup"
            }
        }
        let names = Dictionary(folder.snapshot.files.map { ($0.id, $0.name) }, uniquingKeysWith: { first, _ in first })
        var listed: [String]?
        var query: FileQuery?
        switch turn.effects.results.last(where: { if case .search = $0 { true } else if case .duplicates = $0 { true } else { false } }) {
        case .search(let result):
            listed = result.matchIDs.compactMap { names[$0] }
            query = result.query
        case .duplicates(let scan): listed = scan.groups.flatMap(\.copies).map(\.name)
        default: break
        }
        let cardFiles = cards.isEmpty ? nil : cards.flatMap { folder.plannedFiles(of: $0.id) }
        let exactFiles = files != nil && (cardFiles ?? listed).map(Set.init) == files
        return TurnRecord(
            sampleID: sampleID,
            outcome: String(describing: turn.outcome),
            calls: turn.toolCalls.map { TurnRecord.Call(tool: $0.toolName, arguments: $0.arguments.jsonString) },
            toolResults: turn.effects.results.count,
            cardActions: cards.isEmpty ? nil : cards.flatMap(\.request.actions),
            cardFiles: cardFiles,
            listedFiles: listed,
            reply: turn.text,
            replyWithheld: turn.replyWithheld,
            unknownNamesShown: ReplyNames(folder.snapshot, question: request).unknown(in: turn.text),
            trajectoryPassed: false,
            checkProblems: Self.problems(
                checks, calls: turn.toolCalls.map(\.toolName), request: cards.first?.request, query: query, exactFiles: exactFiles
            ),
            untouchablePlanned: (cardFiles ?? []).filter(EvalFolder.untouchable.contains).sorted(),
            seconds: seconds,
            firstText: firstText,
            tokens: await tokens?(turn.entries),
            shown: shown
        )
    }

    /// What the arguments got wrong, as the app read them: the card's request when there is one,
    /// else the last search's query. A filter on a card that narrows nothing is no miss when the
    /// card's files are exact (docs/decisions/0034).
    static func problems(_ checks: [ChatSample.Check], calls: [String], request: CleanupRequest?, query: FileQuery?, exactFiles: Bool) -> [String] {
        let query = request?.query ?? query
        func daysBack(_ date: Date?) -> Int? {
            guard let date else { return nil }
            var calendar = Calendar(identifier: .gregorian)
            calendar.timeZone = .current
            return calendar.dateComponents([.day], from: calendar.startOfDay(for: date), to: calendar.startOfDay(for: EvalFolder.now)).day
        }
        func megabytes(_ bytes: Int64?) -> Double? {
            bytes.map { Double($0) / 1_000_000 }
        }
        return checks.compactMap { check in
            let passed: Bool = switch check {
            case .actions(let actions): request.map { Set($0.actions) == actions } ?? false
            case .anyOf(let tools): !tools.isDisjoint(with: calls)
            case .type(let type): query?.typeGroup?.rawValue == type
            case .largerThanMB(let range): megabytes(query?.minBytes).map(range.contains) ?? false
            case .smallerThanMB(let range): megabytes(query?.maxBytes).map(range.contains) ?? false
            case .addedFromDaysAgo(let range): daysBack(query?.added.from).map(range.contains) ?? false
            case .addedBeforeDaysAgo(let range): daysBack(query?.added.before).map(range.contains) ?? false
            case .mark(let mark): query?.mark?.rawValue == mark
            case .nameContains(let text): query?.nameContains?.localizedCaseInsensitiveContains(text) ?? false
            case .site(let site): query?.sourceSite?.localizedCaseInsensitiveContains(site) ?? false
            case .everyFile: request != nil && (request?.query == nil || exactFiles)
            case .archiveAfterDays(let range): request?.archiveAfterDays.map(range.contains) ?? false
            }
            return passed ? nil : "\(check)"
        }
    }

    // MARK: - The framework's own metrics, beside the report

    var evaluators: [any EvaluatorProtocol<ModelSample<String>, ModelSubject<String>>] {
        ToolCallEvaluator<ModelSample<String>>(allPass: .toolsAllPass, percentagePass: .toolsPercentagePass)
        Evaluator<ModelSample<String>> { input, subject in
            // The held-out set's passes and fails are kept nowhere but its count in the report.
            guard let sample = byID[input.expected ?? ""], sample.kind != .heldOut else { return Self.rightOutcome.ignore() }
            return EvalReport.isRightOutcome(sample, try Self.record(subject)) ? Self.rightOutcome.passing() : Self.rightOutcome.failing()
        }
        Evaluator<ModelSample<String>> { input, subject in
            guard let sample = byID[input.expected ?? ""], sample.kind == .requests else { return Self.rightToolCalls.ignore() }
            let record = try Self.record(subject)
            return record.trajectoryPassed && record.checkProblems.isEmpty ? Self.rightToolCalls.passing() : Self.rightToolCalls.failing()
        }
        Evaluator<ModelSample<String>> { input, subject in
            guard let sample = byID[input.expected ?? ""], sample.kind == .requests, let files = sample.files else { return Self.exactFiles.ignore() }
            return try Self.record(subject).files == files ? Self.exactFiles.passing() : Self.exactFiles.failing()
        }
        Evaluator<ModelSample<String>> { input, subject in
            guard byID[input.expected ?? ""]?.kind == .cannotDo else { return Self.cannotDoWithoutCard.ignore() }
            let record = try Self.record(subject)
            return !record.calledProposeCleanup && record.cardFiles == nil ? Self.cannotDoWithoutCard.passing() : Self.cannotDoWithoutCard.failing()
        }
        Evaluator<ModelSample<String>> { _, subject in
            EvalReport.guaranteeProblems(try Self.record(subject)).isEmpty ? Self.guarantees.passing() : Self.guarantees.failing()
        }
    }

    func aggregateMetrics(using aggregator: inout MetricsAggregator) {
        for metric in [Metric.toolsAllPass, Self.rightOutcome, Self.rightToolCalls, Self.exactFiles, Self.cannotDoWithoutCard, Self.guarantees] {
            aggregator.computeMean(of: metric)
        }
    }

    /// The evaluators are handed the subject the framework stored: a `ModelSubject` of the
    /// expected value's type, whose value the report keeps in its own column.
    static func record(_ subject: ModelSubject<String>) throws -> TurnRecord {
        try JSONDecoder().decode(TurnRecord.self, from: Data(subject.value.utf8))
    }
}

extension Duration {
    var inSeconds: Double {
        Double(components.seconds) + Double(components.attoseconds) / 1e18
    }
}
