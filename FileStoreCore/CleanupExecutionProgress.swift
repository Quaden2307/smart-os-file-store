import Foundation

/// How far carrying out a plan has got.
public struct CleanupExecutionProgress: Sendable, Hashable {
    /// Confirmed items dealt with so far, whether moved, skipped or failed.
    public let itemsCompleted: Int

    public let itemsTotal: Int

    /// Bytes of the files moved to the Trash so far.
    public let bytesFreed: Int64

    public init(itemsCompleted: Int, itemsTotal: Int, bytesFreed: Int64) {
        self.itemsCompleted = itemsCompleted
        self.itemsTotal = itemsTotal
        self.bytesFreed = bytesFreed
    }

    /// Progress by items, from 0 to 1. A run with nothing to do counts as complete.
    public var fractionCompleted: Double {
        guard itemsTotal > 0 else { return 1 }
        return min(1, max(0, Double(itemsCompleted) / Double(itemsTotal)))
    }
}
