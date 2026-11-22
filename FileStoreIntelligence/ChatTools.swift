import Foundation
import FoundationModels

/// Plans a cleanup in the app: the request, and the files it is narrowed to (nil for all). The app
/// keeps the plan and hands back rows. Nil when it could not plan.
public typealias ProposeCleanup = @Sendable (CleanupRequest, Set<URL>?) async -> CleanupProposal?

/// What the tools work from: the app's current view of the folder, its duplicate scan, its
/// cleanup planning, and the turn's record.
struct ToolContext: Sendable {
    let snapshot: @Sendable () async -> FolderSnapshot
    /// Nil when the scan could not run. Copies are found within each folder of the scope.
    let findDuplicates: @Sendable (FolderScope) async -> DuplicateScan?
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

    // No description: the name says it, and every token here is read in every turn (0029).
    var folder: String?
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
            let scope = try FolderScope.resolve(arguments.folder, in: snapshot, insideLastResult: query.withinIDs != nil)
            guard !context.recorder.isRepeat(.search(query, sort, limit: limit, scope: scope), turn: turn) else {
                return ToolOutput.repeated
            }
            let result = FileSearchResult(
                query: query, sort: sort, limit: limit, in: snapshot.narrowed(to: scope), scope: snapshot.folders.isEmpty ? nil : scope
            )
            context.recorder.record(.search(result), turn: turn)
            return ToolOutput.search(result, now: snapshot.now)
        } catch {
            // Returned, not thrown: a thrown error ends the turn, and the model can fix this itself.
            return ToolOutput.invalid(error)
        }
    }

}

// No folder argument: the room it takes is not there (0029). A summary is of the folder on
// screen; searchFiles answers totals for another folder or for all of them.
@Generable
struct FolderSummaryArguments {}

/// Read-only: totals for the whole snapshot.
struct FolderSummaryTool: Tool {
    let name = "folderSummary"
    let description = PromptLibrary.folderSummaryTool.text
    let context: ToolContext

    func call(arguments: FolderSummaryArguments) async -> String {
        let turn = context.recorder.turn
        guard !context.recorder.isRepeat(.summary(folder: nil), turn: turn) else { return ToolOutput.repeated }
        let snapshot = await context.snapshot()
        let scope: FolderScope
        do throws(FilterError) {
            scope = try FolderScope.resolve(nil, in: snapshot)
        } catch {
            return ToolOutput.invalid(error)
        }
        let summary = FolderSummary(snapshot.narrowed(to: scope), scope: snapshot.folders.isEmpty ? nil : scope)
        context.recorder.record(.summary(summary), turn: turn)
        return ToolOutput.summary(summary)
    }
}

@Generable
struct FindDuplicatesArguments {
    // No description: the name says it, and every token here is read in every turn (0029).
    var folder: String?
}

/// Read-only: the app's Find Duplicates scan, which reads the files to compare their content. A
/// mark cannot answer this: it holds only what the last Tidy Now found.
struct FindDuplicatesTool: Tool {
    let name = "findDuplicates"
    let description = PromptLibrary.findDuplicatesTool.text
    let context: ToolContext

    func call(arguments: FindDuplicatesArguments) async -> String {
        let turn = context.recorder.turn
        let asked = arguments.folder?.trimmingCharacters(in: .whitespaces).lowercased()
        guard !context.recorder.isRepeat(.duplicates(folder: asked), turn: turn) else { return ToolOutput.repeated }
        let snapshot = await context.snapshot()
        let scope: FolderScope
        do throws(FilterError) {
            scope = try FolderScope.resolve(arguments.folder, in: snapshot)
        } catch {
            context.recorder.forget(.duplicates(folder: asked), turn: turn)
            return ToolOutput.invalid(error)
        }
        guard let scan = await context.findDuplicates(scope) else {
            context.recorder.forget(.duplicates(folder: asked), turn: turn)
            return ToolOutput.duplicatesUnavailable
        }
        context.recorder.record(.duplicates(scan), turn: turn)
        // Copies are compared within a folder, never across folders.
        return ToolOutput.duplicates(scan) + (scope == .all && snapshot.folders.count > 1 ? "\n" + PromptLibrary.duplicatesPerFolder.text : "")
    }
}

