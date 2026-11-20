import FileStoreCore
import SwiftUI

/// What carrying out a plan did: how many files went to the Trash and how much space that freed, or
/// how many were renamed, then every file that was left as it was, with the reason.
struct CleanupSummaryView: View {
    let result: CleanupResult

    private var isRename: Bool { result.action.definition.operation == .rename }
    private var isArchive: Bool { result.action.definition.operation == .archive }

    var body: some View {
        VStack(spacing: 0) {
            Card {
                CardHeader(title: outcome, subtitle: explanation)
                    .accessibilityElement(children: .combine)
                CardFigures {
                    if isRename {
                        CardFigure(value: Text("\(result.renamed.count)"), label: Text("renamed"))
                    } else {
                        if isArchive {
                            CardFigure(value: Text("\(result.moved.count)"), label: Text("moved into Old downloads"))
                        }
                        if !isArchive || result.trashedCount > 0 {
                            CardFigure(value: Text("\(result.trashedCount)"), label: Text("moved to the Trash"))
                            CardFigure(value: Text(result.bytesFreed.formattedFileSize), label: Text("to free when the Trash is emptied"))
                        }
                    }
                    if !result.leftAlone.isEmpty {
                        CardFigure(value: Text("\(result.leftAlone.count)"), label: isRename ? Text("not renamed") : Text("not moved"))
                    }
                }
                if let logFailure = result.logFailure {
                    LogFailureNotice(failure: logFailure, result: result)
                }
            }
            .padding([.horizontal, .top], Design.Space.l)

            if result.leftAlone.isEmpty {
                Spacer(minLength: 0)
            } else {
                List {
                    Section {
                        ForEach(result.leftAlone) { item in
                            NotMovedRow(item: item, action: result.action)
                        }
                    } header: {
                        isRename ? Text("Not renamed") : Text("Not moved")
                    }
                }
                .accessibilityLabel(isRename ? Text("Files not renamed") : Text("Files not moved"))
            }
        }
    }

    /// What happened, in a few words. The numbers are the card's figures.
    private var outcome: Text {
        if !result.hasDoneItems {
            Text("Nothing changed")
        } else if isRename {
            Text("Renamed")
        } else if isArchive, !result.moved.isEmpty {
            Text("Moved into Old downloads")
        } else {
            Text("Moved to the Trash")
        }
    }

    private var explanation: Text {
        if !result.hasDoneItems {
            Text("Every file is as it was.")
        } else if isRename {
            Text("Undo gives back every old name.")
        } else if isArchive, result.moved.isEmpty {
            Text("Old downloads already held identical copies. Undo puts every file back where it was.")
        } else if isArchive {
            Text("Undo puts every file back where it was.")
        } else {
            Text("The space is free once you empty the Trash. Until then, Undo puts every file back.")
        }
    }
}

/// A file that stayed where it was, and why.
struct NotMovedRow: View {
    let item: CleanupItemResult
    let action: CleanupAction

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: Design.Space.s) {
            FileIconView(record: item.change.record)
            Text(item.change.record.displayName)
                .lineLimit(1)
                .truncationMode(.middle)
            Spacer()
            Text(item.outcome.localizedDescription(for: action))
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.trailing)
        }
        .accessibilityElement(children: .combine)
    }
}

/// Says that the activity log stopped working during the run, and what that meant for the files:
/// nothing changed when the run could not be opened in the log; otherwise which file, if any, was
/// changed without its row being completed, and that the files after it were not touched.
private struct LogFailureNotice: View {
    let failure: CleanupLogFailure
    let result: CleanupResult

    var body: some View {
        StateBar(symbol: "exclamationmark.triangle", title: title) {
            if untouchedCount == 0 {
                Text("It is listed as interrupted in Activity.")
            } else if untouchedCount < result.items.count {
                if let unrecorded {
                    Text("\(unrecorded.change.record.displayName) was the last file reached, and the log could not record how it ended: \(unrecorded.outcome.localizedDescription(for: result.action))")
                }
                // No count here, so no verb has to agree with one; the list below names the files.
                Text("Nothing after it was touched.")
            }
            Text("See the message at the bottom of the main window.")
        }
    }

    private var title: Text {
        if untouchedCount == result.items.count {
            Text("The activity log couldn’t be written, so nothing changed.")
        } else if untouchedCount == 0 {
            Text("Every file was recorded, but the activity log couldn’t mark the cleanup as finished.")
        } else {
            Text("The activity log stopped working, so the cleanup stopped.")
        }
    }

    /// Files left alone because the log had stopped.
    private var untouchedCount: Int {
        result.items.count { $0.outcome == .skipped(.activityLogUnavailable) }
    }

    /// The item whose row could not be completed, when there is one.
    private var unrecorded: CleanupItemResult? {
        guard let id = failure.unrecordedChangeID else { return nil }
        return result.items.first { $0.id == id }
    }
}
