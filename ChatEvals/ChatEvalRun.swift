import Evaluations
import FileStoreIntelligence
import Foundation
import FoundationModels
import Testing

/// The chat on the real on-device model, over every labelled sample: the run that writes
/// docs/evals/<date>-prompts-v<N>.md and its row in docs/evals/README.md (`scripts/run-evals.sh`).
/// It needs Apple Intelligence, so it runs from the Evals plan only; the guarantees must hold.
@Suite(
    "Chat eval run",
    .serialized,
    .timeLimit(.minutes(60)),
    .enabled(if: ProcessInfo.processInfo.environment["SMARTOS_RUN_EVALS"] == "1", "runs from the Evals test plan only")
)
struct ChatEvalRun {
    @Test func theChatOnTheOnDeviceModel() async throws {
        guard SystemLanguageModel.default.isAvailable else {
            Issue.record("not run: Apple Intelligence is \(SystemLanguageModel.default.availability) on this Mac")
            return
        }
        let folder = try await EvalFolder.make()
        defer { folder.remove() }
        let fixed = try await ChatEngine.fixedPromptTokens(cleanupActions: ChatPlanning.cleanupActions)
        let evaluation = ChatEvaluation(
            samples: Datasets.all, folder: folder, model: { _ in SystemLanguageModel.default }, meter: .system,
            tokens: { entries in
                (try? await SystemLanguageModel.default.tokenCount(for: entries)).map { $0 + fixed.instructions + fixed.tools }
            }
        )
        let result = try await evaluation.run(info: ["prompts": "v\(PromptLibrary.version)"])
        let records = try result.detailed[evaluation.responseColumn].compactMap { try $0.map(ChatEvaluation.record) }
        #expect(records.count == Datasets.all.count, "\(result.errors.inferenceFailureCount) samples did not run")
        // The parsed chat over the same samples, beside it in the report (docs/decisions/0036).
        let parsedEvaluation = ChatEvaluation(samples: Datasets.all, folder: folder, model: { _ in SystemLanguageModel.default }, engine: .parsed)
        let parsedResult = try await parsedEvaluation.run(info: ["prompts": "v\(PromptLibrary.version)", "engine": "parsed"])
        let parsedChat = try parsedResult.detailed[parsedEvaluation.responseColumn].compactMap { try $0.map(ChatEvaluation.record) }
        #expect(parsedChat.count == Datasets.all.count, "\(parsedResult.errors.inferenceFailureCount) parsed samples did not run")
        // The parse-only pass: the same requests read by the parser alone, acted on by nothing.
        let parses = await ParsePass.run(Datasets.all, in: folder) { _ in SystemLanguageModel.default }

        let report = EvalReport(records: records, samples: Datasets.all, run: .current(model: "On-device model (SystemLanguageModel)"), parses: parses, parsedChat: parsedChat)
        for line in [
            "right outcome \(report.rightOutcome)", "held-out \(report.heldOut)", "right tool calls \(report.rightToolCalls)", "exact files \(report.exactFiles)",
            "cards with unasked files \(report.cardsWithUnaskedFiles)", "cannot do without card \(report.cannotDoWithoutCard)",
            "hostile changed \(report.hostileChanged)", "first text \(report.firstText)", "turn \(report.fullTurn)", "tokens \(report.tokens)",
            "parse right \(report.parseRight)", "parse held-out \(report.parseHeldOut)", "parse kind \(report.parseKind)",
            "parse cleanups \(report.parseCleanups)", "parse folder \(report.parseFolder)", "parse time \(report.parseTime)",
        ] + (report.parsedReport.map { parsed in [
            "parsed right outcome \(parsed.rightOutcome)", "parsed held-out \(parsed.heldOut)", "parsed exact files \(parsed.exactFiles)",
            "parsed cannot do without card \(parsed.cannotDoWithoutCard)", "parsed turn \(parsed.fullTurn)",
        ] } ?? []) {
            print("CHAT EVAL \(line)")
        }
        if let directory = ProcessInfo.processInfo.environment["SMARTOS_EVAL_REPORT_DIR"] {
            let written = try report.write(to: URL(filePath: directory, directoryHint: .isDirectory))
            print("CHAT EVAL report \(written.path(percentEncoded: false))")
        }
        for (name, rate) in report.guarantees + (report.parsedReport?.guarantees ?? []) {
            #expect(rate.passed == rate.total, "guarantee broken: \(name), \(rate)")
        }
    }
}
