import Foundation

/// Cleans one file name for Fix Messy Names, by five rules and only these, in this order:
///
/// 1. Decode percent-encoding (`%20`) in the name before the extension, once, when the whole name
///    decodes to valid text and the result holds no path separator (`/`, or `:`, which Finder shows
///    as `/`), control character, bidirectional control or further escape (`%2520` would need a
///    second decoding, which could turn a `%41` the person typed into `A`, so it is left alone).
/// 2. Remove a leftover of a web address from the very end, right after a real extension:
///    `?` or `_` then one of `webLeftoverQueries`, or `@download` (`brochure.pdf_dl=1`).
/// 3. Remove a doubled extension (`slides.pdf.pdf`).
/// 4. Remove a copy suffix, by `FileNameCopySuffix`, so duplicates and renames agree.
/// 5. Collapse runs of spaces, and trim spaces, dots and underscores left at the end of the name
///    before the extension, and at its start only when decoding changed the start: rules 2 to 4
///    only ever remove from the end, so `_draft (1).docx` keeps its underscore.
///
/// The rules run again until nothing changes, so a cleaned name is clean (`report.pdf (1).pdf`
/// needs rule 3 after rule 4). A name only counts as messy when rules 1 to 4 find something: rule 5
/// alone never renames a file (`__init__.py`, `a  b.pdf`). The extension is never changed, except
/// that rule 2 takes a leftover off the end of it; case, dates, versions and words are left alone.
///
/// Pure: names in, names out.
public enum MessyNameCleaner {
    /// A clean name and the rules that made it.
    public struct Cleaned: Sendable, Hashable {
        public let name: String
        public let fixes: [NameFix]
    }

    /// The queries rule 2 knows, as a browser leaves them after `?` or `_`: Dropbox's `dl` and
    /// `raw`, GitHub's `raw` and the common `download`. Compared case-insensitively.
    public static let webLeftoverQueries = ["dl=0", "dl=1", "raw=1", "raw=true", "download=1", "download=true"]

    /// Everything rule 2 removes, longest first, so that `_download=1` is not read as `_dl=1`'s kin.
    static let webLeftovers: [String] = (webLeftoverQueries.flatMap { ["?" + $0, "_" + $0] } + ["@download"])
        .sorted { $0.count > $1.count }

    /// The clean name for `name`, or nil when it is already clean or cleaning it would leave nothing
    /// before the extension or a name no rename may give (`FileNameRules.isAllowedFileName`).
    public static func clean(_ name: String) -> Cleaned? {
        var current = name
        var fixes: [NameFix] = []
        var escapes: [String] = []
        var expectedExtension = parts(of: name).extension
        var decodedAny = false
        // Every pass that changes the name makes it shorter, so this many passes always suffice.
        for _ in 0...name.unicodeScalars.count {
            let passStart = current

            if let decoded = decodingPercentEncoding(current) {
                guard !decoded.stem.isEmpty else { return nil }
                if let candidate = joined(decoded.stem, current, keeping: expectedExtension) {
                    current = candidate
                    escapes += decoded.escapes.filter { !escapes.contains($0) }
                    decodedAny = true
                }
            }
            if let removed = removingWebLeftover(current) {
                current = removed.name
                expectedExtension = parts(of: current).extension
                fixes.append(.removedWebLeftover(removed.leftover))
            }
            if let removed = removingDoubledExtension(current),
               let candidate = joined(removed.stem, current, keeping: expectedExtension) {
                current = candidate
                fixes.append(.removedDoubledExtension(removed.removed))
            }
            if let removed = FileNameCopySuffix.removingCopySuffix(fromStem: parts(of: current).stem) {
                guard !removed.stem.isEmpty else { return nil }
                if let candidate = joined(removed.stem, current, keeping: expectedExtension) {
                    current = candidate
                    fixes.append(.removedCopySuffix(removed.removed))
                }
            }
            if let collapsed = collapsingSpaces(parts(of: current).stem),
               let candidate = joined(collapsed, current, keeping: expectedExtension) {
                current = candidate
                fixes.append(.collapsedSpaces)
            }
            if let trimmed = trimmingEnds(parts(of: current).stem, includingStart: decodedAny) {
                guard !trimmed.isEmpty else { return nil }
                if let candidate = joined(trimmed, current, keeping: expectedExtension) {
                    current = candidate
                    fixes.append(.trimmedEnds)
                }
            }

            if current.unicodeScalars.elementsEqual(passStart.unicodeScalars) {
                break
            }
        }

        if !escapes.isEmpty {
            fixes.insert(.decodedPercentEncoding(escapes: escapes), at: 0)
        }
        var unique: [NameFix] = []
        for fix in fixes where !unique.contains(fix) {
            unique.append(fix)
        }
        let foundMess = unique.contains { fix in
            switch fix {
            case .decodedPercentEncoding, .removedWebLeftover, .removedDoubledExtension, .removedCopySuffix:
                true
            case .collapsedSpaces, .trimmedEnds:
                false
            }
        }
        guard foundMess,
              !current.unicodeScalars.elementsEqual(name.unicodeScalars),
              FileNameRules.isAllowedFileName(current, maximumLength: FileNameRules.defaultMaximumLength) else {
            return nil
        }
        return Cleaned(name: current, fixes: unique)
    }

    // MARK: - Parts of a name

    /// The name before the extension, and the extension with its dot: the extension is what
    /// `FileNameCopySuffix` reads as one (`.pdf`, `.tar.gz`), or empty.
    static func parts(of name: String) -> (stem: String, extension: String) {
        let stem = FileNameCopySuffix.stem(of: name)
        let utf16 = name.utf16
        guard let split = utf16.index(utf16.startIndex, offsetBy: stem.utf16.count, limitedBy: utf16.endIndex) else {
            return (name, "")
        }
        return (stem, String(name[split...]))
    }

