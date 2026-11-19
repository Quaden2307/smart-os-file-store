import Foundation
import FoundationModels

/// What the model is shown of a conversation. The session keeps every entry; before each call to
/// the model it shows the instructions, the turn in progress in full, and the latest earlier turns
/// with each tool output cut to its first line, the short summary `ToolOutput` puts there. The
/// app drew the full results when they arrived, so the model only needs to know what was found
/// (docs/decisions/0021).
enum ChatHistory {
    /// `entries` as the model should see them, with at most `earlierTurns` of the turns before the
    /// one in progress. A turn starts at a prompt; what comes before the first one (the
    /// instructions) is always kept. `note` is what the app remembers (`ChatMemory`): it goes in
    /// front of the question of the turn in progress only, so the transcript keeps the question as
    /// asked and a note is never shown twice.
    static func compacted(
        _ entries: [Transcript.Entry], keepingEarlierTurns earlierTurns: Int, note: String? = nil
    ) -> [Transcript.Entry] {
        let starts = turnStarts(in: entries)
        guard let current = starts.last else { return entries }
        let earlier = starts.dropLast()
        let firstShown = earlier.dropFirst(max(0, earlier.count - max(0, earlierTurns))).first ?? current
        var inProgress = Array(entries[current...])
        if let note, case .prompt(var prompt) = inProgress[0] {
            // In the question's own segment where it has one: how the model is shown two is not documented.
            if case .text(var question)? = prompt.segments.first {
                question.content = note + question.content
                prompt.segments[0] = .text(question)
            } else {
                prompt.segments.insert(.text(Transcript.TextSegment(content: note)), at: 0)
            }
            inProgress[0] = .prompt(prompt)
        }
        return Array(entries[..<starts[0]]) + entries[firstShown..<current].map(stubbed) + inProgress
    }

    /// The last `count` turns of `entries`, with nothing before them: the history a fresh
    /// conversation starts from when the old one is too full to go on.
    static func lastTurns(_ entries: [Transcript.Entry], _ count: Int) -> [Transcript.Entry] {
        let starts = turnStarts(in: entries)
        guard count > 0, let first = starts.dropFirst(max(0, starts.count - count)).first else { return [] }
        return Array(entries[first...])
    }

    /// How many turns `entries` holds.
    static func turnCount(_ entries: [Transcript.Entry]) -> Int {
        turnStarts(in: entries).count
    }

    private static func turnStarts(in entries: [Transcript.Entry]) -> [Int] {
        entries.indices.filter { if case .prompt = entries[$0] { true } else { false } }
    }

    /// A tool output cut to its first line.
    private static func stubbed(_ entry: Transcript.Entry) -> Transcript.Entry {
        guard case .toolOutput(var output) = entry else { return entry }
        let text = output.segments.map { segment in
            if case .text(let text) = segment { text.content } else { "" }
        }.joined()
        output.segments = [.text(Transcript.TextSegment(content: String(text.prefix { !$0.isNewline })))]
        return .toolOutput(output)
    }
}
