import FileStoreCore
import SwiftUI

/// The preview of a cleanup plan: what stays, what would change, and why. Read-only in this
/// segment; the next one adds the checkboxes and the Move to Trash button.
struct CleanupPreviewSheet: View {
    let plan: CleanupPlan

    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(spacing: 0) {
            header
                .padding(16)
            Divider()
            if plan.isEmpty, plan.skippedItems.isEmpty {
                ContentUnavailableView(
                    "No Duplicates Found",
                    systemImage: "checkmark.circle",
                    description: Text("No two files in this folder have the same content.")
                )
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                groupList
            }
            Divider()
            footer
                .padding(12)
        }
        .frame(minWidth: 620, idealWidth: 700, minHeight: 420, idealHeight: 540)
        .onExitCommand {
            dismiss()
        }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("Duplicates")
                .font(.title2.weight(.semibold))
            if plan.isEmpty {
                Text("No Duplicates Found")
                    .foregroundStyle(.secondary)
            } else {
                Text("^[\(plan.changes.count) duplicate](inflect: true) in ^[\(plan.duplicateGroups.count) group](inflect: true) would free \(plan.bytesToFree.formattedFileSize)")
                    .foregroundStyle(.secondary)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var groupList: some View {
        List {
            ForEach(plan.duplicateGroups) { group in
                Section {
                    ForEach(group.duplicates) { record in
                        DuplicateFileRow(
                            record: record,
                            sizeInBytes: group.fileSizeInBytes,
                            reason: .sameContent(asFileNamed: group.kept.displayName)
                        )
                    }
                } header: {
                    KeptFileRow(record: group.kept)
                }
                .headerProminence(.increased)
            }
            if !plan.skippedItems.isEmpty {
                Section("Not Checked") {
                    ForEach(plan.skippedItems) { item in
                        SkippedFileRow(item: item)
                    }
                }
            }
        }
        .accessibilityLabel("Duplicate groups")
    }

    private var footer: some View {
        HStack {
            if !plan.skippedItems.isEmpty {
                Text("^[\(plan.skippedItems.count) file](inflect: true) could not be checked")
                    .foregroundStyle(.secondary)
            }
            Spacer()
            Button("Done") {
                dismiss()
            }
            .keyboardShortcut(.defaultAction)
        }
    }
}

/// The copy that stays, marked Keep.
private struct KeptFileRow: View {
    let record: FileRecord

    var body: some View {
        HStack(spacing: 8) {
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
                .foregroundStyle(Color.accentColor)
                .background(Color.accentColor.opacity(0.15), in: Capsule())
            Spacer()
            if let size = record.formattedSize {
                Text(size)
                    .font(.body)
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
            }
        }
        .accessibilityElement(children: .combine)
    }
}

/// A copy proposed for the Trash, with its Date Added and size.
private struct DuplicateFileRow: View {
    let record: FileRecord
    let sizeInBytes: Int64
    let reason: ProposedChange.Reason

    var body: some View {
        HStack(spacing: 8) {
            FileIconView(record: record)
            Text(record.displayName)
                .lineLimit(1)
                .truncationMode(.middle)
            Spacer()
            DateCell(date: record.dateAdded)
                .foregroundStyle(.secondary)
            Text(sizeInBytes.formattedFileSize)
                .monospacedDigit()
                .foregroundStyle(.secondary)
                .frame(minWidth: 72, alignment: .trailing)
        }
        .help(reason.localizedDescription)
        .accessibilityElement(children: .combine)
        .accessibilityValue(reason.localizedDescription)
    }
}

/// A file the search could not check, and why. It is left alone.
private struct SkippedFileRow: View {
    let item: CleanupPlan.SkippedItem

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: "exclamationmark.triangle")
                .foregroundStyle(.secondary)
                .accessibilityHidden(true)
            Text(item.url.lastPathComponent)
                .lineLimit(1)
                .truncationMode(.middle)
            Spacer()
            Text(item.reason.localizedDescription)
                .foregroundStyle(.secondary)
                .lineLimit(1)
        }
        .accessibilityElement(children: .combine)
    }
}
