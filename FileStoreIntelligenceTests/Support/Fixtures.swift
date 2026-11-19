import FileStoreIntelligence
import Foundation
import FoundationModels
import Synchronization
import UniformTypeIdentifiers

/// A fixed folder for the tests: plain rows, as the app would hand them over. Nothing is on disk.
enum Fixtures {
    /// The calendar the chat reads and writes days in: Gregorian, in this Mac's time zone.
    static let calendar: Calendar = {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = .current
        return calendar
    }()

    /// Noon, so a row dated a whole number of days back is never near a day's edge.
    static let now: Date = calendar.date(from: DateComponents(year: 2026, month: 11, day: 18, hour: 12)) ?? .distantPast

    static func daysAgo(_ days: Int) -> Date {
        calendar.date(byAdding: .day, value: -days, to: now) ?? .distantPast
    }

    static func file(
        _ name: String, _ type: UTType?, megabytes: Double?, added: Int?, opened: Int? = nil,
        recordsOpens: Bool = true, downloading: Bool = false, site: String? = nil, marks: Set<FolderSnapshot.Mark> = []
    ) -> FolderSnapshot.File {
        FolderSnapshot.File(
            id: URL(filePath: "/tmp/FakeDownloads/\(name)"),
            name: name,
            contentType: type,
            sizeInBytes: megabytes.map { Int64($0 * 1_000_000) },
            dateAdded: added.map(daysAgo),
            lastOpened: opened.map(daysAgo),
            recordsOpens: recordsOpens,
            isDownloading: downloading,
            sourceSite: site,
            marks: marks
        )
    }

    static let files: [FolderSnapshot.File] = [
        file("report.pdf", .pdf, megabytes: 2.5, added: 3, opened: 1, site: "example.com"),
        file("Annual Report 2025.pdf", .pdf, megabytes: 12, added: 200, opened: 150, marks: [.unused, .old]),
        file("notes.txt", .plainText, megabytes: 0.01, added: 10),
        file("budget.xlsx", .spreadsheet, megabytes: 0.4, added: 45, marks: [.neverOpened]),
        file("holiday.jpg", .jpeg, megabytes: 4.2, added: 6, opened: 6, site: "photos.example.com"),
        file("screenshot.png", .png, megabytes: 1.1, added: 0),
        file("old-photo.heic", .heic, megabytes: 3.3, added: 400, marks: [.neverOpened, .old]),
        file("Xcode.dmg", .diskImage, megabytes: 900, added: 20, opened: 19, site: "developer.apple.com", marks: [.installed]),
        file("Tool.pkg", UTType("com.apple.installer-package-archive"), megabytes: 55, added: 8, site: "github.com"),
        file("project.zip", .zip, megabytes: 30, added: 12, opened: 12, site: "objects.github.com", marks: [.kept]),
        file("backup.tar.gz", .gzip, megabytes: 250, added: 95, marks: [.neverOpened, .old]),
        file("movie.mov", .quickTimeMovie, megabytes: 700, added: 2, opened: 2),
        file("clip.mp4", .mpeg4Movie, megabytes: 80, added: 33, opened: 31, marks: [.unused]),
        file("song.mp3", .mp3, megabytes: 6, added: 7, opened: 5),
        file("podcast.m4a", .mpeg4Audio, megabytes: 40, added: 60, marks: [.neverOpened]),
        file("mystery.xyz", nil, megabytes: 0.5, added: 1),
        file("setup.dmg.crdownload", UTType(filenameExtension: "crdownload"), megabytes: 15, added: 4, downloading: true, marks: [.failedDownload]),
        file("report copy.pdf", .pdf, megabytes: 2.5, added: 3),
        file("Photos", .folder, megabytes: nil, added: 30, recordsOpens: false),
        file("Notes.app", .applicationBundle, megabytes: 20, added: 15, recordsOpens: false),
        file("undated.pdf", .pdf, megabytes: 1, added: nil),
    ]

    static let snapshot = FolderSnapshot(files: files, bytesMovedToTrash: 3_400_000_000, now: now)

    /// What Find Duplicates would find in the fixture folder, as the app hands it over.
    static let duplicates = DuplicateScan(groups: [
        DuplicateScan.Group(kept: named("report.pdf")[0], copies: named("report copy.pdf")),
    ])

