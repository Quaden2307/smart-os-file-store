import Foundation

/// Which of a conversation's cleanup cards may still be confirmed. The plans are the app's; this
/// holds only the rules, so they are in one place: the newest card is the current one, and only
/// a current card that is still ready can be reviewed or confirmed.
public struct CleanupCards: Sendable, Equatable {
    public enum State: Sendable, Equatable {
        case ready
        /// One of its files changed on disk, or a newer card took its place. Refresh plans it again.
        case outOfDate
        case confirmed
    }

    private var states: [CleanupProposal.ID: State] = [:]
    public private(set) var current: CleanupProposal.ID?

    public init() {}

    public func state(of id: CleanupProposal.ID) -> State? {
        states[id]
    }

    /// A card came on screen, or was planned again. It is now the current one, and the one before
    /// it, if still waiting, is out of date.
    public mutating func show(_ id: CleanupProposal.ID) {
        if let current, current != id, states[current] == .ready {
            states[current] = .outOfDate
        }
        current = id
        states[id] = .ready
    }

    /// One of the card's files is no longer as it was planned.
    public mutating func filesChanged(_ id: CleanupProposal.ID) {
        if states[id] == .ready {
            states[id] = .outOfDate
        }
    }

    /// True while the card may be reviewed and confirmed.
    public func canConfirm(_ id: CleanupProposal.ID) -> Bool {
        id == current && states[id] == .ready
    }

    /// True while Refresh is offered.
    public func canRefresh(_ id: CleanupProposal.ID) -> Bool {
        states[id] == .outOfDate
    }

    /// The card's plan was carried out. A card that was run never goes back to waiting.
    public mutating func executed(_ id: CleanupProposal.ID) {
        if states[id] != nil {
            states[id] = .confirmed
        }
    }
}
