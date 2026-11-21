import FileStoreCore
import Foundation

/// Debug builds only, with `-SeedDemoHistory` on a demo home: twelve weeks of past cleanups, so
/// the insights have a past to show in a demo. Written through the activity log's own recording
/// calls (`beginRun`, `recordIntent`, `recordResult`, `finishRun`) with past dates, never by hand
/// in SQL, and only into a demo home's own log that holds no run yet. Nothing on disk changes:
/// the files named are fictional, and none of these runs can be undone.
enum DemoHistory {
    static var isAsked: Bool {
        #if DEBUG
        let arguments = ProcessInfo.processInfo.arguments
        return arguments.contains("-SeedDemoHistory") && arguments.contains("-DemoHome")
        #else
        false
        #endif
    }

    /// One past run: how many weeks and days back, which cleanup, in which folder, and its files.
    private struct Past {
        let daysAgo: Int
        let action: CleanupAction
        let kind: ManagedFolder.Kind
        let files: [(name: String, megabytes: Int)]
    }

    private static let past: [Past] = [
        Past(daysAgo: 82, action: .findDuplicates, kind: .downloads, files: [("Holiday Photos (1).zip", 640), ("budget copy.xlsx", 1)]),
        Past(daysAgo: 78, action: .clearFailedDownloads, kind: .downloads, files: [("os-image.iso.crdownload", 1_200)]),
        Past(daysAgo: 71, action: .removeUnpackedZips, kind: .downloads, files: [("design-kit.zip", 310), ("lecture-notes.zip", 45)]),
        Past(daysAgo: 64, action: .findDuplicates, kind: .desktop, files: [("Screenshot 2026-08-14 copy.png", 3), ("Screenshot 2026-08-15 (1).png", 4)]),
        Past(daysAgo: 57, action: .reviewLargeDownloads, kind: .downloads, files: [("Conference Talk.mov", 2_100)]),
        Past(daysAgo: 50, action: .findDuplicates, kind: .downloads, files: [("Annual Plan (1).pdf", 12), ("Annual Plan copy.pdf", 12), ("team-photo (2).jpg", 9)]),
        Past(daysAgo: 43, action: .removeEmptyFolders, kind: .desktop, files: [("Untitled Folder 2", 0), ("New Folder", 0)]),
        Past(daysAgo: 36, action: .removeUnpackedZips, kind: .downloads, files: [("photo-export.zip", 820)]),
        Past(daysAgo: 29, action: .clearFailedDownloads, kind: .downloads, files: [("dataset-2026.csv.part", 260), ("episode-12.mp4.crdownload", 480)]),
        Past(daysAgo: 22, action: .findDuplicates, kind: .downloads, files: [("Lecture 4 (1).mp4", 730), ("syllabus (1).pdf", 2)]),
        Past(daysAgo: 15, action: .reviewLargeDownloads, kind: .downloads, files: [("Old Backup.dmg", 3_400)]),
        Past(daysAgo: 9, action: .findDuplicates, kind: .desktop, files: [("draft (1).txt", 1), ("Screenshot 2026-11-03 copy.png", 5)]),
        Past(daysAgo: 4, action: .removeUnpackedZips, kind: .downloads, files: [("wallpapers.zip", 150)]),
    ]

    private static func reason(for action: CleanupAction, name: String, at date: Date, bytes: Int64) -> ProposedChange.Reason {
        switch action {
        case .clearFailedDownloads: .failedDownload(stoppedOn: date, finishedFileName: nil)
        case .removeUnpackedZips: .unpackedZip(unpackedTo: (name as NSString).deletingPathExtension)
        case .reviewLargeDownloads: .largeDownload(sizeOnDisk: bytes, lastOpened: nil, opensRecorded: true)
        case .removeEmptyFolders: .emptyFolder
        default: .sameContent(asFileNamed: name.replacing(#/ \(\d\)| copy/#, with: ""))
        }
    }

    /// Writes the past runs into `log` when it holds none, for the folders it has.
    @concurrent
    static func seed(_ log: ActivityLog, folders: [ManagedFolder], now: Date = .now) async {
        guard isAsked, (try? await log.runs().isEmpty) == true else { return }
        for run in past {
            guard let folder = folders.first(where: { $0.kind == run.kind }) else { continue }
            let date = now.addingTimeInterval(TimeInterval(-run.daysAgo * 86_400 + 3_600 * 11))
            do throws(ActivityLogError) {
                let runID = try log.beginRun(CleanupRunStart(action: run.action, folder: folder, confirmedCount: run.files.count, startedAt: date))
                for (sequence, file) in run.files.enumerated() {
                    let bytes = Int64(file.megabytes) * 1_000_000
                    let url = folder.url.appending(path: file.name)
                    let record = FileRecord(
                        url: url, displayName: file.name, kind: file.megabytes == 0 ? .folder : .file, localizedTypeDescription: nil,
                        contentType: nil, sizeInBytes: file.megabytes == 0 ? nil : bytes, dateAdded: date, dateModified: date,
                        isDownloading: false
                    )
                    let change = ProposedChange(record: record, operation: .moveToTrash, reason: reason(for: run.action, name: file.name, at: date, bytes: bytes))
                    guard case .recorded(let rowID) = try log.recordIntent(
                        CleanupChangeIntent(runID: runID, sequence: sequence, change: change, contentHash: nil, attemptedAt: date)
                    ) else { continue }
                    let trashed = CleanupItemResult(change: change, outcome: .trashed(trashURL: nil))
                    try log.recordResult(CleanupChangeResult(runID: runID, changeID: rowID, sequence: sequence, item: trashed, attemptedAt: date))
                }
                try log.finishRun(CleanupRunFinish(runID: runID, finishedAt: date, wasCancelled: false, notReached: []))
            } catch {
                return
            }
        }
    }
}
