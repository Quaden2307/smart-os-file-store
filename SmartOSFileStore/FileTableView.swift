import FileStoreCore
import QuickLook
import SwiftUI

/// The sortable file table. Space or a double click opens Quick Look; the context menu and the
/// File menu reveal the selection in Finder.
struct FileTableView: View {
    @Bindable var model: FileListModel
    @Binding var selection: Set<FileRecord.ID>

    @State private var previewItem: URL?
    @State private var previewItems: [URL] = []

    var body: some View {
        Table(model.sortedRecords, selection: $selection, sortOrder: $model.sortOrder) {
            TableColumn("Name", value: \.displayName) { record in
                HStack(spacing: 6) {
                    FileIconView(record: record)
                    Text(record.displayName)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
            }
            .width(min: 160, ideal: 220)

            TableColumn("Kind", value: \.kindDescription) { record in
                Text(record.kindDescription)
                    .lineLimit(1)
            }
            .width(min: 90, ideal: 110)

            TableColumn("Size", sortUsing: KeyPathComparator(\FileRecord.sizeInBytes)) { record in
                if let size = record.formattedSize {
                    Text(size)
                        .monospacedDigit()
                } else {
                    NoValueCell(label: "No size")
                }
            }
            .width(min: 60, ideal: 70)
            .alignment(.numeric)

            TableColumn("Date Added", sortUsing: KeyPathComparator(\FileRecord.dateAdded)) { record in
                DateCell(date: record.dateAdded)
            }
            .width(min: 120, ideal: 165)

            TableColumn("Date Modified", sortUsing: KeyPathComparator(\FileRecord.dateModified)) { record in
                DateCell(date: record.dateModified)
            }
            .width(min: 120, ideal: 165)
        }
        .contextMenu(forSelectionType: FileRecord.ID.self) { ids in
            Button("Quick Look") {
                preview(ids)
            }
            Button("Reveal in Finder") {
                RevealInFinder.reveal(urls(for: ids))
            }
        } primaryAction: { ids in
            preview(ids)
        }
        .onKeyPress(.space) {
            // Space toggles, as in Finder: the panel sets the binding back to nil when it closes.
            if previewItem != nil {
                previewItem = nil
                return .handled
            }
            guard !selection.isEmpty else { return .ignored }
            preview(selection)
            return .handled
        }
        .quickLookPreview($previewItem, in: previewItems)
        .accessibilityLabel("Files")
    }

    /// The selected URLs in the table's display order.
    private func urls(for ids: Set<FileRecord.ID>) -> [URL] {
        model.sortedRecords.filter { ids.contains($0.id) }.map(\.url)
    }

    private func preview(_ ids: Set<FileRecord.ID>) {
        let urls = urls(for: ids)
        guard !urls.isEmpty else { return }
        previewItems = urls
        previewItem = urls.first
    }
}

