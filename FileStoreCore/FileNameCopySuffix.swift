import Foundation

/// Recognises the suffixes browsers and Finder add to a copy's name: `report (1).pdf`,
/// `report copy.pdf`, `report copy 2.pdf`. A name without one is "clean", and the duplicate finder
/// prefers to keep clean names. Fix Messy Names removes the same suffixes, so the two always agree.
public enum FileNameCopySuffix {
    /// True when the name, minus its extension, ends in ` (N)`, ` copy` or ` copy N`, compared
    /// case-insensitively. The space is required: `report(1).pdf` and `copy.pdf` are clean names.
    public static func hasCopySuffix(_ fileName: String) -> Bool {
        removingCopySuffix(fromStem: stem(of: fileName)) != nil
    }

    /// `stem` without its copy suffix, and the suffix as it was written (` (2)`, ` Copy 2`), or nil
    /// when it has none. Only the very end counts: `Chapter (2) notes` has no suffix.
    public static func removingCopySuffix(fromStem stem: String) -> (stem: String, removed: String)? {
        guard let lastSpace = stem.lastIndex(of: " ") else { return nil }
        let head = stem[..<lastSpace]
        let tail = stem[stem.index(after: lastSpace)...]

        if tail.lowercased() == "copy" {
            return (String(head), String(stem[lastSpace...]))
        }
        if tail.hasPrefix("("), tail.hasSuffix(")"), isDigits(tail.dropFirst().dropLast()) {
            return (String(head), String(stem[lastSpace...]))
        }
        if isDigits(tail), head.lowercased().hasSuffix(" copy") {
            let copyStart = head.index(head.endIndex, offsetBy: -5)
            return (String(stem[..<copyStart]), String(stem[copyStart...]))
        }
        return nil
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
