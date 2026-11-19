import Foundation

/// The files a turn ended on: what "those" means in the next one. The engine keeps it; the model
/// only ever gets one line about it, and narrows it by asking `searchFiles` for the mark `lastResult`.
struct LastResult: Sendable, Equatable {
    /// The tool that found them.
    var tool: String
    /// The filter in words, built by code.
    var words: String
    var sort: FileSort?
    /// Every file found, not only the ones listed.
    var ids: [URL]
    var bytes: Int64

    /// Above this, the words say less instead of being cut, which could cut a data mark in half.
    static let wordsLimit = 160

    /// Nil for a cleanup card, which is not a list to look in.
    init?(_ result: TurnEffects.Result, after previous: LastResult?) {
        switch result {
        case .search(let search):
            tool = "searchFiles"
            let own = search.query.words.joined(separator: ", ")
            // A search inside the last result is that result's filter and its own.
            // Asked again (Continue after Stop), the same narrowing is said once.
            let all = if search.query.withinIDs != nil, let previous {
                own.isEmpty || previous.words.hasSuffix(own) ? previous.words : previous.words + ", " + own
            } else {
                own.isEmpty ? "all items" : own
            }
            words = all.count > Self.wordsLimit ? "several filters" : all
            sort = search.sort
            ids = search.matchIDs
            bytes = search.totalBytes
        case .summary(let summary):
            tool = "folderSummary"
            words = "the largest files"
            sort = .largest
            ids = summary.largest.map(\.id)
            bytes = summary.largest.reduce(0) { $0 + ($1.sizeInBytes ?? 0) }
        case .duplicates(let scan):
            tool = "findDuplicates"
            words = "files with the same content"
            sort = nil
            let files = scan.groups.flatMap { [$0.kept] + $0.copies }
            ids = files.map(\.id)
            bytes = files.reduce(0) { $0 + ($1.sizeInBytes ?? 0) }
        case .cleanup:
            return nil
        }
    }
}

/// What the app remembers of a conversation, whatever becomes of the model's session: a line per
/// answered turn, the last result, and a question that was stopped before it was answered. The
/// model's context is small and its session forgets a turn that did not finish, so this is kept
/// in code and handed over as a short note before each question (docs/decisions/0022).
struct ChatMemory: Sendable {
    static let linesKept = 20
    /// The most characters of earlier turns the note carries; the oldest go first.
    static let summaryLimit = 300
    static let questionLimit = 60
    static let stoppedQuestionLimit = 200

    private(set) var lines: [String] = []
    private(set) var lastResult: LastResult?
    /// The question of a turn that was stopped or ran out of time.
    private(set) var pending: String?

    /// True for a message that only asks to go on. With a stopped question waiting, that question
    /// is asked again in its place; any other wording is left to the model, which is told of it.
    static func isContinue(_ text: String) -> Bool {
        let trimmed = CharacterSet.whitespacesAndNewlines.union(.punctuationCharacters)
        var words = text.lowercased().trimmingCharacters(in: trimmed)
        // "Keep going please" is no more a new request than "keep going". Left to the model, it
        // answered the stopped question and then prepared a cleanup nobody asked for (0023).
        for polite in ["please ", " please"] where words.hasPrefix(polite) || words.hasSuffix(polite) {
            words = words.replacingOccurrences(of: polite, with: "").trimmingCharacters(in: trimmed)
        }
        return [
            "continue", "go on", "keep going", "resume", "carry on", "try again", "go ahead", "finish",
            "finish it", "finish what you were doing",
        ].contains(words)
    }

    /// What to ask the model for `text`: the stopped question when `text` only says to continue.
    func question(for text: String) -> String {
        if let pending, Self.isContinue(text) { pending } else { text }
    }

    /// Takes in a turn that ended.
    mutating func record(_ question: String, outcome: TurnOutcome, effects: TurnEffects) {
        switch outcome {
        case .answered:
            pending = nil
            let found = effects.results.last.map(Self.found) ?? "no lookup"
            lines.append("\"\(ToolOutput.cleaned(question, limit: Self.questionLimit))\": \(found)")
            lines.removeFirst(max(0, lines.count - Self.linesKept))
        case .stopped, .timedOut:
            pending = question
        case .toolLimitReached, .refused, .contextFull, .unavailable, .failed:
            // The stopped question may be tried again after it failed. Any other question since
            // means the user moved on: a later "try again" must not bring the old one back.
            if question != pending { pending = nil }
        }
        // The turns whose card the app shows. A search that found nothing leaves "those" as they
        // were, so "the ones over 500 MB then" still has files to look in.
        // A cleanup card is not a list to look in: the lookup before it, if any, is.
        let previous = lastResult
        if outcome == .answered || outcome == .stopped,
           let found = effects.results.reversed().lazy.compactMap({ LastResult($0, after: previous) }).first,
           !found.ids.isEmpty {
            lastResult = found
        }
    }

    private static func found(_ result: TurnEffects.Result) -> String {
        switch result {
        case .search(let search): "\(search.matchCount) files, \(ToolOutput.size(search.totalBytes))"
        case .summary: "folder totals"
        case .duplicates(let scan): "\(scan.copyCount) copies"
        case .cleanup(let proposal): "a cleanup preview of \(proposal.count) files, not confirmed here"
        }
    }

    /// The note the model reads before `question`, or nil with nothing to say: the turns it is no
    /// longer shown (all but the latest `shownTurns`), a stopped question unless it is the one being
    /// asked, and one line about the last result. Never a list of files.
    ///
    /// With `shownTurns` nil it is the note at its longest, for counting tokens: the summary is the
    /// lines repeated to exactly its limit, which no real summary exceeds. That size does not
    /// change as turns drop out or the summary fills up, so fitting a turn stays at one or two counts.
    func note(showingTurns shownTurns: Int?, asking question: String, largeMegabytes: Int) -> String? {
        var notes: [String] = []
        var summary: [String] = []
        for line in lines.dropLast(max(0, shownTurns ?? 0)).reversed() {
            guard (summary + [line]).joined(separator: "; ").count <= Self.summaryLimit else { break }
            summary.insert(line, at: 0)
        }
        var earlier = summary.joined(separator: "; ")
        if shownTurns == nil, !lines.isEmpty {
            let all = lines.joined(separator: "; ") + "; "
            earlier = String(String(repeating: all, count: Self.summaryLimit / all.count + 1).prefix(Self.summaryLimit))
        }
        if !earlier.isEmpty {
            notes.append(PromptLibrary.noteEarlier.text.replacingOccurrences(of: "{lines}", with: earlier))
        }
        if let pending, pending != question {
            let stopped = ToolOutput.cleaned(pending, limit: Self.stoppedQuestionLimit)
            notes.append(PromptLibrary.noteStopped.text.replacingOccurrences(of: "{question}", with: stopped))
        }
        if let lastResult {
            let sorted = lastResult.sort.map { ", sorted \($0.rawValue)" } ?? ""
            notes.append(
                PromptLibrary.noteLastResult.text
                    .replacingOccurrences(of: "{count}", with: String(lastResult.ids.count))
                    .replacingOccurrences(of: "{size}", with: ToolOutput.size(lastResult.bytes))
                    .replacingOccurrences(of: "{large}", with: String(largeMegabytes))
                    // Last: the words can hold text the model chose, which must not be filled in again.
                    .replacingOccurrences(of: "{words}", with: lastResult.words + sorted)
            )
        }
        guard !notes.isEmpty else { return nil }
        return PromptLibrary.note.text.replacingOccurrences(of: "{notes}", with: notes.joined(separator: "\n"))
    }
}
