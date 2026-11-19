import Foundation
import FoundationModels

/// Whether the chat can answer and, when it cannot, the one reason the chat bar gives.
public enum IntelligenceAvailability: Sendable, Equatable {
    case available
    case turnedOffInSystemSettings
    case modelDownloading
    case deviceNotEligible
    case languageNotSupported
    case turnedOffInSettings

    /// The `UserDefaults` key of the app's own "Use Apple Intelligence" switch. Unset counts as on.
    public static let enabledKey = "UseAppleIntelligence"

    /// The app's switch wins, then the system's reason, then the language: a user who turned the
    /// chat off here is not told about a download they did not ask for.
    public init(system: SystemLanguageModel.Availability, languageSupported: Bool, enabledInSettings: Bool) {
        guard enabledInSettings else {
            self = .turnedOffInSettings
            return
        }
        switch system {
        case .available:
            self = languageSupported ? .available : .languageNotSupported
        case .unavailable(.deviceNotEligible):
            self = .deviceNotEligible
        case .unavailable(.appleIntelligenceNotEnabled):
            self = .turnedOffInSystemSettings
        case .unavailable:
            // `modelNotReady`, and any reason a later SDK adds: all the bar can say is "not ready yet".
            self = .modelDownloading
        }
    }

    /// The state right now. `SystemLanguageModel` is observable, so a SwiftUI view that calls this
    /// is drawn again when the system's side changes.
    public static func current(enabledInSettings: Bool) -> IntelligenceAvailability {
        let model = SystemLanguageModel.default
        return IntelligenceAvailability(
            system: model.availability,
            languageSupported: model.supportsLocale(),
            enabledInSettings: enabledInSettings
        )
    }
}
