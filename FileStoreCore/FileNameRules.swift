import Foundation
import UniformTypeIdentifiers

/// The rules a name must pass before the executor gives it to anything, and the folders a move's
/// destination names. Pure: nothing here reads the disk, so whether a name is already taken is
/// left to the exclusive rename, which asks the volume itself.
enum FileNameRules {
    /// The longest name, in UTF-16 code units, when the volume does not say. APFS, HFS+ and exFAT
    /// all allow 255.
    static let defaultMaximumLength = 255

    /// True when `name` can be one item's name in a folder: not empty, not `.` or `..`, no `/`
    /// (which would make it a path) and no NUL (which would cut it short on the way to the
    /// system), and at most `maximumLength` UTF-16 code units. That is how APFS counts: 255 "a"
    /// or 255 "é" fit, 128 emoji (256 code units) do not.
    ///
    /// `/` and NUL are looked for among the Unicode scalars, as the system sees the name: a `/`
    /// joined with a combining mark into one Swift `Character` (`"a/\u{301}b"`) is still a `/`.
    static func isSingleName(_ name: String, maximumLength: Int) -> Bool {
        !name.isEmpty
            && name != "."
            && name != ".."
            && !name.unicodeScalars.contains("/")
            && !name.unicodeScalars.contains("\0")
            && name.utf16.count <= maximumLength
    }

    /// True when a rename or a move may give an item `name`. On top of `isSingleName`, the name
    /// must not hide the item, look like the archive or look like a download still in progress,
    /// since every action would then leave the item alone for good.
    static func isAllowedFileName(_ name: String, maximumLength: Int) -> Bool {
        isSingleName(name, maximumLength: maximumLength)
            // One name for every kind of folder today. When kinds get names of their own, a new
            // name must be none of them.
            && !CandidateEligibility.isExcludedName(name, archiveFolderName: CandidateEligibility.archiveFolderName)
            && !FileRecord.isInProgressDownload(name: name)
    }

    /// The first free name of `<stem> YYYY-MM-DD<ext>`, then ` v2`, ` v3`…, for `name` and `date`
    /// written in `timeZone`, or nil when the name would be too long or not allowed. One more try
    /// than names taken always finds a free one.
    static func datedName(_ name: String, date: Date, timeZone: TimeZone, takenCount: Int, isFree: (String) -> Bool) -> String? {
        let (stem, pathExtension) = MessyNameCleaner.parts(of: name)
        let dated = "\(stem) \(date.formatted(Date.ISO8601FormatStyle(timeZone: timeZone).year().month().day().dateSeparator(.dash)))"
        for number in 1...(takenCount + 1) {
            let name = (number == 1 ? dated : "\(dated) v\(number)") + pathExtension
            guard isAllowedFileName(name, maximumLength: defaultMaximumLength) else {
                return nil
            }
            if isFree(name) {
                return name
            }
        }
        return nil
    }

    /// True when a move may put an item in a folder named `name`, or make one: a single name that
    /// does not hide what goes inside. The archive's name is allowed; it is where archiving moves to.
    static func isAllowedFolderName(_ name: String, maximumLength: Int) -> Bool {
        isSingleName(name, maximumLength: maximumLength) && !name.hasPrefix(".")
    }

    /// True when a folder called `name` would be a package, such as an `.app`, which macOS shows as
    /// one item: nothing is ever moved into one.
    static func isPackageName(_ name: String) -> Bool {
        let pathExtension = (name as NSString).pathExtension
        guard !pathExtension.isEmpty else {
            return false
        }
        return UTType(filenameExtension: pathExtension, conformingTo: .directory)?.conforms(to: .package) ?? false
    }

    /// The names of the folders leading from `folderURL` down to `destination`, outermost first, or
    /// nil when `destination` is not strictly inside it.
    ///
    /// The URLs' own path components are compared, with no `standardizedFileURL` (which consults
    /// the file system, so the same folder can come out spelled two ways), and a `.` or `..` among
    /// the extra components counts as outside. A destination spelled differently from the folder
    /// is refused, never guessed about.
    static func folderNames(from folderURL: URL, to destination: URL) -> [String]? {
        guard folderURL.isFileURL, destination.isFileURL else {
            return nil
        }
        let folderComponents = folderURL.pathComponents
        let destinationComponents = destination.pathComponents
        guard destinationComponents.count > folderComponents.count,
              destinationComponents.starts(with: folderComponents) else {
            return nil
        }
        let names = Array(destinationComponents.dropFirst(folderComponents.count))
        guard !names.contains(where: { $0 == "." || $0 == ".." }) else {
            return nil
        }
        return names
    }
}
