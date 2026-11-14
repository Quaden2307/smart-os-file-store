import Foundation

extension Duration {
    /// The duration in milliseconds, for timing lines in the log.
    public var milliseconds: Double {
        Double(components.seconds) * 1_000 + Double(components.attoseconds) / 1e15
    }
}
