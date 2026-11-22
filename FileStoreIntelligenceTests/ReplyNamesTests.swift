import FileStoreIntelligence
import Foundation
import Testing

@Suite("Names in a reply")
struct ReplyNamesTests {
    @Test func aWordReadsAsAFileNameOnlyWithAnExtensionTheSystemKnows() {
        #expect(ReplyNames.fileNames(in: "See report.pdf, holiday.jpg and Xcode.dmg.") == ["report.pdf", "holiday.jpg", "Xcode.dmg"])
        #expect(ReplyNames.fileNames(in: "That is 1.5 MB, e.g. a photo, version v2.1.").isEmpty)
        #expect(ReplyNames.fileNames(in: "Saved as “budget.xlsx”.") == ["budget.xlsx"])
        // A path ends at its last slash; Markdown's marks are not part of the name.
        #expect(ReplyNames.fileNames(in: "It is ~/Downloads/report.pdf, or _notes.txt_.") == ["report.pdf", "notes.txt"])
    }

    @Test func aNameTheUserWroteMayBeQuotedBack() {
        let names = ReplyNames(FolderSnapshot(files: Fixtures.files), question: "Do I have invoice-2026.pdf?")
        #expect(names.unknown(in: "No, invoice-2026.pdf is not here.").isEmpty)
        #expect(names.unknown(in: "No, but invoice-2025.pdf is.") == ["invoice-2025.pdf"])
    }

    @Test func aNameIsKnownWhenItIsPartOfAFileASiteOrAFolder() {
        let names = ReplyNames(FolderSnapshot(files: Fixtures.files, folders: [FolderSnapshot.Folder(name: "Downloads")]))
        // A name with spaces reads as several words; its last one is part of the name.
        #expect(names.unknown(in: "Annual Report 2025.pdf is the oldest.").isEmpty)
        #expect(names.unknown(in: "It came from developer.apple.com.").isEmpty)
        #expect(names.unknown(in: "REPORT.PDF is here.").isEmpty)
        #expect(names.unknown(in: "Look at report-final.pdf and Report 2026.pdf.") == ["report-final.pdf", "2026.pdf"])
    }
}
