import SwiftUI

/// Explains why the folder cannot be shown and offers the way out.
struct ScanErrorView: View {
    let failure: ScanFailure

    /// Runs the scan again. Nil when a retry cannot help (the folder itself could not be resolved).
    let retry: (@MainActor () -> Void)?

    @Environment(\.openURL) private var openURL

    /// The Files & Folders page of Privacy & Security in System Settings.
    private static let privacySettingsURL = URL(
        string: "x-apple.systempreferences:com.apple.preference.security?Privacy_FilesAndFolders"
    )

    var body: some View {
        ContentUnavailableView {
            Label(failure.title, systemImage: failure.isPermissionDenied ? "lock.fill" : "exclamationmark.triangle")
        } description: {
            Text(failure.message)
        } actions: {
            if let privacySettingsURL {
                // The way out of a permission problem, so it answers Return; Try Again keeps the
                // toolbar's Command-R.
                Button("Open Privacy Settings") {
                    openURL(privacySettingsURL)
                }
                .buttonStyle(.borderedProminent)
                .keyboardShortcut(.defaultAction)
                .help("Open the Files & Folders privacy settings in System Settings (Return)")
            }
            if let retry {
                let button = Button("Try Again", action: retry)
                    .help("Scan the folder again (⌘R)")
                if privacySettingsURL == nil {
                    button.keyboardShortcut(.defaultAction)
                } else {
                    button
                }
            }
        }
    }

    private var privacySettingsURL: URL? {
        failure.isPermissionDenied ? Self.privacySettingsURL : nil
    }
}
