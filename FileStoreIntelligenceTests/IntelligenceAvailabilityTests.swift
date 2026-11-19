import FileStoreIntelligence
import FoundationModels
import Testing

@Suite("Intelligence availability")
struct IntelligenceAvailabilityTests {
    @Test(arguments: [
        (SystemLanguageModel.Availability.available, true, IntelligenceAvailability.available),
        (.unavailable(.appleIntelligenceNotEnabled), true, .turnedOffInSystemSettings),
        (.unavailable(.modelNotReady), true, .modelDownloading),
        (.unavailable(.deviceNotEligible), true, .deviceNotEligible),
        (.available, false, .languageNotSupported),
        // The system's reason comes before the language: the language cannot matter yet.
        (.unavailable(.deviceNotEligible), false, .deviceNotEligible),
    ])
    func eachSystemStateHasItsReason(
        system: SystemLanguageModel.Availability, languageSupported: Bool, expected: IntelligenceAvailability
    ) {
        #expect(IntelligenceAvailability(system: system, languageSupported: languageSupported, enabledInSettings: true) == expected)
    }

    @Test(arguments: [
        SystemLanguageModel.Availability.available,
        .unavailable(.appleIntelligenceNotEnabled),
        .unavailable(.modelNotReady),
        .unavailable(.deviceNotEligible),
    ])
    func ourOwnSwitchWinsOverEverySystemState(system: SystemLanguageModel.Availability) {
        for languageSupported in [true, false] {
            let state = IntelligenceAvailability(system: system, languageSupported: languageSupported, enabledInSettings: false)
            #expect(state == .turnedOffInSettings)
        }
    }
}
