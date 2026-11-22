/// Cleanups and questions the chat can do, over `EvalFolder`, written by hand. Each file set is
/// what a right answer ends on: the planners' and the filter's own result for the right call,
/// which the scripted check proves for every sample (`ChatEvalHarnessTests`).
enum Requests {
    // What each action plans on the whole folder.
    static let duplicates = ["beach.jpg", "receipt (1).pdf", "report (2).pdf", "report (3).pdf", "report copy.pdf", "report.pdf"]
    static let failed = ["movie.mp4.crdownload", "partial.part", "presentation.key.download"]
    static let zips = ["contract.zip", "project.zip"]
    static let installers = ["Gizmo-1.5.pkg", "Locked-1.0.dmg", "SomeApp-2.1.dmg", "Widget-3.2-arm64.zip"]
    static let messy = [
        "agenda (1).docx", "agenda copy.docx", "brochure.pdf_dl=1", "budget copy.xlsx", "file%20name%20with%20junk.txt",
        "invoice (1).pdf", "notes (1).txt", "slides.pdf.pdf",
    ]
    static let near = ["agenda (1).docx", "agenda copy.docx", "invoice (1).pdf", "invoice.pdf", "notes (1).txt", "notes.txt"]
    static let archive = [
        "Annual Report 2025.pdf", "backup-2025.tar.gz", "budget-2026.xlsx", "conference-talk.mov", "old-manual.pdf",
        "old-receipt.pdf", "podcast-episode-12.m4a", "wallpaper.heic",
    ]
    static let large = ["conference-talk.mov"]
    static let emptyFolders = ["Empty Folder", "Folder With DS_Store"]
    /// Tidy Now's merge of every action: review lists are not part of it.
    static let everything = duplicates + failed + zips + installers + messy + archive + emptyFolders

    static let images = ["IMG_4021.jpg", "beach.jpg", "holiday-beach.jpg", "screenshot-2026-11-15.png", "wallpaper.heic"]
    static let videos = ["big-video.mov", "conference-talk.mov", "family-video.mp4", "movie.mp4"]
    static let reports = ["Annual Report 2025.pdf", "report (1).pdf", "report (2).pdf", "report (3).pdf", "report copy.pdf", "report-link.pdf", "report.pdf"]
    static let installerFiles = ["Gizmo-1.5.pkg", "Locked-1.0.dmg", "SomeApp-2.1.dmg", "Tool.pkg", "disk-backup.img"]
    static let olderThanAYear = ["old-manual.pdf", "old-receipt.pdf", "tax-form-2024.pdf", "wallpaper.heic"]

    static let all: [ChatSample] = cleanups + filteredCleanups + questions + followUps + copies + overviews

    // MARK: - One action, or several, on every file