/// `proposeCleanup`'s arguments as the model wrote them. Read by hand, not generated: the list of
/// actions is the app's and only known when the app runs, so the schema is built then.
struct ProposeCleanupArguments: ConvertibleFromGeneratedContent {
    var actions: [String]?
    var filter: FileFilter?
    var archiveAfterDays: Int?
    var largeFileMB: Int?
    var folder: String?
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
        folder = read("folder")
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
            // Not "Only matching files.": the model copied the filter of a search it made first,
            // narrowing a cleanup nobody had narrowed (docs/decisions/0033, round 1).
            .init(name: "filter", description: "Only if the user said which files.", schema: DynamicGenerationSchema(type: FileFilter.self), isOptional: true),
            .init(name: "archiveAfterDays", description: "Archive what was unopened this many days.", schema: DynamicGenerationSchema(type: Int.self), isOptional: true),
            .init(name: "largeFileMB", description: "Large is this many MB or more.", schema: DynamicGenerationSchema(type: Int.self), isOptional: true),
            .init(name: "folder", schema: DynamicGenerationSchema(type: String.self), isOptional: true),
        ])
        guard let schema = try? GenerationSchema(root: root, dependencies: []) else { return nil }
        parameters = schema
        self.context = context
    }

    func call(arguments: ProposeCleanupArguments) async -> String {
        let turn = context.recorder.turn
        let snapshot = await context.snapshot()
        do throws(FilterError) {
            let asked = try arguments.validated(
                allowed: context.cleanupActions, now: snapshot.now, lastResultIDs: context.recorder.previous?.ids
            )
            let scope = try FolderScope.resolve(arguments.folder, in: snapshot, insideLastResult: asked.query?.withinIDs != nil)
            // A card belongs to one folder: a request for several makes one card per folder.
            let folders: [String?] = snapshot.folders.isEmpty ? [nil] : scope.folderNames(in: snapshot)
            var outputs: [String] = []
            for folder in folders {
                var request = asked
                request.folder = folder
                outputs.append(await propose(request, in: snapshot.narrowed(to: folder.map(FolderScope.folder) ?? .all), turn: turn))
            }
            let unread = scope == .all ? snapshot.unreadableFolders.map { ToolOutput.quoted($0.name) } : []
            if !unread.isEmpty {
                outputs.append("Not prepared, as the app cannot read them now: \(unread.joined(separator: ", ")).")
            }
            return outputs.joined(separator: "\n")
        } catch {
            // Returned, not thrown: a thrown error ends the turn, and the model can fix this itself.
            return ToolOutput.invalid(error)
        }
    }

    /// One folder's card, or why there is none.
    private func propose(_ request: CleanupRequest, in snapshot: FolderSnapshot, turn: Int) async -> String {
        let prefix = request.folder.map { "\(ToolOutput.quoted($0)): " } ?? ""
        guard !context.recorder.isRepeat(.cleanup(request), turn: turn) else { return prefix + ToolOutput.repeated }
        let ids = request.fileIDs(in: snapshot)
        // No file matches, so no planner needs to read any.
        if ids?.isEmpty == true { return prefix + ToolOutput.nothingToCleanUp }
        guard let proposal = await context.proposeCleanup(request, ids) else {
            context.recorder.forget(.cleanup(request), turn: turn)
            return prefix + ToolOutput.cleanupUnavailable
        }
        let turnedOff = proposal.notOffered.isEmpty ? "" : ToolOutput.turnedOff(proposal.notOffered, in: request.folder)
        guard !proposal.rows.isEmpty else { return prefix + (turnedOff.isEmpty ? ToolOutput.nothingToCleanUp : turnedOff) }
        context.recorder.record(.cleanup(proposal), turn: turn)
        return prefix + ToolOutput.cleanup(proposal) + (turnedOff.isEmpty ? "" : "\n" + turnedOff)
    }
}
