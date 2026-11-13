import Foundation

/// How far a duplicate search has got with hashing.
public struct DuplicateScanProgress: Sendable, Hashable {
    /// Files whose hashing has finished, whether it succeeded or had to be skipped.
    public let filesHashed: Int

    /// Files that share a size with another file and therefore need hashing.
    public let filesToHash: Int

    public let bytesHashed: Int64

    public let bytesToHash: Int64

    public init(filesHashed: Int, filesToHash: Int, bytesHashed: Int64, bytesToHash: Int64) {
        self.filesHashed = filesHashed
        self.filesToHash = filesToHash
        self.bytesHashed = bytesHashed
        self.bytesToHash = bytesToHash
    }

    /// Progress by bytes, from 0 to 1. A search with nothing to hash counts as complete.
    public var fractionCompleted: Double {
        guard bytesToHash > 0 else { return 1 }
        return min(1, max(0, Double(bytesHashed) / Double(bytesToHash)))
    }
}
