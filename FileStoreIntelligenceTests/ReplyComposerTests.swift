import FileStoreIntelligence
import Foundation
import Testing

@Suite("Reply composer")
struct ReplyComposerTests {
    private static func search(_ names: String..., limit: Int = 20) -> FileSearchResult {
        var query = FileQuery()
        query.withinIDs = Set(Fixtures.files.filter { names.contains($0.name) }.map(\.id))
        return FileSearchResult(query: query, sort: .newest, limit: limit, in: Fixtures.snapshot)
    }

    private static func proposal(count: Int, notOffered: [String] = []) -> CleanupProposal {
        CleanupProposal(
            request: CleanupRequest(actions: ["findDuplicates"]),
            rows: count == 0 ? [] : [CleanupProposal.Row(action: "findDuplicates", count: count, bytes: 2_500_000, tickedCount: count)],
            sampleNames: ["report copy.pdf"], notOffered: notOffered
        )
    }

    @Test func countsAgreeWithTheirNumber() {
        #expect(ReplyComposer.search(Self.search("report.pdf"), count: false) == "Found 1 file, 2.5 MB in all.")
        #expect(ReplyComposer.search(Self.search("report.pdf", "report copy.pdf", "notes.txt"), count: false) == "Found 3 files, 5 MB in all.")
        #expect(ReplyComposer.search(Self.search("report.pdf", "report copy.pdf", limit: 1), count: false) == "Found 2 files, 5 MB in all. The list shows the first 1.")
        #expect(ReplyComposer.search(Self.search("report.pdf"), count: true) == "That comes to 1 file, 2.5 MB in all.")
        #expect(ReplyComposer.search(Self.search(), count: true) == "No files match that.")
        #expect(ReplyComposer.cleanup([Self.proposal(count: 1)], unplanned: 0, unreadable: 0) == "A preview of 1 file is ready. Nothing changes until you confirm.")
        #expect(ReplyComposer.cleanup([Self.proposal(count: 2), Self.proposal(count: 3)], unplanned: 0, unreadable: 0)
            == "Previews of 5 files are ready in 2 folders. Nothing changes until you confirm.")
        #expect(ReplyComposer.duplicates(Fixtures.duplicates) == "Found 1 copy of other files, taking 2.5 MB.")
        #expect(ReplyComposer.overview(FolderSummary(Fixtures.snapshot)).hasPrefix("That’s 21 items, "))
    }

    @Test func aCleanupSaysWhatWasNotPrepared() {
        #expect(ReplyComposer.cleanup([Self.proposal(count: 0)], unplanned: 0, unreadable: 0) == "There’s nothing to clean up for that.")
        #expect(ReplyComposer.cleanup([Self.proposal(count: 0, notOffered: ["findDuplicates"])], unplanned: 0, unreadable: 0)
            == "There’s nothing to clean up for that. Some of the cleanups you named are turned off in Settings.")
        #expect(ReplyComposer.cleanup([Self.proposal(count: 0, notOffered: ["findDuplicates"])], unplanned: 0, unreadable: 0, named: false)
            == "There’s nothing to clean up for that.")
        #expect(ReplyComposer.cleanup([], unplanned: 1, unreadable: 0) == "The cleanup couldn’t be prepared just now. Try the Clean Up menu.")
        #expect(ReplyComposer.cleanup([Self.proposal(count: 2)], unplanned: 0, unreadable: 1).hasSuffix("Folders the app can’t read now were left out."))
        #expect(ReplyComposer.duplicates(nil).contains("Clean Up menu"))
        #expect(ReplyComposer.duplicates(DuplicateScan(groups: [], recentCount: 2)) == "No duplicates found. Files added in the last hour are left for later.")
    }

    @Test func noReplyNamesAFile() {
        let snapshot = Fixtures.snapshot
        let reasons: [ChatRequestPlanner.CannotDoReason] = [
            .asked(.move), .asked(.deleteForever), .asked(.emptyTrash), .asked(.open), .asked(.send), .asked(.compress), .asked(.convert),
            .asked(.schedule), .asked(.watch), .asked(.organize), .asked(.restore), .asked(.other),
        ]
        let missing: [ChatRequestPlanner.Missing] = [.cleanup, .lastResult, .when, .files, .folder]
        let replies = [
            ReplyComposer.search(FileSearchResult(query: FileQuery(), sort: .largest, limit: 5, in: snapshot), count: false),
            ReplyComposer.cleanup([Self.proposal(count: 4)], unplanned: 0, unreadable: 0),
            ReplyComposer.duplicates(Fixtures.duplicates),
            ReplyComposer.overview(FolderSummary(snapshot)),
            ReplyComposer.chat,
        ] + reasons.map(ReplyComposer.cannotDo) + missing.map(ReplyComposer.needsMore)
        for reply in replies {
            #expect(ReplyNames.fileNames(in: reply).isEmpty, "\(reply)")
            for file in snapshot.files {
                #expect(!reply.contains(file.name), "\(reply) names \(file.name)")
            }
        }
    }

    @Test func needsMoreAsksOneShortQuestion() {
        for missing in [ChatRequestPlanner.Missing.cleanup, .lastResult, .when, .files, .folder] {
            let reply = ReplyComposer.needsMore(missing)
            #expect(reply.hasSuffix("?") && reply.count(where: { $0 == "?" }) == 1, "\(reply)")
            #expect(reply.count <= 80, "\(reply)")
        }
        #expect(ReplyComposer.needsMore(.cleanup) == "Which cleanup did you mean: duplicates, failed downloads or old files?")
    }

    @Test func everyCannotDoSaysWhatTheAppCanDoInstead() {
        for reason in [ChatRequest.CannotDo.move, .deleteForever, .emptyTrash, .open, .send, .compress, .convert, .schedule, .watch, .organize, .restore, .other] {
            let reply = ReplyComposer.cannotDo(.asked(reason))
            // A second sentence, or the way to do it.
            #expect(reply.split(separator: ". ").count >= 2 || reason == .restore, "\(reason): \(reply)")
        }
        #expect(ReplyComposer.cannotDo(.folder("Desktop", .permissionNeeded)).contains("System Settings"))
        #expect(ReplyComposer.cannotDo(.folder("Backup", .unavailable)).contains("disconnected"))
    }
}
