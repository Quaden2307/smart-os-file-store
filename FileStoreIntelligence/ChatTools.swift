import Foundation
import FoundationModels

/// What the tools work from: the app's current view of the folder, its duplicate scan, and the
/// turn's record.
struct ToolContext: Sendable {
    let snapshot: @Sendable () async -> FolderSnapshot
    /// Nil when the scan could not run.
    let findDuplicates: @Sendable () async -> DuplicateScan?
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
