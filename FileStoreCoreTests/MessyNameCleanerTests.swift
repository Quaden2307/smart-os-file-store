import FileStoreCore
import Foundation
import Testing

/// Fix Messy Names' cleaner on names alone: each rule by itself and together, the names it must
/// leave alone, and that a cleaned name is clean.
@Suite("Messy name cleaner")
struct MessyNameCleanerTests {
    private func cleaned(_ name: String) -> String? {
        MessyNameCleaner.clean(name)?.name
    }

    private func fixes(_ name: String) -> [NameFix]? {
        MessyNameCleaner.clean(name)?.fixes
    }

    // MARK: - Rule 1: percent-encoding

    @Test func percentEncodingIsDecoded() {
        #expect(cleaned("file%20name%20with%20junk.txt") == "file name with junk.txt")
        #expect(fixes("file%20name%20with%20junk.txt") == [.decodedPercentEncoding(escapes: ["%20"])])
        #expect(cleaned("r%C3%A9sum%c3%a9.pdf") == "résumé.pdf")
        #expect(fixes("a%28b%29%20c.pdf") == [.decodedPercentEncoding(escapes: ["%28", "%29", "%20"])])
        #expect(cleaned("50%25 off (1).pdf") == "50% off.pdf")
    }

    @Test func invalidOrDangerousEncodingIsLeftAlone() {
        let untouched = [
            "100%.pdf", "100% done.pdf", "50%zz.pdf", "a%FFb.pdf", "a%C3b.pdf", // not valid text
            "a%2Fb.pdf", "a%3Ab.pdf", "a%00b.pdf", "a%0Ab.pdf", // separators and controls
            "%E2%80%AEfdp.exe", "a%E2%81%A6b.pdf", // bidirectional controls
            "a%2Epdf", // would make an extension
            "a%2520b.pdf", "50%2541 off.pdf", // would need a second decoding, which could invent a name
        ]
        for name in untouched {
            #expect(cleaned(name) == nil, "\(name) should be left alone")
        }
        // The other rules still apply when the encoding is not decoded.
        #expect(cleaned("100% (1).pdf") == "100%.pdf")
    }

    // MARK: - Rule 2: web leftovers

    @Test func aWebLeftoverAfterTheExtensionIsRemoved() {
        #expect(cleaned("brochure.pdf_dl=1") == "brochure.pdf")
        #expect(fixes("brochure.pdf_dl=1") == [.removedWebLeftover("_dl=1")])
        #expect(cleaned("file.pdf?dl=0") == "file.pdf")
        #expect(cleaned("file.pdf@download") == "file.pdf")
        #expect(cleaned("data.csv_raw=true") == "data.csv")
        #expect(cleaned("data.csv?raw=1") == "data.csv")
        #expect(cleaned("file.zip_download=1") == "file.zip")
        #expect(cleaned("file.zip?download=true") == "file.zip")
        #expect(cleaned("Paper.PDF_DL=1") == "Paper.PDF")
        #expect(fixes("Paper.PDF_DL=1") == [.removedWebLeftover("_DL=1")])
    }

    @Test func webLeftoversAreOnlyTheListedOnesAfterARealExtension() {
        let untouched = [
            "file_dl=1", "file._dl=1", "notes_dl=1.txt", "file.pdf_dl=2", "file.pdf_dl=10", "file.pdf?id=4",
            "file.pdf_downloaded", "file.pdf@downloads", "file.p-f_dl=1", "file.abcdefghijk_dl=1",
        ]
        for name in untouched {
            #expect(cleaned(name) == nil, "\(name) should be left alone")
        }
    }

    // MARK: - Rule 3: doubled extensions

    @Test func aDoubledExtensionIsRemoved() {
        #expect(cleaned("slides.pdf.pdf") == "slides.pdf")
        #expect(fixes("slides.pdf.pdf") == [.removedDoubledExtension(".pdf")])
        #expect(cleaned("report.PDF.pdf") == "report.pdf")
        #expect(cleaned("a.pdf.pdf.pdf") == "a.pdf")
        #expect(cleaned("archive.tar.gz.tar.gz") == "archive.tar.gz")
        for name in ["pdf.pdf", "report.pdf.txt", "report.docx.pdf", "a.tar.gz"] {
            #expect(cleaned(name) == nil, "\(name) should be left alone")
        }
    }

    // MARK: - Rule 4: copy suffixes

    @Test func copySuffixesAreRemoved() {
        #expect(cleaned("report (1).pdf") == "report.pdf")
        #expect(fixes("report (1).pdf") == [.removedCopySuffix(" (1)")])
        #expect(cleaned("budget copy.xlsx") == "budget.xlsx")
        #expect(cleaned("budget copy 2.xlsx") == "budget.xlsx")
        #expect(fixes("budget copy 2.xlsx") == [.removedCopySuffix(" copy 2")])
        #expect(cleaned("Report Copy.PDF") == "Report.PDF")
        #expect(cleaned("archive (1).tar.gz") == "archive.tar.gz")
        #expect(cleaned("LICENSE copy") == "LICENSE")
        #expect(cleaned("Photo copy (1).jpg") == "Photo.jpg")
        #expect(cleaned("Photo (2) (3).jpg") == "Photo.jpg")
    }

