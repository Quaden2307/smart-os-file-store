import Foundation

/// Compares the versions an installer and an installed app give (decision record 0012). Dotted whole
/// numbers of any length compare part by part, with missing parts as 0, so `2.1` = `2.1.0` and
/// `2.10` > `2.9`. Parts compare by their digits, so no length can overflow. Anything else, such as
/// `2.1b3` or `1.0 (45)`, cannot be compared.
public enum InstallerVersion {
    /// How `first` compares with `second`, or nil when either cannot be compared.
    public static func compare(_ first: String, _ second: String) -> ComparisonResult? {
        guard let left = parts(of: first), let right = parts(of: second) else {
            return nil
        }
        for index in 0..<max(left.count, right.count) {
            let a = index < left.count ? left[index] : "0"
            let b = index < right.count ? right[index] : "0"
            if a.count != b.count {
                return a.count < b.count ? .orderedAscending : .orderedDescending
            }
            if a != b {
                return a < b ? .orderedAscending : .orderedDescending
            }
        }
        return .orderedSame
    }

    /// How the installed app's version compares with the installer's: the short version decides,
    /// and the build breaks a tie when both builds can be compared. Without short versions on both
    /// sides, the builds decide alone. Nil when nothing can be compared.
    public static func compare(installed: BundleFacts, installer: BundleFacts) -> ComparisonResult? {
        let builds = installed.build.flatMap { a in installer.build.flatMap { b in compare(a, b) } }
        guard let installedShort = installed.shortVersion, let installerShort = installer.shortVersion else {
            return builds
        }
        guard let short = compare(installedShort, installerShort) else {
            return nil
        }
        return short == .orderedSame ? builds ?? .orderedSame : short
    }

    /// The parts of `version` without leading zeros, or nil when it is not dotted whole numbers.
    private static func parts(of version: String) -> [Substring]? {
        let parts = version.split(separator: ".", omittingEmptySubsequences: false)
        guard parts.allSatisfy({ part in !part.isEmpty && part.allSatisfy { $0.isASCII && $0.isNumber } }) else {
            return nil
        }
        return parts.map { part in
            let trimmed = part.drop { $0 == "0" }
            return trimmed.isEmpty ? "0" : trimmed
        }
    }
}