    static let cleanups: [ChatSample] = [
        .cleanup("dup-1", "Get rid of duplicate files.", actions: ["findDuplicates"], files: duplicates),
        .cleanup("dup-2", "Remove the copies of files I downloaded twice.", actions: ["findDuplicates"], files: duplicates),
        .cleanup("dup-3", "trash the duplicates please", actions: ["findDuplicates"], files: duplicates),
        .cleanup("failed-1", "Clear out the failed downloads.", actions: ["clearFailedDownloads"], files: failed),
        .cleanup("failed-2", "Delete the downloads that never finished.", actions: ["clearFailedDownloads"], files: failed),
        .cleanup("failed-3", "Remove broken partial downloads", actions: ["clearFailedDownloads"], files: failed),
        .cleanup("zips-1", "Remove the zips I've already unpacked.", actions: ["removeUnpackedZips"], files: zips),
        .cleanup("zips-2", "Clean up zip files that were already extracted.", actions: ["removeUnpackedZips"], files: zips),
        .cleanup("installers-1", "Remove the installers I've already used.", actions: ["removeUsedInstallers"], files: installers),
        .cleanup("installers-2", "Get rid of installers for apps I've already installed.", actions: ["removeUsedInstallers"], files: installers),
        .cleanup("installers-3", "Trash the dmg files for apps I already have", actions: ["removeUsedInstallers"], files: installers),
        .cleanup("messy-1", "Fix the messy file names.", actions: ["fixMessyNames"], files: messy),
        .cleanup("messy-2", "Rename the files with junk like (1) or copy in their names.", actions: ["fixMessyNames"], files: messy),
        .cleanup("messy-3", "Clean up the file names", actions: ["fixMessyNames"], files: messy),
        .cleanup("near-1", "Find files that are almost the same so I can clean them up.", actions: ["reviewNearDuplicates"], files: near),
        .cleanup("near-2", "Prepare a cleanup of near-duplicate files.", actions: ["reviewNearDuplicates"], files: near),
        .cleanup("archive-1", "Archive my old downloads.", actions: ["archiveOldDownloads"], files: archive),
        .cleanup("archive-2", "Put the files I haven't used in a while into Old downloads.", actions: ["archiveOldDownloads"], files: archive),
        .cleanup("archive-3", "Tuck away my stale downloads.", actions: ["archiveOldDownloads"], files: archive),
        .cleanup("large-1", "Review my large downloads for cleanup.", actions: ["reviewLargeDownloads"], files: large),
        .cleanup("large-2", "Help me get rid of big downloads.", actions: ["reviewLargeDownloads"], files: large),
        .cleanup("empty-1", "Remove empty folders.", actions: ["removeEmptyFolders"], files: emptyFolders),
        .cleanup("empty-2", "Delete the folders with nothing in them.", actions: ["removeEmptyFolders"], files: emptyFolders),
        .cleanup("all-1", "Tidy up my whole Downloads folder.", actions: ["all"], files: everything),
        .cleanup("all-2", "Clean up everything you can.", actions: ["all"], files: everything),
        .cleanup("all-3", "Do a full cleanup.", actions: ["all"], files: everything),
        .cleanup("two-1", "Remove duplicates and failed downloads.", actions: ["findDuplicates", "clearFailedDownloads"], files: duplicates + failed),
        .cleanup("two-2", "Fix the names and archive the old stuff.", actions: ["fixMessyNames", "archiveOldDownloads"], files: messy + archive),
        .cleanup("two-3", "Get rid of used installers and unpacked zips.", actions: ["removeUsedInstallers", "removeUnpackedZips"], files: installers + zips),
        .cleanup("two-4", "Clear the failed downloads and the empty folders", actions: ["clearFailedDownloads", "removeEmptyFolders"], files: failed + emptyFolders),
    ]

    // MARK: - Narrowed by a filter or a setting

    static let filteredCleanups: [ChatSample] = [
        .cleanup(
            "filter-1", "Archive the files I downloaded before September and never opened.", actions: ["archiveOldDownloads"],
            filter: #"{"addedBefore":"2026-09-01","neverOpened":true}"#, checks: [.addedBeforeDaysAgo(76...80)],
            files: ["backup-2025.tar.gz", "old-manual.pdf", "wallpaper.heic"]
        ),
        .cleanup(
            "filter-2", "Archive old videos.", actions: ["archiveOldDownloads"], filter: #"{"typeGroup":"video"}"#,
            checks: [.type("video")], files: ["conference-talk.mov"]
        ),
        .cleanup(
            "filter-3", "Archive files older than 6 months.", actions: ["archiveOldDownloads"], filter: #"{"addedBefore":"180 days ago"}"#,
            checks: [.addedBeforeDaysAgo(170...190)], files: ["Annual Report 2025.pdf", "old-manual.pdf", "old-receipt.pdf", "wallpaper.heic"]
        ),
        .cleanup(
            "filter-4", "Remove only the duplicate PDFs.", actions: ["findDuplicates"], filter: #"{"typeGroup":"documents"}"#,
            files: ["receipt (1).pdf", "report (2).pdf", "report (3).pdf", "report copy.pdf", "report.pdf"]
        ),
        .cleanup(
            "filter-5", "Remove the duplicate photos.", actions: ["findDuplicates"], filter: #"{"typeGroup":"images"}"#,
            checks: [.type("images")], files: ["beach.jpg"]
        ),
        .cleanup(
            "filter-6", "Archive the old stuff that's bigger than 100 MB.", actions: ["archiveOldDownloads"], filter: #"{"largerThanMB":100}"#,
            checks: [.largerThanMB(90...110)], files: ["backup-2025.tar.gz", "conference-talk.mov"]
        ),
        .cleanup(
            "filter-7", "Archive the audio files I don't listen to.", actions: ["archiveOldDownloads"], filter: #"{"typeGroup":"audio"}"#,
            checks: [.type("audio")], files: ["podcast-episode-12.m4a"]
        ),
        .cleanup(
            "filter-8", "Clear out failed downloads from the last week.", actions: ["clearFailedDownloads"], filter: #"{"addedSince":"7 days ago"}"#,
            checks: [.addedFromDaysAgo(6...8)], files: failed
        ),
        .cleanup(
            "filter-9", "Archive everything older than two years.", actions: ["archiveOldDownloads"], filter: #"{"addedBefore":"730 days ago"}"#,
            checks: [.addedBeforeDaysAgo(720...740)], files: ["old-manual.pdf"]
        ),
        .cleanup(
            "filter-10", "Archive files I downloaded more than 3 months ago.", actions: ["archiveOldDownloads"], filter: #"{"addedBefore":"90 days ago"}"#,
            checks: [.addedBeforeDaysAgo(85...94)],
            files: ["Annual Report 2025.pdf", "backup-2025.tar.gz", "old-manual.pdf", "old-receipt.pdf", "wallpaper.heic"]
        ),
        .cleanup(
            "filter-11", "Remove the failed Chrome downloads.", actions: ["clearFailedDownloads"], filter: #"{"nameContains":"crdownload"}"#,
            checks: [.nameContains("crdownload")], files: ["movie.mp4.crdownload"]
        ),
        .cleanup(
            "setting-1", "Archive the files I haven't opened in 50 days.", actions: ["archiveOldDownloads"], settings: #","archiveAfterDays":50"#,
            checks: [.archiveAfterDays(50...50)],
            files: ["Annual Report 2025.pdf", "backup-2025.tar.gz", "old-manual.pdf", "old-receipt.pdf", "podcast-episode-12.m4a", "wallpaper.heic"]
        ),
        .cleanup(
            "setting-2", "Let me review downloads that take more than 50 MB.", actions: ["reviewLargeDownloads"], settings: #","largeFileMB":50"#,
            files: large
        ),
    ]

