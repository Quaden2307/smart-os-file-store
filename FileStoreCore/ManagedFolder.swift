import Foundation

/// A folder the app looks after: Downloads, and in time Desktop, Documents and folders the user adds.
///
/// A folder is known by its `id`, made once when it is first managed and stored in the activity
/// log, never by its path: a path changes when the folder is renamed or moved, and a different
/// folder can be made at the old one. Every plan, run and undo belongs to exactly one folder.
///
/// Two values are equal when they name the same folder, wherever it was found: a bookmark made
/// again or a folder found at a new place does not make a plan a different plan.
public struct ManagedFolder: Sendable, Identifiable {
    public enum Kind: Sendable, Hashable, CaseIterable {
        case downloads
        case desktop
        case documents
        /// A folder the user chose.
        case custom
    }

    /// How the folder is found again at the next launch.
    public enum Locator: Sendable, Hashable {
        /// One of the user's standard folders: the system is asked where it is, each launch.
        case standard
        /// A bookmark, which follows the folder when it is renamed or moved (decision record 0026).
        case bookmark(Data)
    }

    public let id: UUID

    public let kind: Kind

    /// The folder's name as the log knows it: the name the user gave a custom folder, or a standard
    /// folder's name on disk. The app puts a standard folder's kind into words itself.
    public let displayName: String

    public let locator: Locator

    /// Where the folder was found this launch, as a standardized file URL. Links in it are not
    /// resolved: the activity log stores paths with this spelling, and undo compares them.
    public let url: URL

    /// What the folder allows: its actions, Tidy Now, ticks and thresholds. Its kind's defaults
    /// until the user changes them (`FolderRules.defaults(for:)`).
    public let rules: FolderRules

    /// The archive: a folder with this name at the top level of the folder. Neither it nor anything
    /// in it is ever a candidate. One name for every kind for now (decision record 0026).
    public var archiveFolderName: String { CandidateEligibility.archiveFolderName }

    /// Describes a folder that is already known. The app gets its folders from `FolderRegistry`;
    /// tests describe a temporary folder.
    public init(
        id: UUID = UUID(), kind: Kind, displayName: String? = nil, locator: Locator = .standard, url: URL, rules: FolderRules? = nil
    ) {
        self.rules = rules ?? .defaults(for: kind)
        self.id = id
        self.kind = kind
        self.url = url.standardizedFileURL
        self.displayName = displayName ?? self.url.lastPathComponent
        self.locator = locator
    }
}

extension ManagedFolder: Hashable {
    public static func == (lhs: ManagedFolder, rhs: ManagedFolder) -> Bool {
        lhs.id == rhs.id
    }

    public func hash(into hasher: inout Hasher) {
        hasher.combine(id)
    }
}
