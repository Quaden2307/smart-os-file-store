import FileStoreIntelligence
import Foundation

extension TurnOutcome {
    /// The plain sentence shown with a reply that did not end as an answer. Nil for an answer.
    var message: String? {
        switch self {
        case .answered:
            nil
        case .stopped:
            String(localized: "Stopped.")
        case .timedOut:
            String(localized: "That took too long, so the reply was stopped. Try a shorter question.")
        case .toolLimitReached:
            String(localized: "That needed too many lookups for one question. Try asking for one thing at a time.")
        case .refused:
            String(localized: "Apple Intelligence declined to answer that. The Clean Up menu still does everything the app can do.")
        case .contextFull:
            // Usually after the question was already asked again in a fresh conversation (not when
            // the first try used up the time limit).
            String(localized: "This question needs more room than the on-device model has. Try asking for one thing at a time.")
        case .unavailable(let availability):
            availability.reason
        case .failed:
            // Usually after the question was already asked again in a fresh conversation.
            String(localized: "Something went wrong answering that, so the conversation has started again.")
        }
    }
}

extension IntelligenceAvailability {
    /// Why the chat cannot answer, in one line. Nil when it can.
    var reason: String? {
        switch self {
        case .available:
            nil
        case .turnedOffInSystemSettings:
            String(localized: "Apple Intelligence is turned off, so the chat can’t answer. Turn it on in System Settings.")
        case .modelDownloading:
            String(localized: "Apple Intelligence isn’t ready yet. Its model may still be downloading.")
        case .deviceNotEligible:
            String(localized: "This Mac doesn’t support Apple Intelligence, so the chat isn’t available.")
        case .languageNotSupported:
            String(localized: "Apple Intelligence doesn’t support this Mac’s language yet, so the chat can’t answer.")
        case .turnedOffInSettings:
            String(localized: "The chat is turned off. Turn on Use Apple Intelligence in Settings to ask about your Downloads.")
        }
    }

    /// True when System Settings is where the user can change it.
    var isChangedInSystemSettings: Bool {
        switch self {
        case .turnedOffInSystemSettings, .modelDownloading, .languageNotSupported: true
        case .available, .deviceNotEligible, .turnedOffInSettings: false
        }
    }
}

extension FileSearchResult {
    /// What was looked up, put into words by the app from the lookup itself and not by the model:
    /// "Images · 100 MB or more". A lookup that is not what the question meant shows here.
    var lookedUp: String {
        func day(_ date: Date) -> String {
            date.formatted(.dateTime.day().month(.abbreviated).year())
        }
        /// The last day a range includes; the range itself ends at the start of the day after.
        func lastDay(before date: Date) -> String {
            day(Calendar.current.date(byAdding: .day, value: -1, to: date) ?? date)
        }
        var parts: [String] = []
        if let group = query.typeGroup { parts.append(group.title) }
        if let text = query.nameContains { parts.append(String(localized: "name contains “\(text)”")) }
        if let from = query.added.from { parts.append(String(localized: "added since \(day(from))")) }
        if let before = query.added.before { parts.append(String(localized: "added up to \(lastDay(before: before))")) }
        if let from = query.opened.from { parts.append(String(localized: "opened since \(day(from))")) }
        if let before = query.opened.before { parts.append(String(localized: "opened up to \(lastDay(before: before))")) }
        if query.neverOpened { parts.append(String(localized: "never opened")) }
        if let bytes = query.minBytes { parts.append(String(localized: "\(bytes.formattedFileSize) or more")) }
        if let bytes = query.maxBytes { parts.append(String(localized: "\(bytes.formattedFileSize) or less")) }
        if let site = query.sourceSite { parts.append(String(localized: "from \(site)")) }
        if let mark = query.mark { parts.append(String(localized: "marked \(mark.fileMark.title)")) }
        return parts.isEmpty ? String(localized: "All items") : parts.joined(separator: " · ")
    }
}

extension FileTypeGroup {
    var title: String {
        switch self {
        case .documents: String(localized: "Documents")
        case .images: String(localized: "Images")
        case .installers: String(localized: "Installers")
        case .archives: String(localized: "Archives")
        case .video: String(localized: "Video")
        case .audio: String(localized: "Audio")
        case .other: String(localized: "Other")
        }
    }
}
