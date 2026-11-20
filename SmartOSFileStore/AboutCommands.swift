import SwiftUI

/// App menu > About Smart OS File Store: the system's standard About window (icon, name, version),
/// with the app's one-line description under the version.
struct AboutCommands: Commands {
    var body: some Commands {
        CommandGroup(replacing: .appInfo) {
            Button("About Smart OS File Store") {
                var options: [NSApplication.AboutPanelOptionKey: Any] = [
                    .credits: NSAttributedString(
                        string: String(localized: "Keeps your Downloads folder tidy, with a preview and an undo for every change."),
                        attributes: Design.About.creditsAttributes
                    ),
                ]
                // The window would otherwise show the bundle's name, which has no spaces.
                if let name = Bundle.main.object(forInfoDictionaryKey: "CFBundleDisplayName") as? String {
                    options[.applicationName] = name
                }
                NSApplication.shared.orderFrontStandardAboutPanel(options: options)
            }
        }
    }
}
