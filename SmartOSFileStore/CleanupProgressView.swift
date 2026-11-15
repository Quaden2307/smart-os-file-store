import FileStoreCore
import SwiftUI

/// The line above the status bar while a cleanup action looks for things to change: for an action
/// that reads file content, a bar and the counts; for any other, a small spinner and what it is
/// doing. Then a Cancel button. The table above it stays usable.
struct CleanupProgressView: View {
    let action: CleanupAction
    let progress: DuplicateScanProgress
    let cancel: @MainActor () -> Void

    var body: some View {
        let display = action.display
        HStack(spacing: 12) {
            if display.showsReadingProgress {
                if progress.bytesToHash > 0 {
                    ProgressView(value: progress.fractionCompleted)
                        .frame(maxWidth: 240)
                        .accessibilityLabel("Progress")
                } else {
                    ProgressView()
                        .controlSize(.small)
                        .accessibilityLabel("Progress")
                }
                Text("Checked \(progress.filesHashed) of ^[\(progress.filesToHash) file](inflect: true), \(progress.bytesHashed.formattedFileSize) of \(progress.bytesToHash.formattedFileSize)")
                    .monospacedDigit()
                    .lineLimit(1)
            } else {
                ProgressView()
                    .controlSize(.small)
                    .accessibilityLabel("Progress")
                Text("\(display.progressLabel)…")
                    .lineLimit(1)
            }
            Spacer()
            Button("Cancel", action: cancel)
                .keyboardShortcut(.cancelAction)
                .help(display.cancelHelp)
        }
        .font(.callout)
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
        .accessibilityElement(children: .contain)
        .accessibilityLabel(display.progressLabel)
    }
}
