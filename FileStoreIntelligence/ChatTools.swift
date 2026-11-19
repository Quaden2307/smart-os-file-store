import Foundation
import FoundationModels

/// Plans a cleanup in the app: the request, and the files it is narrowed to (nil for all). The app
/// keeps the plan and hands back rows. Nil when it could not plan.
public typealias ProposeCleanup = @Sendable (CleanupRequest, Set<URL>?) async -> CleanupProposal?

/// What the tools work from: the app's current view of the folder, its duplicate scan, its
/// cleanup planning, and the turn's record.
struct ToolContext: Sendable {
    let snapshot: @Sendable () async -> FolderSnapshot
    /// Nil when the scan could not run.
    let findDuplicates: @Sendable () async -> DuplicateScan?
    /// The names of the app's cleanup actions. Empty when the app offers none to the chat.
    var cleanupActions: [String] = []
    var proposeCleanup: ProposeCleanup = { _, _ in nil }
    let recorder: TurnRecorder
}

@Generable
struct SearchFilesArguments {
    @Guide(description: "What the files must match.")
    var filter: FileFilter?

    @Guide(description: "Order of the list.", .anyOf(["largest", "smallest", "newest", "earliest", "recentlyOpened", "leastRecentlyOpened", "name"]))
    var sort: String?

    // The range is checked in code, and a wrong limit is answered with it.
    @Guide(description: "How many to list.")
    var limit: Int?
}

/// Read-only: filters, counts, sums and sorts the snapshot in code.
struct SearchFilesTool: Tool {
    let name = "searchFiles"
    let description = PromptLibrary.searchFilesTool.text
    let context: ToolContext

    func call(arguments: SearchFilesArguments) async -> String {
        let turn = context.recorder.turn
        let snapshot = await context.snapshot()
        do throws(FilterError) {
            let previous = context.recorder.previous
            let query = try (arguments.filter ?? FileFilter()).validated(now: snapshot.now, lastResultIDs: previous?.ids)
            // "Only the big ones" keeps the order the list was in.
            let kept = query.withinIDs == nil ? nil : previous?.sort
            let sort: FileSort = try FileFilter.choice(arguments.sort, named: "sort") ?? kept ?? .newest
            let limit = arguments.limit ?? FileSearchResult.defaultLimit
            guard FileSearchResult.limitRange.contains(limit) else {
                throw FilterError(message: "limit must be between 1 and 100.")
            }
            guard !context.recorder.isRepeat(.search(query, sort, limit: limit), turn: turn) else {
                return ToolOutput.repeated
            }
            let result = FileSearchResult(query: query, sort: sort, limit: limit, in: snapshot)
            context.recorder.record(.search(result), turn: turn)
            return ToolOutput.search(result, now: snapshot.now)
        } catch {
            // Returned, not thrown: a thrown error ends the turn, and the model can fix this itself.
            return ToolOutput.invalid(error)
        }
    }
}

@Generable
struct FolderSummaryArguments {}

/// Read-only: totals for the whole snapshot.
struct FolderSummaryTool: Tool {
    let name = "folderSummary"
    let description = PromptLibrary.folderSummaryTool.text
    let context: ToolContext

    func call(arguments: FolderSummaryArguments) async -> String {
        let turn = context.recorder.turn
        guard !context.recorder.isRepeat(.summary, turn: turn) else { return ToolOutput.repeated }
        let summary = FolderSummary(await context.snapshot())
        context.recorder.record(.summary(summary), turn: turn)
        return ToolOutput.summary(summary)
    }
}

@Generable
struct FindDuplicatesArguments {}

/// Read-only: the app's Find Duplicates scan, which reads the files to compare their content. A
/// mark cannot answer this: it holds only what the last Tidy Now found.
struct FindDuplicatesTool: Tool {
    let name = "findDuplicates"
    let description = PromptLibrary.findDuplicatesTool.text
    let context: ToolContext

    func call(arguments: FindDuplicatesArguments) async -> String {
        let turn = context.recorder.turn
        guard !context.recorder.isRepeat(.duplicates, turn: turn) else { return ToolOutput.repeated }
        guard let scan = await context.findDuplicates() else {
            context.recorder.forget(.duplicates, turn: turn)
            return ToolOutput.duplicatesUnavailable
        }
        context.recorder.record(.duplicates(scan), turn: turn)
        return ToolOutput.duplicates(scan)
    }
}

/// `proposeCleanup`'s arguments as the model wrote them. Read by hand, not generated: the list of
/// actions is the app's and only known when the app runs, so the schema is built then.
struct ProposeCleanupArguments: ConvertibleFromGeneratedContent {
    var actions: [String]?
    var filter: FileFilter?
    var archiveAfterDays: Int?
    var largeFileMB: Int?
    /// The arguments that were there but not of their kind. A throw here would end the turn, and
    /// reading one as "not given" could widen a cleanup to every file, so the call is answered instead.
    var unreadable: [String] = []

