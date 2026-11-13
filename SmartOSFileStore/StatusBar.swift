import FileStoreCore
import SwiftUI

/// The line under the table: item count, total size, skipped items, and a spinner while
/// refreshing. Debug builds add a second line naming the folder being scanned.
struct StatusBar: View {
    let model: FileListModel

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack(spacing: 8) {
                Text("^[\(model.itemCount) item](inflect: true), \(model.totalBytes.formatted(.byteCount(style: .file, spellsOutZero: false)))")
                if !model.skippedItems.isEmpty {
                    Text("^[\(model.skippedItems.count) item](inflect: true) could not be read")
                        .foregroundStyle(.secondary)
                }
                if model.isLoading {
                    ProgressView()
                        .controlSize(.small)
                        .accessibilityLabel("Refreshing")
                }
                Spacer()
            }
            #if DEBUG
            if let location = model.location {
                Text("Scanning \(location.folderURL.path(percentEncoded: false)) (\(location.source.localizedName))")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
                    .accessibilityLabel("Folder being scanned")
                    .accessibilityValue(location.folderURL.path(percentEncoded: false))
            }
            #endif
        }
        .font(.callout)
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}
