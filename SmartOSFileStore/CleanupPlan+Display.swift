import FileStoreCore
import Foundation

extension ProposedChange.Reason {
    /// The reason in the user's words, for the preview.
    var localizedDescription: String {
        switch self {
        case .sameContent(let fileName):
            String(localized: "Same content as \(fileName)")
        }
    }
}

extension CleanupSkipReason {
    /// Why a file was not checked, in the user's words.
    var localizedDescription: String {
        switch self {
        case .changedSinceScan:
            String(localized: "Changed since the folder was scanned")
        case .notFound:
            String(localized: "No longer in the folder")
        case .accessDenied:
            String(localized: "Not allowed to read it")
        case .notDownloaded:
            String(localized: "Not downloaded to this Mac yet")
        case .unreadable(let reason):
            String(localized: "Could not be read: \(reason)")
        }
    }
}
