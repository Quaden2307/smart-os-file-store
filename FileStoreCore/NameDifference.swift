import Foundation

/// Where two names differ, as the preview of a rename marks it: the part both start with, the part
/// both end with, and between them what the old name loses and the new name gains. Compared by
/// `Character`, so an accented letter or an emoji is never split. Pure.
public struct NameDifference: Sendable, Hashable {
    public let commonPrefix: String
    /// What the old name has between the common parts, and the new name does not.
    public let removed: String
    /// What the new name has between the common parts, and the old name does not.
    public let added: String
    public let commonSuffix: String

    public init(from old: String, to new: String) {
        let oldCharacters = Array(old)
        let newCharacters = Array(new)
        var prefix = 0
        while prefix < oldCharacters.count, prefix < newCharacters.count, oldCharacters[prefix] == newCharacters[prefix] {
            prefix += 1
        }
        // The suffix never overlaps the prefix: "aa" to "a" removes one "a", not a negative one.
        var suffix = 0
        while suffix < oldCharacters.count - prefix, suffix < newCharacters.count - prefix,
              oldCharacters[oldCharacters.count - 1 - suffix] == newCharacters[newCharacters.count - 1 - suffix] {
            suffix += 1
        }
        commonPrefix = String(oldCharacters[..<prefix])
        removed = String(oldCharacters[prefix..<(oldCharacters.count - suffix)])
        added = String(newCharacters[prefix..<(newCharacters.count - suffix)])
        commonSuffix = String(oldCharacters[(oldCharacters.count - suffix)...])
    }
}
