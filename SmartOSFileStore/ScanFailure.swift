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

    /// Why Downloads could not be found. The other kinds of folder are not shown yet, so every
    /// case speaks of Downloads.
    init(_ error: FolderLocationError) {
        isPermissionDenied = false
        switch error {
        case .refused:
            title = String(localized: "Downloads folder can’t be used")
            message = String(
                localized: "Your Downloads folder leads to a place Smart OS File Store does not look after, such as your home folder, the top of a disk, or a system or cloud-storage folder. Move Downloads to an ordinary folder, then click Try again."
            )
        case .standardFolderUnavailable, .bookmarkUnusable:
            title = String(localized: "Downloads folder not found")
            message = String(
                localized: "Your Downloads folder could not be located. Check that a Downloads folder exists in your home folder, then open Smart OS File Store again."
            )
        case .overrideValueMissing(let source):
            title = String(localized: "No folder to scan")
            message = String(localized: "The \(source.localizedName) was given without a folder path.")
        case .overrideDoesNotExist(let path, let source):
            title = String(localized: "Folder not found")
            message = String(localized: "The folder “\(path)” from the \(source.localizedName) does not exist.")
        case .overrideIsNotAFolder(let path, let source):
            title = String(localized: "Not a folder")
            message = String(localized: "“\(path)” from the \(source.localizedName) is a file, not a folder.")
        }
    }

    init(_ error: FolderScanError) {
        switch error {
        case .folderNotFound(let url):
            isPermissionDenied = false
            title = String(localized: "Folder not found")
            message = String(
                localized: "The folder “\(url.lastPathComponent)” could not be found. Reconnect its disk or create the folder, then click Try again."
            )
        case .accessDenied(let url):
            isPermissionDenied = true
            title = String(localized: "Access to “\(url.lastPathComponent)” is blocked")
            // The error alone does not say whether macOS privacy protection or the folder's own
            // permissions refused, so the advice names the common case without asserting it.
            message = String(
                localized: "If you chose Don’t Allow when macOS asked, turn on Smart OS File Store under Files & Folders in Privacy & Security. The folder is read again when you come back."
            )
        // The system's own sentence for these usually repeats the name and is logged by the engine;
        // the window says what to do instead.
        case .folderUnreadable(let url, _):
            isPermissionDenied = false
            title = String(localized: "Folder can’t be read")
            message = String(
                localized: "“\(url.lastPathComponent)” could not be read. Check that its disk is connected, then click Try again."
            )
        case .itemUnreadable(let url, _):
            isPermissionDenied = false
            title = String(localized: "Item can’t be read")
            message = String(
                localized: "“\(url.lastPathComponent)” could not be read. Check that its disk is connected, then click Try again."
            )
        case .cancelled:
            isPermissionDenied = false
            title = String(localized: "Scan stopped")
            message = String(localized: "The scan was stopped before it finished.")
        }
    }
}

extension FolderOverride.Source {
    /// How the status line and error messages name the way the folders were chosen.
    var localizedName: String {
        switch self {
        case .demoHomeArgument:
            String(localized: "-DemoHome launch argument")
        case .scanFolderArgument:
            String(localized: "-ScanFolder launch argument")
        case .demoHomeVariable:
            String(localized: "SMARTOS_DEMO_HOME environment variable")
        case .scanFolderVariable:
            String(localized: "SMARTOS_SCAN_FOLDER environment variable")
        }
    }
}
