import FileStoreCore
import Foundation

extension FileRecord {
    /// The Kind column: macOS's description of the type, or a plain fallback when it has none.
    var kindDescription: String {
        if let localizedTypeDescription, !localizedTypeDescription.isEmpty {
            return localizedTypeDescription
        }
        return kind.fallbackDescription
    }

    /// The Size column text. Nil for folders and packages, which show a dash.
    var formattedSize: String? {
        sizeInBytes?.formatted(.byteCount(style: .file, spellsOutZero: false))
    }
}

extension FileRecord.Kind {
    var fallbackDescription: String {
        switch self {
        case .file:
            String(localized: "File")
        case .folder:
            String(localized: "Folder")
        case .symlink:
            String(localized: "Alias")
        case .package:
            String(localized: "Package")
        }
    }
}
