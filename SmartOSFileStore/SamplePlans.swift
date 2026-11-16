#if DEBUG
import FileStoreCore
import Foundation
import UniformTypeIdentifiers

/// A made-up plan for the Debug menu (debug builds only), so the preview of moves can be looked at
/// before any action proposes them. Its files live in a folder that does not exist, at the top of
/// the startup disk where nothing can create it, and the preview offers no way to apply moves.
enum SamplePlans {
    static let folderURL = URL(filePath: "/Smart OS File Store Sample", directoryHint: .isDirectory)

    /// Moves into the archive folder, as Archive old downloads will propose them.
    static var oldDownloads: CleanupPlan {
        let archive = folderURL.appending(path: CandidateEligibility.archiveFolderName, directoryHint: .isDirectory)
        let files: [(name: String, size: Int64, daysAgo: Double)] = [
            ("old-receipt.pdf", 31_206, 140),
            ("old-manual.pdf", 1_204_551, 210),
            ("tax-form-2024.pdf", 402_118, 330),
        ]
        return CleanupPlan(
            action: .archiveOldDownloads,
            folderURL: folderURL,
            changes: files.map { file in
                ProposedChange(
                    record: record(file.name, size: file.size, daysAgo: file.daysAgo),
                    operation: .move(to: archive, name: file.name),
                    reason: .oldDownload
                )
            }
        )
    }

    private static func record(_ name: String, size: Int64, daysAgo: Double) -> FileRecord {
        let url = folderURL.appending(path: name)
        let contentType = UTType(filenameExtension: url.pathExtension)
        let date = Date(timeIntervalSinceNow: -daysAgo * 86_400)
        return FileRecord(
            url: url,
            displayName: name,
            kind: .file,
            localizedTypeDescription: contentType?.localizedDescription,
            contentType: contentType,
            sizeInBytes: size,
            dateAdded: date,
            dateModified: date,
            isDownloading: false
        )
    }
}
#endif
