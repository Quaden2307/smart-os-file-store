import Foundation

/// The only place that writes text for the model to read. A tool's output is short on purpose:
/// counts, a total and a few names. The app shows the full result from `TurnEffects`, so the
/// model never has to carry a list or a number the user depends on.
public enum ToolOutput {
    public static let namesShown = 8
    public static let nameLimit = 60
    /// About 300 tokens: names, sizes and dates come to about two characters a token (measured:
    /// docs/decisions/0020). Names are dropped from the end to fit.
    public static let characterLimit = 600

    /// Text from the disk made safe to put in front of the model: no control or invisible
    /// characters (line breaks, direction overrides, tag characters, variation selectors, fillers),
    /// no delimiter characters, at most `limit` characters.
    static func cleaned(_ text: String, limit: Int) -> String {
        let scalars = text.unicodeScalars.filter { scalar in
            // Characters that draw nothing can carry text a person never sees.
            guard !scalar.properties.isDefaultIgnorableCodePoint else { return false }
            return switch scalar.properties.generalCategory {
            case .control, .format, .lineSeparator, .paragraphSeparator, .surrogate, .privateUse, .unassigned:
                false
            default:
                scalar != PromptLibrary.dataOpen.unicodeScalars.first && scalar != PromptLibrary.dataClose.unicodeScalars.first
            }
        }
        let clean = String(String.UnicodeScalarView(scalars))
        return clean.count > limit ? clean.prefix(limit - 1) + "…" : clean
    }

    /// Untrusted text between the delimiters the instructions describe as data.
    public static func quoted(_ text: String) -> String {
        "\(PromptLibrary.dataOpen)\(cleaned(text, limit: nameLimit))\(PromptLibrary.dataClose)"
    }

    static func size(_ bytes: Int64) -> String {
        bytes.formatted(.byteCount(style: .file, spellsOutZero: false))
    }

    public static func search(_ result: FileSearchResult, now: Date) -> String {
        // Unknown is said, never counted: macOS dates no opens for folders, apps and links.
        let unknown = result.unknownOpenCount > 0
            ? "\n\(result.unknownOpenCount) more items: last opened unknown, not counted." : ""
        guard result.matchCount > 0 else { return "No files match." + unknown }
        // All macOS can say of a file without a last-opened date (docs/decisions/0022).
        let found = result.query.neverOpened ? "files have no open recorded by macOS" : "files match"
        let header = """
            \(result.matchCount) \(found), \(size(result.totalBytes)) in total. The app shows the user the list.\(unknown)
            The first ones, sorted by \(result.sort.rawValue):
            """
        let lines = result.files.prefix(namesShown).map { file in
            var line = quoted(file.name)
            if let bytes = file.sizeInBytes { line += " \(size(bytes))" }
            if let added = file.dateAdded { line += ", added \(DayText.daysBack(from: added, to: now))" }
            return line
        }
        return capped(header, lines)
    }

    public static func summary(_ summary: FolderSummary) -> String {
        /// "documents 6 (18.4 MB), images 3 (8.6 MB)"; counts alone for marks, to leave room for names.
        func totals<Key: RawRepresentable & CaseIterable & Hashable>(_ totals: [Key: FolderSummary.Total], sizes: Bool) -> String
        where Key.RawValue == String {
            let parts = Key.allCases.compactMap { key in
                totals[key].map { sizes ? "\(key.rawValue) \($0.count) (\(size($0.bytes)))" : "\(key.rawValue) \($0.count)" }
            }
            return parts.isEmpty ? "none" : parts.joined(separator: ", ")
        }
        var header = """
            \(summary.all.count) items, \(size(summary.all.bytes)) in total. The app shows the user these numbers.
            By kind: \(totals(summary.byTypeGroup, sizes: true)).
            By mark: \(totals(summary.byMark, sizes: false)).
            """
        if let moved = summary.bytesMovedToTrash {
            header += "\nCleanups have moved \(size(moved)) to the Trash so far."
        }
        guard !summary.largest.isEmpty else { return header }
        let lines = summary.largest.prefix(namesShown).map { file in
            "\(quoted(file.name)) \(size(file.sizeInBytes ?? 0))"
        }
        return capped(header + "\nLargest files:", lines)
    }

    public static func duplicates(_ scan: DuplicateScan) -> String {
        var notes = ""
        if scan.recentCount > 0 { notes += "\n\(scan.recentCount) files added in the last hour are not checked yet." }
        if scan.unreadableCount > 0 { notes += "\n\(scan.unreadableCount) files could not be read, so they are not counted." }
        guard scan.copyCount > 0 else { return "No two files have the same content." + notes }
        let header = """
            \(scan.copyCount) files are copies of another file, \(size(scan.copyBytes)) in the copies. The app shows the user the list.\(notes)
            Each kept file and its number of copies:
            """
        let lines = scan.groups.prefix(namesShown).map { group in
            "\(quoted(group.kept.name)) \(group.copies.count) \(group.copies.count == 1 ? "copy" : "copies")"
        }
        return capped(header, lines)
    }

    /// What the model gets when the app could not run Find Duplicates.
    public static let duplicatesUnavailable = PromptLibrary.duplicatesUnavailable.text

    /// What the model gets for a lookup it already made in this turn: nothing runs twice.
    public static let repeated = PromptLibrary.repeatedLookup.text

    /// What the model gets back for arguments that made no sense, so it can call again correctly.
    public static func invalid(_ error: FilterError) -> String {
        "That call was not understood: \(error.message)"
    }

    private static func capped(_ header: String, _ lines: [String]) -> String {
        var lines = lines
        func text() -> String { ([header] + lines).joined(separator: "\n") }
        while text().count > characterLimit, !lines.isEmpty {
            lines.removeLast()
        }
        return text()
    }
}
