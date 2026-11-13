import FileStoreCore
import SwiftUI

/// What carrying out a plan did: how many files went to the Trash and how much space that freed,
/// then every file that was not moved, with the reason.
struct CleanupSummaryView: View {
    let result: CleanupResult

    var body: some View {
        VStack(spacing: 0) {
            VStack(spacing: 6) {
                Image(systemName: "trash")
                    .font(.system(size: 36))
                    .foregroundStyle(.secondary)
                    .accessibilityHidden(true)
                if result.trashedCount > 0 {
                    Text("^[\(result.trashedCount) file](inflect: true) moved to the Trash")
                        .font(.title2.weight(.semibold))
                    Text("\(result.bytesFreed.formattedFileSize) freed. You can put them back from the Trash.")
                        .foregroundStyle(.secondary)
                } else {
                    Text("No Files Were Moved")
                        .font(.title2.weight(.semibold))
                    Text("Nothing in the folder was changed.")
                        .foregroundStyle(.secondary)
                }
            }
            .multilineTextAlignment(.center)
            .padding(24)
            .frame(maxWidth: .infinity)
            .accessibilityElement(children: .combine)

            if result.notMoved.isEmpty {
                Spacer(minLength: 0)
            } else {
                List {
                    Section("Not Moved") {
                        ForEach(result.notMoved) { item in
                            NotMovedRow(item: item)
                        }
                    }
                }
                .accessibilityLabel("Files not moved")
            }
        }
    }
}

/// A file that stayed where it was, and why.
private struct NotMovedRow: View {
    let item: CleanupItemResult

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            FileIconView(record: item.change.record)
            Text(item.change.record.displayName)
                .lineLimit(1)
                .truncationMode(.middle)
            Spacer()
            Text(item.outcome.localizedDescription)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.trailing)
        }
        .accessibilityElement(children: .combine)
    }
}
