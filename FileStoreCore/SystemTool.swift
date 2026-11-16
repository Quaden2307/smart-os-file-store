import Foundation
import Synchronization

/// Runs one of the system's own tools (`diskutil`, `hdiutil`, `fsck_hfs`, `fsck_apfs`, `pkgutil`) by
/// its absolute path, and waits for it without blocking a thread. Standard input is empty, so a
/// tool can never wait for a password; the environment is minimal; both outputs are drained all
/// the time and capped, so a full pipe never stalls the tool. A timeout or a cancel stops it, and
/// a run returns only once the tool has exited.
public struct SystemTool: Sendable {
    public struct Output: Sendable {
        public let status: Int32
        public let standardOutput: Data
        public let standardError: Data

        public var succeeded: Bool { status == 0 }
    }

    public enum Failure: Error, Sendable, Hashable {
        case launchFailed
        case timedOut
        case cancelled
        /// It wrote more than `outputLimit` to one of its outputs.
        case outputTooLarge
    }

    /// The most bytes kept from each output.
    public static let outputLimit = 1 << 20

    /// How long a tool gets to stop after it is asked to, before it is killed.
    static let killDelay: Duration = .seconds(2)

    /// Told of every run before it starts, with the tool and its arguments: what tests count.
    public var observer: (@Sendable (String, [String]) -> Void)?

    public init(observer: (@Sendable (String, [String]) -> Void)? = nil) {
        self.observer = observer
    }

    /// Runs `executable` with `arguments`.
    ///
    /// - Parameter ignoringCancellation: For a step that must finish whatever happens, such as
    ///   ejecting a disk image: a cancel then does not stop it, only the timeout does.
    public func run(
        _ executable: String,
        _ arguments: [String],
        timeout: Duration,
        ignoringCancellation: Bool = false
    ) async throws(Failure) -> Output {
        observer?(executable, arguments)
        if !ignoringCancellation, Task.isCancelled {
            throw .cancelled
        }
        let process = Process()
        process.executableURL = URL(filePath: executable)
        process.arguments = arguments
        process.environment = ["PATH": "/usr/bin:/bin:/usr/sbin:/sbin", "LANG": "C"]
        process.standardInput = FileHandle.nullDevice
        let output = Pipe()
        let errors = Pipe()
        process.standardOutput = output
        process.standardError = errors

        let run = Run()
        output.fileHandleForReading.readabilityHandler = { handle in run.received(handle.availableData, from: .output) }
        errors.fileHandleForReading.readabilityHandler = { handle in run.received(handle.availableData, from: .errors) }
        process.terminationHandler = { _ in run.exited() }
        do {
            try process.run()
        } catch {
            output.fileHandleForReading.readabilityHandler = nil
            errors.fileHandleForReading.readabilityHandler = nil
            throw .launchFailed
        }

        let timer = Task {
            try? await Task.sleep(for: timeout)
            guard !Task.isCancelled else { return }
            run.stop(because: .timedOut)
            await Self.stop(process)
        }
        await withTaskCancellationHandler {
            await run.finished()
        } onCancel: {
            guard !ignoringCancellation else { return }
            run.stop(because: .cancelled)
            Task { await Self.stop(process) }
        }
        timer.cancel()
        output.fileHandleForReading.readabilityHandler = nil
        errors.fileHandleForReading.readabilityHandler = nil

        let result = run.result()
        if let failure = result.failure {
            throw failure
        }
        return Output(status: process.terminationStatus, standardOutput: result.output, standardError: result.errors)
    }

    /// Asks `process` to stop, then kills it if it is still running after `killDelay`.
    private static func stop(_ process: Process) async {
        guard process.isRunning else { return }
        process.terminate()
        try? await Task.sleep(for: killDelay)
        // shortcut: the pid could in theory be reused between this check and the kill; move to
        // posix_spawn with our own waitpid if that ever matters.
        if process.isRunning {
            kill(process.processIdentifier, SIGKILL)
        }
    }
}

/// One run's state, shared by the pipes' handlers, the termination handler and the waiting task.
private final class Run: Sendable {
    enum Stream {
        case output
        case errors
    }

    private struct State {
        var output = Data()
        var errors = Data()
        var outputEnded = false
        var errorsEnded = false
        var hasExited = false
        var failure: SystemTool.Failure?
        var waiter: CheckedContinuation<Void, Never>?

        var isDone: Bool { hasExited && outputEnded && errorsEnded }
    }

    private let state = Mutex(State())

    func received(_ data: Data, from stream: Stream) {
        let waiter = state.withLock { state -> CheckedContinuation<Void, Never>? in
            if data.isEmpty {
                switch stream {
                case .output: state.outputEnded = true
                case .errors: state.errorsEnded = true
                }
            } else {
                Self.append(data, to: stream, in: &state)
            }
            return Self.takeWaiterIfDone(&state)
        }
        waiter?.resume()
    }

    func exited() {
        let waiter = state.withLock { state -> CheckedContinuation<Void, Never>? in
            state.hasExited = true
            return Self.takeWaiterIfDone(&state)
        }
        waiter?.resume()
    }

    /// Records why the run is being stopped; the first reason stands.
    func stop(because failure: SystemTool.Failure) {
        state.withLock { state in
            if state.failure == nil, !state.isDone {
                state.failure = failure
            }
        }
    }

    /// Returns once the tool has exited and both outputs have ended.
    func finished() async {
        await withCheckedContinuation { continuation in
            let resumeNow = state.withLock { state -> Bool in
                if state.isDone {
                    return true
                }
                state.waiter = continuation
                return false
            }
            if resumeNow {
                continuation.resume()
            }
        }
    }

    func result() -> (output: Data, errors: Data, failure: SystemTool.Failure?) {
        state.withLock { state in (state.output, state.errors, state.failure) }
    }

    /// Keeps `data` while the output is within the limit; past it the bytes are read and thrown
    /// away, so the tool never blocks on a full pipe, and the run fails.
    private static func append(_ data: Data, to stream: Stream, in state: inout State) {
        let kept = stream == .output ? state.output.count : state.errors.count
        guard kept + data.count <= SystemTool.outputLimit else {
            if state.failure == nil {
                state.failure = .outputTooLarge
            }
            return
        }
        switch stream {
        case .output: state.output.append(data)
        case .errors: state.errors.append(data)
        }
    }

    private static func takeWaiterIfDone(_ state: inout State) -> CheckedContinuation<Void, Never>? {
        guard state.isDone, let waiter = state.waiter else {
            return nil
        }
        state.waiter = nil
        return waiter
    }
}
