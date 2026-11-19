import Foundation
import Synchronization

/// What `searchFiles` found: every match counted and summed, and the first `limit` of them in order.
public struct FileSearchResult: Sendable, Equatable {
    public var query: FileQuery
    public var sort: FileSort
    public var matchCount: Int
    /// Of every match with a known size, not only the listed ones.
    public var totalBytes: Int64
    public var files: [FolderSnapshot.File]

    public static let defaultLimit = 20
    public static let limitRange = 1...100

    public init(query: FileQuery, sort: FileSort, limit: Int, in snapshot: FolderSnapshot) {
        let matches = sort.sorted(snapshot.files.filter(query.matches))
        self.query = query
        self.sort = sort
        matchCount = matches.count
        totalBytes = matches.reduce(0) { $0 + ($1.sizeInBytes ?? 0) }
        files = Array(matches.prefix(limit))
    }
}

/// What `folderSummary` reports about the whole folder.
public struct FolderSummary: Sendable, Equatable {
    public struct Total: Sendable, Equatable {
        public var count = 0
        public var bytes: Int64 = 0
    }

    public static let largestCount = 10

    public var all = Total()
    public var byTypeGroup: [FileTypeGroup: Total] = [:]
    public var byMark: [FolderSnapshot.Mark: Total] = [:]
    public var largest: [FolderSnapshot.File]
    public var bytesMovedToTrash: Int64?

    public init(_ snapshot: FolderSnapshot) {
        for file in snapshot.files {
            let bytes = file.sizeInBytes ?? 0
            func add(to total: inout Total) {
                total.count += 1
                total.bytes += bytes
            }
            add(to: &all)
            add(to: &byTypeGroup[FileTypeGroup(contentType: file.contentType), default: Total()])
            for mark in file.marks {
                add(to: &byMark[mark, default: Total()])
            }
        }
        largest = Array(FileSort.largest.sorted(snapshot.files.filter { $0.sizeInBytes != nil }).prefix(Self.largestCount))
        bytesMovedToTrash = snapshot.bytesMovedToTrash
    }
}

/// The full results of one turn's tool calls, in the order they finished. The app draws its file
/// rows and numbers from this; the model only ever gets `ToolOutput`'s short text.
public struct TurnEffects: Sendable, Equatable {
    public enum Result: Sendable, Equatable {
        case search(FileSearchResult)
        case summary(FolderSummary)
    }

    public var results: [Result] = []

    public init() {}
}

/// Why the tool-call hook refused a call.
enum ToolRefusal: Error {
    case notRegistered
    case overLimit
}

/// One conversation's record of the turn in progress, shared by the session's tool-call hook and
/// its tools, which the session may run several at a time.
final class TurnRecorder: Sendable {
    private struct State {
        var turn = 0
        var calls = 0
        var effects = TurnEffects()
    }

    private let state = Mutex(State())

    /// Starts a turn with an empty record and a full budget of tool calls.
    func begin() {
        state.withLock { $0 = State(turn: $0.turn + 1) }
    }

    var turn: Int {
        state.withLock { $0.turn }
    }

    /// Counts a tool call, or refuses it: only a registered tool, and only `limit` calls a turn.
    func admit(_ toolName: String, registered: Set<String>, limit: Int) throws(ToolRefusal) {
        guard registered.contains(toolName) else { throw .notRegistered }
        let allowed = state.withLock { state in
            state.calls += 1
            return state.calls <= limit
        }
        guard allowed else { throw .overLimit }
    }

    /// Keeps a result, unless it comes from a call of an earlier turn that finished late.
    func record(_ result: TurnEffects.Result, turn: Int) {
        state.withLock { state in
            if state.turn == turn { state.effects.results.append(result) }
        }
    }

    var effects: TurnEffects {
        state.withLock { $0.effects }
    }
}
