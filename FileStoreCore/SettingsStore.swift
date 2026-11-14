import Foundation

/// Somewhere settings are kept by key. The app uses `UserDefaults.standard`; tests use a store in
/// memory, so they never write to the user's preferences.
public protocol SettingsStore: AnyObject {
    func object(forKey defaultName: String) -> Any?
    func set(_ value: Any?, forKey defaultName: String)
}

extension UserDefaults: SettingsStore {}