    /// A number in brackets is a copy suffix only at the very end, as Find Duplicates reads it.
    @Test func aNumberInBracketsCountsOnlyAtTheVeryEnd() {
        #expect(cleaned("Chapter (2).pdf") == "Chapter.pdf")
        #expect(FileNameCopySuffix.hasCopySuffix("Chapter (2).pdf"))
        let untouched = [
            "Chapter (2) notes.pdf", "Chapter(2).pdf", "Chapter (two).pdf", "Chapter ().pdf", "copy.pdf",
            "photocopy.pdf", "Episode 1.mp4", "copy 2.pdf", "LICENSE", "IMG_4021.jpg",
        ]
        for name in untouched {
            #expect(cleaned(name) == nil, "\(name) should be left alone")
            #expect(!FileNameCopySuffix.hasCopySuffix(name), "\(name) should be a clean name for duplicates too")
        }
    }

    // MARK: - Rule 5: spaces and ends

    @Test func spacesAndEndsAreTidiedAfterAnotherRule() {
        #expect(cleaned("report (1) .pdf") == "report.pdf")
        #expect(cleaned("my  report (1).pdf") == "my report.pdf")
        #expect(fixes("my  report (1).pdf") == [.removedCopySuffix(" (1)"), .collapsedSpaces])
        #expect(cleaned("report_ (1).pdf") == "report.pdf")
        #expect(fixes("report_ (1).pdf") == [.removedCopySuffix(" (1)"), .trimmedEnds])
        #expect(cleaned("file%20.pdf.pdf") == "file.pdf")
        // Only decoding changes the start, so only then is the start trimmed.
        #expect(cleaned("_draft (1).docx") == "_draft.docx")
        #expect(cleaned(" report (1).pdf") == " report.pdf")
        #expect(cleaned("%20report (1).pdf") == "report.pdf")
    }

    @Test func spacesAndEndsAloneNeverRenameAFile() {
        for name in ["a  b.pdf", "__init__.py", "_draft.docx", "notes_.txt", " report.pdf", "report..pdf", "report .pdf"] {
            #expect(cleaned(name) == nil, "\(name) should be left alone")
        }
    }

    // MARK: - Together

    @Test func theRulesWorkTogether() {
        #expect(cleaned("file%20name%20(1).pdf.pdf") == "file name.pdf")
        #expect(cleaned("report.pdf (1).pdf") == "report.pdf")
        #expect(cleaned("brochure (1).pdf_dl=1") == "brochure.pdf")
        #expect(fixes("brochure (1).pdf_dl=1") == [.removedWebLeftover("_dl=1"), .removedCopySuffix(" (1)")])
    }

    // MARK: - What is never changed

    @Test func theExtensionIsNeverAddedChangedOrRemoved() {
        // No extension before, so none after: "notes.txt" would read as a text file.
        #expect(cleaned("notes.txt (1)") == nil)
        #expect(cleaned("a%2Etxt") == nil)
        // Without the suffix, ".5" would read as an extension, so the name is left alone.
        #expect(cleaned("Version 1.5 (1)") == nil)
        #expect(cleaned("Version 1.5 (1).pdf") == "Version 1.5.pdf")
    }

    @Test func aNameThatWouldBecomeEmptyIsLeftAlone() {
        for name in [" (1).pdf", "(1).pdf", " copy.pdf", "%20.pdf", " .pdf", ".pdf", ".pdf.pdf", " (1)", "%20 (1).txt"] {
            #expect(cleaned(name) == nil, "\(name) should be left alone")
        }
    }

    @Test func unicodeAndEmojiNamesKeepTheirCharacters() {
        #expect(cleaned("résumé – final ✓ (2).pdf") == "résumé – final ✓.pdf")
        #expect(cleaned("🎉 party (1).png") == "🎉 party.png")
        #expect(cleaned("👨‍👩‍👧 family copy.jpg") == "👨‍👩‍👧 family.jpg")
        // The Unicode form on disk stays as it is.
        let decomposed = "re\u{301}sume\u{301} (1).pdf"
        #expect(cleaned(decomposed).map { Array($0.unicodeScalars) } == Array("re\u{301}sume\u{301}.pdf".unicodeScalars))
        #expect(cleaned("résumé – final ✓.pdf") == nil)
    }

    @Test func veryLongNamesAreCleanedWithoutTruncating() {
        let long = String(repeating: "a", count: 247) + " (1).pdf"
        #expect(long.utf16.count == 255)
        #expect(cleaned(long) == String(repeating: "a", count: 247) + ".pdf")
        let emoji = String(repeating: "🙂", count: 120) + " copy.txt"
        #expect(cleaned(emoji) == String(repeating: "🙂", count: 120) + ".txt")
    }

    @Test func cleaningACleanNameChangesNothing() {
        let corpus = [
            "file%20name%20with%20junk.txt", "r%C3%A9sum%c3%a9.pdf", "50%25 off (1).pdf", "_draft (1).docx", "brochure.pdf_dl=1",
            "file.pdf@download", "slides.pdf.pdf", "a.pdf.pdf.pdf", "report (1).pdf", "budget copy 2.xlsx",
            "Photo copy (1).jpg", "Chapter (2).pdf", "report (1) .pdf", "my  report (1).pdf", "report_ (1).pdf",
            "file%20name%20(1).pdf.pdf", "report.pdf (1).pdf", "brochure (1).pdf_dl=1", "100% (1).pdf",
            "résumé – final ✓ (2).pdf", "👨‍👩‍👧 family copy.jpg", "archive (1).tar.gz", "x (1) (1).pdf.pdf_dl=1",
            "a  (1)  .pdf", "report.pdf.pdf (1).pdf", "file%20%20name (1).txt",
        ]
        for name in corpus {
            guard let once = MessyNameCleaner.clean(name) else {
                Issue.record("\(name) should be cleaned")
                continue
            }
            #expect(MessyNameCleaner.clean(once.name) == nil, "\(name) cleaned to \(once.name), which is not clean")
            #expect(!once.fixes.isEmpty)
        }
    }
}
