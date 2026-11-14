import FileStoreCore
import Foundation

extension FileMark {
    /// The badge text and the filter's name for the mark.
    var title: String {
        switch self {
        case .neverOpened:
            String(localized: "Never opened")
        case .unused:
            String(localized: "Unused")
        case .old:
            String(localized: "Old")
        }
    }
}
