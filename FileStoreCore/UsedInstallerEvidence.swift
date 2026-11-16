import Foundation

/// Why Remove Used Installers proposes an installer: the installed app it matched, and how strongly
/// (decision record 0012).
public struct UsedInstallerEvidence: Sendable, Hashable {
    public enum Strength: Sendable, Hashable {
        /// The identifier matches, and the installed version is the same or newer: ticked.
        case strong
        /// Only the name matches: proposed unticked, as a possible match.
        case possible
    }

    public let strength: Strength

    /// The installed app's name, or for a package that installs no app, its identifier.
    public let name: String

    /// The installed app's version, or the receipt's.
    public let version: String?

    /// The installed app, `/Applications/SomeApp.app`. Nil for a package matched by its receipts alone.
    public let installedAppPath: String?

    /// For a strong match on an app, its bundle identifier, checked again right before the installer
    /// moves.
    public let bundleIdentifier: String?

    /// For a package matched by its receipts alone, the receipts checked again right before it moves.
    public let receiptIdentifiers: [String]

    /// How many more apps or parts matched besides the one named.
    public let otherMatches: Int

    public init(
        strength: Strength,
        name: String,
        version: String?,
        installedAppPath: String?,
        bundleIdentifier: String?,
        receiptIdentifiers: [String] = [],
        otherMatches: Int = 0
    ) {
        self.strength = strength
        self.name = name
        self.version = version
        self.installedAppPath = installedAppPath
        self.bundleIdentifier = bundleIdentifier
        self.receiptIdentifiers = receiptIdentifiers
        self.otherMatches = otherMatches
    }
}
