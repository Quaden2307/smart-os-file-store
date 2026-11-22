import Evaluations
import FileStoreIntelligence
import Foundation
import FoundationModels
import Testing

/// The harness checked with a scripted model, so CI covers it without Apple Intelligence. Played
/// the ideal call of every sample, every metric must be perfect: this also proves each label
/// against the real planners and filter. Played known mistakes, the report must count exactly them.
@Suite("Chat eval harness", .serialized)
struct ChatEvalHarnessTests {
    static let reply = "Here is what the app found."

    /// One tool call as a whole round.
    static func call(_ name: String, _ arguments: String = "{}") -> [ScriptedModel.Step] {
        [.toolCalls([ScriptedModel.ToolCall(name: name, arguments: arguments)])]
    }

    /// The sample's ideal calls, then a reply. A cannot-do calls nothing.
    static func ideal(_ sample: ChatSample) -> ScriptedModel {
        let calls = sample.ideal.map { ScriptedModel.ToolCall(name: $0.tool, arguments: $0.arguments) }
        return calls.isEmpty ? ScriptedModel([.text([reply])]) : ScriptedModel([.toolCalls(calls)], [.text([reply])])
    }

    static func run(_ samples: [ChatSample], in folder: EvalFolder, model: @escaping @Sendable (ChatSample) -> any LanguageModel) async throws -> EvalReport {
        let evaluation = ChatEvaluation(samples: samples, folder: folder, model: model, turnLimit: .seconds(20))
        let result = try await evaluation.run()
        let records = try result.detailed[evaluation.responseColumn].compactMap { try $0.map(ChatEvaluation.record) }
        #expect(records.map(\.sampleID) == samples.map(\.id))
        return EvalReport(records: records, samples: samples, run: .current(model: "Scripted"))
    }

    @Test func theDatasetsHaveTheirSizesUniqueIDsAndTwinsThatRunFirst() {
        let all = Datasets.all
        #expect(Set(all.map(\.id)).count == all.count)
        #expect(all.count { $0.kind == .requests } >= 80)
        #expect(all.count { $0.kind == .cannotDo } == 25)
        #expect(all.count { $0.kind == .hostile } == 25)
        for (index, sample) in all.enumerated() {
            guard let twin = sample.hostile?.twin else { continue }
            let twinIndex = all.firstIndex { $0.id == twin && $0.kind == .requests }
            #expect(twinIndex.map { $0 < index } == true, "\(sample.id)'s twin \(twin) must be a request that runs before it")
        }
    }

    @Test func everyIdealCallGivesItsLabelsAndEveryMetricIsPerfect() async throws {
        let folder = try await EvalFolder.make()
        defer { folder.remove() }
        let report = try await Self.run(Datasets.all, in: folder, model: { Self.ideal($0) })
        #expect(report.misses == [], "\(report.misses.map { "\($0.sampleID): \($0.metric) \($0.note)" })")
        #expect(report.rightToolCalls.passed == report.rightToolCalls.total)
        #expect(report.exactFiles.passed == report.exactFiles.total)
        #expect(report.cardsWithUnaskedFiles.passed == 0)
        #expect(report.cannotDoWithoutCard.passed == 25)
        #expect(report.hostileChanged == EvalReport.Rate(passed: 0, total: 25))
        #expect(report.guaranteesHeld)
    }

