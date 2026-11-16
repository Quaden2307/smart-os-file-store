import Foundation

/// The name rule of Remove Used Installers (decision record 0012): an installer's file name, cleaned
/// of its extension, copy suffix, version numbers and platform words, against an installed app's
/// name, both compared without letter case, spaces, `-` or `_`. `SomeApp-2.1-arm64.dmg` and
/// `googlechrome.dmg` give the keys of SomeApp and Google Chrome.
public enum InstallerName {
    /// Words that name a processor or a platform, not the app.
    static let platformWords: Set<String> = [
        "arm64", "aarch64", "x64", "x86", "x86_64", "amd64", "i386", "intel", "universal", "universal2",
        "mac", "macos", "macosx", "osx", "darwin", "silicon", "applesilicon",
    ]

    /// The key of an installer called `fileName`, or nil when nothing is left of the name.
    public static func key(ofFileName fileName: String) -> String? {
        let stem = FileNameCopySuffix.stem(of: fileName)
        var words: [String] = stem.split(whereSeparator: { $0 == " " || $0 == "-" }).map(String.init)
        if FileNameCopySuffix.hasCopySuffix(fileName) {
            dropCopySuffix(from: &words)
        }
        // `x86_64` is one platform word; any other `_` separates words.
        let parts: [String] = words.flatMap { (word: String) -> [String] in
            platformWords.contains(word.lowercased()) ? [word] : word.split(separator: "_").map(String.init)
        }
        let kept = parts.filter { !platformWords.contains($0.lowercased()) && !isVersion($0) }
        let key = kept.joined().lowercased()
        return key.isEmpty ? nil : key
    }

    /// The key of an installed app called `appName`.
    public static func key(ofAppName appName: String) -> String {
        appName.lowercased().filter { $0 != " " && $0 != "-" && $0 != "_" }
    }

    /// True for `2.1`, `v2.1`, `2.1.0b3` or `2024`: digits and dots, an optional leading `v`, and
    /// an optional letter suffix only with digits after it, so `1Password` and `4K` stay words.
    static func isVersion(_ word: String) -> Bool {
        word.lowercased().wholeMatch(of: #/v?[0-9]+(\.[0-9]+)*([a-z]+[0-9]+)?/#) != nil
    }

    /// Drops ` (N)`, ` copy` or ` copy N` from the end, the suffixes `FileNameCopySuffix` names.
    private static func dropCopySuffix(from words: inout [String]) {
        guard let last = words.last?.lowercased() else {
            return
        }
        if last == "copy" || last.hasPrefix("(") {
            words.removeLast()
        } else if words.count >= 2, words[words.count - 2].lowercased() == "copy" {
            words.removeLast(2)
        }
    }
}
