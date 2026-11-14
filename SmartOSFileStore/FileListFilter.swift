import FileStoreCore
import Foundation

/// Which rows the file table shows: all of them, or those carrying one mark.
enum FileListFilter: Hashable, Identifiable {
    case all
    case marked(FileMark)

    /// The choices above the table and in the View menu: All, then every mark in display order.
    static let options: [FileListFilter] = [.all] + FileMark.allCases.map(FileListFilter.marked)

    var id: Self { self }

    var title: String {
        switch self {
        case .all:
            String(localized: "All")
        case .marked(let mark):
            mark.title
        }
    }
}