    init(_ content: GeneratedContent) {
        func read<Value: ConvertibleFromGeneratedContent>(_ name: String) -> Value? {
            do {
                return try content.value(Value?.self, forProperty: name)
            } catch {
                unreadable.append(name)
                return nil
            }
        }
        actions = read("actions")
        filter = read("filter")
        archiveAfterDays = read("archiveAfterDays")
        largeFileMB = read("largeFileMB")
    }

    /// What `actions` may hold in place of every name.
    static let everyAction = "all"
    static let daysRange = 1...3650
    static let megabytesRange = 1...1_000_000

    /// The request with every argument checked, or the first problem found.
    func validated(allowed: [String], now: Date, lastResultIDs: [URL]?) throws(FilterError) -> CleanupRequest {
        if let name = unreadable.first {
            throw FilterError(message: "\(name) could not be read. Write it as the tool describes.")
        }
        let list = allowed.joined(separator: ", ")
        guard var actions, !actions.isEmpty else {
            throw FilterError(message: "actions must list one or more of: \(list).")
        }
        // "all" stands for every action: the model then has nine names fewer to write out.
        if actions.contains(where: { $0.caseInsensitiveCompare(Self.everyAction) == .orderedSame }) {
            actions = allowed
        }
        for action in actions where !allowed.contains(where: { $0.caseInsensitiveCompare(action) == .orderedSame }) {
            throw FilterError(message: "actions \"\(ToolOutput.cleaned(action, limit: 40))\" is not one of: \(list).")
        }
        func number(_ value: Int?, named name: String, in range: ClosedRange<Int>) throws(FilterError) -> Int? {
            guard let value else { return nil }
            guard range.contains(value) else {
                throw FilterError(message: "\(name) must be between \(range.lowerBound) and \(range.upperBound).")
            }
            return value
        }
        let query = try filter?.validated(now: now, lastResultIDs: lastResultIDs)
        return CleanupRequest(
            // In the app's order, each once, spelled as the app spells it.
            actions: allowed.filter { name in actions.contains { $0.caseInsensitiveCompare(name) == .orderedSame } },
            // A filter with nothing in it narrows nothing.
            query: query == FileQuery() ? nil : query,
            archiveAfterDays: try number(archiveAfterDays, named: "archiveAfterDays", in: Self.daysRange),
            largeFileMB: try number(largeFileMB, named: "largeFileMB", in: Self.megabytesRange)
        )
    }
}

/// Plans a cleanup and changes nothing: the app runs its planners and keeps the plan as a card
/// the user reviews and confirms. This module cannot carry a plan out (docs/decisions/0023).
struct ProposeCleanupTool: Tool {
    let name = "proposeCleanup"
    let description = PromptLibrary.proposeCleanupTool.text
    let parameters: GenerationSchema
    let context: ToolContext

    /// Nil when the app offers no actions, or their names make no schema.
    init?(context: ToolContext) {
        guard !context.cleanupActions.isEmpty else { return nil }
        let root = DynamicGenerationSchema(name: "ProposeCleanupArguments", properties: [
            .init(
                name: "actions", description: "Cleanups to prepare.",
                // Bounded: with no end in sight the model went on writing actions until the turn's
                // time ran out (measured: docs/decisions/0023).
                schema: DynamicGenerationSchema(
                    arrayOf: DynamicGenerationSchema(name: "CleanupAction", anyOf: context.cleanupActions + [ProposeCleanupArguments.everyAction]),
                    minimumElements: 1, maximumElements: context.cleanupActions.count
                )
            ),
            .init(name: "filter", description: "Only matching files.", schema: DynamicGenerationSchema(type: FileFilter.self), isOptional: true),
            .init(name: "archiveAfterDays", description: "Archive what was unopened this many days.", schema: DynamicGenerationSchema(type: Int.self), isOptional: true),
            .init(name: "largeFileMB", description: "Large is this many MB or more.", schema: DynamicGenerationSchema(type: Int.self), isOptional: true),
        ])
        guard let schema = try? GenerationSchema(root: root, dependencies: []) else { return nil }
        parameters = schema
        self.context = context
    }

    func call(arguments: ProposeCleanupArguments) async -> String {
        let turn = context.recorder.turn
        let snapshot = await context.snapshot()
        do throws(FilterError) {
            let request = try arguments.validated(
                allowed: context.cleanupActions, now: snapshot.now, lastResultIDs: context.recorder.previous?.ids
            )
            guard !context.recorder.isRepeat(.cleanup(request), turn: turn) else { return ToolOutput.repeated }
            let ids = request.fileIDs(in: snapshot)
            // No file matches, so no planner needs to read any.
            if ids?.isEmpty == true { return ToolOutput.nothingToCleanUp }
            guard let proposal = await context.proposeCleanup(request, ids) else {
                context.recorder.forget(.cleanup(request), turn: turn)
                return ToolOutput.cleanupUnavailable
            }
            guard !proposal.rows.isEmpty else { return ToolOutput.nothingToCleanUp }
            context.recorder.record(.cleanup(proposal), turn: turn)
            return ToolOutput.cleanup(proposal)
        } catch {
            // Returned, not thrown: a thrown error ends the turn, and the model can fix this itself.
            return ToolOutput.invalid(error)
        }
    }
}
