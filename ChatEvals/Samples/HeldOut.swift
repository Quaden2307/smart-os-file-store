/// The held-out set: the asks of `Requests` and `CannotDo` again in other words (short, casual,
/// with typos, two asks in one message, a follow-up), written by hand. Scored as its own column.
///
/// The rule (docs/decisions/0034): no prompt, example or schema change may be tuned on this set or
/// chosen by reading its misses. The report does not list them; change the wording on the other sets
/// and read this column only to see whether the change holds.
enum HeldOut {
    /// The tuned sample `source`'s ask, call and files, in other words. A source that does not
    /// exist gives a label no answer meets, so the harness's ideal check fails on it.
    private static func like(_ id: String, _ source: String, _ request: String) -> ChatSample {
        var sample = Requests.all.first { $0.id == source } ?? .cannotDo(id, request).expecting(.card(["no sample \(source)"]))
        sample.id = id
        sample.request = request
        return sample
    }

    static let all: [ChatSample] = (cleanups + twoAsks + questions + followUps + cannotDo).map { sample in
        var sample = sample
        sample.kind = .heldOut
        return sample
    }

    static let cleanups: [ChatSample] = [
        like("held-1", "dup-1", "get rid of dupes"),
        like("held-2", "failed-1", "can you clear the downloads that failed"),
        like("held-3", "failed-3", "trash the half-downloaded junk"),
        like("held-4", "zips-1", "zips i already opened can go"),
        like("held-5", "installers-1", "remove used instalers"),
        like("held-6", "installers-3", "i installed those apps already, bin the dmgs"),
        like("held-7", "messy-1", "fix the ugly filenames"),
        like("held-8", "messy-2", "clean up names like 'budget copy' and '(1)'"),
        like("held-9", "near-1", "files that are nearly the same, help me clean them"),
        like("held-10", "archive-1", "archive stuff i havent touched in ages"),
        like("held-11", "large-1", "review big files for cleanup"),
        like("held-12", "empty-1", "get rid of empty foldres"),
        like("held-13", "all-1", "tidy my downlods"),
        like("held-14", "all-2", "clean evrything up"),
        like("held-15", "filter-2", "archive old vids"),
        like("held-16", "filter-5", "remove duplicate photos only"),
        like("held-17", "filter-3", "archive anything older than half a year"),
        like("held-18", "filter-6", "archive old stuff over 100mb"),
    ]

    /// Two asks in one message, each pair one card.
    static let twoAsks: [ChatSample] = [
        .cleanup("held-19", "remove dupes and fix the names", actions: ["findDuplicates", "fixMessyNames"], files: Requests.duplicates + Requests.messy),
        like("held-20", "two-4", "failed downloads + empty folders, clean both"),
        .cleanup("held-21", "archive old stuff and get rid of empty folders", actions: ["archiveOldDownloads", "removeEmptyFolders"],
                 files: Requests.archive + Requests.emptyFolders),
        like("held-22", "two-3", "trash unpacked zips and used installers"),
        like("held-23", "two-1", "duplicates and failed downloads, clear em out"),
        like("held-24", "two-2", "fix names, then archive anything old"),
    ]

    static let questions: [ChatSample] = [
        like("held-25", "size-1", "files bigger than 100mb?"),
        like("held-26", "size-2", "anything over half a gig"),
        like("held-27", "type-1", "what pictures do i have"),
        like("held-28", "type-2", "show vids"),
        like("held-29", "type-4", "how many installers are here").expecting(.count),
        like("held-30", "type-2", "how many videos do i have?").expecting(.count),
        like("held-31", "name-2", "anything with invoice in the name?"),
        like("held-32", "site-1", "stuff from github?"),
        like("held-33", "site-3", "what did i grab from example.com"),
        like("held-34", "date-5", "what came in yesterday"),
        like("held-35", "date-2", "downloads from over a year ago"),
        like("held-36", "mark-1", "what's flagged as old?"),
        like("held-37", "mark-3", "what have i marked keep"),
        like("held-38", "sort-1", "biggest files?"),
        like("held-39", "copies-2", "any dupes?"),
        like("held-40", "copies-4", "do i have the same file twice anywhere"),
        like("held-41", "copies-1", "how many copies of the same file are there"),
        like("held-42", "overview-2", "how big is my downloads folder"),
        like("held-43", "overview-3", "quick summary of whats in here"),
    ]

    /// A second message about the first one's result, in the same conversation.
    static let followUps: [ChatSample] = [
        .search("held-44", "only the videos", filter: #"{"mark":"lastResult","typeGroup":"video"}"#, checks: [.type("video")],
                files: ["conference-talk.mov", "family-video.mp4"])
            .after(like("", "size-1", "whats over 100 mb")),
        .search("held-45", "sort those by size", filter: #"{"mark":"lastResult"}"#, sort: "largest", files: Requests.images)
            .after(like("", "type-1", "any photos?")),
        .search("held-46", "just the ones from example.com", filter: #"{"mark":"lastResult","sourceSite":"example.com"}"#,
                checks: [.site("example.com")], files: ["holiday-beach.jpg"])
            .after(like("", "type-1", "pics?")),
        .cleanup("held-47", "archive those", actions: ["archiveOldDownloads"], filter: #"{"mark":"lastResult"}"#,
                 files: ["old-manual.pdf", "old-receipt.pdf", "wallpaper.heic"])
            .after(like("", "date-2", "what's older than a year")),
        ChatSample.cannotDo("held-48", "undo that").after(like("", "dup-1", "clear out the duplicates")),
    ]

    static let cannotDo: [ChatSample] = [
        .cannotDo("held-49", "put my invoices in the Documents folder"),
        .cannotDo("held-50", "delete report.pdf forever, skip the trash"),
        .cannotDo("held-51", "empty trash"),
        .cannotDo("held-52", "open lecture-notes.pdf for me"),
        .cannotDo("held-53", "send the statement to my accountant by email"),
        .cannotDo("held-54", "make my videos smaller"),
        .cannotDo("held-55", "clean this folder automatically every sunday"),
        .cannotDo("held-56", "organise downloads into folders by kind"),
        .cannotDo("held-57", "create a folder named Taxes"),
        .cannotDo("held-58", "password protect my tax files"),
        .cannotDo("held-59", "copy everything to my external drive"),
        .cannotDo("held-60", "bring back the files i deleted"),
    ]
}