    /// The app's cleanup actions by name, as its registry spells them today. The module is handed
    /// the list when the app runs; this copy is for the tests and the token measurement.
    static let cleanupActions = [
        "findDuplicates", "clearFailedDownloads", "removeUnpackedZips", "removeUsedInstallers", "fixMessyNames",
        "reviewNearDuplicates", "archiveOldDownloads", "reviewLargeDownloads", "removeEmptyFolders",
    ]

    /// A stand-in for the app's planning: each action asked for "finds" every file the request is
    /// narrowed to (the whole fixture when it is not), ticked unless the action only reviews.
    static let proposal: ProposeCleanup = { request, ids in
        let found = files.filter { ids?.contains($0.id) ?? true }
        return CleanupProposal(
            request: request,
            rows: request.actions.map { action in
                CleanupProposal.Row(
                    action: action, count: found.count, bytes: found.reduce(0) { $0 + ($1.sizeInBytes ?? 0) },
                    tickedCount: action.hasPrefix("review") ? 0 : found.count
                )
            },
            sampleNames: found.map(\.name)
        )
    }

    static func named(_ names: String...) -> [FolderSnapshot.File] {
        names.compactMap { name in files.first { $0.name == name } }
    }
}

/// Collects values handed to a callback on other tasks, and counts calls.
final class Collected<Value: Sendable>: Sendable {
    private let values = Mutex<[Value]>([])

    func add(_ value: Value) {
        values.withLock { $0.append(value) }
    }

    var all: [Value] {
        values.withLock { $0 }
    }

    /// Waits, at most five seconds, for a value that passes.
    func waitFor(_ passes: @Sendable (Value) -> Bool) async -> Bool {
        for _ in 0..<500 {
            if all.contains(where: passes) { return true }
            try? await Task.sleep(for: .milliseconds(10))
        }
        return false
    }
}

extension ScriptedModel {
    /// One tool call as a whole round.
    static func call(_ name: String, _ arguments: String = "{}") -> [Step] {
        [.toolCalls([ToolCall(name: name, arguments: arguments)])]
    }

    /// The text of every tool output the session showed the model, in order.
    var toolOutputsSeen: [String] {
        guard let transcript = script.requests.last?.transcript else { return [] }
        return transcript.compactMap { entry in
            guard case .toolOutput(let output) = entry else { return nil }
            return output.segments.compactMap { segment in
                if case .text(let text) = segment { text.content } else { nil }
            }.joined()
        }
    }

    /// The question the model is answering at its latest request, with any note the app put before it.
    var latestPrompt: String {
        script.requests.last?.transcript.compactMap { entry -> String? in
            guard case .prompt(let prompt) = entry else { return nil }
            return prompt.segments.compactMap { if case .text(let text) = $0 { text.content } else { nil } }.joined()
        }.last ?? ""
    }

    /// How many questions the model has in front of it at its latest request.
    var promptsInLatestRequest: Int {
        script.requests.last?.transcript.count { if case .prompt = $0 { true } else { false } } ?? 0
    }
}

extension ContextMeter {
    /// The scripted model's measure, where a token is a character.
    static func characters(_ contextSize: Int) -> ContextMeter {
        ContextMeter(contextSize: contextSize) { ScriptedModel.size(of: $0) }
    }
}

extension ChatEngine {
    /// An engine over the fixture folder. `reads` counts how often a tool asked for the folder,
    /// which is once per tool call that ran.
    static func scripted(
        _ model: ScriptedModel, reads: Collected<Void>? = nil, turnLimit: Duration = .seconds(10),
        availability: @escaping @Sendable () -> IntelligenceAvailability = { .available },
        duplicates: @escaping @Sendable () async -> DuplicateScan? = { Fixtures.duplicates },
        cleanup: @escaping ProposeCleanup = Fixtures.proposal,
        meter: ContextMeter? = nil
    ) -> ChatEngine {
        ChatEngine(
            model: model,
            snapshot: {
                reads?.add(())
                return Fixtures.snapshot
            },
            findDuplicates: duplicates,
            cleanupActions: Fixtures.cleanupActions,
            proposeCleanup: cleanup,
            availability: availability,
            turnLimit: turnLimit,
            now: { Fixtures.now },
            meter: meter
        )
    }

    func ask(_ question: String = "A question") async -> Turn {
        await respond(to: question) { _ in }
    }
}
