import FileStoreCore
import Foundation
import Synchronization

/// A `CleanupRecording` for tests. It keeps every call in the order it arrived, can make one chosen
/// call fail the way a broken database would, and can pass the calls it lets through on to a real
/// log, so a test can watch the order of writes and read the rows they left.
final class SpyRecorder: CleanupRecording {
    enum Kind: Sendable, Hashable {
        case beginRun
        case recordIntent
        case recordResult
        case finishRun
    }

    enum Call: Sendable, Hashable {
        case beginRun(CleanupRunStart)
        case recordIntent(CleanupChangeIntent)
        case recordResult(CleanupChangeResult)
        case finishRun(CleanupRunFinish)

        var kind: Kind {
            switch self {
            case .beginRun: .beginRun
            case .recordIntent: .recordIntent
            case .recordResult: .recordResult
            case .finishRun: .finishRun
            }
        }

        /// The name of the file the call is about, for calls about one file.
        var fileName: String? {
            switch self {
            case .recordIntent(let intent): intent.change.record.displayName
            case .recordResult(let result): result.item.change.record.displayName
            case .beginRun, .finishRun: nil
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

    func recordIntent(_ intent: CleanupChangeIntent) throws(ActivityLogError) -> Int64 {
        try admit(.recordIntent)
        let id = try log?.recordIntent(intent)
        return remember(.recordIntent(intent), keepingID: id)
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

    /// Remembers the call and returns the real log's identifier when there is one, else its own.
    private func remember(_ call: Call, keepingID id: Int64?) -> Int64 {
        let own = remember(call)
        return id ?? own
    }
}

extension CleanupExecutor {
    /// The executor as most tests use it: recording into a throwaway `SpyRecorder`. The engine
    /// itself has no executor without a recorder; tests about the log pass their own.
    init(hasher: ContentHasher = ContentHasher(), eligibility: CandidateEligibility = CandidateEligibility()) {
        self.init(recorder: SpyRecorder(), hasher: hasher, eligibility: eligibility)
    }
}
