#if DEBUG
import FileStoreCore
import Foundation
import UniformTypeIdentifiers

/// Made-up plans for the Debug menu (debug builds only), so the preview of renames and moves can
/// be looked at before any action proposes them. Their files live in a folder that does not exist,
/// at the top of the startup disk where nothing can create it, and the preview offers no way to
/// apply renames or moves.
enum SamplePlans {
    static let folderURL = URL(filePath: "/Smart OS File Store Sample", directoryHint: .isDirectory)

    /// Renames of the kinds Fix messy names will propose, a long and a Unicode name among them,
    /// and one file it could not check.
    static var messyNames: CleanupPlan {
        let renames: [(name: String, newName: String, size: Int64)] = [
            ("invoice (1).pdf", "invoice.pdf", 48_213),
            ("budget copy.xlsx", "budget.xlsx", 19_874),
            ("file%20name%20with%20junk.txt", "file name with junk.txt", 1_024),
            ("brochure.pdf_dl=1", "brochure.pdf", 2_381_902),
            ("slides.pdf.pdf", "slides.pdf", 5_120_331),
            ("résumé – final ✓ (2).pdf", "résumé – final ✓.pdf", 88_410),
            (
                "Quarterly report for the regional sales team, with every appendix and the speaker notes (3).docx",
                "Quarterly report for the regional sales team, with every appendix and the speaker notes.docx",
                734_002
            ),
        ]
        return CleanupPlan(
            action: .fixMessyNames,
            folderURL: folderURL,
            changes: renames.enumerated().map { index, rename in
                ProposedChange(
                    record: record(rename.name, size: rename.size, daysAgo: Double(3 + index * 4)),
                    operation: .rename(to: rename.newName),
                    reason: .messyName
                )
            },
            skippedItems: [
                CleanupPlan.SkippedItem(url: folderURL.appending(path: "manual (2).pdf"), reason: .accessDenied),
            ]
        )
    }

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