    // MARK: - Questions

    static let questions: [ChatSample] = [
        .search("size-1", "Which files are larger than 100 MB?", filter: #"{"largerThanMB":100}"#, checks: [.largerThanMB(95...105)],
                files: ["backup-2025.tar.gz", "conference-talk.mov", "disk-backup.img", "family-video.mp4"]),
        .search("size-2", "Show me everything over 500 MB", filter: #"{"largerThanMB":500}"#, checks: [.largerThanMB(490...510)],
                files: ["disk-backup.img", "family-video.mp4"]),
        .search("size-3", "Anything bigger than 1 GB?", filter: #"{"largerThanMB":1000}"#, checks: [.largerThanMB(950...1100)], files: []),
        .search("size-4", "Which files are between 10 and 50 MB?", filter: #"{"largerThanMB":10,"smallerThanMB":50}"#,
                checks: [.largerThanMB(9...11), .smallerThanMB(49...51)], files: ["Annual Report 2025.pdf", "dataset.csv", "podcast-episode-12.m4a"]),
        .search("type-1", "Which images are here?", filter: #"{"typeGroup":"images"}"#, checks: [.type("images")], files: images),
        .search("type-2", "List my videos", filter: #"{"typeGroup":"video"}"#, checks: [.type("video")], files: videos),
        .search("type-3", "Do I have any music or podcasts?", filter: #"{"typeGroup":"audio"}"#, checks: [.type("audio")],
                files: ["podcast-episode-12.m4a", "song.mp3"]),
        .search("type-4", "Which installers are here?", filter: #"{"typeGroup":"installers"}"#, checks: [.type("installers")], files: installerFiles),
        .search("type-5", "Show me my videos over 100 MB", filter: #"{"typeGroup":"video","largerThanMB":100}"#,
                checks: [.type("video"), .largerThanMB(95...105)], files: ["conference-talk.mov", "family-video.mp4"]),
        .search("type-6", "Which documents did I add in the last month that are over 1 MB?",
                filter: #"{"typeGroup":"documents","addedSince":"30 days ago","largerThanMB":1}"#,
                checks: [.type("documents"), .addedFromDaysAgo(28...31), .largerThanMB(0.9...1.1)],
                files: ["dataset.csv", "ebook.epub", "lecture-notes.pdf"]),
        .search("name-1", "Find files with report in the name.", filter: #"{"nameContains":"report"}"#, checks: [.nameContains("report")], files: reports),
        .search("name-2", "Which files have invoice in their name?", filter: #"{"nameContains":"invoice"}"#, checks: [.nameContains("invoice")],
                files: ["invoice (1).pdf", "invoice.pdf"]),
        .search("name-3", "Find anything with budget in the name", filter: #"{"nameContains":"budget"}"#, checks: [.nameContains("budget")],
                files: ["budget copy.xlsx", "budget-2026.xlsx"]),
        .search("name-4", "Where are my tax files?", filter: #"{"nameContains":"tax"}"#, checks: [.nameContains("tax")],
                files: ["tax-form-2024.pdf", "tax-return-2025.pdf"]),
        .search("name-5", "Show me the screenshots.", filter: #"{"nameContains":"screenshot"}"#, checks: [.nameContains("screenshot")],
                files: ["screenshot-2026-11-15.png"]),
        .search("site-1", "What did I download from GitHub?", filter: #"{"sourceSite":"github"}"#, checks: [.site("github")], files: ["dataset.csv"]),
        .search("site-2", "Which files came from photos.example.com?", filter: #"{"sourceSite":"photos.example.com"}"#,
                checks: [.site("photos.example.com")], files: ["holiday-beach.jpg"]),
        .search("site-3", "What did I get from example.com?", filter: #"{"sourceSite":"example.com"}"#, checks: [.site("example.com")],
                files: ["ebook.epub", "holiday-beach.jpg", "statement.pdf"]),
        .search("site-4", "Which downloads came from the books site?", filter: #"{"sourceSite":"books"}"#, files: ["ebook.epub"]),
        .search("date-1", "What did I download between 10 and 20 days ago?", filter: #"{"addedSince":"20 days ago","addedBefore":"10 days ago"}"#,
                checks: [.addedFromDaysAgo(19...21), .addedBeforeDaysAgo(8...10)], files: ["dataset.csv", "ebook.epub", "lecture-notes.pdf"]),
        .search("date-2", "What did I download more than a year ago?", filter: #"{"addedBefore":"365 days ago"}"#,
                checks: [.addedBeforeDaysAgo(360...370)], files: olderThanAYear),
        .search("date-3", "Which files were added before 2026?", filter: #"{"addedBefore":"2026-01-01"}"#,
                checks: [.addedBeforeDaysAgo(320...322)], files: olderThanAYear),
        .search("date-4", "Show the files I downloaded in September.", filter: #"{"addedSince":"2026-09-01","addedBefore":"2026-10-01"}"#,
                checks: [.addedFromDaysAgo(78...78), .addedBeforeDaysAgo(48...49)], files: ["podcast-episode-12.m4a"]),
        .search("date-5", "What did I download yesterday?", filter: #"{"addedSince":"yesterday","addedBefore":"today"}"#,
                checks: [.addedFromDaysAgo(1...1), .addedBeforeDaysAgo(0...0)], files: ["mystery.xyz"]),
        .search("date-6", "Which files did I open in the last week?", filter: #"{"openedSince":"7 days ago"}"#,
                files: ["family-video.mp4", "holiday-beach.jpg", "song.mp3", "tax-form-2024.pdf"]),
        .search("date-7", "Which files have I never opened that are older than 3 months?", filter: #"{"neverOpened":true,"addedBefore":"90 days ago"}"#,
                checks: [.addedBeforeDaysAgo(85...95)], files: ["backup-2025.tar.gz", "old-manual.pdf", "tax-return-2025.pdf", "wallpaper.heic"]),
        .search("mark-1", "Which files are marked old?", filter: #"{"mark":"old"}"#, checks: [.mark("old")],
                files: ["Annual Report 2025.pdf", "backup-2025.tar.gz", "old-manual.pdf", "old-receipt.pdf", "tax-form-2024.pdf", "tax-return-2025.pdf", "wallpaper.heic"]),
        .search("mark-2", "Which files are marked unused?", filter: #"{"mark":"unused"}"#, checks: [.mark("unused")],
                files: ["Annual Report 2025.pdf", "budget-2026.xlsx", "old-receipt.pdf"]),
        .search("mark-3", "Which files am I keeping?", filter: #"{"mark":"kept"}"#, checks: [.mark("kept")],
                files: ["manual (2).pdf", "report (1).pdf", "tax-return-2025.pdf"]),
        .search("mark-4", "Show the downloads that failed.", filter: #"{"mark":"failedDownload"}"#, checks: [.mark("failedDownload")], files: failed),
        .search("mark-5", "Which installers have I already installed?", filter: #"{"mark":"installed"}"#, checks: [.mark("installed")],
                files: ["SomeApp-2.1.dmg", "Widget-3.2-arm64.zip"]),
        .search("sort-1", "What are the biggest files?", filter: nil, sort: "largest", files: nil),
        .search("sort-2", "What was added first?", filter: nil, sort: "earliest", files: nil),
        .search("sort-3", "Which file did I open most recently?", filter: nil, sort: "recentlyOpened", files: nil),
        .search("sort-4", "Sort my audio files by size", filter: #"{"typeGroup":"audio"}"#, sort: "largest", checks: [.type("audio")],
                files: ["podcast-episode-12.m4a", "song.mp3"]),
        .search("sort-5", "List my images, newest first", filter: #"{"typeGroup":"images"}"#, sort: "newest", checks: [.type("images")], files: images),
        // From 0029's fixed cases (docs/decisions/0034).
        // Leaves out what cannot be told: the in-progress download.
        .search("never-1", "Which files have I never opened?", filter: #"{"neverOpened":true}"#, files: [
            "Chapter (2) notes.pdf", "Gizmo-1.5.pkg", "IMG_4021.jpg", "LICENSE", "Locked-1.0.dmg", "OtherApp-1.4.zip",
            "SomeApp-2.1.dmg", "Tool.pkg", "Widget-3.2-arm64.zip", "agenda (1).docx", "agenda copy.docx", "archive-2023.zip",
            "backup-2025.tar.gz", "beach.jpg", "big-video.mov", "brochure.pdf_dl=1", "budget copy.xlsx", "conference-talk.mov",
            "contract.docx", "contract.zip", "dataset.csv", "disk-backup.img", "empty-a.txt", "empty-b.txt",
            "file%20name%20with%20junk.txt", "invoice (1).pdf", "invoice.pdf", "just-downloaded.pdf", "locked.txt", "manual (2).pdf",
            "movie.mp4", "mystery.xyz", "notes (1).txt", "notes.txt", "old-manual.pdf", "photos.zip", "podcast-episode-12.m4a",
            "project.zip", "receipt (1).pdf", "receipt.pdf", "report (1).pdf", "report (2).pdf", "report (3).pdf", "report copy.pdf",
            "report.pdf", "résumé – final ✓.pdf", "same-size-a.bin", "same-size-b.bin", "screenshot-2026-11-15.png", "slides.pdf.pdf",
            "statement.pdf", "tax-return-2025.pdf", "todo.md", "todo.txt", "wallpaper.heic",
        ]),
    ]

    // MARK: - Follow-ups, from 0029's fixed cases (docs/decisions/0034)

    static let followUps: [ChatSample] = [
        .search("follow-1", "just the large ones", filter: #"{"mark":"lastResult","largerThanMB":100}"#, checks: [.largerThanMB(99...101)],
                files: ["backup-2025.tar.gz", "conference-talk.mov", "disk-backup.img", "family-video.mp4"])
            .after(.search("", "Which files are larger than 50 MB?", filter: #"{"largerThanMB":50}"#, files: nil)),
        .search("follow-2", "sort those by size", filter: #"{"mark":"lastResult"}"#, sort: "largest", files: images)
            .after(.search("", "Which images are here?", filter: #"{"typeGroup":"images"}"#, files: nil)),
    ]

    // MARK: - Copies, read from the files

    static let copies: [ChatSample] = [
        .duplicates("copies-1", "How many duplicate files are there?", files: duplicates),
        .duplicates("copies-2", "Do I have any duplicates?", files: duplicates),
        .duplicates("copies-3", "Are there copies of the same file?", files: duplicates),
        .duplicates("copies-4", "Did I download the same file twice?", files: duplicates),
        .duplicates("copies-5", "Which files are identical?", files: duplicates),
        .duplicates("copies-6", "Do I have anything more than once?", files: duplicates),
    ]

    // MARK: - The folder as a whole

    static let overviews: [ChatSample] = [
        .overview("overview-1", "How many files do I have?"),
        .overview("overview-2", "How much space does my Downloads folder use?"),
        .overview("overview-3", "Give me an overview of my downloads."),
        .overview("overview-4", "What kinds of files are here?"),
        .overview("overview-5", "How much has the app moved to the Trash?"),
        // From 0029's fixed cases (docs/decisions/0034).
        .overview("space-1", "What's taking the most space?"),
    ]
}
