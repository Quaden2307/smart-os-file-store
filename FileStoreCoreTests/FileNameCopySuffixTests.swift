import FileStoreCore
import Testing

@Suite("FileNameCopySuffix")
struct FileNameCopySuffixTests {
    @Test func recognisesCopySuffixes() {
        let copies = [
            "report (1).pdf", "report (12).pdf", "report copy.pdf", "report Copy 2.PDF",
            "archive (1).tar.gz", "report (1).numbers", "db copy.sqlite", "LICENSE copy",
            "Hard copy.pdf", "Photo (2).HEIC",
        ]
        for name in copies {
            #expect(FileNameCopySuffix.hasCopySuffix(name), "\(name) should count as a copy")
        }
    }

    @Test func leavesCleanNamesAlone() {
        let clean = [
            "report.pdf", "report(1).pdf", "copy.pdf", "photocopy.pdf", "report (1) final.pdf",
            "Episode 1.mp4", "IMG_4021.jpg", "report ().pdf", "beach.jpg", "résumé – final ✓.pdf",
            "copy 2.pdf", "LICENSE", "",
        ]
        for name in clean {
            #expect(!FileNameCopySuffix.hasCopySuffix(name), "\(name) should be a clean name")
        }
    }

    private func removed(_ stem: String) -> [String]? {
        FileNameCopySuffix.removingCopySuffix(fromStem: stem).map { [$0.stem, $0.removed] }
    }

    @Test func removingASuffixKeepsHowItWasWritten() {
        #expect(removed("report (12)") == ["report", " (12)"])
        #expect(removed("Report COPY") == ["Report", " COPY"])
        #expect(removed("Report Copy 2") == ["Report", " Copy 2"])
        #expect(removed("Chapter (2) notes") == nil)
        #expect(removed("copy") == nil)
        #expect(removed("") == nil)
    }
}
