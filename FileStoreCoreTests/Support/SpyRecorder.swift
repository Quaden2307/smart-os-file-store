import FileStoreCore
import Foundation
import Synchronization

/// A `CleanupRecording` for tests. It keeps every call in the order it arrived, can make one chosen
/// call fail the way a broken database would, and can pass the calls it lets through on to a real
/// log, so a test can watch the order of writes and read the rows they left. A started row the log
/// refused because the file is Kept was not written, so it is not among the calls.
final class SpyRecorder: CleanupRecording {
    enum Kind: Sendable, Hashable {
        case beginRun
        case recordIntent
        case recordResult
        case finishRun
        case beginUndoRun
        case recordUndoIntent
        case recordUndoResult
        case finishUndoRun
    }

    enum Call: Sendable, Hashable {
        case beginRun(CleanupRunStart)
        case recordIntent(CleanupChangeIntent)
        case recordResult(CleanupChangeResult)
        case finishRun(CleanupRunFinish)
        case beginUndoRun(UndoRunStart)
        case recordUndoIntent(UndoChangeIntent)
        case recordUndoResult(UndoChangeResult)
        case finishUndoRun(UndoRunFinish)

        var kind: Kind {
            switch self {
            case .beginRun: .beginRun
            case .recordIntent: .recordIntent
            case .recordResult: .recordResult
            case .finishRun: .finishRun
            case .beginUndoRun: .beginUndoRun
            case .recordUndoIntent: .recordUndoIntent
            case .recordUndoResult: .recordUndoResult
            case .finishUndoRun: .finishUndoRun
            }
        }

        /// The name of the file the call is about, for calls about one file. For undo, the name the
        /// file goes back to.
        var fileName: String? {
            switch self {
            case .recordIntent(let intent): intent.change.record.displayName
            case .recordResult(let result): result.item.change.record.displayName
            case .recordUndoIntent(let intent): intent.step.originalName
            case .recordUndoResult(let result): result.item.originalName
            case .beginRun, .finishRun, .beginUndoRun, .finishUndoRun: nil
            }
        }
    }

    /// Makes the `occurrence`-th call of `kind` (from zero) throw `error` instead of being recorded.
    struct Failure: Sendable {
        let kind: Kind
        let occurrence: Int
        var error: ActivityLogError = .writeFailed(code: 13)
    }

    private struct State {
        var calls: [Call] = []
        var seen: [Kind: Int] = [:]
        var nextID: Int64 = 1
    }

    private let state = Mutex(State())
    private let failure: Failure?
    private let log: ActivityLog?

    /// - Parameters:
    ///   - failure: The one call to fail, if any. A failed call is not passed on.
    ///   - log: A real log that receives every call that did not fail.
    init(failing failure: Failure? = nil, forwardingTo log: ActivityLog? = nil) {
        self.failure = failure
        self.log = log
    }

    /// Every call that was let through, in order.
    var calls: [Call] {
        state.withLock { $0.calls }
    }

    /// `beginRun`, `recordIntent a.txt`, `recordResult a.txt`…: the calls as a test reads them.
    var callNames: [String] {
        calls.map { call in
            let name = switch call.kind {
            case .beginRun: "beginRun"
            case .recordIntent: "recordIntent"
            case .recordResult: "recordResult"
            case .finishRun: "finishRun"
            case .beginUndoRun: "beginUndoRun"
            case .recordUndoIntent: "recordUndoIntent"
            case .recordUndoResult: "recordUndoResult"
            case .finishUndoRun: "finishUndoRun"
            }
            return call.fileName.map { "\(name) \($0)" } ?? name
        }
    }

    var results: [CleanupChangeResult] {
        calls.compactMap { call in
            if case .recordResult(let result) = call {
                return result
            }
            return nil
        }
    }

