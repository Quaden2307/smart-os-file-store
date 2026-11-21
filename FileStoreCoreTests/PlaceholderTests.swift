import FileStoreCore
import Foundation
import Testing

/// Cloud placeholders: files whose content is not on this Mac, as iCloud leaves them in Desktop and
/// Documents and a cloud drive can in Downloads. Reading one would download it, so no planner does.
///
/// A test cannot make a real placeholder (the system alone sets that flag on a file), so each
/// record is flagged as the scan flags one, and the file behind it is made unreadable: a planner
/// that opened it anyway would report "access denied", not "not downloaded". Decision record 0026
/// says how each planner treats a placeholder.
@Suite("Cloud placeholders")
struct PlaceholderTests {
    /// The actions whose planners read what is in a file.
    private static let contentReaders: [CleanupAction] = [
        .findDuplicates, .reviewNearDuplicates, .fixMessyNames, .archiveOldDownloads, .removeUnpackedZips, .removeUsedInstallers,
    ]

    /// The actions that decide by content alone: without it they propose nothing.
    private static let decidedByContent: Set<CleanupAction> = [.findDuplicates, .reviewNearDuplicates, .removeUnpackedZips, .removeUsedInstallers]

    private func plan(_ action: CleanupAction, _ records: [FileRecord], in folder: ManagedFolder, applications: URL) async throws -> CleanupPlan {
        // Every planner is run in every kind of folder, whatever its rules offer: reading is what is tested.
        var rules = folder.rules
        rules.offered = Set(CleanupAction.allCases)
        let everyAction = ManagedFolder(id: folder.id, kind: folder.kind, url: folder.url, rules: rules)
        return try #require(
            try await CleanupPlanners.plan(
                action,
                records: records,
                in: everyAction,
                eligibility: CandidateEligibility(),
                keptItems: KeptItems(),
                installers: .testing(applications: [applications])
            )
        )
    }

    @Test func theScanFlagsNoOrdinaryFile() async throws {
        try await withFakeHome { home in
            for (kind, url) in home.folders {
                let records = try await FolderScanner().scan(ManagedFolder(kind: kind, url: url)).records
                #expect(!records.isEmpty)
                #expect(records.allSatisfy { !$0.isDataless }, "\(kind)")
            }
        }
    }

    @Test(arguments: [ManagedFolder.Kind.downloads, .desktop, .documents])
    func noPlannerReadsAFileFlaggedAsAPlaceholder(kind: ManagedFolder.Kind) async throws {
        try await withFakeHome { home in
            let url = try #require(home.folders.first { $0.kind == kind }?.url)
            let folder = ManagedFolder(kind: kind, url: url)
            let records = try await FolderScanner().scan(folder).records
            // What each action makes of the folder while every file is on this Mac.
            var before: [CleanupAction: CleanupPlan] = [:]
            for action in Self.contentReaders {
                before[action] = try await plan(action, records, in: folder, applications: home.downloads.applicationsURL)
            }
            // Its duplicates and its same-named files are found, so there is content to read.
            #expect(before[.findDuplicates]?.changes.isEmpty == false)
            #expect(before[.reviewNearDuplicates]?.changes.isEmpty == false)
            #expect(before[.fixMessyNames]?.changes.isEmpty == false)
            #expect(before[.archiveOldDownloads]?.changes.isEmpty == false)

            // Every file is now a placeholder, and cannot be opened. (A locked file keeps its
            // permissions; its record is flagged like the rest.)
            let flagged = records.map { $0.kind == .file ? $0.flaggedAsPlaceholder() : $0 }
            for record in records where record.kind == .file {
                try? FileManager.default.setAttributes([.posixPermissions: 0o000], ofItemAtPath: record.url.path(percentEncoded: false))
            }

            for action in Self.contentReaders {
                let was = try #require(before[action])
                let now = try await plan(action, flagged, in: folder, applications: home.downloads.applicationsURL)
                if Self.decidedByContent.contains(action) {
                    #expect(now.changes.isEmpty, "\(action)")
                } else {
                    // A rename or a move reads nothing, so those stand; only a change that content
                    // would have decided is left out.
                    #expect(Set(now.changes.map(\.id)).isSubset(of: Set(was.changes.map(\.id))), "\(action)")
                    #expect(!now.changes.isEmpty, "\(action)")
                }
                // Whatever was left out for the first time was left out as not downloaded: nothing
                // was opened, or an unreadable file would say so.
                let newlySkipped = now.skippedItems.filter { !was.skippedItems.contains($0) }
                #expect(newlySkipped.allSatisfy { $0.reason == .notDownloaded }, "\(action): \(newlySkipped.map(\.reason))")
            }
            // Where content decided before, the plan now says why it did not look.
            for action in [CleanupAction.findDuplicates, .reviewNearDuplicates] {
                let now = try await plan(action, flagged, in: folder, applications: home.downloads.applicationsURL)
                #expect(now.skippedItems.contains { $0.reason == .notDownloaded }, "\(action)")
            }
        }
    }

    /// One flagged copy among files that are here: it is never read and never proposed, and the
    /// others are judged without it.
    @Test func aPlaceholderAmongOrdinaryFilesIsLeftOutAndTheRestAreStillFound() async throws {
        try await withTemporaryFolderAsync { url in
            try FileDates.writeSettled(["a.txt": "same", "a (1).txt": "same", "a (2).txt": "same"], in: url)
            let folder = ManagedFolder.temporary(url)
            let records = try await FolderScanner().scan(folder).records
            let placeholderName = "a (2).txt"
            let flagged = try records.map { record in
                guard record.displayName == placeholderName else { return record }
                try FileManager.default.setAttributes([.posixPermissions: 0o000], ofItemAtPath: record.url.path(percentEncoded: false))
                return record.flaggedAsPlaceholder()
            }

            let plan = try await DuplicatePlanner().plan(records: flagged, in: folder)

            #expect(plan.changes.map(\.record.displayName) == ["a (1).txt"])
            #expect(plan.skippedItems.map(\.url.lastPathComponent) == [placeholderName])
            #expect(plan.skippedItems.map(\.reason) == [.notDownloaded])
        }
    }
}
