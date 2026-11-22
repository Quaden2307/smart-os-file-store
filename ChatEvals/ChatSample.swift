import Evaluations
import FileStoreIntelligence
import Foundation

/// One labelled request for the evals: what is asked, which tools a right answer calls, the exact
/// files it ends on, and the call a right answer makes, which the scripted check plays back.
struct ChatSample: Sendable {
    enum Kind: String, Sendable, CaseIterable {
        /// Cleanups and questions the chat can do.
        case requests
        /// Asks outside the app: no card.
        case cannotDo
        /// A hostile file, site or request: its twin's outcome, the hostile thing ignored.
        case hostile
        /// The same asks in other words, never tuned on (`HeldOut`).
        case heldOut
    }

    /// What the user gets, whatever path the model took (docs/decisions/0034). Read from what the
    /// turn showed: its card, else its last lookup.
    enum Outcome: Sendable, Equatable, CustomStringConvertible {
        /// Files listed: a search.
        case list
        /// A number: a search or a summary.
        case count
        /// A card with exactly these actions.
        case card(Set<String>)
        /// The copies Find Duplicates read.
        case duplicates
        /// The folder as a whole: a summary or a search.
        case overview
        /// Something the app cannot do: no card.
        case cannotDo
        /// Talk with no file in it: no card.
        case chat

        var description: String {
            switch self {
            case .list: "list"
            case .count: "count"
            case .card(let actions): "card(\(actions.sorted().joined(separator: ", ")))"
            case .duplicates: "duplicates"
            case .overview: "overview"
            case .cannotDo: "cannotDo"
            case .chat: "chat"
            }
        }
    }

    /// What the evaluator cannot see: inside the filter and the action list it matches nothing
    /// (measured, docs/decisions/0033). Checked in code on the arguments as the app read them, on
    /// the card's request when there is one, else on the last search.
    enum Check: Sendable, Equatable {
        /// Exactly these actions on the card.
        case actions(Set<String>)
        /// Any of these tools was called.
        case anyOf(Set<String>)
        case type(String)
        /// The query's lower size bound, in MB.
        case largerThanMB(ClosedRange<Double>)
        case smallerThanMB(ClosedRange<Double>)
        /// The first day of the added range, in days before `EvalFolder.now`.
        case addedFromDaysAgo(ClosedRange<Int>)
        /// The day after the last day of the added range, in days before `EvalFolder.now`.
        case addedBeforeDaysAgo(ClosedRange<Int>)
        case mark(String)
        case nameContains(String)
        case site(String)
        /// The card is for every file: no filter.
        case everyFile
        case archiveAfterDays(ClosedRange<Int>)
    }

    /// A tool call as the model would write it.
    struct Call: Sendable {
        let tool: String
        let arguments: String
    }

    /// A hostile sample: the file it adds (with a download site, maybe) and the request sample whose
    /// result it must keep. A hostile request adds no file.
    struct Hostile: Sendable {
        var fileName: String?
        var site: String?
        let twin: String
    }

    /// An earlier turn of the same conversation, asked before the sample's own.
    struct Turn: Sendable {
        let request: String
        let ideal: [Call]
    }

    var id: String
    var kind: Kind
    var request: String
    let trajectory: TrajectoryExpectation
    let checks: [Check]
    var outcome: Outcome
    /// The exact files a right answer ends on: the card's, else the last lookup's (a search or the
    /// copies found). Nil when the request names no files, such as a summary or a cannot-do.
    var files: Set<String>?
    let ideal: [Call]
    var hostile: Hostile?
    /// Turns asked first in the same conversation; only the sample's own turn is scored.
    var earlier: [Turn] = []

    /// The sample as the framework takes it: the expected value is the id, to look the labels up by.
    var modelSample: ModelSample<String> {
        ModelSample(prompt: request, expected: id, expectations: trajectory)
    }
}

// MARK: - Writing samples

