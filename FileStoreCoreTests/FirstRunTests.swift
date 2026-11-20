import FileStoreCore
import Foundation
import Testing

/// The welcome is shown once and never again. Every test uses a store in memory.
@Suite("FirstRun")
struct FirstRunTests {
    @Test func aNewInstallNeedsTheWelcome() {
        #expect(FirstRun.needsWelcome(in: MemoryStore()))
    }

    @Test func onceShownItIsNeverNeededAgain() {
        let store = MemoryStore()
        FirstRun.markWelcomeShown(in: store)
        #expect(!FirstRun.needsWelcome(in: store))
        // A later launch reads the same store, and marking it again changes nothing.
        FirstRun.markWelcomeShown(in: store)
        #expect(!FirstRun.needsWelcome(in: store))
    }

    @Test func markingWritesOnlyItsOwnKey() {
        let store = MemoryStore(["CleanupOldAfterDays": 90])
        FirstRun.markWelcomeShown(in: store)
        #expect(Set(store.values.keys) == ["CleanupOldAfterDays", FirstRun.welcomeShownKey])
    }

    /// `-WelcomeShown NO` on the command line shows it again for a hand test; the value is text.
    @Test func aLaunchArgumentDecides() {
        #expect(FirstRun.needsWelcome(in: MemoryStore([FirstRun.welcomeShownKey: "NO"])))
        #expect(!FirstRun.needsWelcome(in: MemoryStore([FirstRun.welcomeShownKey: "YES"])))
    }

    @Test func aValueThatIsNoAnswerShowsTheWelcome() {
        #expect(FirstRun.needsWelcome(in: MemoryStore([FirstRun.welcomeShownKey: Date.distantPast])))
        #expect(FirstRun.needsWelcome(in: MemoryStore([FirstRun.welcomeShownKey: ["yes"]])))
    }
}
