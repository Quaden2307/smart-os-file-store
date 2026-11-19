import Foundation
import FoundationModels
import Synchronization

/// A language model that plays back a script, so the framework's real session and tool loop run
/// in tests without Apple Intelligence. Each time the session asks the model to respond it plays
/// the next round. A round that calls a tool ends there; the session runs the tool and comes back
/// with its output for the round after it.
struct ScriptedModel: LanguageModel {
    enum Step: Sendable {
        /// Reply text, one chunk per element.
        case text([String])
        /// Tool calls made together in one round.
        case toolCalls([ToolCall])
        /// A pause that ends early when the turn is cancelled.
        case wait(Duration)
        /// A pause that ignores cancellation: a model that will not stop.
        case stall(Duration)
        case fail(any Error)
    }

    struct ToolCall: Sendable {
        var name: String
        /// The arguments as the model would write them: JSON text.
        var arguments: String
    }

    /// The rounds still to play, and every request the session made. Reached through the model,
    /// which the framework hands to the executor on each request, so tests running side by side
    /// never share a script.
    final class Script: Sendable {
        private struct State {
            var rounds: [[Step]]
            var requests: [LanguageModelExecutorGenerationRequest] = []
        }

        private let state: Mutex<State>

        init(_ rounds: [[Step]]) {
            state = Mutex(State(rounds: rounds))
        }

        var requests: [LanguageModelExecutorGenerationRequest] {
            state.withLock { $0.requests }
        }

        /// An empty round once the script has run out, which ends the reply with no more text.
        fileprivate func nextRound(for request: LanguageModelExecutorGenerationRequest) -> [Step] {
            state.withLock { state in
                state.requests.append(request)
                return state.rounds.isEmpty ? [] : state.rounds.removeFirst()
            }
        }
    }

    let script: Script

    init(_ rounds: [Step]...) {
        script = Script(rounds)
    }

    var capabilities: LanguageModelCapabilities {
        LanguageModelCapabilities([.toolCalling, .guidedGeneration])
    }

    var executorConfiguration: Executor.Configuration {
        Executor.Configuration()
    }

    struct Executor: LanguageModelExecutor {
        struct Configuration: Hashable, Sendable {}

        init(configuration: Configuration) {}

        nonisolated(nonsending) func respond(
            to request: LanguageModelExecutorGenerationRequest,
            model: ScriptedModel,
            streamingInto channel: LanguageModelExecutorGenerationChannel
        ) async throws {
            for step in model.script.nextRound(for: request) {
                switch step {
                case .text(let chunks):
                    // The session hands its reader a snapshot two events late (measured on Xcode 27.2),
                    // so two empty fragments follow the text to push it through before any pause.
                    for chunk in chunks + ["", ""] {
                        await channel.send(.response(action: .appendText(chunk, tokenCount: 1)))
                    }
                case .toolCalls(let calls):
                    for call in calls {
                        let arguments = LanguageModelExecutorGenerationChannel.ToolCalls.ToolCall.Action
                            .appendArguments(call.arguments, tokenCount: 1)
                        await channel.send(.toolCalls(action: .toolCall(
                            id: UUID().uuidString, name: call.name, action: arguments
                        )))
                    }
                case .wait(let duration):
                    try await Task.sleep(for: duration)
                case .stall(let duration):
                    await withCheckedContinuation { continuation in
                        DispatchQueue.global().asyncAfter(deadline: .now() + duration.seconds) {
                            continuation.resume()
                        }
                    }
                case .fail(let error):
                    throw error
                }
            }
        }
    }
}

private extension Duration {
    var seconds: Double {
        Double(components.seconds) + Double(components.attoseconds) / 1e18
    }
}
