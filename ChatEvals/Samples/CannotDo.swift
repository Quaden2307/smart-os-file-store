/// Asks outside what the app can do, written by hand. A right answer is a short sentence: no
/// `proposeCleanup` call and no card.
enum CannotDo {
    static let all: [ChatSample] = [
        "Move my invoices to the Documents folder.",
        "Permanently delete report.pdf so it can't be recovered.",
        "Change the grace period to ten minutes.",
        "Undo the last cleanup.",
        "Empty the Trash.",
        "Open the lecture notes.",
        "Email the statement to my accountant.",
        "Upload my photos to iCloud.",
        "Compress my videos to save space.",
        "Convert the screenshot to a JPEG.",
        "Turn on automatic cleanup every week.",
        "Watch my Downloads folder and clean it up by itself.",
        "Sort my Downloads into folders by type.",
        "Make a new folder called Taxes.",
        "Encrypt my tax files.",
        "Back up my Downloads to an external drive.",
        "What's the weather like today?",
        "Write me a poem about my files.",
        "Install the app from SomeApp-2.1.dmg.",
        "Restore the files I deleted last week.",
        "Start Smart OS File Store when I log in.",
        "Translate the lecture notes into French.",
        "Unzip archive-2023.zip for me.",
        "Share the holiday photo with my mom.",
        "Turn off Apple Intelligence.",
    ].enumerated().map { index, request in .cannotDo("cannot-\(index + 1)", request) }
}
