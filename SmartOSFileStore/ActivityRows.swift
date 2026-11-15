import FileStoreCore
import SwiftUI

/// One cleanup in the Activity place: an arrow that shows or hides its files, its action, when it
/// ran, and what it did in numbers.
struct ActivityRunRow: View {
    /// How far a cleanup's files are set in under it.
    static let itemIndent: CGFloat = 22

    let run: ActivityRun
    let isExpanded: Bool
    let toggle: @MainActor () -> Void

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Button(action: toggle) {
                Text(Image(systemName: "chevron.right"))
                    .fontWeight(.semibold)
                    .rotationEffect(.degrees(isExpanded ? 90 : 0))
                    .frame(width: 14)
            }
            .buttonStyle(.plain)
            .foregroundStyle(.secondary)
            .help(isExpanded ? Text("Hide the files") : Text("Show the files"))
            // VoiceOver offers the same through the row's own action, below.
            .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 2) {
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    Text(run.title)
                        .fontWeight(.semibold)
                    if let stateLabel = run.stateLabel {
                        Text(stateLabel)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    Text("^[\(run.doneCount) file](inflect: true) cleaned up")
                    if run.leftAloneCount > 0 {
                        separator
                        Text("^[\(run.leftAloneCount) file](inflect: true) left alone")
                    }
                    if run.bytesMovedToTrash > 0 {
                        separator
                        Text("\(run.bytesMovedToTrash.formattedFileSize) moved to the Trash")
                    }
                }
                .font(.callout)
                .foregroundStyle(.secondary)
                .monospacedDigit()
            }
            Spacer(minLength: 12)
            DateCell(date: run.startedAt)
                .foregroundStyle(.secondary)
        }
        .padding(.vertical, 2)
        .accessibilityElement(children: .combine)
        .accessibilityAction(named: isExpanded ? Text("Hide Files") : Text("Show Files"), toggle)
    }

    private var separator: some View {
        Text(verbatim: "·")
            .accessibilityHidden(true)
    }
}

/// One item of a cleanup: the file's name, what was to be done and why, what happened, and when.
struct ActivityChangeRow: View {
    let change: ActivityChange
    let run: ActivityRun

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Image(systemName: change.symbolName)
                .foregroundStyle(.secondary)
                .frame(width: 18)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 2) {
                Text(change.displayName)
                    .lineLimit(1)
                    .truncationMode(.middle)
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    Text(change.operationTitle)
                    if let reason = change.reason {
                        Text(verbatim: "·")
                            .accessibilityHidden(true)
                        Text(reason.localizedDescription)
                            .lineLimit(1)
                            .truncationMode(.middle)
                    }
                }
                .font(.callout)
                .foregroundStyle(.secondary)
            }
            Spacer(minLength: 12)
            VStack(alignment: .trailing, spacing: 2) {
                Text(change.outcomeDescription(in: run))
                    .multilineTextAlignment(.trailing)
                Text(change.attemptedAt, format: .dateTime.hour().minute().second())
                    .font(.caption)
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
            }
            .font(.callout)
        }
        .padding(.vertical, 1)
        .help(change.originalPath)
        .accessibilityElement(children: .combine)
    }
}
