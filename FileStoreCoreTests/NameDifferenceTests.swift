import FileStoreCore
import Testing

/// The part of a name a rename changes, which the preview marks.
@Suite("Name difference")
struct NameDifferenceTests {
    private func parts(_ old: String, _ new: String) -> [String] {
        let difference = NameDifference(from: old, to: new)
        return [difference.commonPrefix, difference.removed, difference.added, difference.commonSuffix]
    }

    @Test func theChangedMiddleIsFound() {
        #expect(parts("report (2).pdf", "report.pdf") == ["report", " (2)", "", ".pdf"])
        #expect(parts("invoice (1).pdf", "invoice 2026-11-13.pdf") == ["invoice ", "(1)", "2026-11-13", ".pdf"])
        #expect(parts("brochure.pdf_dl=1", "brochure.pdf") == ["brochure.pdf", "_dl=1", "", ""])
        #expect(parts("file%20name.txt", "file name.txt") == ["file", "%20", " ", "name.txt"])
    }

    @Test func overlapsAndEqualNamesNeverGoNegative() {
        #expect(parts("aa", "a") == ["a", "a", "", ""])
        #expect(parts("same", "same") == ["same", "", "", ""])
        #expect(parts("", "new") == ["", "", "new", ""])
    }

    @Test func charactersAreNeverSplit() {
        #expect(parts("é (1).pdf", "e\u{301}.pdf") == ["é", " (1)", "", ".pdf"])
        #expect(parts("👨‍👩‍👧 copy.jpg", "👨‍👩‍👧.jpg") == ["👨‍👩‍👧", " copy", "", ".jpg"])
    }
}
