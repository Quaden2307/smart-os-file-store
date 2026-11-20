import FileStoreCore
import SwiftUI

/// One large download in the preview: its checkbox, name, reason, and the facts the user decides
/// with (kind, date added, last opened, where it came from), and the space it takes on disk.
/// Nothing is ticked for the user.
struct LargeDownloadRow: View {
    let change: ProposedChange
    @Binding var isTicked: Bool
    let isEnabled: Bool
    let focusedCheckbox: FocusState<URL?>.Binding

    private var record: FileRecord { change.record }

    var body: some View {
        HStack(spacing: Design.Space.s) {
            // The label is hidden but still read by VoiceOver.
            Toggle(isOn: $isTicked) {
                Text("Move \(record.displayName) to the Trash")
            }
            .toggleStyle(.checkbox)
            .labelsHidden()
            .disabled(!isEnabled)
            .focused(focusedCheckbox, equals: record.id)
            // One VoiceOver element after the checkbox: name, reason, facts and size.
            HStack(spacing: Design.Space.s) {
                FileIconView(record: record)
                VStack(alignment: .leading, spacing: Design.Space.tight) {
                    Text(record.displayName)
                        .lineLimit(1)
                        .truncationMode(.middle)
                    Text(change.reason.localizedDescription)
                        .font(Design.Typography.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                    HStack(spacing: Design.Space.s) {
                        Text(record.kindDescription)
                            .lineLimit(1)
                        HStack(spacing: Design.Space.xs) {
                            Text("Added")
                            DateCell(date: record.dateAdded)
                        }
                        HStack(spacing: Design.Space.xs) {
                            Text("Opened")
                            LastOpenedCell(record: record)
                        }
                        if let source = record.downloadSourceTooltip {
                            Text(source)
                                .lineLimit(1)
                                .truncationMode(.middle)
                        }
                    }
                    .font(Design.Typography.caption)
                    .foregroundStyle(.secondary)
                }
                Spacer()
                Text((change.reason.sizeOnDisk ?? 0).formattedFileSize)
                    .foregroundStyle(.secondary)
                    .frame(minWidth: Design.Size.sizeColumn, alignment: .trailing)
                    .help(Text("Space on disk"))
            }
            .accessibilityElement(children: .combine)
        }
    }
}

extension CleanupPlan {
    /// For Review Large Downloads: the space the listed items take on disk, and the share of the
    /// folder's top-level total that is. Nil for any other plan, or one listing nothing.
    var largeDownloadsShare: (listed: Int64, total: Int64, fraction: Double)? {
        guard action == .reviewLargeDownloads, let total = topLevelSizeOnDisk, total > 0, !changes.isEmpty else {
            return nil
        }
        let listed = changes.reduce(Int64(0)) { $0 + ($1.reason.sizeOnDisk ?? 0) }
        return (listed, total, min(1, Double(listed) / Double(total)))
    }
}

extension ProposedChange.Reason {
    /// The space on disk a large download's reason states. Nil for every other reason.
    var sizeOnDisk: Int64? {
        if case .largeDownload(let sizeOnDisk, _, _) = self {
            return sizeOnDisk
        }
        return nil
    }
}
