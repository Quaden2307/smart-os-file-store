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
        ProgressLine(fraction: fraction(display.progressStyle), text: text(display), label: Text("Progress")) {
            Button("Stop", action: cancel)
                .keyboardShortcut(.cancelAction)
                .help(display.cancelHelp)
        }
        .barInset()
        .accessibilityElement(children: .contain)
        .accessibilityLabel(display.progressLabel)
    }

    /// The bar's fill once there is a total to measure against; until then nil, the spinner.
    private func fraction(_ style: CleanupActionDisplay.ProgressStyle) -> Double? {
        switch style {
        case .bytesRead:
            progress.bytesToRead > 0 ? progress.fractionCompleted : nil
        case .zipsChecked, .installersChecked:
            progress.itemsToCheck > 0 ? progress.fractionCompleted : nil
        case .spinner:
            nil
        }
    }

    private func text(_ display: CleanupActionDisplay) -> Text {
        switch display.progressStyle {
        case .bytesRead:
            Text("Checked \(progress.itemsChecked) of ^[\(progress.itemsToCheck) file](inflect: true), \(progress.bytesRead.formattedFileSize) of \(progress.bytesToRead.formattedFileSize)")
        case .zipsChecked:
            Text("Checked \(progress.itemsChecked) of ^[\(progress.itemsToCheck) zip](inflect: true)")
        case .installersChecked:
            Text("Checked \(progress.itemsChecked) of ^[\(progress.itemsToCheck) installer](inflect: true)")
        case .spinner:
            Text("\(display.progressLabel)…")
        }
    }
}
