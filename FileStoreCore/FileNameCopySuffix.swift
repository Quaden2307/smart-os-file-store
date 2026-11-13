import Foundation

/// Recognises the suffixes browsers and Finder add to a copy's name: `report (1).pdf`,
/// `report copy.pdf`, `report copy 2.pdf`. A name without one is "clean", and the duplicate finder
/// prefers to keep clean names.
public enum FileNameCopySuffix {
    /// True when the name, minus its extension, ends in ` (N)`, ` copy` or ` copy N`, compared
    /// case-insensitively. The space is required: `report(1).pdf` and `copy.pdf` are clean names.
    public static func hasCopySuffix(_ fileName: String) -> Bool {
        let stem = stem(of: fileName).lowercased()
        guard let lastSpace = stem.lastIndex(of: " ") else { return false }
        let head = stem[..<lastSpace]
        let tail = stem[stem.index(after: lastSpace)...]

        if tail == "copy" {
            return true
        }
        if tail.hasPrefix("("), tail.hasSuffix(")") {
            return isDigits(tail.dropFirst().dropLast())
        }
        return isDigits(tail) && head.hasSuffix(" copy")
    }

    /// The name without its last extension, and without a further `.tar`, so that
    /// `archive (1).tar.gz` reads as `archive (1)`.
    static func stem(of fileName: String) -> String {
        var stem = (fileName as NSString).deletingPathExtension
        if stem.lowercased().hasSuffix(".tar") {
            stem = String(stem.dropLast(4))
        }
        return stem
    }

    private static func isDigits(_ text: Substring) -> Bool {
        !text.isEmpty && text.allSatisfy { $0.isASCII && $0.isNumber }
    }
}