    /// Counts the call, and throws when it is the one chosen to fail.
    private func admit(_ kind: Kind) throws(ActivityLogError) {
        let occurrence = state.withLock { state -> Int in
            let occurrence = state.seen[kind, default: 0]
            state.seen[kind] = occurrence + 1
            return occurrence
        }
        if let failure, failure.kind == kind, failure.occurrence == occurrence {
            throw failure.error
        }
    }

    private func remember(_ call: Call) -> Int64 {
        state.withLock { state in
            state.calls.append(call)
            defer { state.nextID += 1 }
            return state.nextID
        }
    }

    func beginRun(_ start: CleanupRunStart) throws(ActivityLogError) -> Int64 {
        try admit(.beginRun)
        let id = try log?.beginRun(start)
        return remember(.beginRun(start), keepingID: id)
    }

    /// Without a real log, nothing is Kept.
    func recordIntent(_ intent: CleanupChangeIntent) throws(ActivityLogError) -> CleanupIntentDecision {
        try admit(.recordIntent)
        guard let log else {
            return .recorded(rowID: remember(.recordIntent(intent)))
        }
        let decision = try log.recordIntent(intent)
        if case .recorded(let rowID) = decision {
            return .recorded(rowID: remember(.recordIntent(intent), keepingID: rowID))
        }
        return decision
    }

    func recordResult(_ result: CleanupChangeResult) throws(ActivityLogError) {
        try admit(.recordResult)
        try log?.recordResult(result)
        _ = remember(.recordResult(result))
    }

    func finishRun(_ finish: CleanupRunFinish) throws(ActivityLogError) {
        try admit(.finishRun)
        try log?.finishRun(finish)
        _ = remember(.finishRun(finish))
    }

    func beginUndoRun(_ start: UndoRunStart) throws(ActivityLogError) -> Int64 {
        try admit(.beginUndoRun)
        let id = try log?.beginUndoRun(start)
        return remember(.beginUndoRun(start), keepingID: id)
    }

    /// Without a real log, every change counts as recorded and not undone yet.
    func recordUndoIntent(_ intent: UndoChangeIntent) throws(ActivityLogError) -> UndoIntentDecision {
        try admit(.recordUndoIntent)
        guard let log else {
            return .recorded(rowID: remember(.recordUndoIntent(intent)))
        }
        let decision = try log.recordUndoIntent(intent)
        if case .recorded(let rowID) = decision {
            return .recorded(rowID: remember(.recordUndoIntent(intent), keepingID: rowID))
        }
        return decision
    }

    func recordUndoResult(_ result: UndoChangeResult) throws(ActivityLogError) {
        try admit(.recordUndoResult)
        try log?.recordUndoResult(result)
        _ = remember(.recordUndoResult(result))
    }

    func finishUndoRun(_ finish: UndoRunFinish) throws(ActivityLogError) {
        try admit(.finishUndoRun)
        try log?.finishUndoRun(finish)
        _ = remember(.finishUndoRun(finish))
    }

    /// Remembers the call and returns the real log's identifier when there is one, else its own.
    private func remember(_ call: Call, keepingID id: Int64?) -> Int64 {
        let own = remember(call)
        return id ?? own
    }
}

extension ActivityLog {
    /// A started row for a change the test knows is not Kept: the row's identifier.
    func recordedIntent(_ intent: CleanupChangeIntent) throws -> Int64 {
        guard case .recorded(let rowID) = try recordIntent(intent) else {
            throw UnexpectedlyKept()
        }
        return rowID
    }
}

/// A test wrote a started row for a file it had not marked Kept, and the log said it was Kept.
struct UnexpectedlyKept: Error {}

extension CleanupExecutor {
    /// The executor as most tests use it: recording into a throwaway `SpyRecorder`. The engine
    /// itself has no executor without a recorder; tests about the log pass their own.
    init(hasher: ContentHasher = ContentHasher(), eligibility: CandidateEligibility = CandidateEligibility()) {
        self.init(recorder: SpyRecorder(), hasher: hasher, eligibility: eligibility)
    }
}
