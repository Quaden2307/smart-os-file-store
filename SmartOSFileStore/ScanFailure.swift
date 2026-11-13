import FileStoreCore
import Foundation

/// A scan problem in the words the window shows. Keeps every user-facing sentence in the app's
/// String Catalog; the engine only reports typed errors.
struct ScanFailure: Equatable {
    /// Short heading for the error view.
    let title: String

    /// One or two sentences: what happened and what to do.
    let message: String

    /// True when macOS blocked access, so the view can offer the privacy settings.
    let isPermissionDenied: Bool

    init(_ error: ScanLocationError) {
        isPermissionDenied = false
        switch error {
        case .downloadsFolderUnavailable:
            title = String(localized: "Downloads Folder Not Found")
            message = String(localized: "Your Downloads folder could not be located.")
        case .overrideValueMissing(let source):
            title = String(localized: "No Folder to Scan")
            message = String(localized: "The \(source.localizedName) was given without a folder path.")
        case .overrideDoesNotExist(let path, let source):
            title = String(localized: "Folder Not Found")
            message = String(localized: "The folder “\(path)” from the \(source.localizedName) does not exist.")
        case .overrideIsNotAFolder(let path, let source):
            title = String(localized: "Not a Folder")
            message = String(localized: "“\(path)” from the \(source.localizedName) is a file, not a folder.")
        }
    }

    init(_ error: FolderScanError) {
        switch error {
        case .folderNotFound(let url):
            isPermissionDenied = false
            title = String(localized: "Folder Not Found")
            message = String(localized: "The folder “\(url.lastPathComponent)” could not be found.")
        case .accessDenied(let url):
            isPermissionDenied = true
            title = String(localized: "Access to “\(url.lastPathComponent)” Is Blocked")
            // The error alone does not say whether macOS privacy protection or the folder's own
            // permissions refused, so the advice names the common case without asserting it.
            message = String(
                localized: "Smart OS File Store isn’t allowed to read “\(url.lastPathComponent)”. If macOS asked for permission and you chose Don’t Allow, turn on Smart OS File Store under Files and Folders in Privacy & Security, then try again."
            )
        case .folderUnreadable(let url, let reason):
            isPermissionDenied = false
            title = String(localized: "Folder Can’t Be Read")
            message = String(localized: "“\(url.lastPathComponent)” could not be read. \(reason)")
        case .itemUnreadable(let url, let reason):
            isPermissionDenied = false
            title = String(localized: "Item Can’t Be Read")
            message = String(localized: "“\(url.lastPathComponent)” could not be read. \(reason)")
        case .cancelled:
            isPermissionDenied = false
            title = String(localized: "Scan Stopped")
            message = String(localized: "The scan was stopped before it finished.")
        }
    }
}

extension ScanLocation.Source {
    /// How the status line and error messages name the way the folder was chosen.
    var localizedName: String {
        switch self {
        case .downloadsFolder:
            String(localized: "Downloads folder")
        case .launchArgument:
            String(localized: "-ScanFolder launch argument")
        case .environmentVariable:
            String(localized: "SMARTOS_SCAN_FOLDER environment variable")
        }
    }
}
