import Foundation

/// One change a cleanup action proposes. Nothing happens to the file until the user confirms it.
public struct ProposedChange: Sendable, Hashable, Identifiable {
    /// What would be done to the file. Every operation is one an undo can reverse; nothing is
    /// ever deleted and nothing is ever overwritten.
    public enum Operation: Sendable, Hashable {
        /// Move the file to the Trash with `FileManager.trashItem`. Never a permanent delete.
        case moveToTrash

        /// Give the file a new name in the same folder. `to` is one file name, not a path. Fails,
        /// rather than overwrites, when the name is taken.
        case rename(to: String)

        /// Move the file into `to`, a folder inside the scanned folder (made if it is missing),
        /// under `name`. Fails, rather than overwrites, when the name is taken there.
        case move(to: URL, name: String)
    }

    /// Why the action proposes the change. Typed, so the app can put it into words in the user's
    /// language; the engine has no String Catalog.
    public enum Reason: Sendable, Hashable {
        /// The file has exactly the same bytes as the named file, which is kept.
        case sameContent(asFileNamed: String)

        /// The name has copy numbers or leftover junk that the new name drops, as `fix` says.
        case messyName(MessyNameFix)

        /// The file is marked Unused: last opened on the date given, longer ago than the setting.
        /// It is filed into the archive.
        case notOpenedSince(Date)

        /// The file is marked Never opened: added on the date given, longer ago than the setting,
        /// and never opened since. It is filed into the archive.
        case neverOpened(downloadedOn: Date)

        /// The file would be filed into the archive, which already holds `copyNamed` with exactly the
        /// same bytes, so this copy goes to the Trash instead.
        case alreadyArchived(copyNamed: String)

        /// A download that stopped at `stoppedOn`, its last change, and never finished.
        /// `finishedFileName` names a finished item beside it with the name the download would
        /// have had (`movie.mp4` beside `movie.mp4.crdownload`), when there is one.
        case failedDownload(stoppedOn: Date, finishedFileName: String?)

        /// A zip whose every entry already sits next to it, unpacked, at the same size. `unpackedTo`
        /// names the item beside it that holds them (`project` beside `project.zip`), which is never
        /// touched.
        case unpackedZip(unpackedTo: String)

        /// An installer whose app is installed, as `evidence` shows: ticked when it is strong, a
        /// possible match when only the name matches.
        case usedInstaller(UsedInstallerEvidence)

        /// The file has the same cleaned name as the named file, and different content. Shown for
        /// review only.
        case nearDuplicate(sameNameAs: String)

        /// The file or package takes `sizeOnDisk` bytes on disk, at least the large-download setting.
        /// `lastOpened` is when it was last opened; when nil, `opensRecorded` tells whether that
        /// means never opened (true) or that macOS records no date for it, as for an app (false).
        /// Shown for review only.
        case largeDownload(sizeOnDisk: Int64, lastOpened: Date?, opensRecorded: Bool)

        /// True for a change that only the user may tick, by hand, after looking: a near-duplicate
        /// or a large download. Nothing ticks it for them: not the preview, not Select All, and no
        /// automatic flow (Tidy Now included).
        public var isReviewOnly: Bool {
            switch self {
            case .nearDuplicate, .largeDownload:
                true
            case .sameContent, .messyName, .notOpenedSince, .neverOpened, .alreadyArchived, .failedDownload, .unpackedZip, .usedInstaller:
                false
            }
        }

        /// True for a change the preview leaves unticked: a possible match, which the user ticks
        /// only after looking.
        public var isPossibleMatch: Bool {
            if case .usedInstaller(let evidence) = self {
                return evidence.strength == .possible
            }
            return false
        }
    }

    public var id: URL { record.url }

    /// The file as the scan saw it.
    public let record: FileRecord

    public let operation: Operation

    public let reason: Reason

    /// Size at scan time: for a folder whose contents the scan read, the total of its files.
    /// Execution rechecks it right before acting.
    public let sizeInBytes: Int64

    /// Modification date at scan time: for a folder whose contents the scan read, its last change
    /// (`FileRecord.lastChange`). Execution rechecks it right before acting.
    public let dateModified: Date?

    /// Where the file was, so a later undo can put it back. Never ends in `/`, even for a folder.
    public let originalPath: String

    /// Where the file would be after a rename or a move, so a later undo can find it there. Nil for
    /// the Trash, which picks the place itself; the result reports where the file went.
    public let destinationPath: String?

    public init(record: FileRecord, operation: Operation, reason: Reason) {
        self.record = record
        self.operation = operation
        self.reason = reason
        self.sizeInBytes = record.contentSizeInBytes ?? 0
        self.dateModified = record.lastChange
        self.originalPath = record.url.storedPath
        switch operation {
        case .moveToTrash:
            self.destinationPath = nil
        case .rename(to: let newName):
            self.destinationPath = record.url.deletingLastPathComponent().appending(path: newName).storedPath
        case .move(to: let folder, name: let name):
            self.destinationPath = folder.appending(path: name).storedPath
        }
    }

    /// True when the item is a folder, a package included, rather than a file.
    public var isFolder: Bool {
        switch record.kind {
        case .folder, .package:
            true
        case .file, .symlink:
            false
        }
    }
}
