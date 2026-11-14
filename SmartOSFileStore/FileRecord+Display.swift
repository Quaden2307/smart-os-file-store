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
        sizeInBytes?.formattedFileSize
    }

    /// The row's tooltip: the site the file came from and the app that downloaded it, whichever
    /// macOS recorded. Nil when it recorded neither.
    var downloadSourceTooltip: String? {
        guard let downloadSource else { return nil }
        switch (downloadSource.site, downloadSource.downloadingApp) {
        case let (site?, app?):
            return String(localized: "Downloaded from \(site) with \(app)")
        case let (site?, nil):
            return String(localized: "Downloaded from \(site)")
        case let (nil, app?):
            return String(localized: "Downloaded with \(app)")
        case (nil, nil):
            return nil
        }
    }
}

extension Int64 {
    /// A byte count the way Finder shows one, for example "21 bytes" or "209.7 MB".
    var formattedFileSize: String {
        formatted(.byteCount(style: .file, spellsOutZero: false))
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
