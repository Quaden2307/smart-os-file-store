import Foundation

/// How far a cleanup action has got looking for things to change, as the app's progress line shows
/// it for every action: the items it checks, and for an action that reads whole files (Find
/// Duplicates), the bytes.
public struct CleanupPlanningProgress: Sendable, Hashable {
    /// Items checked so far, whether they turned out to be candidates or not.
    public let itemsChecked: Int

    public let itemsToCheck: Int

    /// Bytes read so far. Zero for an action that reads no whole files.
    public let bytesRead: Int64

    public let bytesToRead: Int64

    public init(itemsChecked: Int, itemsToCheck: Int, bytesRead: Int64 = 0, bytesToRead: Int64 = 0) {
        self.itemsChecked = itemsChecked
        self.itemsToCheck = itemsToCheck
        self.bytesRead = bytesRead
        self.bytesToRead = bytesToRead
    }

    /// Find Duplicates' progress: the files hashed, and their bytes.
    public init(_ progress: DuplicateScanProgress) {
        self.init(
            itemsChecked: progress.filesHashed,
            itemsToCheck: progress.filesToHash,
            bytesRead: progress.bytesHashed,
            bytesToRead: progress.bytesToHash
        )
    }

    /// Progress from 0 to 1: by bytes when the action reads any, otherwise by items. A search with
    /// nothing to check counts as complete.
    public var fractionCompleted: Double {
        if bytesToRead > 0 {
            return min(1, max(0, Double(bytesRead) / Double(bytesToRead)))
        }
        if itemsToCheck > 0 {
            return min(1, max(0, Double(itemsChecked) / Double(itemsToCheck)))
        }
        return 1
    }
}
