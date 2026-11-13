import Foundation

/// Why a folder, or one item in it, could not be scanned.
public enum FolderScanError: Error, Sendable, Equatable {
    /// The folder does not exist.
    case folderNotFound(URL)

    /// macOS refused access to the folder, for example when the user denied the app
    /// permission to read Downloads in Privacy & Security.
    case accessDenied(URL)

    /// The folder exists but could not be listed for another reason. `reason` is the system's
    /// description of the failure.
    case folderUnreadable(URL, reason: String)

    /// One item inside the folder could not be read. The scan continues; the item is reported
    /// in `FolderScanResult.skippedItems` instead of being thrown.
    case itemUnreadable(URL, reason: String)

    /// The task running the scan was cancelled before it finished.
    case cancelled
}

extension FolderScanError {
    /// Classifies the error `FileManager` threw while listing `folder`.
    init(listingError error: any Error, folder: URL) {
        if let cocoaError = error as? CocoaError {
            switch cocoaError.code {
            case .fileNoSuchFile, .fileReadNoSuchFile:
                self = .folderNotFound(folder)
                return
            case .fileReadNoPermission:
                self = .accessDenied(folder)
                return
            default:
                break
            }
            if let posixError = cocoaError.underlying as? POSIXError,
               let classified = Self.classify(posixError, folder: folder) {
                self = classified
                return
            }
        }
        if let posixError = error as? POSIXError,
           let classified = Self.classify(posixError, folder: folder) {
            self = classified
            return
        }
        self = .folderUnreadable(folder, reason: error.localizedDescription)
    }

    private static func classify(_ error: POSIXError, folder: URL) -> FolderScanError? {
        switch error.code {
        case .ENOENT:
            return .folderNotFound(folder)
        case .EACCES, .EPERM:
            return .accessDenied(folder)
        default:
            return nil
        }
    }
}
