import SwiftUI

/// Explains why the folder cannot be shown and offers the way out.
struct ScanErrorView: View {
    let failure: ScanFailure

    /// Runs the scan again. Nil when a retry cannot help (the folder itself could not be resolved).
    let retry: (@MainActor () -> Void)?

    @Environment(\.openURL) private var openURL

    /// The Files and Folders page of Privacy & Security in System Settings.
    private static let privacySettingsURL = URL(
        string: "x-apple.systempreferences:com.apple.preference.security?Privacy_FilesAndFolders"
    )

    var body: some View {
        ContentUnavailableView {
            Label(failure.title, systemImage: failure.isPermissionDenied ? "lock.fill" : "exclamationmark.triangle")
        } description: {
            Text(failure.message)
        } actions: {
            if failure.isPermissionDenied, let url = Self.privacySettingsURL {
                Button("Open Privacy Settings") {
                    openURL(url)
                }
                .buttonStyle(.borderedProminent)
                .help("Open the Files and Folders privacy settings in System Settings")
            }
            if let retry {
                Button("Try Again", action: retry)
                    .keyboardShortcut(.defaultAction)
            }
        }
    }
}
