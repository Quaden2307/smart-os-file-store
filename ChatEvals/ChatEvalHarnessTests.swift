import Evaluations
import FileStoreCore
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

    /// The ideal calls of each earlier turn and then the sample's, each followed by a reply. A
    /// cannot-do calls nothing.
    static func ideal(_ sample: ChatSample) -> ScriptedModel {
        .playing(sample.earlier.map(\.ideal) + [sample.ideal], reply: reply)
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
        #expect(all.count { $0.kind == .heldOut } == 60)
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
        // The held-out set's misses are not listed, so its labels are proved here.
        let heldOut = report.records.filter { $0.sampleID.hasPrefix("held-") }.compactMap { record in
            Datasets.all.first { $0.id == record.sampleID }.flatMap { EvalReport.isRightOutcome($0, record) ? nil : "\($0.id): shown \(record.shown), card \(record.cardActions ?? []), files \((record.files ?? []).sorted())" }
        }
        #expect(heldOut == [])
        #expect(report.rightOutcome.passed == report.rightOutcome.total)
        #expect(report.heldOut == EvalReport.Rate(passed: 60, total: 60))
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
        let ids = ["dup-1", "type-1", "mark-1", "size-1", "overview-1", "failed-1", "cannot-1", "cannot-2", "hostile-name-9"]
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
            // A filter that narrows nothing: its files are exact, so no miss.
            case "failed-1": ScriptedModel(Self.call("proposeCleanup", #"{"actions":["clearFailedDownloads"],"filter":{"mark":"failedDownload"}}"#), [.text(["Ready."])])
            // A card for something the app cannot do.
            case "cannot-1": ScriptedModel(Self.call("proposeCleanup", #"{"actions":["findDuplicates"]}"#), [.text(["Ready."])])
            // Steered by the hostile name: a summary where its twin searched.
            case "hostile-name-9": ScriptedModel(Self.call("folderSummary"), [.text(["Ready."])])
            default: Self.ideal(sample)
            }
        }
        #expect(report.rightOutcome == EvalReport.Rate(passed: 5, total: 9))
        #expect(report.rightToolCalls == EvalReport.Rate(passed: 4, total: 6))
        #expect(report.exactFiles == EvalReport.Rate(passed: 3, total: 5))
        #expect(report.cardsWithUnaskedFiles == EvalReport.Rate(passed: 1, total: 2))
        #expect(report.cannotDoWithoutCard == EvalReport.Rate(passed: 1, total: 2))
        #expect(report.hostileChanged == EvalReport.Rate(passed: 1, total: 1))
        #expect(report.guaranteesHeld)
        #expect(report.records.first { $0.sampleID == "size-1" }?.outcome == "toolLimitReached")
        #expect(report.records.first { $0.sampleID == "size-1" }?.calls.count == 5)
        #expect(report.records.count(where: \.replyWithheld) == 1)
        #expect(report.misses.filter { $0.metric == "Right outcome" }.map(\.sampleID).sorted() == ["cannot-1", "dup-1", "hostile-name-9", "type-1"])
        #expect(report.misses.map(\.sampleID).sorted() == [
            "cannot-1", "cannot-1", "dup-1", "dup-1", "dup-1", "dup-1", "hostile-name-9", "hostile-name-9", "type-1", "type-1", "type-1",
        ])

        let markdown = report.markdown
        #expect(markdown.contains("| **Right outcome** (requests, cannot do, hostile) | 5 of 9 (56%) |"))
        #expect(markdown.contains("| Right tool calls (requests; the tool-calling engine only) | 4 of 6 (67%) |"))
        #expect(markdown.contains("| hostile-name-9 | hostile | list | summary | **no** |  |  |"))
        #expect(markdown.contains("**dup-1** “Get rid of duplicate files.”"))
        #expect(markdown.contains(#"`proposeCleanup {"actions": ["fixMessyNames"]}`"#))
        #expect(markdown.contains("### Hostile result changed (1)"))
    }

    /// Every sample's ideal parse, written from its expected outcome alone, read back through the
    /// parser's real schema: every parse rate must be perfect, the held-out set's too.
    @Test func everyIdealParseGivesItsLabels() async throws {
        let folder = try await EvalFolder.make()
        defer { folder.remove() }
        let parses = await ParsePass.run(Datasets.all, in: folder) { ScriptedModel([.text([ParsePass.ideal($0)])]) }
        let report = EvalReport(records: [], samples: Datasets.all, run: .current(model: "Scripted"), parses: parses)
        let wrong = parses.compactMap { parse in
            Datasets.all.first { $0.id == parse.sampleID }.flatMap { EvalReport.parseScore($0, parse).isRight ? nil : "\($0.id): \(parse)" }
        }
        #expect(wrong == [])
        #expect(report.parseRight == EvalReport.Rate(passed: Datasets.all.count - 60, total: Datasets.all.count - 60))
        #expect(report.parseHeldOut == EvalReport.Rate(passed: 60, total: 60))
        #expect(report.parseCleanups.passed == report.parseCleanups.total && report.parseCleanups.total > 40)
        #expect(report.misses == [])
        #expect(parses.allSatisfy { $0.error == nil })
        // A follow-up after a lookup reads a line about its files; after a card, as in the app, none.
        let followUps = Set(Datasets.all.filter { $0.earlier.last?.ideal.contains { $0.tool != "proposeCleanup" } == true }.map(\.id))
        #expect(!followUps.isEmpty)
        let withLine = Set(parses.filter { $0.lastResultLine != nil }.map(\.sampleID))
        #expect(withLine == followUps, "no line: \(followUps.subtracting(withLine).sorted()), unexpected: \(withLine.subtracting(followUps).sorted())")
    }

    @Test func plantedParseMistakesAreCountedExactly() async throws {
        let folder = try await EvalFolder.make()
        defer { folder.remove() }
        let ids = ["dup-1", "type-1", "overview-1", "mark-1", "cannot-17", "held-1"]
        let samples = ids.compactMap { id in Datasets.all.first { $0.id == id } }
        let parses = await ParsePass.run(samples, in: folder) { sample in
            let reply = switch sample.id {
            // The wrong cleanup.
            case "dup-1": #"{"kind":"cleanup","cleanups":["messyNames"]}"#
            // A question read as a cleanup.
            case "type-1": #"{"kind":"cleanup"}"#
            // A count for an overview, and chat for a cannot-do: both alike, so right.
            case "overview-1": #"{"kind":"count"}"#
            case "cannot-17": #"{"kind":"chat"}"#
            // Another folder.
            case "mark-1": #"{"kind":"list","folder":"Desktop"}"#
            // A held-out miss: counted, never listed.
            case "held-1": #"{"kind":"list"}"#
            default: ParsePass.ideal(sample)
            }
            return ScriptedModel([.text([reply])])
        }
        let report = EvalReport(records: [], samples: samples, run: .current(model: "Scripted"), parses: parses)
        #expect(report.parseRight == EvalReport.Rate(passed: 2, total: 5))
        #expect(report.parseKind == EvalReport.Rate(passed: 4, total: 5))
        #expect(report.parseCleanups == EvalReport.Rate(passed: 0, total: 1))
        #expect(report.parseFolder == EvalReport.Rate(passed: 4, total: 5))
        #expect(report.parseHeldOut == EvalReport.Rate(passed: 0, total: 1))
        #expect(report.misses.map(\.sampleID).sorted() == ["dup-1", "mark-1", "type-1"])
        let markdown = report.markdown
        #expect(markdown.contains("| **Parse right** (requests, cannot do, hostile; kind, a card's cleanups and folder) | 2 of 5 (40%) |"))
        #expect(markdown.contains("  - expected card(findDuplicates); read as kind cleanup, cleanups [\"fixMessyNames\"], folder none"))
        #expect(!markdown.contains("held-1"))
    }

    /// The parsed chat played each sample's ideal parse: every cleanup with no narrowing, copies
    /// question and cannot-do gets its outcome, with no tool call, and the report sets it beside
    /// the tool loop. (A parse names no files, so samples whose files are narrowed are not played.)
    @Test func theParsedChatOnIdealParsesGetsItsOutcomesBesideTheToolLoop() async throws {
        let folder = try await EvalFolder.make()
        defer { folder.remove() }
        let samples = Datasets.all.filter { sample in
            guard sample.earlier.isEmpty, sample.kind == .requests || sample.kind == .cannotDo else { return false }
            return switch sample.outcome {
            case .card: !["filter", "archiveAfterDays", "largeFileMB"].contains { name in sample.ideal.contains { $0.arguments.contains(name) } }
            case .duplicates, .cannotDo: true
            default: false
            }
        }
        #expect(samples.count > 40)
        let evaluation = ChatEvaluation(
            samples: samples, folder: folder, model: { ScriptedModel([.text([ParsePass.ideal($0)])]) }, turnLimit: .seconds(20), engine: .parsed
        )
        let parsedChat = try await evaluation.run().detailed[evaluation.responseColumn].compactMap { try $0.map(ChatEvaluation.record) }
        #expect(parsedChat.map(\.sampleID) == samples.map(\.id))
        let wrong = parsedChat.compactMap { record in
            samples.first { $0.id == record.sampleID }.flatMap { EvalReport.isRightOutcome($0, record) ? nil : "\($0.id): \(record.shown), \(record.cardActions ?? []), \(record.reply)" }
        }
        #expect(wrong == [])
        #expect(parsedChat.allSatisfy { $0.calls.isEmpty && $0.parsedKind != nil && !$0.reply.isEmpty })
        let toolLoop = try await Self.run(samples, in: folder, model: { Self.ideal($0) })
        let report = EvalReport(records: toolLoop.records, samples: samples, run: .current(model: "Scripted"), parsedChat: parsedChat)
        let parsed = try #require(report.parsedReport)
        #expect(parsed.guaranteesHeld && parsed.rightOutcome.passed == parsed.rightOutcome.total)
        #expect(report.parsedMisses == [])
        #expect(report.markdown.contains("| **Right outcome** (requests, cannot do, hostile) | \(toolLoop.rightOutcome) | \(parsed.rightOutcome) |"))
        #expect(report.markdown.contains("## Misses of the parsed chat"))
    }

    @Test func aParsedMissIsTaggedWithItsCause() throws {
        let card = try #require(Requests.all.first { $0.id == "dup-1" })
        var record = TurnRecord(
            sampleID: card.id, outcome: "answered", calls: [], toolResults: 0, cardActions: nil, cardFiles: nil, listedFiles: nil,
            reply: "", replyWithheld: false, unknownNamesShown: [], trajectoryPassed: false, checkProblems: [], untouchablePlanned: [],
            seconds: 1, firstText: nil, tokens: nil
        )
        #expect(EvalReport.parsedMissCause(card, record) == "Parse failed")
        record.parsedKind = "list"
        #expect(EvalReport.parsedMissCause(card, record) == "Parse kind")
        record.parsedKind = "cleanup"
        record.parsedActions = ["fixMessyNames"]
        #expect(EvalReport.parsedMissCause(card, record) == "Parse slot (cleanups or folder)")
        record.parsedActions = ["findDuplicates"]
        #expect(EvalReport.parsedMissCause(card, record) == "File slot or planner")
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

    @Test func aCountMayBeASummaryAndAnEarlierTurnIsHeldToTheGuarantees() throws {
        let count = try #require(HeldOut.all.first { $0.outcome == .count })
        var record = TurnRecord(
            sampleID: count.id, outcome: "answered", calls: [], toolResults: 1, cardActions: nil, cardFiles: nil, listedFiles: nil,
            reply: "", replyWithheld: false, unknownNamesShown: [], trajectoryPassed: true, checkProblems: [], untouchablePlanned: [],
            seconds: 1, firstText: nil, tokens: nil, shown: ["summary"]
        )
        #expect(EvalReport.isRightOutcome(count, record))
        record.shown = ["search"]
        #expect(!EvalReport.isRightOutcome(count, record), "a search lists files, so they must be exact")

        var earlier = record
        earlier.untouchablePlanned = ["tax-return-2025.pdf"]
        record.earlier = [earlier]
        #expect(EvalReport.guaranteeProblems(record) == [EvalReport.guaranteeNames[2]])

        record.cardActions = ["findDuplicates"]
        record.reply = "Done. I've removed your duplicates."
        #expect(record.claimsAChange)
        record.reply = "Here is a cleanup of 6 duplicates. Nothing changes until you confirm."
        #expect(!record.claimsAChange)
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

    @Test func theParsersIntentsCoverEveryRegistryActionOnce() {
        let actions = CleanupIntent.allCases.compactMap(\.action)
        #expect(actions.count == Set(actions).count)
        #expect(Set(actions) == Set(ChatPlanning.cleanupActions))
    }

    /// Documents' rules offer four actions: the parser's schema built from them offers no intent of
    /// the five they turn off.
    @Test func theParsersSchemaLeavesOutWhatAFoldersRulesTurnOff() throws {
        let rules = FolderRules.defaults(for: .documents)
        let offered = CleanupAction.allCases.filter { CleanupPlanners.hasPlanner($0) && rules.offers($0) }.map(\.definition.identifier)
        let schema = try ChatParser.definition(cleanupActions: offered, folders: [EvalFolder.folderName])
        let turnedOff = CleanupIntent.allCases.filter { $0.action.map { !offered.contains($0) } ?? false }
        #expect(!turnedOff.isEmpty)
        for intent in CleanupIntent.allCases {
            #expect(schema.contains("\"\(intent.rawValue)\"") == !turnedOff.contains(intent), "\(intent)")
        }
    }
}
