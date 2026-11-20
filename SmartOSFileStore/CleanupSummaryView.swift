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
            VStack(spacing: Design.Space.s) {
                Image(systemName: isRename ? "pencil" : isArchive ? "archivebox" : "trash")
                    .font(Design.Icon.large)
                    .imageScale(.large)
                    .foregroundStyle(.secondary)
                    .accessibilityHidden(true)
                if isRename, !result.renamed.isEmpty {
                    Text("^[\(result.renamed.count) file](inflect: true) renamed")
                        .font(Design.Typography.windowTitle)
                        .accessibilityAddTraits(.isHeader)
                    Text("Undo gives the files their old names back.")
                        .foregroundStyle(.secondary)
                } else if isRename {
                    Text("No files were renamed")
                        .font(Design.Typography.windowTitle)
                        .accessibilityAddTraits(.isHeader)
                    Text("Nothing in the folder was changed.")
                        .foregroundStyle(.secondary)
                } else if isArchive, result.moved.isEmpty, result.trashedCount > 0 {
                    Text("^[\(result.trashedCount) identical copy](inflect: true) moved to the Trash")
                        .font(Design.Typography.windowTitle)
                        .accessibilityAddTraits(.isHeader)
                    Text("Old downloads already held them. Undo puts them back where they were.")
                        .foregroundStyle(.secondary)
                } else if isArchive, !result.moved.isEmpty {
                    Text("^[\(result.moved.count) file](inflect: true) moved into Old downloads")
                        .font(Design.Typography.windowTitle)
                        .accessibilityAddTraits(.isHeader)
                    if result.trashedCount > 0 {
                        Text("^[\(result.trashedCount) identical copy](inflect: true) moved to the Trash. Undo puts every file back where it was.")
                            .foregroundStyle(.secondary)
                    } else {
                        Text("Undo puts the files back where they were.")
                            .foregroundStyle(.secondary)
                    }
                } else if result.trashedCount > 0 {
                    Text("^[\(result.trashedCount) file](inflect: true) moved to the Trash")
                        .font(Design.Typography.windowTitle)
                        .accessibilityAddTraits(.isHeader)
                    Text("\(result.bytesFreed.formattedFileSize) moved to the Trash. The space is free once you empty the Trash; until then you can put the files back.")
                        .foregroundStyle(.secondary)
                } else {
                    Text("No files were moved")
                        .font(Design.Typography.windowTitle)
                        .accessibilityAddTraits(.isHeader)
                    Text("Nothing in the folder was changed.")
                        .foregroundStyle(.secondary)
                }
            }
            .multilineTextAlignment(.center)
            .padding(Design.Space.xl)
            .frame(maxWidth: .infinity)
            .accessibilityElement(children: .combine)

            if let logFailure = result.logFailure {
                LogFailureNotice(failure: logFailure, result: result)
                    .padding(.horizontal, Design.Space.xl)
                    .padding(.bottom, Design.Space.l)
            }

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
        HStack(alignment: .firstTextBaseline, spacing: Design.Space.s) {
            Image(systemName: "exclamationmark.triangle")
                .foregroundStyle(.secondary)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: Design.Space.tight) {
                if untouchedCount == result.items.count {
                    Text("The activity log couldn’t be written, so nothing was changed.")
                        .fontWeight(.semibold)
                } else if untouchedCount == 0 {
                    Text("Every file was recorded, but the activity log couldn’t mark the cleanup as finished.")
                        .fontWeight(.semibold)
                    Text("It is listed as interrupted in Activity.")
                } else {
                    Text("The activity log stopped working, so the cleanup stopped.")
                        .fontWeight(.semibold)
                    if let unrecorded {
                        Text("\(unrecorded.change.record.displayName) was the last file reached, and the log could not record how it ended: \(unrecorded.outcome.localizedDescription(for: result.action))")
                    }
                    // No count here, so no verb has to agree with one; the list below names the files.
                    Text("Nothing after it was touched.")
                }
                Text("See the message at the bottom of the main window.")
            }
            .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
        }
        .font(Design.Typography.secondary)
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .combine)
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
