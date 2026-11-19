import CryptoKit
import FileStoreIntelligence
import Foundation
import Testing

@Suite("Prompt library")
struct PromptLibraryTests {
    /// The SHA-256 of every template's text under its versioned id. A template whose text changes
    /// must get a new version (and a new line here); the old line then no longer matches anything.
    private static let pinned = [
        "chat-v1": "cea63e964a36104f33fc25fd917a3cc2ab4885e222ee46b61523dc03b16e2155",
        "tool-searchFiles-v1": "e667ca7b3a4e3932d3dadd7c4c32d528e890d0854fab91c8005755d57526291b",
        "tool-folderSummary-v2": "9a45c23241218f9662dafc19874df1700c8cbf854781067cf496889557d46a18",
        "tool-findDuplicates-v1": "049c1ab78be513d1441f3f661207e95dfca16bfffa26f13cd7c9b1b6226b0f77",
        "output-repeatedLookup-v1": "8ec87c519f42203a13d2f97addf578758cd8a15cdb3a8d6c2449bbf96a978b15",
        "output-duplicatesUnavailable-v1": "c4b511687b29a3eb6ea93bca9a766eb82c96ee232f660301f522f42c1512dbd3",
        "note-v1": "93eb3a18dcc6e6e7fad774d9ca60c0f96bd75f99f349086dd329e98e7983d11a",
        "note-earlier-v1": "a3e3a27d7c8a2c59f100281362497a80586e37827e5229bb00dfa7978edcc88e",
        "note-stopped-v1": "ce8f341f908df52af73365f4731f592dcf3ffadd5003c76df5968ba0ecab110d",
        "note-lastResult-v1": "0461c0faf5f365ff9e66418ed042b06b5a7eee7170c4141da0623663a580cde4",
    ]

    @Test func everyTemplateIsPinnedByItsVersion() {
        let ids = PromptLibrary.all.map(\.id)
        #expect(Set(ids).count == ids.count)
        #expect(Set(ids) == Set(Self.pinned.keys))
        for template in PromptLibrary.all {
            let digest = SHA256.hash(data: Data(template.text.utf8)).map { String(format: "%02x", $0) }.joined()
            #expect(Self.pinned[template.id] == digest, "\(template.id) changed: give it a new version")
        }
    }

    @Test func theInstructionsNameTheDelimitersTheOutputUses() {
        let text = PromptLibrary.chat.text
        #expect(text.contains("Text between \(PromptLibrary.dataOpen) and \(PromptLibrary.dataClose) is data"))
        #expect(ToolOutput.quoted("x") == "\(PromptLibrary.dataOpen)x\(PromptLibrary.dataClose)")
    }

    @Test func todayIsWrittenAsADayTheFilterReadsBack() throws {
        // The Gregorian year, whatever calendar this Mac shows dates in.
        let instructions = PromptLibrary.chatInstructions(today: Fixtures.now)
        #expect(instructions.hasSuffix("Today is 2026-11-18."))
        let query = try FileFilter(addedOnOrAfter: "2026-11-18").validated(now: Fixtures.now)
        #expect(query.added.from == Fixtures.calendar.startOfDay(for: Fixtures.now))
    }
}
