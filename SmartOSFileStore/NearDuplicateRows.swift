import FileStoreCore
import QuickLookUI
import SwiftUI

// Review Near-Duplicates in the preview: one row per file of a group, with the facts that tell
// versions apart, and a side-by-side Quick Look of two selected rows.

/// One file of a near-duplicate group: its checkbox, name, reason, size and dates. "Newest" and
/// "Largest" are facts about the group, not advice: nothing is ticked or chosen for the user.
struct NearDuplicateRow: View {
    let member: NearDuplicateGroup.Member
    let reason: ProposedChange.Reason
    let isNewest: Bool
    let isLargest: Bool
    @Binding var isTicked: Bool
    /// False for the last unticked file of its group, which must stay.
    let canTick: Bool
    let isEnabled: Bool
    let focusedCheckbox: FocusState<URL?>.Binding

    private var record: FileRecord { member.record }

    var body: some View {
        HStack(spacing: Design.Space.s) {
            // The label is hidden but still read by VoiceOver.
            Toggle(isOn: $isTicked) {
                Text("Move \(record.displayName) to the Trash")
            }
            .toggleStyle(.checkbox)
            .labelsHidden()
            .disabled(!isEnabled || (!isTicked && !canTick))
            .help(!isTicked && !canTick ? String(localized: "One file of each group always stays, so the last one can’t be ticked.") : "")
            .focused(focusedCheckbox, equals: record.id)
            // One VoiceOver element after the checkbox: name, facts, reason, dates and size.
            HStack(spacing: Design.Space.s) {
                FileIconView(record: record)
                VStack(alignment: .leading, spacing: Design.Space.tight) {
                    HStack(spacing: Design.Space.s) {
                        Text(record.displayName)
                            .lineLimit(1)
                            .truncationMode(.middle)
                        if isNewest {
                            Badge(Text("Newest")).help(Text("Modified most recently of this group"))
                        }
                        if isLargest {
                            Badge(Text("Largest")).help(Text("The largest file of this group"))
                        }
                    }
                    Text(reason.localizedDescription)
                        .font(Design.Typography.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                    HStack(spacing: Design.Space.s) {
                        HStack(spacing: Design.Space.xs) {
                            Text("Added")
                            DateCell(date: record.dateAdded)
                        }
                        HStack(spacing: Design.Space.xs) {
                            Text("Modified")
                            DateCell(date: record.dateModified)
                        }
                        HStack(spacing: Design.Space.xs) {
                            Text("Opened")
                            LastOpenedCell(record: record)
                        }
                    }
                    .font(Design.Typography.caption)
                    .foregroundStyle(.secondary)
                    if !member.identicalCopies.isEmpty {
                        Text("^[\(member.identicalCopies.count) identical copy](inflect: true) not listed: Find Duplicates handles those")
                            .font(Design.Typography.caption)
                            .foregroundStyle(.secondary)
                    }
                }
                Spacer()
                Text((record.sizeInBytes ?? 0).formattedFileSize)
                    .foregroundStyle(.secondary)
                    .frame(minWidth: Design.Size.sizeColumn, alignment: .trailing)
            }
            .accessibilityElement(children: .combine)
        }
    }
}

extension NearDuplicateGroup {
    /// The members modified last, when not every member shares that date.
    var newestIDs: Set<URL> {
        Self.leaders(members, by: { $0.record.dateModified })
    }

    /// The largest members, when not every member is that size.
    var largestIDs: Set<URL> {
        Self.leaders(members, by: { $0.record.sizeInBytes })
    }

    private static func leaders<Value: Comparable>(_ members: [Member], by value: (Member) -> Value?) -> Set<URL> {
        let values = members.compactMap(value)
        guard let top = values.max(), values.count == members.count, Set(values.map { $0 == top }).count > 1 else {
            return []
        }
        return Set(members.filter { value($0) == top }.map(\.id))
    }
}

/// Two files side by side in Quick Look, to compare them: Space with two rows selected.
struct CompareFilesSheet: View {
    let records: [FileRecord]

    @Environment(\.dismiss) private var dismiss

    var body: some View {
        SheetScaffold(
            title: Text("Compare files"),
            subtitle: Text("The two selected files, side by side. Nothing changes here."),
            size: .large
        ) {
            HStack(spacing: 0) {
                ForEach(records) { record in
                    VStack(spacing: Design.Space.s) {
                        Text(record.displayName)
                            .font(Design.Typography.sectionTitle)
                            .lineLimit(1)
                            .truncationMode(.middle)
                        QuickLookPane(url: record.url)
                            .accessibilityLabel(Text("Preview of \(record.displayName)"))
                    }
                    .padding(Design.Space.s)
                    if record.id != records.last?.id {
                        Divider()
                    }
                }
            }
        } buttons: {
            Button("Close") {
                dismiss()
            }
            .keyboardShortcut(.cancelAction)
        }
    }
}

/// Quick Look's preview of one file, inside a view. Shows nothing if Quick Look offers no view.
private struct QuickLookPane: NSViewRepresentable {
    let url: URL

    func makeNSView(context: Context) -> NSView {
        guard let preview = QLPreviewView(frame: .zero, style: .normal) else {
            return NSView()
        }
        preview.autostarts = true
        preview.previewItem = url as NSURL
        return preview
    }

    func updateNSView(_ view: NSView, context: Context) {
        guard let preview = view as? QLPreviewView, (preview.previewItem as? NSURL) as URL? != url else { return }
        preview.previewItem = url as NSURL
    }

    static func dismantleNSView(_ view: NSView, coordinator: ()) {
        (view as? QLPreviewView)?.close()
    }
}
