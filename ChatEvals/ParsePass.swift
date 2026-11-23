import FileStoreIntelligence
import Foundation
import FoundationModels

/// What `ChatParser` read one sample's request as, and how long it took.
struct ParseRecord: Codable, Sendable, Equatable {
    var sampleID: String
    var kind: String?
    /// The cleanups as the app's action names, "everything" as every action.
    var actions: [String]?
    var folder: String?
    /// What the parser read about the last result, for a follow-up.
    var lastResultLine: String?
    var seconds: Double
    /// Why there is no request: the parse threw or ran out of time.
    var error: String?
}

/// The parse-only pass (docs/decisions/0035): every sample's request read by the parser, one at a
/// time, and nothing acted on. A follow-up's earlier turns are played first with their ideal calls,
/// so its last-result line is the one a right first turn leaves. A hostile file is not added: the
/// parser reads no file name.
enum ParsePass {
    static func run(_ samples: [ChatSample], in folder: EvalFolder, model: @Sendable (ChatSample) -> any LanguageModel) async -> [ParseRecord] {
        var records: [ParseRecord] = []
        for sample in samples {
            let lastResult = await lastResult(before: sample, in: folder)
            let parser = ChatParser(model: model(sample), cleanupActions: ChatPlanning.cleanupActions)
            var record = ParseRecord(sampleID: sample.id, lastResultLine: lastResult.flatMap { ChatParser.lastResultLine($0, in: folder.snapshot) }, seconds: 0)
            let started = ContinuousClock.now
            do {
                let request = try await parser.parse(sample.request, in: folder.snapshot, lastResult: lastResult)
                record.kind = "\(request.kind)"
                record.actions = request.actions(offered: ChatPlanning.cleanupActions)
                record.folder = request.folder
            } catch {
                record.error = String(describing: error)
            }
            record.seconds = (ContinuousClock.now - started).inSeconds
            records.append(record)
        }
        return records
    }

    /// The files the sample's earlier turns end on, played with their ideal calls, as the engine
    /// remembers them. Nil with none.
    private static func lastResult(before sample: ChatSample, in folder: EvalFolder) async -> [URL]? {
        guard !sample.earlier.isEmpty else { return nil }
        let engine = ChatEngine(
            model: ScriptedModel.playing(sample.earlier.map(\.ideal), reply: "Done."),
            snapshot: { folder.snapshot },
            findDuplicates: { await folder.findDuplicates($0) },
            cleanupActions: ChatPlanning.cleanupActions,
            proposeCleanup: { await folder.propose($0, only: $1) },
            now: { EvalFolder.now }
        )
        for turn in sample.earlier {
            _ = await engine.respond(to: turn.request) { _ in }
        }
        return await engine.lastResultIDs
    }

    /// The reply a right parse writes, from the sample's expected outcome alone.
    static func ideal(_ sample: ChatSample) -> String {
        switch sample.outcome {
        case .card(let actions):
            let intents = actions == Set(ChatPlanning.cleanupActions)
                ? [CleanupIntent.everything]
                : CleanupIntent.allCases.filter { $0.action.map(actions.contains) ?? false }
            return #"{"kind":"cleanup","cleanups":[\#(intents.map { "\"\($0.rawValue)\"" }.joined(separator: ","))]}"#
        case .cannotDo:
            return #"{"kind":"cannotDo","cannotDo":"other"}"#
        default:
            return #"{"kind":"\#(sample.outcome)"}"#
        }
    }
}

extension ScriptedModel {
    /// Each turn's calls and then `reply`; a turn with no calls only replies.
    static func playing(_ turns: [[ChatSample.Call]], reply: String) -> ScriptedModel {
        ScriptedModel(rounds: turns.flatMap { ideal -> [[Step]] in
            let calls = ideal.map { ToolCall(name: $0.tool, arguments: $0.arguments) }
            return calls.isEmpty ? [[.text([reply])]] : [[.toolCalls(calls)], [.text([reply])]]
        })
    }
}
