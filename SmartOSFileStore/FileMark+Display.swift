import FileStoreCore
import Foundation

extension FileMark {
    /// The badge text and the filter's name for the mark.
    var title: String {
        switch self {
        case .kept:
            String(localized: "Kept")
        case .failedDownload:
            String(localized: "Failed download")
        case .installed:
            String(localized: "Installed")
        case .duplicate:
            String(localized: "Duplicate")
        case .neverOpened:
            String(localized: "Never opened")
        case .unused:
            String(localized: "Unused")
        case .old:
            String(localized: "Old")
        }
    }

    /// What the list says when the filter for the mark matches nothing.
    var emptyFilterDescription: String {
        switch self {
        case .kept:
            String(localized: "No files are marked Kept.")
        case .failedDownload:
            String(localized: "No files are marked Failed download.")
        case .installed:
            String(localized: "No installer checked so far is for an installed app. Clean Up > Remove Used Installers checks them.")
        case .duplicate:
            String(localized: "No duplicates found by the last Tidy Now. Clean Up > Tidy Now looks for them.")
        case .neverOpened:
            String(localized: "No files are marked Never opened.")
        case .unused:
            String(localized: "No files are marked Unused.")
        case .old:
            String(localized: "No files are marked Old.")
        }
    }
}
