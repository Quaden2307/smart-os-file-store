import FileStoreCore
import Foundation
import Testing

/// The age-mark thresholds and how they are kept. Every test uses a store in memory, so nothing
/// is written to the user's preferences.
@Suite("CleanupSettings")
struct CleanupSettingsTests {
    /// A `SettingsStore` that keeps values in a dictionary.
    private final class MemoryStore: SettingsStore {
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

    private let unusedKey = CleanupSettings.unusedAfterDaysKey
    private let oldKey = CleanupSettings.oldAfterDaysKey

    @Test func defaultsAreThirtyAndNinetyDays() {
        let settings = CleanupSettings()
        #expect(settings.unusedAfterDays == 30)
        #expect(settings.oldAfterDays == 90)
        #expect(settings.unusedAfter == 30 * 24 * 60 * 60)
        #expect(settings.oldAfter == 90 * 24 * 60 * 60)
    }

    @Test func emptyStoreGivesDefaults() {
        #expect(CleanupSettings.load(from: MemoryStore()) == CleanupSettings())
    }

    @Test func storedWholeNumbersAreUsed() {
        let store = MemoryStore([unusedKey: 7, oldKey: NSNumber(value: 14)])
        #expect(CleanupSettings.load(from: store) == CleanupSettings(unusedAfterDays: 7, oldAfterDays: 14))
    }

    /// A launch argument such as `-CleanupUnusedAfterDays 7` arrives as text.
    @Test func textOfAWholeNumberIsUsed() {
        let store = MemoryStore([unusedKey: "7", oldKey: " 14 "])
        #expect(CleanupSettings.load(from: store) == CleanupSettings(unusedAfterDays: 7, oldAfterDays: 14))
    }

    /// An unusable value never makes a mark looser: that threshold gets its default, the other is
    /// still read.
    @Test func unusableValuesFallBackPerKey() {
        let unusable: [Any] = [0, -5, 7.5, "seven", "", true, Data([1, 2]), [7]]
        for value in unusable {
            let store = MemoryStore([unusedKey: value, oldKey: 120])
            let settings = CleanupSettings.load(from: store)
            #expect(settings.unusedAfterDays == CleanupSettings.defaultUnusedAfterDays, "\(value) should be ignored")
            #expect(settings.oldAfterDays == 120)
        }
    }

    @Test func thresholdsBelowOneDayGetTheirDefaults() {
        let settings = CleanupSettings(unusedAfterDays: 0, oldAfterDays: -1)
        #expect(settings == CleanupSettings())
    }

    @Test func saveThenLoadRoundTrips() {
        let store = MemoryStore()
        let settings = CleanupSettings(unusedAfterDays: 10, oldAfterDays: 45)
        settings.save(to: store)
        #expect(store.values[unusedKey] as? Int == 10)
        #expect(store.values[oldKey] as? Int == 45)
        #expect(CleanupSettings.load(from: store) == settings)
    }

    /// The app passes `UserDefaults.standard`. The test runner's defaults hold neither key, so
    /// reading them (and nothing is written) gives the defaults.
    @Test func loadsFromUserDefaults() {
        #expect(UserDefaults.standard.object(forKey: unusedKey) == nil)
        #expect(UserDefaults.standard.object(forKey: oldKey) == nil)
        #expect(CleanupSettings.load(from: UserDefaults.standard) == CleanupSettings())
    }
}
