import Foundation
import FoundationModels

/// What both tools work from: the app's current view of the folder, and the turn's record.
struct ToolContext: Sendable {
    let snapshot: @Sendable () async -> FolderSnapshot
    let recorder: TurnRecorder
}

@Generable
struct SearchFilesArguments {
    @Guide(description: "What the files must match.")
    var filter: FileFilter?

    @Guide(description: "Order of the list.", .anyOf(["largest", "smallest", "newest", "earliest", "recentlyOpened", "leastRecentlyOpened", "name"]))
    var sort: String?

    @Guide(description: "How many to list, 1 to 100.")
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
            let query = try (arguments.filter ?? FileFilter()).validated(now: snapshot.now)
            let sort: FileSort = try FileFilter.choice(arguments.sort, named: "sort") ?? .newest
            let limit = arguments.limit ?? FileSearchResult.defaultLimit
            guard FileSearchResult.limitRange.contains(limit) else {
                throw FilterError(message: "limit must be between 1 and 100.")
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
        let summary = FolderSummary(await context.snapshot())
        context.recorder.record(.summary(summary), turn: turn)
        return ToolOutput.summary(summary)
    }
}
