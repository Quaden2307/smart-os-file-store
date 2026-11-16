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
        HStack(spacing: 8) {
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
            HStack(spacing: 8) {
                FileIconView(record: record)
                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: 6) {
                        Text(record.displayName)
                            .lineLimit(1)
                            .truncationMode(.middle)
                        if isNewest {
                            FactTag(text: Text("Newest"), help: Text("Modified most recently of this group"))
                        }
                        if isLargest {
                            FactTag(text: Text("Largest"), help: Text("The largest file of this group"))
                        }
                    }
                    Text(reason.localizedDescription)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                    HStack(spacing: 10) {
                        HStack(spacing: 3) {
                            Text("Added")
                            DateCell(date: record.dateAdded)
                        }
                        HStack(spacing: 3) {
                            Text("Modified")
                            DateCell(date: record.dateModified)
                        }
                        HStack(spacing: 3) {
                            Text("Opened")
                            LastOpenedCell(record: record)
                        }
                    }
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    if !member.identicalCopies.isEmpty {
                        Text("^[\(member.identicalCopies.count) identical copy](inflect: true) not listed: Find Duplicates handles those")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
                Spacer()
                Text((record.sizeInBytes ?? 0).formattedFileSize)
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
                    .frame(minWidth: 72, alignment: .trailing)
            }
            .accessibilityElement(children: .combine)
        }
    }
}

/// A small capsule stating a fact about a row.
private struct FactTag: View {
    let text: Text
    let help: Text

    var body: some View {
        text
            .font(.caption.weight(.semibold))
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .foregroundStyle(.secondary)
            .background(.quaternary, in: Capsule())
            .help(help)
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
        VStack(spacing: 0) {
            HStack(spacing: 0) {
                ForEach(records) { record in
                    VStack(spacing: 6) {
                        Text(record.displayName)
                            .font(.headline)
                            .lineLimit(1)
                            .truncationMode(.middle)
                        QuickLookPane(url: record.url)
                            .accessibilityLabel(Text("Preview of \(record.displayName)"))
                    }
                    .padding(8)
                    if record.id != records.last?.id {
                        Divider()
                    }
                }
            }
            Divider()
            HStack {
                Spacer()
                Button("Close") {
                    dismiss()
                }
                .keyboardShortcut(.cancelAction)
            }
            .padding(12)
        }
        .frame(minWidth: 820, idealWidth: 1000, minHeight: 520, idealHeight: 640)
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