    /// `stem` with `name`'s extension, or nil when the result would read with another extension
    /// than `expectedExtension`: no rule but the web leftover's may change it.
    private static func joined(_ stem: String, _ name: String, keeping expectedExtension: String) -> String? {
        let candidate = stem + parts(of: name).extension
        let reread = parts(of: candidate)
        guard reread.extension == expectedExtension, reread.stem == stem else {
            return nil
        }
        return candidate
    }

    // MARK: - The rules

    /// Rule 1: the name before the extension decoded, with the escapes it held, or nil when there is
    /// nothing to decode, the whole name does not decode, or the result holds a forbidden character.
    private static func decodingPercentEncoding(_ name: String) -> (stem: String, escapes: [String])? {
        let stem = parts(of: name).stem
        guard stem.contains("%"),
              name.removingPercentEncoding != nil,
              let decoded = stem.removingPercentEncoding,
              !decoded.unicodeScalars.elementsEqual(stem.unicodeScalars),
              !decoded.unicodeScalars.contains(where: isForbiddenAfterDecoding),
              percentEscapes(in: decoded).isEmpty else {
            return nil
        }
        return (decoded, percentEscapes(in: stem))
    }

    /// True for a character decoding must never put into a name: a path separator, a control
    /// character (NUL among them) or a bidirectional control, which can make `exe.pdf` read as `fdp.exe`.
    static func isForbiddenAfterDecoding(_ scalar: Unicode.Scalar) -> Bool {
        if scalar == "/" || scalar == ":" || scalar.properties.generalCategory == .control {
            return true
        }
        switch scalar.value {
        case 0x061C, 0x200E, 0x200F, 0x202A...0x202E, 0x2066...0x2069:
            return true
        default:
            return false
        }
    }

    /// The distinct `%XX` escapes in `text`, upper-cased, in order.
    private static func percentEscapes(in text: String) -> [String] {
        let bytes = Array(text.utf8)
        var escapes: [String] = []
        var index = 0
        while index + 2 < bytes.count {
            if bytes[index] == UInt8(ascii: "%"), isHexDigit(bytes[index + 1]), isHexDigit(bytes[index + 2]) {
                let escape = String(decoding: bytes[index...(index + 2)], as: UTF8.self).uppercased()
                if !escapes.contains(escape) {
                    escapes.append(escape)
                }
                index += 3
            } else {
                index += 1
            }
        }
        return escapes
    }

    private static func isHexDigit(_ byte: UInt8) -> Bool {
        (UInt8(ascii: "0")...UInt8(ascii: "9")).contains(byte)
            || (UInt8(ascii: "a")...UInt8(ascii: "f")).contains(byte)
            || (UInt8(ascii: "A")...UInt8(ascii: "F")).contains(byte)
    }

    /// Rule 2: `name` without a known leftover at its end, and the leftover as written. Only when
    /// what is left ends in a real extension, one to ten ASCII letters or digits after a dot, with
    /// something before the dot: `file_dl=1` keeps its name.
    private static func removingWebLeftover(_ name: String) -> (name: String, leftover: String)? {
        let scalars = name.unicodeScalars
        for leftover in webLeftovers {
            let length = leftover.unicodeScalars.count
            guard scalars.count > length else { continue }
            let cut = scalars.index(scalars.endIndex, offsetBy: -length)
            let tail = String(name[cut...])
            guard tail.lowercased() == leftover else { continue }
            let rest = String(name[..<cut])
            guard let dot = rest.lastIndex(of: "."), dot != rest.startIndex else { continue }
            let pathExtension = rest[rest.index(after: dot)...]
            guard (1...10).contains(pathExtension.count),
                  pathExtension.allSatisfy({ $0.isASCII && ($0.isLetter || $0.isNumber) }) else { continue }
            return (rest, tail)
        }
        return nil
    }

    /// Rule 3: the name before the extension without a repeat of the extension at its end, and
    /// the repeat as written (`.PDF` in `report.PDF.pdf`). The outer extension stays as it is.
    private static func removingDoubledExtension(_ name: String) -> (stem: String, removed: String)? {
        let (stem, pathExtension) = parts(of: name)
        let length = pathExtension.unicodeScalars.count
        let scalars = stem.unicodeScalars
        guard !pathExtension.isEmpty, scalars.count > length else { return nil }
        let cut = scalars.index(scalars.endIndex, offsetBy: -length)
        let repeated = String(stem[cut...])
        guard repeated.lowercased() == pathExtension.lowercased() else { return nil }
        return (String(stem[..<cut]), repeated)
    }

    /// Rule 5, first half: `stem` with every run of spaces made one, or nil when it has none.
    private static func collapsingSpaces(_ stem: String) -> String? {
        guard stem.contains("  ") else { return nil }
        var collapsed = ""
        var previousWasSpace = false
        for character in stem {
            if character == " ", previousWasSpace { continue }
            previousWasSpace = character == " "
            collapsed.append(character)
        }
        return collapsed
    }

    /// Rule 5, second half: `stem` without spaces, dots and underscores at its end, and at its
    /// start too when `includingStart`, or nil when there are none to remove.
    private static func trimmingEnds(_ stem: String, includingStart: Bool) -> String? {
        let junk: Set<Character> = [" ", ".", "_"]
        var trimmed = Substring(stem)
        while let last = trimmed.last, junk.contains(last) {
            trimmed = trimmed.dropLast()
        }
        while includingStart, let first = trimmed.first, junk.contains(first) {
            trimmed = trimmed.dropFirst()
        }
        return trimmed.count == stem.count ? nil : String(trimmed)
    }
}
