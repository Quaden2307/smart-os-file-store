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
        StateView(
            title: Text(failure.title),
            symbol: failure.isPermissionDenied ? "lock" : "exclamationmark.triangle",
            message: Text(failure.message)
        ) {
            // One way out. For a permission problem that is the privacy settings: the folder is
            // read again when the app comes back to the front, and Command-R still tries again.
            if let privacySettingsURL {
                Button("Open privacy settings") {
                    openURL(privacySettingsURL)
                }
                .keyboardShortcut(.defaultAction)
                .help("Open the Files & Folders privacy settings in System Settings (Return)")
            } else if let retry {
                Button("Try again", action: retry)
                    .keyboardShortcut(.defaultAction)
                    .help("Scan the folder again (⌘R)")
            }
        }
    }

    private var privacySettingsURL: URL? {
        failure.isPermissionDenied ? Self.privacySettingsURL : nil
    }
}
