import Foundation
import FoundationModels

/// Reads a message into a `ChatRequest` with one guided generation: no tools, no history, nothing
/// to loop on. A fresh session each turn, so no earlier message can steer this one; what the app
/// remembers reaches it as one line written by code (docs/decisions/0035). Not used by the app yet.
public struct ChatParser: Sendable {
    public enum ParseError: Error, Equatable {
        case timedOut
    }

    private let model: any LanguageModel
    private let cleanupActions: [String]
    private let timeLimit: Duration

    /// - Parameter cleanupActions: The actions offered, as the app names them, with those the
    ///   folders' rules turn off left out.
    public init(model: any LanguageModel = SystemLanguageModel.default, cleanupActions: [String], timeLimit: Duration = ChatEngine.turnLimit) {
        self.model = model
        self.cleanupActions = cleanupActions
        self.timeLimit = timeLimit
    }

    /// The request in `message`. `lastResult` is the files the last turn ended on, if any.
    public func parse(_ message: String, in snapshot: FolderSnapshot, lastResult: [URL]? = nil) async throws -> ChatRequest {
        let schema = try Self.schema(cleanupActions: cleanupActions, folders: snapshot.folders.map(\.name))
        let profile = LanguageModelSession.Profile { Instructions(PromptLibrary.parse.text) }
            .model(model)
            .samplingMode(.greedy)
        let session = LanguageModelSession(profile: profile)
        let prompt = [lastResult.flatMap { Self.lastResultLine($0, in: snapshot) }, message].compactMap(\.self).joined(separator: "\n")
        let limit = timeLimit
        return try await withThrowingTaskGroup(of: ChatRequest.self) { group in
            group.addTask { try ChatRequest(try await session.respond(to: prompt, schema: schema).content) }
            group.addTask {
                try await Task.sleep(for: limit)
                throw ParseError.timedOut
            }
            defer { group.cancelAll() }
            guard let request = try await group.next() else { throw CancellationError() }
            return request
        }
    }

    /// The one line the parser reads about the last result: how many files and of which kinds,
    /// written by code. Never a name: a name is data from the disk, and here it would sit outside
    /// the marks that say so. Nil when there is no last result.
    /// Files gone from the folder since are not counted; nil when none is left.
    public static func lastResultLine(_ ids: [URL], in snapshot: FolderSnapshot) -> String? {
        let wanted = Set(ids)
        let files = snapshot.files.filter { wanted.contains($0.id) }
        guard !files.isEmpty else { return nil }
        let kinds = Set(files.map { FileTypeGroup(contentType: $0.contentType).rawValue })
        return PromptLibrary.parseLastResult.text
            .replacingOccurrences(of: "{count}", with: files.count == 1 ? "1 file" : "\(files.count) files")
            .replacingOccurrences(of: "{kinds}", with: kinds.sorted().joined(separator: ", "))
    }

    /// `ChatRequest`'s schema with the lists only known when the app runs: the cleanups whose action
    /// is offered, and the managed folders. Built as `ProposeCleanupTool` builds its own.
    public static func schema(cleanupActions: [String], folders: [String]) throws -> GenerationSchema {
        let intents = CleanupIntent.allCases.filter { $0.action.map(cleanupActions.contains) ?? true }
        var properties: [DynamicGenerationSchema.Property] = [
            .init(name: "kind", schema: DynamicGenerationSchema(type: ChatRequest.Kind.self)),
            .init(
                name: "cleanups", description: "Only for kind cleanup.",
                // Bounded, as proposeCleanup's actions are: unbounded, the model wrote on until the
                // turn's time ran out (docs/decisions/0023).
                schema: DynamicGenerationSchema(
                    arrayOf: DynamicGenerationSchema(name: "CleanupIntent", anyOf: intents.map { intent in
                        DynamicGenerationSchema(name: intent.rawValue, description: intent.guide, anyOf: [intent.rawValue])
                    }),
                    maximumElements: intents.count
                ),
                isOptional: true
            ),
            .init(name: "files", schema: DynamicGenerationSchema(type: FileSlots.self), isOptional: true),
            .init(name: "sort", schema: DynamicGenerationSchema(name: "Sort", anyOf: FileSort.allCases.map(\.rawValue)), isOptional: true),
            .init(name: "limit", schema: DynamicGenerationSchema(type: Int.self), isOptional: true),
        ]
        // Folder names are the user's and the disk's: cleaned and cut short like any data the model
        // reads, each once. "all" is offered only when no folder is called that.
        var names: [String] = []
        for name in folders.map({ ToolOutput.cleaned($0, limit: 40) }) where !name.isEmpty {
            if !names.contains(where: { $0.caseInsensitiveCompare(name) == .orderedSame }) { names.append(name) }
        }
        if names.count > 1, !names.contains(where: { $0.caseInsensitiveCompare("all") == .orderedSame }) { names.append("all") }
        if !names.isEmpty {
            properties.append(.init(name: "folder", schema: DynamicGenerationSchema(name: "Folder", anyOf: names), isOptional: true))
        }
        properties += [
            .init(name: "aboutLastResult", description: "true for those, them, the last result.", schema: DynamicGenerationSchema(type: Bool.self), isOptional: true),
            .init(name: "cannotDo", schema: DynamicGenerationSchema(type: ChatRequest.CannotDo.self), isOptional: true),
        ]
        return try GenerationSchema(root: DynamicGenerationSchema(name: "ChatRequest", properties: properties), dependencies: [])
    }

    /// What the model reads before any message, in tokens: the instructions and the schema.
    public static func fixedPromptTokens(cleanupActions: [String], folders: [String]) async throws -> (instructions: Int, schema: Int) {
        let model = SystemLanguageModel.default
        return (
            try await model.tokenCount(for: Instructions(PromptLibrary.parse.text)),
            try await model.tokenCount(for: try schema(cleanupActions: cleanupActions, folders: folders))
        )
    }

    /// The schema as sorted JSON. `PromptLibraryTests` pins its hash with `PromptLibrary.version`.
    public static func definition(cleanupActions: [String], folders: [String]) throws -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        return String(decoding: try encoder.encode(try schema(cleanupActions: cleanupActions, folders: folders)), as: UTF8.self)
    }
}
