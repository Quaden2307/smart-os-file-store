import Foundation

/// Whether the welcome has been shown. It is shown once: the first time the main window opens, and
/// never again once it has been dismissed.
public enum FirstRun {
    public static let welcomeShownKey = "WelcomeShown"

    /// True until the welcome has been marked shown. A value that is not a yes or a no counts as
    /// not shown: showing the welcome twice is better than never.
    public static func needsWelcome(in store: any SettingsStore) -> Bool {
        switch store.object(forKey: welcomeShownKey) {
        case let number as NSNumber:
            !number.boolValue
        // A launch argument (`-WelcomeShown NO`, for a hand test) arrives as text.
        case let text as NSString:
            !text.boolValue
        default:
            true
        }
    }

    public static func markWelcomeShown(in store: any SettingsStore) {
        store.set(true, forKey: welcomeShownKey)
    }
}
