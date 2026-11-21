import FileStoreCore
import SwiftUI

/// The line under the table: item count and total size (of the filtered rows when a filter is on),
/// skipped items, a spinner while refreshing, and, once there is any, everything the app has moved
/// to the Trash so far. In a debug build its tooltip names the folder being scanned and the
/// activity log's file, so a hand test can see it is on a fake folder.
struct StatusBar: View {
    let model: FileListModel
    let activity: ActivityLogModel

    /// False while a place other than Downloads is shown: the item counts and the filter they
    /// follow belong to the file list.
    var showsFileCounts = true

    var body: some View {
        HStack(spacing: Design.Space.s) {
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
        .font(Design.Typography.secondary)
        .barInset()
        .frame(maxWidth: .infinity, alignment: .leading)
        #if DEBUG
        .help(debugPaths)
        #endif
    }

    #if DEBUG
    private var debugPaths: String {
        [
            model.folder.map { "Scanning \($0.url.path(percentEncoded: false)) (\(activity.folders.activeOverride?.source.localizedName ?? String(localized: "Downloads folder")))" },
            activity.location?.databaseURL.map { "Activity log at \($0.path(percentEncoded: false))" },
        ]
        .compactMap(\.self)
        .joined(separator: "\n")
    }
    #endif
}
