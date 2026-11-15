import FileStoreCore
import SwiftUI

/// What the main window shows above its status line when the activity log needs attention: the
/// problem and the ways out while the log cannot be used, and where the old file went once it was
/// set aside for a fresh log. Nothing otherwise.
struct ActivityLogNotices: View {
    let activity: ActivityLogModel

    var body: some View {
        if let error = activity.failure {
            Divider()
            ActivityLogProblemBanner(activity: activity, failure: ActivityLogFailure(error))
        }
        if let setAsideURL = activity.setAsideURL {
            Divider()
            HStack(spacing: 10) {
                Image(systemName: "checkmark.circle")
                    .foregroundStyle(.secondary)
                    .accessibilityHidden(true)
                Text("The old activity log is kept as \(setAsideURL.lastPathComponent).")
                Spacer()
                Button("Show in Finder") {
                    RevealInFinder.reveal([setAsideURL])
                }
                .help("Show the old activity log in Finder")
                Button("OK") {
                    activity.dismissSetAsideNotice()
                }
                .help("Hide this message")
            }
            .font(.callout)
            .padding(.horizontal, 12)
            .padding(.vertical, 6)
            .accessibilityElement(children: .contain)
            .accessibilityLabel("Activity log notice")
        }
    }
}

/// The two ways out of a log that cannot be used: open it again, or keep it aside and start afresh.
struct ActivityLogRecoveryButtons: View {
    let activity: ActivityLogModel
    let failure: ActivityLogFailure

    var body: some View {
        if activity.canRetry {
            Button("Try Again") {
                activity.retry()
            }
            .help("Open the activity log again")
            .disabled(activity.isRecovering)
        }
        if failure.canStartFresh {
            Button("Start a Fresh Log") {
                activity.startFresh()
            }
            .help("Keep the existing log file under a new name and start an empty one. The total moved to the Trash starts again from zero.")
            .disabled(activity.isRecovering)
        }
    }
}

/// The problem as one line across the main window, with the ways out beside it.
struct ActivityLogProblemBanner: View {
    let activity: ActivityLogModel
    let failure: ActivityLogFailure

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            Image(systemName: "exclamationmark.triangle")
                .foregroundStyle(.secondary)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 2) {
                Text(failure.title)
                    .fontWeight(.semibold)
                Text(failure.message)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 12)
            ActivityLogRecoveryButtons(activity: activity, failure: failure)
        }
        .font(.callout)
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Activity log problem")
    }
}

/// The problem filling a window: the Activity window's content while the log cannot be used.
struct ActivityLogProblemView: View {
    let activity: ActivityLogModel
    let failure: ActivityLogFailure

    var body: some View {
        ContentUnavailableView {
            Label(failure.title, systemImage: "exclamationmark.triangle")
        } description: {
            Text(failure.message)
        } actions: {
            ActivityLogRecoveryButtons(activity: activity, failure: failure)
        }
    }
}

/// Shown instead of a cleanup preview when the log stopped working after the search began: nothing
/// may be carried out, so nothing is offered.
struct ActivityLogUnavailableSheet: View {
    let activity: ActivityLogModel

    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(spacing: 0) {
            ContentUnavailableView {
                Label("Nothing Can Be Cleaned Up Right Now", systemImage: "exclamationmark.triangle")
            } description: {
                Text("The activity log isn’t working, and nothing is changed that can’t be recorded. Close this and see the message at the bottom of the window.")
            }
            Divider()
            HStack {
                Spacer()
                Button("Close") {
                    dismiss()
                }
                .keyboardShortcut(.defaultAction)
            }
            .padding(12)
        }
        .frame(minWidth: 460, minHeight: 260)
        .onExitCommand {
            dismiss()
        }
    }
}
