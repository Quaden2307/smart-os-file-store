import Foundation
import os

/// Settles the undo rows a crash left unfinished. Undo writes a `started` row before each move and
/// completes it right after; when the app stops in between, the next launch finds the row still
/// started and does not know whether the file moved. The reconciler looks, and records what it sees.
///
/// It finds the file only by what the row recorded: its two paths, size, modification date, the
/// disk ID read right before the move, and the content hash when there is one. A folder is found by
/// its disk ID alone, which its row always has (`UndoEvidence`). It moves nothing.
///
/// - The file is at its original place and no longer at the place it was taken from: the move
///   happened. The row is completed as undone, exactly as the executor would have done it.
/// - Otherwise the row is completed as not undone (interrupted). When the file is still where it
///   was, the change can be undone again; when it is in neither place, the change's own check says so.
///
/// Cleanup rows a crash left started are not settled here; they stay interrupted (decision record 0006).
public struct UndoReconciler: Sendable {
    /// What one reconciliation found.
    public struct Result: Sendable, Hashable {
        /// Rows completed as undone: the move back had happened.
        public let undone: Int
        /// Rows completed as not undone.
        public let notUndone: Int

        public init(undone: Int, notUndone: Int) {
            self.undone = undone
            self.notUndone = notUndone
        }
    }

    public let hasher: ContentHasher

    private static let logger = Logger(subsystem: "com.quaden2307.FileStoreCore", category: "UndoReconciler")

    public init(hasher: ContentHasher = ContentHasher()) {
        self.hasher = hasher
    }

    /// Settles every interrupted undo row in `log`. A row whose write fails is left as it was, for
    /// the next launch, and the others are settled. Running it again finds nothing more to do.
    @concurrent
    public func reconcile(_ log: ActivityLog, now: Date = .now) async throws(ActivityLogError) -> Result {
        let rows = try await log.interruptedUndoRows()
        var undone = 0
        var notUndone = 0
        var unsettled = 0
        // Each row on its own: one that cannot be settled leaves the others to be.
        for row in rows {
            let wasUndone = await isBackInPlace(row)
            do throws(ActivityLogError) {
                try await log.resolveInterruptedUndo(row, wasUndone: wasUndone, at: now)
            } catch {
                unsettled += 1
                Self.logger.error("An interrupted undo row could not be settled: \(String(describing: error), privacy: .public)")
                continue
            }
            if wasUndone {
                undone += 1
            } else {
                notUndone += 1
            }
        }
        if !rows.isEmpty {
            Self.logger.notice(
                "Settled \(undone + notUndone) of \(rows.count) interrupted undo rows: \(undone) had been undone, \(notUndone) had not, \(unsettled) left as they were"
            )
        }
        return Result(undone: undone, notUndone: notUndone)
    }

    /// True when the row's file is provably at its original place and not at the place undo took it from.
    private func isBackInPlace(_ row: ActivityChange) async -> Bool {
        guard let originalPath = row.resultingPath, row.fileNumber != nil else {
            return false
        }
        let evidence = row.undoEvidence
        guard case .item(let facts) = UndoObservation.place(at: originalPath), evidence.refusal(for: facts) == nil else {
            return false
        }
        if case .item(let facts) = UndoObservation.place(at: row.originalPath), evidence.refusal(for: facts) == nil,
           !Self.folderListsOnly(originalPath, notTheOtherSpellingOf: row.originalPath) {
            // The same file in both places: a second link to it. Nothing can be told for sure.
            return false
        }
        guard let expected = evidence.contentHash else {
            return true
        }
        let hash = try? await hasher.hash(contentsOf: URL(filePath: originalPath), expectedSizeInBytes: evidence.sizeInBytes)
        return hash == expected
    }

    /// True when `path` and `other` are one name in two letter cases or Unicode forms in the same
    /// folder, which a disk that ignores them answers at both, and the folder lists the name exactly
    /// as `path` spells it and not as `other` does: a rename back of the case or form only, done.
    private static func folderListsOnly(_ path: String, notTheOtherSpellingOf other: String) -> Bool {
        let url = URL(filePath: path)
        let otherURL = URL(filePath: other)
        let folder = url.deletingLastPathComponent()
        let name = url.lastPathComponent
        let otherName = otherURL.lastPathComponent
        let folded = { (name: String) in name.precomposedStringWithCanonicalMapping.lowercased() }
        guard folder.standardizedFileURL.pathComponents == otherURL.deletingLastPathComponent().standardizedFileURL.pathComponents,
              folded(name) == folded(otherName),
              let names = try? FileManager.default.contentsOfDirectory(atPath: folder.path(percentEncoded: false)) else {
            return false
        }
        // Scalar by scalar: Swift's `==` would call two Unicode forms of one name equal.
        let listed = Set(names.map { Array($0.unicodeScalars) })
        return listed.contains(Array(name.unicodeScalars)) && !listed.contains(Array(otherName.unicodeScalars))
    }
}
