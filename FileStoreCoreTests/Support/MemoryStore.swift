import FileStoreCore

/// A `SettingsStore` that keeps values in a dictionary, so a test never writes to the user's
/// preferences.
final class MemoryStore: SettingsStore {
    var values: [String: Any]

    init(_ values: [String: Any] = [:]) {
        self.values = values
    }

    func object(forKey defaultName: String) -> Any? {
        values[defaultName]
    }

    func set(_ value: Any?, forKey defaultName: String) {
        values[defaultName] = value
    }
}