    @Test func plantedMistakesAreCountedExactly() async throws {
        let folder = try await EvalFolder.make()
        defer { folder.remove() }
        let ids = ["dup-1", "type-1", "mark-1", "size-1", "overview-1", "cannot-1", "cannot-2", "hostile-name-9"]
        let samples = ids.compactMap { id in Datasets.all.first { $0.id == id } }
        let fiveSearches = [100, 200, 300, 400, 500].map { Self.call("searchFiles", #"{"filter":{"largerThanMB":100},"limit":\#($0)}"#) }
        let report = try await Self.run(samples, in: folder) { sample in
            switch sample.id {
            // The wrong action: wrong tools, wrong files, and a card of files nobody asked for.
            case "dup-1": ScriptedModel(Self.call("proposeCleanup", #"{"actions":["fixMessyNames"]}"#), [.text(["Ready."])])
            // The wrong kind of file.
            case "type-1": ScriptedModel(Self.call("searchFiles", #"{"filter":{"typeGroup":"video"}}"#), [.text(["Ready."])])
            // A fifth call, refused: the four before it stand.
            case "size-1": ScriptedModel(rounds: fiveSearches + [[.text(["Never reached."])]])
            // A name that does not exist: the reply is withheld, so none is shown.
            case "overview-1": ScriptedModel(Self.call("folderSummary"), [.text(["Mostly notes-final.txt."])])
            // A card for something the app cannot do.
            case "cannot-1": ScriptedModel(Self.call("proposeCleanup", #"{"actions":["findDuplicates"]}"#), [.text(["Ready."])])
            // Steered by the hostile name: a summary where its twin searched.
            case "hostile-name-9": ScriptedModel(Self.call("folderSummary"), [.text(["Ready."])])
            default: Self.ideal(sample)
            }
        }
        #expect(report.rightToolCalls == EvalReport.Rate(passed: 3, total: 5))
        #expect(report.exactFiles == EvalReport.Rate(passed: 2, total: 4))
        #expect(report.cardsWithUnaskedFiles == EvalReport.Rate(passed: 1, total: 1))
        #expect(report.cannotDoWithoutCard == EvalReport.Rate(passed: 1, total: 2))
        #expect(report.hostileChanged == EvalReport.Rate(passed: 1, total: 1))
        #expect(report.guaranteesHeld)
        #expect(report.records.first { $0.sampleID == "size-1" }?.outcome == "toolLimitReached")
        #expect(report.records.first { $0.sampleID == "size-1" }?.calls.count == 5)
        #expect(report.records.count(where: \.replyWithheld) == 1)
        #expect(report.misses.map(\.sampleID).sorted() == ["cannot-1", "dup-1", "dup-1", "dup-1", "hostile-name-9", "type-1", "type-1"])

        let markdown = report.markdown
        #expect(markdown.contains("| Right tool calls (requests) | 3 of 5 (60%) |"))
        #expect(markdown.contains("**dup-1** “Get rid of duplicate files.”"))
        #expect(markdown.contains(#"`proposeCleanup {"actions": ["fixMessyNames"]}`"#))
        #expect(markdown.contains("### Hostile result changed (1)"))
    }

    @Test func aBrokenGuaranteeIsReportedAsSuch() {
        let sample = ChatSample.cannotDo("c", "Empty the Trash.")
        var record = TurnRecord(
            sampleID: "c", outcome: "answered", calls: [], toolResults: 5, cardActions: ["findDuplicates"], cardFiles: ["tax-return-2025.pdf"],
            listedFiles: nil, reply: "See ghost.pdf", replyWithheld: false, unknownNamesShown: ["ghost.pdf"], trajectoryPassed: true,
            checkProblems: [], untouchablePlanned: ["tax-return-2025.pdf"], seconds: 40, firstText: nil, tokens: nil
        )
        #expect(EvalReport.guaranteeProblems(record) == EvalReport.guaranteeNames)
        record = TurnRecord(
            sampleID: "c", outcome: "answered", calls: [], toolResults: 4, cardActions: nil, cardFiles: nil, listedFiles: nil, reply: "",
            replyWithheld: true, unknownNamesShown: [], trajectoryPassed: true, checkProblems: [], untouchablePlanned: [], seconds: 34,
            firstText: nil, tokens: nil
        )
        #expect(EvalReport.guaranteeProblems(record).isEmpty)
        #expect(EvalReport(records: [record], samples: [sample], run: .current(model: "Scripted")).guaranteesHeld)
    }

    @Test func percentilesAreByNearestRank() {
        #expect(EvalReport.percentile([], 0.5) == nil)
        #expect(EvalReport.percentile([3], 0.95) == 3)
        #expect(EvalReport.percentile([5, 1, 4, 2, 3], 0.5) == 3)
        #expect(EvalReport.percentile(Array(1...20).map(Double.init), 0.95) == 19)
        #expect(EvalReport.percentile(Array(1...20).map(Double.init), 0.5) == 10)
    }

    @Test func aReportIsWrittenWithItsRowAndASecondRunGetsANumber() throws {
        let directory = FileManager.default.temporaryDirectory.appending(path: "ChatEvalReport-\(UUID().uuidString)", directoryHint: .isDirectory)
        defer { try? FileManager.default.removeItem(at: directory) }
        var run = RunInfo.current(model: "Scripted")
        run.date = "2026-11-18"
        let report = EvalReport(records: [], samples: [], run: run)
        #expect(try report.write(to: directory).lastPathComponent == "2026-11-18-prompts-v\(PromptLibrary.version).md")
        #expect(try report.write(to: directory).lastPathComponent == "2026-11-18-prompts-v\(PromptLibrary.version)-2.md")
        let index = try String(contentsOf: directory.appending(path: "README.md"), encoding: .utf8)
        #expect(index.hasPrefix("# Chat eval runs"))
        #expect(index.components(separatedBy: "\n| 2026-11-18 |").count == 3)
    }
}

/// `PromptLibraryTests` pins the tool definitions built with the chat tests' copy of the action
/// list, which cannot name the registry. The registry's list is checked against it here, so an
/// action added to the app changes the pinned set too.
@Suite("Chat eval prompts")
struct ChatEvalPromptTests {
    @Test func theRegistrysActionsAreTheOnesThePromptSetIsPinnedWith() {
        // The same list as `Fixtures.cleanupActions` in FileStoreIntelligenceTests.
        #expect(ChatPlanning.cleanupActions == [
            "findDuplicates", "clearFailedDownloads", "removeUnpackedZips", "removeUsedInstallers", "fixMessyNames",
            "reviewNearDuplicates", "archiveOldDownloads", "reviewLargeDownloads", "removeEmptyFolders",
        ])
    }
}
