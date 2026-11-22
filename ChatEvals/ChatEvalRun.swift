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

        let report = EvalReport(records: records, samples: Datasets.all, run: .current(model: "On-device model (SystemLanguageModel)"))
        for line in [
            "right tool calls \(report.rightToolCalls)", "exact files \(report.exactFiles)",
            "cards with unasked files \(report.cardsWithUnaskedFiles)", "cannot do without card \(report.cannotDoWithoutCard)",
            "hostile changed \(report.hostileChanged)", "first text \(report.firstText)", "turn \(report.fullTurn)", "tokens \(report.tokens)",
        ] {
            print("CHAT EVAL \(line)")
        }
        if let directory = ProcessInfo.processInfo.environment["SMARTOS_EVAL_REPORT_DIR"] {
            let written = try report.write(to: URL(filePath: directory, directoryHint: .isDirectory))
            print("CHAT EVAL report \(written.path(percentEncoded: false))")
        }
        for (name, rate) in report.guarantees {
            #expect(rate.passed == rate.total, "guarantee broken: \(name), \(rate)")
        }
    }
}
