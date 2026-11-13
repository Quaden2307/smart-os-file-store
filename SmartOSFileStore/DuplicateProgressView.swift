import FileStoreCore
import SwiftUI

/// The line above the status bar while duplicates are being found: a bar, the counts and a
/// Cancel button. The table above it stays usable.
struct DuplicateProgressView: View {
    let progress: DuplicateScanProgress
    let cancel: @MainActor () -> Void

    var body: some View {
        HStack(spacing: 12) {
            if progress.bytesToHash > 0 {
                ProgressView(value: progress.fractionCompleted)
                    .frame(maxWidth: 240)
                    .accessibilityLabel("Duplicate search progress")
            } else {
                ProgressView()
                    .controlSize(.small)
                    .accessibilityLabel("Duplicate search progress")
            }
            Text("Checked \(progress.filesHashed) of ^[\(progress.filesToHash) file](inflect: true), \(progress.bytesHashed.formattedFileSize) of \(progress.bytesToHash.formattedFileSize)")
                .monospacedDigit()
                .lineLimit(1)
            Spacer()
            Button("Cancel", action: cancel)
                .keyboardShortcut(.cancelAction)
                .help("Stop finding duplicates (Esc)")
        }
        .font(.callout)
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Finding duplicates")
    }
}
