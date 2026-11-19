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
    /// Every match, for a follow-up that searches inside this result.
    public var matchIDs: [URL]
    /// For a query about when files were opened: the items that fit the rest of it but that macOS
    /// keeps no date for (folders, apps, links, a volume without the attribute). Unknown, so they
    /// are not counted as matches, and said to be unknown instead of left out in silence.
    public var unknownOpenCount = 0

    public static let defaultLimit = 20
    public static let limitRange = 1...100

    public init(query: FileQuery, sort: FileSort, limit: Int, in snapshot: FolderSnapshot) {
        let matches = sort.sorted(snapshot.files.filter(query.matches))
        self.query = query
        self.sort = sort
        matchCount = matches.count
        totalBytes = matches.reduce(0) { $0 + ($1.sizeInBytes ?? 0) }
        files = Array(matches.prefix(limit))
        matchIDs = matches.map(\.id)
        if query.asksAboutOpens {
            var rest = query
            rest.neverOpened = false
            rest.opened = FileQuery.DateRange()
            unknownOpenCount = snapshot.files.count { $0.lastOpened == nil && !$0.recordsOpens && rest.matches($0) }
        }
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
        case duplicates(DuplicateScan)
    }

    public var results: [Result] = []

    public init() {}
}

/// A lookup by what it asks, so the same one again in a turn can be told apart from another.
enum Lookup: Hashable {
    case search(FileQuery, FileSort, limit: Int)
    case summary
    case duplicates

    /// True when this lookup found all that `other` asks for: the same one, or the same search
    /// listing as many files or more. (The model was seen searching for everything, then for
    /// everything again with a limit of 1.)
    func covers(_ other: Lookup) -> Bool {
        if case let .search(query, sort, limit) = self, case let .search(otherQuery, otherSort, otherLimit) = other {
            return query == otherQuery && sort == otherSort && limit >= otherLimit
        }
        return self == other
    }
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
        var lookups: [Lookup] = []
        var effects = TurnEffects()
        var earlierTurnsShown = Int.max
        var note: String?
        var previous: LastResult?
    }

    private let state = Mutex(State())

    /// Starts a turn with an empty record and a full budget of tool calls, in which the model is
    /// shown at most `earlierTurns` of the turns before it and `note` before the question
    /// (`ChatHistory`), and `previous` is what a search inside the last result looks in.
    func begin(showingEarlierTurns earlierTurns: Int = .max, note: String? = nil, previous: LastResult? = nil) {
        state.withLock { $0 = State(turn: $0.turn + 1, earlierTurnsShown: earlierTurns, note: note, previous: previous) }
    }

    /// What the history transform shows the model: how many earlier turns, and the note.
    var shown: (earlierTurns: Int, note: String?) {
        state.withLock { ($0.earlierTurnsShown, $0.note) }
    }

    /// The result the turn before ended on.
    var previous: LastResult? {
        state.withLock { $0.previous }
    }

    var turn: Int {
        state.withLock { $0.turn }
    }

    var earlierTurnsShown: Int {
        state.withLock { $0.earlierTurnsShown }
    }

    /// True when `turn` already made a lookup that covers this one. It then does not run: the
    /// model is told it has the result, and the app draws it once (the same lookup three times
    /// drew three lines).
    func isRepeat(_ lookup: Lookup, turn: Int) -> Bool {
        state.withLock { state in
            guard state.turn == turn else { return false }
            if state.lookups.contains(where: { $0.covers(lookup) }) { return true }
            state.lookups.append(lookup)
            return false
        }
    }

    /// Takes back a lookup that found nothing to keep, so the model may try it again.
    func forget(_ lookup: Lookup, turn: Int) {
        state.withLock { state in
            if state.turn == turn { state.lookups.removeAll { $0 == lookup } }
        }
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

    /// Keeps a result, unless it comes from a call of an earlier turn that finished late. A search
    /// for the same files as an earlier one in the turn (in another order, or more of them) takes
    /// its place, so the app draws one line for them.
    func record(_ result: TurnEffects.Result, turn: Int) {
        state.withLock { state in
            guard state.turn == turn else { return }
            if case .search(let search) = result {
                state.effects.results.removeAll { earlier in
                    if case .search(let earlier) = earlier { earlier.query == search.query } else { false }
                }
            }
            state.effects.results.append(result)
        }
    }

    var effects: TurnEffects {
        state.withLock { $0.effects }
    }
}
