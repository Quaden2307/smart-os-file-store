import FileStoreCore
import SwiftUI

// The rows of the cleanup preview: the kept copy and its duplicates for a plan with groups, one row
// per change for any other plan, and the files the action could not check.

/// The copy that stays, marked Keep. Selectable and previewable like any row, but with no checkbox.
struct KeptFileRow: View {
    let record: FileRecord

    var body: some View {
        HStack(spacing: 8) {
            // Takes the checkbox's place so the names line up.
            Color.clear
                .frame(width: DuplicateFileRow.checkboxWidth, height: 1)
                .accessibilityHidden(true)
            FileIconView(record: record)
            Text(record.displayName)
                .font(.body)
                .foregroundStyle(.primary)
                .lineLimit(1)
                .truncationMode(.middle)
            Text("Keep")
                .font(.caption.weight(.semibold))
                .padding(.horizontal, 6)
                .padding(.vertical, 2)
                .foregroundStyle(.secondary)
                .background(.quaternary, in: Capsule())
            Spacer()
            if let size = record.formattedSize {
                Text(size)
                    .font(.body)
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
                    .frame(minWidth: 72, alignment: .trailing)
            }
        }
        .accessibilityElement(children: .combine)
    }
}

/// A copy proposed for the Trash: its checkbox, name, reason, Date Added and size.
struct DuplicateFileRow: View {
    /// Width of a regular checkbox, which the kept row leaves blank.
    static let checkboxWidth: CGFloat = 14

    let record: FileRecord
    let sizeInBytes: Int64
    let reason: ProposedChange.Reason
    @Binding var isTicked: Bool
    let isEnabled: Bool
    let focusedCheckbox: FocusState<URL?>.Binding

    var body: some View {
        HStack(spacing: 8) {
            // The label is hidden but still read by VoiceOver.
            Toggle(isOn: $isTicked) {
                Text("Move \(record.displayName) to the Trash")
            }
            .toggleStyle(.checkbox)
            .labelsHidden()
            .disabled(!isEnabled)
            .focused(focusedCheckbox, equals: record.id)
            // One VoiceOver element after the checkbox: name, reason, date and size in one breath.
            HStack(spacing: 8) {
                FileIconView(record: record)
                VStack(alignment: .leading, spacing: 1) {
                    Text(record.displayName)
                        .lineLimit(1)
                        .truncationMode(.middle)
                    Text(reason.localizedDescription)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
                Spacer()
                DateCell(date: record.dateAdded)
                    .foregroundStyle(.secondary)
                Text(sizeInBytes.formattedFileSize)
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
                    .frame(minWidth: 72, alignment: .trailing)
            }
            .accessibilityElement(children: .combine)
        }
    }
}

/// One proposed change in a plan without groups: its checkbox, the file, where it would go for a
/// rename or a move, the reason, Date Added and size.
struct ChangeRow: View {
    let change: ProposedChange
    /// The scanned folder, so a move names its destination relative to it.
    let folderURL: URL
    @Binding var isTicked: Bool
    let isEnabled: Bool
    let focusedCheckbox: FocusState<URL?>.Binding

    var body: some View {
        HStack(spacing: 8) {
            // The label is hidden but still read by VoiceOver.
            Toggle(isOn: $isTicked) {
                Text(change.checkboxLabel(in: folderURL))
            }
            .toggleStyle(.checkbox)
            .labelsHidden()
            .disabled(!isEnabled)
            .focused(focusedCheckbox, equals: change.id)
            // One VoiceOver element after the checkbox: names, reason, date and size in one breath.
            HStack(spacing: 8) {
                FileIconView(record: change.record)
                VStack(alignment: .leading, spacing: 1) {
                    HStack(spacing: 6) {
                        names
                        if change.reason.isPossibleMatch {
                            // Left unticked: only the name matches, so the user decides.
                            Text("Possible match")
                                .font(.caption.weight(.semibold))
                                .padding(.horizontal, 6)
                                .padding(.vertical, 2)
                                .foregroundStyle(.secondary)
                                .background(.quaternary, in: Capsule())
                        }
                    }
                    // Two lines, so a reason's second sentence ("movie.mp4 is next to it.") shows.
                    Text(change.reason.localizedDescription)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                }
                Spacer()
                DateCell(date: change.record.dateAdded)
                    .foregroundStyle(.secondary)
                Text(change.sizeInBytes.formattedFileSize)
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
                    .frame(minWidth: 72, alignment: .trailing)
            }
            .accessibilityElement(children: .combine)
        }
    }

    /// The name, then an arrow and where the file would go, for a rename or a move.
    @ViewBuilder
    private var names: some View {
        if let destination = change.destinationDisplayName(in: folderURL) {
            HStack(spacing: 4) {
                Text(change.record.displayName)
                    .lineLimit(1)
                    .truncationMode(.middle)
                Image(systemName: "arrow.right")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .accessibilityLabel(Text("to", comment: "Read by VoiceOver between a file’s current name and where a rename or a move would put it"))
                Text(destination)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
        } else {
            Text(change.record.displayName)
                .lineLimit(1)
                .truncationMode(.middle)
        }
    }
}

/// A file the search could not check, and why. It is left alone.
struct SkippedFileRow: View {
    let item: CleanupPlan.SkippedItem
    /// The action whose search skipped it, for the advice in its reason.
    let action: CleanupAction

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: "exclamationmark.triangle")
                .foregroundStyle(.secondary)
                .accessibilityHidden(true)
            Text(item.url.lastPathComponent)
                .lineLimit(1)
                .truncationMode(.middle)
            Spacer()
            Text(item.reason.localizedDescription(for: action))
                .foregroundStyle(.secondary)
                .lineLimit(1)
        }
        .accessibilityElement(children: .combine)
    }
}
