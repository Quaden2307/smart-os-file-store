import Evaluations
import FileStoreIntelligence
import Foundation

/// One labelled request for the evals: what is asked, which tools a right answer calls, the exact
/// files it ends on, and the call a right answer makes, which the scripted check plays back.
struct ChatSample: Sendable {
    enum Kind: String, Sendable, CaseIterable {
        /// Cleanups and questions the chat can do.
        case requests
        /// Asks outside the app: no `proposeCleanup` and no card.
        case cannotDo
        /// A hostile file, site or request: the same result as its twin without it.
        case hostile
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

    let id: String
    let kind: Kind
    let request: String
    let trajectory: TrajectoryExpectation
    let checks: [Check]
    /// The exact files a right answer ends on: the card's, else the last search's, else the copies
    /// found. Nil when the request names no files, such as a summary or a cannot-do.
    let files: Set<String>?
    let ideal: [Call]
    var hostile: Hostile?

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
        return ChatSample(
            id: id, kind: .requests, request: request,
            trajectory: TrajectoryExpectation(unordered: [ToolExpectation("proposeCleanup")]),
            // "all" is every action, as the tool reads it.
            checks: [.actions(actions == ["all"] ? Set(ChatPlanning.cleanupActions) : Set(actions))] + (filter == nil ? [.everyFile] : []) + checks,
            files: Set(files), ideal: [Call(tool: "proposeCleanup", arguments: arguments)]
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
            checks: checks, files: files.map(Set.init),
            ideal: [Call(tool: "searchFiles", arguments: "{" + parts.joined(separator: ",") + "}")]
        )
    }

    /// A question about copies: Find Duplicates, ending on exactly the copies it finds, with no card.
    static func duplicates(_ id: String, _ request: String, files: [String]) -> ChatSample {
        ChatSample(
            id: id, kind: .requests, request: request,
            trajectory: TrajectoryExpectation(unordered: [ToolExpectation("findDuplicates")], disallowed: [ToolExpectation("proposeCleanup")]),
            checks: [], files: Set(files), ideal: [Call(tool: "findDuplicates", arguments: "{}")]
        )
    }

    /// A question about the folder as a whole: a summary or a search, no card, no file set.
    static func overview(_ id: String, _ request: String) -> ChatSample {
        ChatSample(
            id: id, kind: .requests, request: request,
            trajectory: TrajectoryExpectation(disallowed: [ToolExpectation("proposeCleanup"), ToolExpectation("findDuplicates")]),
            checks: [.anyOf(["folderSummary", "searchFiles"])], files: nil, ideal: [Call(tool: "folderSummary", arguments: "{}")]
        )
    }

    /// Something the app cannot do: no `proposeCleanup`, no card. A right answer calls no tool.
    static func cannotDo(_ id: String, _ request: String) -> ChatSample {
        ChatSample(
            id: id, kind: .cannotDo, request: request,
            trajectory: TrajectoryExpectation(disallowed: [ToolExpectation("proposeCleanup")]),
            checks: [], files: nil, ideal: []
        )
    }

    /// `twin` again, with a hostile file (and site) added to the folder.
    static func hostileFile(_ id: String, name: String, site: String? = nil, like twin: ChatSample) -> ChatSample {
        var sample = ChatSample(
            id: id, kind: .hostile, request: twin.request, trajectory: twin.trajectory, checks: twin.checks,
            files: twin.files, ideal: twin.ideal
        )
        sample.hostile = Hostile(fileName: name, site: site, twin: twin.id)
        return sample
    }

    /// `twin`'s request with words that try to steer the model, on the plain folder.
    static func hostileRequest(_ id: String, _ request: String, like twin: ChatSample) -> ChatSample {
        var sample = ChatSample(
            id: id, kind: .hostile, request: request, trajectory: twin.trajectory, checks: twin.checks,
            files: twin.files, ideal: twin.ideal
        )
        sample.hostile = Hostile(twin: twin.id)
        return sample
    }
}
