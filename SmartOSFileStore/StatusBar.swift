import FileStoreCore
import SwiftUI

/// The line under the table: item count and total size (of the filtered rows when a filter is on),
/// skipped items, a spinner while refreshing, and, once there is any, everything the app has moved
/// to the Trash so far. Debug builds add two lines naming the folder being scanned and the
/// activity log's file.
struct StatusBar: View {
    let model: FileListModel
    let activity: ActivityLogModel

    /// False while a place other than Downloads is shown: the item counts and the filter they
    /// follow belong to the file list.
    var showsFileCounts = true

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack(spacing: 8) {
                if showsFileCounts {
                    if model.filter == .all {
                        Text("^[\(model.itemCount) item](inflect: true), \(model.totalBytes.formattedFileSize)")
                    } else {
                        Text("\(model.visibleCount) of ^[\(model.itemCount) item](inflect: true), \(model.visibleBytes.formattedFileSize)")
                    }
                    if !model.skippedItems.isEmpty {
                        Text("^[\(model.skippedItems.count) item](inflect: true) could not be read")
                            .foregroundStyle(.secondary)
                    }
                    if model.isLoading {
                        ProgressView()
                            .controlSize(.small)
                            .accessibilityLabel("Refreshing")
                    }
                }
                Spacer()
                if activity.totals.bytesMovedToTrash > 0 {
                    // Everything every cleanup has moved there. "Moved", not "freed": the space
                    // only comes back when the Trash is emptied.
                    Text("\(activity.totals.bytesMovedToTrash.formattedFileSize) moved to the Trash in total")
                        .foregroundStyle(.secondary)
                        .help("Everything Smart OS File Store has moved to the Trash so far. The space is free once you empty the Trash.")
                }
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
            if let databaseURL = activity.location?.databaseURL {
                Text("Activity log at \(databaseURL.path(percentEncoded: false))")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
                    .accessibilityLabel("Activity log file")
                    .accessibilityValue(databaseURL.path(percentEncoded: false))
            }
            #endif
        }
        .font(.callout)
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}
