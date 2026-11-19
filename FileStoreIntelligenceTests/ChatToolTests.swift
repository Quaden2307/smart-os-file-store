import FileStoreIntelligence
import Foundation
import Testing

/// Each tool is called by the scripted model through the real session, and what it leaves in
/// `TurnEffects` is compared with the same answer worked out here in plain code.
@Suite("Chat tools")
struct ChatToolTests {
    private typealias File = FolderSnapshot.File

    /// Runs one `searchFiles` call and returns what it recorded.
    private func search(_ arguments: String) async throws -> FileSearchResult {
        let model = ScriptedModel(ScriptedModel.call("searchFiles", arguments), [.text(["Done."])])
        let turn = await ChatEngine.scripted(model).ask()
        #expect(turn.outcome == .answered)
        #expect(turn.effects.results.count == 1)
        guard case .search(let result) = turn.effects.results.first else {
            throw Missing()
        }
        // The model was shown exactly the short text made from this result.
        #expect(model.toolOutputsSeen == [ToolOutput.search(result, now: Fixtures.now)])
        return result
    }

    private struct Missing: Error {}

    private func megabytes(_ file: File) -> Double? {
        file.sizeInBytes.map { Double($0) / 1_000_000 }
    }

    private func total(_ files: [File]) -> Int64 {
        files.reduce(0) { $0 + ($1.sizeInBytes ?? 0) }
    }

    @Test func noArgumentsListsTheNewestTwentyOfEverything() async throws {
        let result = try await search("{}")
        #expect(result.matchCount == Fixtures.files.count)
        #expect(result.totalBytes == total(Fixtures.files))
        #expect(result.files.count == 20)
        #expect(result.sort == .newest)
        // Newest first; the two added three days back go by name, and the undated file is last of all.
        #expect(result.files.prefix(5).map(\.name) == ["screenshot.png", "mystery.xyz", "movie.mov", "report copy.pdf", "report.pdf"])
        #expect(!result.files.map(\.name).contains("undated.pdf"))
    }

