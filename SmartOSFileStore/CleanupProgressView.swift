import FileStoreCore
import SwiftUI

/// The line above the status bar while a cleanup action looks for things to change: for an action
/// that reads files, a bar and the counts; for any other, a small spinner and what it is doing.
/// Then a Cancel button. The table above it stays usable.
struct CleanupProgressView: View {
    let action: CleanupAction
    let progress: CleanupPlanningProgress
    let cancel: @MainActor () -> Void

    var body: some View {
        let display = action.display
        HStack(spacing: Design.Space.m) {
            switch display.progressStyle {
            case .bytesRead:
                bar(showing: progress.bytesToRead > 0)
                Text("Checked \(progress.itemsChecked) of ^[\(progress.itemsToCheck) file](inflect: true), \(progress.bytesRead.formattedFileSize) of \(progress.bytesToRead.formattedFileSize)")
                    .lineLimit(1)
            case .zipsChecked:
                bar(showing: progress.itemsToCheck > 0)
                Text("Checked \(progress.itemsChecked) of ^[\(progress.itemsToCheck) zip](inflect: true)")
                    .lineLimit(1)
            case .installersChecked:
                bar(showing: progress.itemsToCheck > 0)
                Text("Checked \(progress.itemsChecked) of ^[\(progress.itemsToCheck) installer](inflect: true)")
                    .lineLimit(1)
            case .spinner:
                spinner
                Text("\(display.progressLabel)…")
                    .lineLimit(1)
            }
            Spacer()
            Button("Cancel", action: cancel)
                .keyboardShortcut(.cancelAction)
                .help(display.cancelHelp)
        }
        .font(Design.Typography.secondary)
        .barInset()
        .accessibilityElement(children: .contain)
        .accessibilityLabel(display.progressLabel)
    }

    /// The bar once there is a total to measure against; until then, the spinner.
    @ViewBuilder
    private func bar(showing hasTotal: Bool) -> some View {
        if hasTotal {
            ProgressView(value: progress.fractionCompleted)
                .frame(maxWidth: Design.Size.progressBar)
                .accessibilityLabel("Progress")
        } else {
            spinner
        }
    }

    private var spinner: some View {
        ProgressView()
            .controlSize(.small)
            .accessibilityLabel("Progress")
    }
}
