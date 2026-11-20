import FileStoreCore
import SwiftUI

// The rows of the cleanup preview: the kept copy and its duplicates for a plan with groups, one row
// per change for any other plan, and the files the action could not check.

/// The copy that stays, marked Keep. Selectable and previewable like any row, but with no checkbox.
struct KeptFileRow: View {
    let record: FileRecord

    var body: some View {
        HStack(spacing: Design.Space.s) {
            // Takes the checkbox's place so the names line up.
            Color.clear
                .frame(width: Design.Size.checkbox, height: 0)
                .accessibilityHidden(true)
            FileIconView(record: record)
            Text(record.displayName)
                .font(Design.Typography.body)
                .foregroundStyle(.primary)
                .lineLimit(1)
                .truncationMode(.middle)
            Badge(Text("Keep"))
            Spacer()
            if let size = record.formattedSize {
                Text(size)
                    .font(Design.Typography.body)
                    .foregroundStyle(.secondary)
                    .frame(minWidth: Design.Size.sizeColumn, alignment: .trailing)
            }
        }
        .accessibilityElement(children: .combine)
    }
}

/// A copy proposed for the Trash: its checkbox, name, reason, Date Added and size.
struct DuplicateFileRow: View {
    let record: FileRecord
    let sizeInBytes: Int64
    let reason: ProposedChange.Reason
    @Binding var isTicked: Bool
    let isEnabled: Bool
    let focusedCheckbox: FocusState<URL?>.Binding

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
            // One VoiceOver element after the checkbox: name, reason, date and size in one breath.
            HStack(spacing: Design.Space.s) {
                FileIconView(record: record)
                VStack(alignment: .leading, spacing: Design.Space.tight) {
                    Text(record.displayName)
                        .lineLimit(1)
                        .truncationMode(.middle)
                    Text(reason.localizedDescription)
                        .font(Design.Typography.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
                Spacer()
                DateCell(date: record.dateAdded)
                    .foregroundStyle(.secondary)
                Text(sizeInBytes.formattedFileSize)
                    .foregroundStyle(.secondary)
                    .frame(minWidth: Design.Size.sizeColumn, alignment: .trailing)
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
        HStack(spacing: Design.Space.s) {
            // The label is hidden but still read by VoiceOver.
            Toggle(isOn: $isTicked) {
                Text(change.checkboxLabel(in: folderURL))
            }
            .toggleStyle(.checkbox)
            .labelsHidden()
            .disabled(!isEnabled)
            .focused(focusedCheckbox, equals: change.id)
            // One VoiceOver element after the checkbox: names, reason, date and size in one breath.
            HStack(spacing: Design.Space.s) {
                FileIconView(record: change.record)
                VStack(alignment: .leading, spacing: Design.Space.tight) {
                    HStack(spacing: Design.Space.s) {
                        names
                        if change.reason.isPossibleMatch {
                            // Left unticked: only the name matches, so the user decides.
                            Badge(Text("Possible match"))
                        }
                    }
                    // Two lines, so a reason's second sentence ("movie.mp4 is next to it.") shows.
                    Text(change.reason.localizedDescription)
                        .font(Design.Typography.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                }
                Spacer()
                DateCell(date: change.record.dateAdded)
                    .foregroundStyle(.secondary)
                Text(change.sizeInBytes.formattedFileSize)
                    .foregroundStyle(.secondary)
                    .frame(minWidth: Design.Size.sizeColumn, alignment: .trailing)
            }
            .accessibilityElement(children: .combine)
        }
    }

    /// The name, then an arrow and where the file would go, for a rename or a move. For a rename,
    /// what the old name loses is struck through and what the new name gains is in semibold.
    @ViewBuilder
    private var names: some View {
        if case .rename(to: let newName) = change.operation {
            let difference = NameDifference(from: change.record.displayName, to: newName)
            // Two lines each before truncating, so the marked part is rarely cut out of view.
            HStack(alignment: .firstTextBaseline, spacing: Design.Space.xs) {
                Text(Self.marked(difference, old: true))
                    .lineLimit(2)
                    .truncationMode(.middle)
                arrow
                Text(Self.marked(difference, old: false))
                    .lineLimit(2)
                    .truncationMode(.middle)
            }
            .layoutPriority(1)
        } else if let destination = change.destinationDisplayName(in: folderURL) {
            HStack(spacing: Design.Space.xs) {
                Text(change.record.displayName)
                    .lineLimit(1)
                    .truncationMode(.middle)
                arrow
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

    private var arrow: some View {
        Image(systemName: "arrow.right")
            .font(Design.Typography.caption)
            .foregroundStyle(.secondary)
            .accessibilityLabel(Text("to", comment: "Read by VoiceOver between a file’s current name and where a rename or a move would put it"))
    }

    /// The old name with the part it loses struck through, or the new name with the part it gains
    /// in semibold. File names, so never looked up in the String Catalog.
    private static func marked(_ difference: NameDifference, old: Bool) -> AttributedString {
        var changed = AttributedString(old ? difference.removed : difference.added)
        if old {
            changed.strikethroughStyle = .single
            changed.foregroundColor = .secondary
        } else {
            changed.font = .body.weight(.semibold)
        }
        return AttributedString(difference.commonPrefix) + changed + AttributedString(difference.commonSuffix)
    }
}

/// A file the search could not check, and why. It is left alone.
struct SkippedFileRow: View {
    let item: CleanupPlan.SkippedItem
    /// The action whose search skipped it, for the advice in its reason.
    let action: CleanupAction

    var body: some View {
        HStack(spacing: Design.Space.s) {
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