    @Test(arguments: [
        (#"{"filter":{"typeGroup":"images"},"sort":"largest"}"#, ["holiday.jpg", "old-photo.heic", "screenshot.png"]),
        (#"{"filter":{"nameContains":"REPORT"},"sort":"name"}"#, ["Annual Report 2025.pdf", "report copy.pdf", "report.pdf"]),
        (#"{"filter":{"addedOnOrAfter":"2 days ago"},"sort":"earliest"}"#, ["movie.mov", "mystery.xyz", "screenshot.png"]),
        (#"{"filter":{"addedOnOrAfter":"2026-11-10","addedOnOrBefore":"2026-11-12"},"sort":"newest"}"#, ["holiday.jpg", "song.mp3", "Tool.pkg"]),
        (#"{"filter":{"openedOnOrBefore":"30 days ago"},"sort":"recentlyOpened"}"#, ["clip.mp4", "Annual Report 2025.pdf"]),
        (#"{"filter":{"openedOnOrAfter":"5 days ago"},"sort":"leastRecentlyOpened"}"#, ["song.mp3", "movie.mov", "report.pdf"]),
        (#"{"filter":{"neverOpened":true,"largerThanMB":10},"sort":"smallest"}"#, ["setup.dmg.crdownload", "podcast.m4a", "Tool.pkg", "backup.tar.gz"]),
        (#"{"filter":{"largerThanMB":50,"smallerThanMB":700},"sort":"largest"}"#, ["movie.mov", "backup.tar.gz", "clip.mp4", "Tool.pkg"]),
        (#"{"filter":{"sourceSite":"example.com"},"sort":"name"}"#, ["holiday.jpg", "report.pdf"]),
        (#"{"filter":{"mark":"neverOpened"},"sort":"largest"}"#, ["backup.tar.gz", "podcast.m4a", "old-photo.heic", "budget.xlsx"]),
        (#"{"filter":{"typeGroup":"documents","neverOpened":true,"addedOnOrBefore":"5 days ago"},"sort":"earliest"}"#, ["budget.xlsx", "notes.txt"]),
        (#"{"filter":{"typeGroup":"video","mark":"kept"}}"#, []),
    ])
    func aFilteredSearchFindsExactlyTheseInThisOrder(arguments: String, expected: [String]) async throws {
        let result = try await search(arguments)
        #expect(result.files.map(\.name) == expected)
        #expect(result.matchCount == expected.count)
        #expect(result.totalBytes == total(Fixtures.files.filter { expected.contains($0.name) }))
    }

    @Test func theLimitCutsTheListButNotTheCountOrTheTotal() async throws {
        let result = try await search(#"{"sort":"largest","limit":3}"#)
        #expect(result.files.map(\.name) == ["Xcode.dmg", "movie.mov", "backup.tar.gz"])
        #expect(result.matchCount == Fixtures.files.count)
        #expect(result.totalBytes == total(Fixtures.files))
    }

    @Test func everySortPutsItemsWithoutTheValueLastAndBreaksTiesByName() async throws {
        let largest = try await search(#"{"sort":"largest","limit":100}"#).files
        let sizes = largest.map(megabytes)
        #expect(sizes.compactMap(\.self) == sizes.compactMap(\.self).sorted(by: >))
        #expect(largest.last?.name == "Photos")
        let tied = largest.map(\.name).filter { $0.hasPrefix("report") }
        #expect(tied == ["report copy.pdf", "report.pdf"])

        let smallest = try await search(#"{"sort":"smallest","limit":100}"#).files
        #expect(smallest.first?.name == "notes.txt")
        #expect(smallest.last?.name == "Photos")

        let earliest = try await search(#"{"sort":"earliest","limit":100}"#).files
        #expect(earliest.first?.name == "old-photo.heic")
        #expect(earliest.last?.name == "undated.pdf")

        let recent = try await search(#"{"sort":"recentlyOpened","limit":100}"#).files
        #expect(recent.prefix(2).map(\.name) == ["report.pdf", "movie.mov"])
        #expect(recent.dropFirst(8).allSatisfy { $0.lastOpened == nil })

        let names = try await search(#"{"sort":"name","limit":100}"#).files.map(\.name)
        #expect(names == names.sorted { $0.localizedStandardCompare($1) == .orderedAscending })
    }

    @Test(arguments: [
        (#"{"filter":{"largerThanMB":-5}}"#, "largerThanMB must be a size in megabytes, 0 or more."),
        (#"{"sort":"biggest"}"#, "sort \"biggest\" is not one of: largest, smallest, newest, earliest, recentlyOpened, leastRecentlyOpened, name."),
        (#"{"limit":0}"#, "limit must be between 1 and 100."),
        (#"{"limit":101}"#, "limit must be between 1 and 100."),
        (#"{"filter":{"typeGroup":"pdfs"}}"#, "typeGroup \"pdfs\" is not one of: documents, images, installers, archives, video, audio, other."),
    ])
    func aCallThatMakesNoSenseIsAnsweredWithTheReasonAndRecordsNothing(arguments: String, reason: String) async {
        let model = ScriptedModel(
            ScriptedModel.call("searchFiles", arguments),
            ScriptedModel.call("searchFiles", #"{"filter":{"typeGroup":"audio"}}"#),
            [.text(["Two audio files."])]
        )
        let turn = await ChatEngine.scripted(model).ask()
        // The model read the reason, called again correctly, and only that call left a result.
        #expect(turn.outcome == .answered)
        #expect(model.toolOutputsSeen.first == "That call was not understood: \(reason)")
        #expect(turn.effects.results.count == 1)
        guard case .search(let result) = turn.effects.results.first else {
            Issue.record("No search result was recorded")
            return
        }
        #expect(Set(result.files.map(\.name)) == ["song.mp3", "podcast.m4a"])
    }

    @Test func theSummaryTotalsEveryItemByKindAndByMark() async throws {
        let model = ScriptedModel(ScriptedModel.call("folderSummary"), [.text(["Here is the folder."])])
        let turn = await ChatEngine.scripted(model).ask()
        guard case .summary(let summary) = turn.effects.results.first, turn.effects.results.count == 1 else {
            Issue.record("No summary was recorded")
            return
        }
        #expect(model.toolOutputsSeen == [ToolOutput.summary(summary)])

        #expect(summary.all.count == Fixtures.files.count)
        #expect(summary.all.bytes == total(Fixtures.files))
        #expect(summary.bytesMovedToTrash == 3_400_000_000)

        // Counted here by hand from the fixture.
        let kinds: [FileTypeGroup: [String]] = [
            .documents: ["report.pdf", "Annual Report 2025.pdf", "notes.txt", "budget.xlsx", "report copy.pdf", "undated.pdf"],
            .images: ["holiday.jpg", "screenshot.png", "old-photo.heic"],
            .installers: ["Xcode.dmg", "Tool.pkg"],
            .archives: ["project.zip", "backup.tar.gz"],
            .video: ["movie.mov", "clip.mp4"],
            .audio: ["song.mp3", "podcast.m4a"],
            .other: ["mystery.xyz", "setup.dmg.crdownload", "Photos", "Notes.app"],
        ]
        for group in FileTypeGroup.allCases {
            let files = Fixtures.files.filter { kinds[group]?.contains($0.name) == true }
            #expect(summary.byTypeGroup[group]?.count == files.count, "\(group)")
            #expect(summary.byTypeGroup[group]?.bytes == total(files), "\(group)")
        }
        for mark in FolderSnapshot.Mark.allCases {
            let files = Fixtures.files.filter { $0.marks.contains(mark) }
            #expect(summary.byMark[mark]?.count ?? 0 == files.count, "\(mark)")
            #expect(summary.byMark[mark]?.bytes ?? 0 == total(files), "\(mark)")
        }
        #expect(summary.largest.map(\.name) == [
            "Xcode.dmg", "movie.mov", "backup.tar.gz", "clip.mp4", "Tool.pkg",
            "podcast.m4a", "project.zip", "Notes.app", "setup.dmg.crdownload", "Annual Report 2025.pdf",
        ])
    }

    @Test func anEmptyFolderSummarisesToZeros() {
        let summary = FolderSummary(FolderSnapshot(files: [], now: Fixtures.now))
        #expect(summary.all.count == 0)
        #expect(summary.largest.isEmpty)
        #expect(summary.bytesMovedToTrash == nil)
        #expect(ToolOutput.summary(summary).contains("0 items"))
    }
}