extension ChatSample {
    /// A cleanup: one `proposeCleanup` with exactly `actions`, ending on exactly `files`.
    /// `filter` is the ideal call's filter as JSON, when the request says which files.
    static func cleanup(
        _ id: String, _ request: String, actions: [String], filter: String? = nil, settings: String = "",
        checks: [Check] = [], files: [String]
    ) -> ChatSample {
        let quoted = actions.map { "\"\($0)\"" }.joined(separator: ",")
        let arguments = "{\"actions\":[\(quoted)]" + (filter.map { ",\"filter\":\($0)" } ?? "") + settings + "}"
        // "all" is every action, as the tool reads it.
        let card = actions == ["all"] ? Set(ChatPlanning.cleanupActions) : Set(actions)
        return ChatSample(
            id: id, kind: .requests, request: request,
            trajectory: TrajectoryExpectation(unordered: [ToolExpectation("proposeCleanup")]),
            checks: [.actions(card)] + (filter == nil ? [.everyFile] : []) + checks,
            outcome: .card(card), files: Set(files), ideal: [Call(tool: "proposeCleanup", arguments: arguments)]
        )
    }

    /// A question answered by one search, ending on exactly `files`, with no card.
    static func search(
        _ id: String, _ request: String, filter: String?, sort: String? = nil, checks: [Check] = [], files: [String]?
    ) -> ChatSample {
        let parts = [filter.map { "\"filter\":\($0)" }, sort.map { "\"sort\":\"\($0)\"" }].compactMap(\.self)
        return ChatSample(
            id: id, kind: .requests, request: request,
            trajectory: TrajectoryExpectation(
                unordered: [ToolExpectation("searchFiles", arguments: sort.map { [.exact(argumentName: "sort", value: .string($0))] } ?? [])],
                disallowed: [ToolExpectation("proposeCleanup")]
            ),
            checks: checks, outcome: .list, files: files.map(Set.init),
            ideal: [Call(tool: "searchFiles", arguments: "{" + parts.joined(separator: ",") + "}")]
        )
    }

    /// A question about copies: Find Duplicates, ending on exactly the copies it finds, with no card.
    static func duplicates(_ id: String, _ request: String, files: [String]) -> ChatSample {
        ChatSample(
            id: id, kind: .requests, request: request,
            trajectory: TrajectoryExpectation(unordered: [ToolExpectation("findDuplicates")], disallowed: [ToolExpectation("proposeCleanup")]),
            checks: [], outcome: .duplicates, files: Set(files), ideal: [Call(tool: "findDuplicates", arguments: "{}")]
        )
    }

    /// A question about the folder as a whole: a summary or a search, no card, no file set.
    static func overview(_ id: String, _ request: String) -> ChatSample {
        ChatSample(
            id: id, kind: .requests, request: request,
            trajectory: TrajectoryExpectation(disallowed: [ToolExpectation("proposeCleanup"), ToolExpectation("findDuplicates")]),
            checks: [.anyOf(["folderSummary", "searchFiles"])], outcome: .overview, files: nil, ideal: [Call(tool: "folderSummary", arguments: "{}")]
        )
    }

    /// Something the app cannot do: no `proposeCleanup`, no card. A right answer calls no tool.
    static func cannotDo(_ id: String, _ request: String) -> ChatSample {
        ChatSample(
            id: id, kind: .cannotDo, request: request,
            trajectory: TrajectoryExpectation(disallowed: [ToolExpectation("proposeCleanup")]),
            checks: [], outcome: .cannotDo, files: nil, ideal: []
        )
    }

    /// `twin` again, with a hostile file (and site) added to the folder. `listed` when a right answer
    /// lists the hostile file too, as a search for its kind or site does.
    static func hostileFile(_ id: String, name: String, site: String? = nil, listed: Bool = false, like twin: ChatSample) -> ChatSample {
        var sample = twin
        sample.id = id
        sample.kind = .hostile
        if listed { sample.files = twin.files?.union([name]) }
        sample.hostile = Hostile(fileName: name, site: site, twin: twin.id)
        return sample
    }

    /// `twin`'s request with words that try to steer the model, on the plain folder.
    static func hostileRequest(_ id: String, _ request: String, like twin: ChatSample) -> ChatSample {
        var sample = twin
        sample.id = id
        sample.kind = .hostile
        sample.request = request
        sample.hostile = Hostile(twin: twin.id)
        return sample
    }

    /// The sample asked right after `first`, in the same conversation.
    func after(_ first: ChatSample) -> ChatSample {
        var sample = self
        sample.earlier = first.earlier + [Turn(request: first.request, ideal: first.ideal)]
        return sample
    }

    /// The sample with another expected outcome, such as a count asked as a search.
    func expecting(_ outcome: Outcome) -> ChatSample {
        var sample = self
        sample.outcome = outcome
        return sample
    }
}
