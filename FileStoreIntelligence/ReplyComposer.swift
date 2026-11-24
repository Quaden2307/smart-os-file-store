import Foundation

/// The parsed chat's replies, written by code from what the turn found (docs/decisions/0036). A
/// reply names no file: the list or the card beside it shows them. Every sentence is in the app's
/// String Catalog; counts agree with their number by Foundation's grammar agreement, which works
/// outside the app too, so the tests and the eval reports read what the user reads.
public enum ReplyComposer {
    /// "3 files", "1 file".
    private static func text(_ resource: AttributedString) -> String {
        String(resource.characters)
    }

    public static func search(_ result: FileSearchResult, count: Bool) -> String {
        let n = result.matchCount
        let size = ToolOutput.size(result.totalBytes)
        var reply = if n == 0 {
            String(localized: "No files match that.")
        } else if count {
            text(AttributedString(localized: "That comes to ^[\(n) file](inflect: true), \(size) in all."))
        } else if result.files.count < n {
            text(AttributedString(localized: "Found ^[\(n) file](inflect: true), \(size) in all. The list shows the first \(result.files.count)."))
        } else {
            text(AttributedString(localized: "Found ^[\(n) file](inflect: true), \(size) in all."))
        }
        if result.unknownOpenCount > 0 {
            reply += " " + text(AttributedString(localized: "Not counted: ^[\(result.unknownOpenCount) item](inflect: true) macOS keeps no open date for."))
        }
        return reply
    }

    /// - Parameters:
    ///   - proposals: The cards made, and any request that found nothing or was turned off.
    ///   - unplanned: How many folders' cleanups the app could not plan.
    ///   - unreadable: How many folders of the scope the app cannot read now.
    ///   - named: True when the user named the cleanups, so the ones turned off are worth a word. For
    ///     "everything", or files with no cleanup named, every cleanup a folder offers is what was asked.
    public static func cleanup(_ proposals: [CleanupProposal], unplanned: Int, unreadable: Int, named: Bool = true) -> String {
        let cards = proposals.filter { !$0.rows.isEmpty }
        let n = cards.reduce(0) { $0 + $1.count }
        var parts: [String] = []
        if cards.count > 1 {
            parts.append(text(AttributedString(localized: "Previews of ^[\(n) file](inflect: true) are ready in \(cards.count) folders. Nothing changes until you confirm.")))
        } else if !cards.isEmpty {
            parts.append(text(AttributedString(localized: "A preview of ^[\(n) file](inflect: true) is ready. Nothing changes until you confirm.")))
        } else if unplanned == 0 {
            parts.append(String(localized: "There’s nothing to clean up for that."))
        }
        if named, proposals.contains(where: { !$0.notOffered.isEmpty }) {
            parts.append(String(localized: "Some of the cleanups you named are turned off in Settings."))
        }
        if unplanned > 0 {
            parts.append(String(localized: "The cleanup couldn’t be prepared just now. Try the Clean Up menu."))
        }
        if unreadable > 0 {
            parts.append(String(localized: "Folders the app can’t read now were left out."))
        }
        return parts.joined(separator: " ")
    }

    /// Nil `scan`: Find Duplicates could not run.
    public static func duplicates(_ scan: DuplicateScan?) -> String {
        guard let scan else {
            return String(localized: "The duplicate check couldn’t run just now. Try Find Duplicates in the Clean Up menu.")
        }
        var reply = scan.copyCount == 0
            ? String(localized: "No duplicates found.")
            : text(AttributedString(localized: "Found ^[\(scan.copyCount) copy](inflect: true) of other files, taking \(ToolOutput.size(scan.copyBytes))."))
        if scan.recentCount > 0 {
            reply += " " + String(localized: "Files added in the last hour are left for later.")
        }
        return reply
    }

    /// The overview in code, when the model's sentence is not used.
    public static func overview(_ summary: FolderSummary) -> String {
        text(AttributedString(localized: "That’s ^[\(summary.all.count) item](inflect: true), \(ToolOutput.size(summary.all.bytes)) in all."))
    }

    /// The facts the model words an overview from, in one line written by code. Never a file name;
    /// a folder's name is the user's, so it sits between the data marks.
    static func overviewFacts(_ summary: FolderSummary, scope: FolderScope?) -> String {
        let place = switch scope {
        case .folder(let name): ToolOutput.quoted(name)
        case .all: "All folders"
        case nil: "The folder"
        }
        var facts = ["\(place): \(summary.all.count) items, \(ToolOutput.size(summary.all.bytes))"]
        let kinds = summary.byTypeGroup.sorted { $0.value.bytes > $1.value.bytes || ($0.value.bytes == $1.value.bytes && $0.key.rawValue < $1.key.rawValue) }
        if !kinds.isEmpty {
            facts.append("by size: " + kinds.map { "\($0.key.rawValue) \(ToolOutput.size($0.value.bytes)) (\($0.value.count))" }.joined(separator: ", "))
        }
        if let moved = summary.bytesMovedToTrash, moved > 0 {
            facts.append("cleanups have moved \(ToolOutput.size(moved)) to the Trash")
        }
        return facts.joined(separator: "; ") + "."
    }

    /// What the app cannot do, and what it can do instead.
    public static func cannotDo(_ reason: ChatRequestPlanner.CannotDoReason) -> String {
        switch reason {
        case .asked(let asked):
            switch asked {
            case .move: String(localized: "The app can’t move files between folders yet. It can archive old files into Old downloads, or find files for you to move.")
            case .deleteForever: String(localized: "The app never deletes files for good. It can move files to the Trash after you confirm a preview.")
            case .emptyTrash: String(localized: "The app can’t empty the Trash. It moves files there only after you confirm, so you can put them back.")
            case .open: String(localized: "The app can’t open files from the chat. It can find them, and you can open them from the list.")
            case .send: String(localized: "The app can’t send or share files. It can find them for you.")
            case .compress: String(localized: "The app can’t compress files. It can find large files for you to review.")
            case .convert: String(localized: "The app can’t convert files. It can find them for you.")
            case .schedule: String(localized: "The app can’t schedule cleanups yet. Ask here, or use Tidy Now, whenever you like.")
            case .watch: String(localized: "The app can’t watch a folder yet. Ask here, or use Tidy Now, whenever you like.")
            case .organize: String(localized: "The app can’t sort files into folders yet. It can fix messy names and archive old files.")
            case .restore: String(localized: "To put files back, use Undo on the cleanup’s card, or Edit > Undo.")
            case .other: String(localized: "That’s not something the app can do. It can look up files and prepare cleanups for you to confirm.")
            }
        case .folder(let name, .permissionNeeded):
            String(localized: "macOS hasn’t allowed the app to read \(name). Allow it in System Settings, then ask again.")
        case .folder(let name, _):
            String(localized: "\(name) can’t be found now. Its disk may be disconnected.")
        }
    }

    public static var chat: String {
        String(localized: "I can look up files in your folders and prepare cleanups for you to confirm.")
    }

    /// One short question for what the request lacks.
    public static func needsMore(_ missing: ChatRequestPlanner.Missing) -> String {
        switch missing {
        case .cleanup: String(localized: "Which cleanup did you mean: duplicates, failed downloads or old files?")
        case .lastResult: String(localized: "Which files do you mean?")
        case .when: String(localized: "When did you mean, for example in March or in the last 2 weeks?")
        case .files: String(localized: "No file can match all of that. Which files did you mean?")
        case .folder: String(localized: "Which folder did you mean?")
        }
    }
}
