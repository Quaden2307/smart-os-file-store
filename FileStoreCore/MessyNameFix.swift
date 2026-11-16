import Foundation

/// One rule Fix Messy Names applied to a name, with what it removed, so the preview can say so.
public enum NameFix: Sendable, Hashable {
    /// Percent-encoding was decoded. `escapes` are the distinct escapes, as written (`%20`).
    case decodedPercentEncoding(escapes: [String])

    /// A leftover of a web address was removed from the end: `_dl=1`, `?raw=true`, `@download`.
    case removedWebLeftover(String)

    /// A doubled extension was removed: `.pdf` from `report.pdf.pdf`.
    case removedDoubledExtension(String)

    /// A copy suffix was removed, as written: ` (2)`, ` copy`, ` copy 2`.
    case removedCopySuffix(String)

    /// Runs of spaces became one space.
    case collapsedSpaces

    /// Spaces, dots or underscores left at either end of the name were removed.
    case trimmedEnds
}

/// Why Fix Messy Names proposes a new name: the rules it applied and, when the clean name was taken
/// by a different file, that name, which is why the date (and maybe a number) was added.
public struct MessyNameFix: Sendable, Hashable {
    public let fixes: [NameFix]

    /// The clean name, when another file has it or an older file in the plan gets it. Nil when the
    /// new name is the clean name.
    public let takenName: String?

    public init(fixes: [NameFix], takenName: String? = nil) {
        self.fixes = fixes
        self.takenName = takenName
    }
}
