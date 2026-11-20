import FileStoreCore
import SwiftUI

/// One cleanup in the Activity place: an arrow that shows or hides its files, its action, when it
/// ran, what it did in numbers, and an Undo button. An undo is listed the same way, named after the
/// run it undid, with no button.
struct ActivityRunRow: View {
    /// How far a cleanup's files are set in under it.
    static let itemIndent = Design.Icon.size + Design.Space.s

    let run: ActivityRun
    let isExpanded: Bool
    let undoAvailability: UndoAvailability
    let toggle: @MainActor () -> Void
    let undo: @MainActor () -> Void

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: Design.Space.s) {
            Button(action: toggle) {
                Text(Image(systemName: "chevron.right"))
                    .fontWeight(.semibold)
                    .rotationEffect(.degrees(isExpanded ? 90 : 0))
                    .motion(Design.Motion.quick, value: isExpanded)
                    .frame(width: Design.Icon.size)
            }
            .buttonStyle(.plain)
            .foregroundStyle(.secondary)
            .help(isExpanded ? Text("Hide the files") : Text("Show the files"))
            // VoiceOver offers the same through the row's own action, below.
            .accessibilityHidden(true)
            // A run is a result summarised: the card's header layout, without the outline a list
            // cannot draw around its rows (docs/design.md, Card).
            CardHeader(title: Text(run.title), isHeading: false) {
                counts
            } trailing: {
                ForEach([run.stateLabel, run.originLabel, run.undoLabel].compactMap(\.self), id: \.self) { label in
                    Badge(Text(label))
                }
                UndoButton(availability: undoAvailability, help: Text("Put this cleanup’s files back where they were"), undo: undo)
                DateCell(date: run.startedAt)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.vertical, Design.Space.tight)
        .accessibilityElement(children: .combine)
        .accessibilityAction(named: isExpanded ? Text("Hide files") : Text("Show files"), toggle)
        .modifier(UndoAccessibilityAction(availability: undoAvailability, undo: undo))
    }

    @ViewBuilder
    private var counts: some View {
        if run.isUndo {
            HStack(alignment: .firstTextBaseline, spacing: Design.Space.s) {
                Text("^[\(run.doneCount) file](inflect: true) put back")
                if run.leftAloneCount > 0 {
                    separator
                    Text("^[\(run.leftAloneCount) file](inflect: true) not put back")
                }
                if run.bytesTakenFromTrash > 0 {
                    separator
                    Text("\(run.bytesTakenFromTrash.formattedFileSize) put back from the Trash")
                }
            }
        } else {
            HStack(alignment: .firstTextBaseline, spacing: Design.Space.s) {
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
        }
    }

    private var separator: some View {
        Text(verbatim: "·")
            .accessibilityHidden(true)
    }
}

/// One item of a cleanup: the file's name, what was to be done and why, what happened, and when,
/// with an Undo button while the change can be undone, or when it was put back.
struct ActivityChangeRow: View {
    let change: ActivityChange
    let run: ActivityRun
    let undoAvailability: UndoAvailability
    let undo: @MainActor () -> Void

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: Design.Space.s) {
            Image(systemName: change.symbolName)
                .foregroundStyle(.secondary)
                .frame(width: Design.Icon.column)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: Design.Space.tight) {
                Text(change.displayName(in: run))
                    .lineLimit(1)
                    .truncationMode(.middle)
                HStack(alignment: .firstTextBaseline, spacing: Design.Space.s) {
                    Text(change.operationTitle(in: run))
                    if let reason = change.reason {
                        Text(verbatim: "·")
                            .accessibilityHidden(true)
                        // Two lines, so a reason's second sentence ("movie.mp4 was next to it.") shows.
                        Text(reason.historyDescription)
                            .lineLimit(2)
                            .truncationMode(.middle)
                    }
                }
                .font(Design.Typography.secondary)
                .foregroundStyle(.secondary)
            }
            Spacer(minLength: Design.Space.m)
            VStack(alignment: .trailing, spacing: Design.Space.tight) {
                Text(change.outcomeDescription(in: run))
                    .multilineTextAlignment(.trailing)
                if let undoneAt = change.undoneAt {
                    Text("Put back at \(undoneAt, format: .dateTime.hour().minute())")
                        .foregroundStyle(.secondary)
                }
                Text(change.attemptedAt, format: .dateTime.hour().minute().second())
                    .font(Design.Typography.caption)
                    .foregroundStyle(.secondary)
            }
            .font(Design.Typography.secondary)
            UndoButton(availability: undoAvailability, help: Text("Put this file back where it was"), undo: undo)
        }
        .padding(.vertical, Design.Space.tight)
        .help(change.originalPath)
        .accessibilityElement(children: .combine)
        .modifier(UndoAccessibilityAction(availability: undoAvailability, undo: undo))
    }
}

/// A row's Undo button: there while there is something to undo, greyed out with the reason
/// written under it when it can't be undone now.
private struct UndoButton: View {
    let availability: UndoAvailability
    let help: Text
    let undo: @MainActor () -> Void

    /// Wide enough for a short reason, so the rows' dates stay lined up.
    private static let width: CGFloat = 172

    var body: some View {
        switch availability {
        case .none:
            EmptyView()
        case .checking:
            Button("Undo") {}
                .controlSize(.small)
                .disabled(true)
                .frame(width: Self.width, alignment: .trailing)
        case .available:
            Button("Undo", action: undo)
                .controlSize(.small)
                .help(help)
                .frame(width: Self.width, alignment: .trailing)
        case .unavailable(let reason):
            VStack(alignment: .trailing, spacing: Design.Space.tight) {
                Button("Undo") {}
                    .controlSize(.small)
                    .disabled(true)
                Text(reason)
                    .font(Design.Typography.caption)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.trailing)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .frame(width: Self.width, alignment: .trailing)
            .help(Text(reason))
        }
    }
}

/// VoiceOver's Undo action on a row, while its Undo button works.
private struct UndoAccessibilityAction: ViewModifier {
    let availability: UndoAvailability
    let undo: @MainActor () -> Void

    func body(content: Content) -> some View {
        if availability.isAvailable {
            content.accessibilityAction(named: Text("Undo"), undo)
        } else {
            content
        }
    }
}
