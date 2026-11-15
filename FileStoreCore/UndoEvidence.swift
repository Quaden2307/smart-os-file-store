import Foundation

/// What the activity log recorded about a file when a change was made: what undo checks to prove
/// that the item it finds is that very file. The rules live here, once, for the planner, the
/// executor and the reconciler (decision record 0008).
public struct UndoEvidence: Sendable, Hashable {
    /// For a file, its size. For a folder, the total of the files inside it.
    public let sizeInBytes: Int64

    /// The modification date the change saw, exactly as stored: for a folder, its last change
    /// (`FileRecord.lastChange`). Nil makes the item uncheckable.
    public let dateModified: Date?

    /// The file's number on its disk (inode) when the change was made. A rename or a move to the
    /// Trash keeps it; a copy or a replacement gets another. Nil for changes recorded before it was.
    public let fileNumber: UInt64?

    /// The content the executor confirmed, when the action compared content.
    public let contentHash: ContentHash?

    /// True when the item was a folder (a package included). Its size and date describe what is
    /// inside it, which only the executor reads (`PackageContents`); a look at the folder itself
    /// checks its disk ID.
    public let isFolder: Bool

    public init(sizeInBytes: Int64, dateModified: Date?, fileNumber: UInt64?, contentHash: ContentHash?, isFolder: Bool = false) {
        self.sizeInBytes = sizeInBytes
        self.dateModified = dateModified
        self.fileNumber = fileNumber
        self.contentHash = contentHash
        self.isFolder = isFolder
    }

    /// The checks a look at the item can answer, without reading it. Nil when they pass.
    ///
    /// - A file: a regular file, with the recorded size and modification date, and the recorded
    ///   disk ID when there is one. An item with another size or date reads as changed before
    ///   another disk ID reads as replaced: an app that saves by writing a new file changes both.
    /// - A folder: a folder, with the recorded disk ID, which it must have; without one it cannot be
    ///   told from another folder of the same name. Its contents are the executor's to compare.
    public func refusal(for facts: UndoItemFacts) -> UndoRefusal? {
        if isFolder {
            return folderRefusal(for: facts)
        }
        guard facts.isRegularFile else {
            return .replaced
        }
        if facts.isDataless {
            return .notDownloaded
        }
        guard let dateModified else {
            return .cannotBeChecked
        }
        guard facts.sizeInBytes == sizeInBytes,
              abs(facts.dateModified.timeIntervalSince(dateModified)) <= CleanupExecutor.modificationDateTolerance else {
            return .changed
        }
        if let fileNumber, facts.fileNumber != fileNumber {
            return .replaced
        }
        return nil
    }

    private func folderRefusal(for facts: UndoItemFacts) -> UndoRefusal? {
        guard facts.isDirectory else {
            return .replaced
        }
        if facts.isDataless {
            return .notDownloaded
        }
        guard let fileNumber, dateModified != nil else {
            return .cannotBeChecked
        }
        return facts.fileNumber == fileNumber ? nil : .replaced
    }
}

/// What one look (`lstat`) at an item says, as undo compares it with `UndoEvidence`.
public struct UndoItemFacts: Sendable, Hashable {
    /// False for a folder, a link or anything else that is not a plain file.
    public let isRegularFile: Bool
    /// True for a folder (a package included), never for a link to one.
    public let isDirectory: Bool
    public let sizeInBytes: Int64
    public let dateModified: Date
    public let fileNumber: UInt64
    /// A cloud placeholder whose bytes are not on this Mac.
    public let isDataless: Bool

    public init(
        isRegularFile: Bool,
        sizeInBytes: Int64,
        dateModified: Date,
        fileNumber: UInt64,
        isDataless: Bool,
        isDirectory: Bool = false
    ) {
        self.isRegularFile = isRegularFile
        self.isDirectory = isDirectory
        self.sizeInBytes = sizeInBytes
        self.dateModified = dateModified
        self.fileNumber = fileNumber
        self.isDataless = isDataless
    }

    init(_ status: FileStatus) {
        self.init(
            isRegularFile: status.isRegularFile && !status.isSymbolicLink,
            sizeInBytes: status.sizeInBytes,
            dateModified: status.modificationDate,
            fileNumber: UInt64(status.identity.inode),
            isDataless: status.isDataless,
            isDirectory: status.isDirectory && !status.isSymbolicLink
        )
    }
}

/// What undo found on disk for one logged change, read with `lstat` only, never the content.
public struct UndoObservation: Sendable, Hashable {
    /// What sits at one place.
    public enum Place: Sendable, Hashable {
        case nothing
        case item(UndoItemFacts)
        /// The place could not be looked at.
        case unreadable
    }

    /// The place the change put the file: in the Trash, or its new name or folder.
    public let currentPlace: Place

    /// Where the file was before the change, which undo puts it back to.
    public let originalPlace: Place

    /// False when the scanned folder could not be reached.
    public let folderIsReachable: Bool

    /// True when the folder the file was in is the scanned folder itself, by its identity on disk:
    /// the scan may spell the same folder another way (`/private/var` for `/var`, or through a link).
    public let originalIsInFolder: Bool

    public init(currentPlace: Place, originalPlace: Place, folderIsReachable: Bool, originalIsInFolder: Bool = true) {
        self.currentPlace = currentPlace
        self.originalPlace = originalPlace
        self.folderIsReachable = folderIsReachable
        self.originalIsInFolder = originalIsInFolder
    }

    /// Looks at `path` without following a link at it.
    static func place(at path: String?) -> Place {
        guard let path else {
            return .nothing
        }
        do throws(FileStatus.Failure) {
            return .item(UndoItemFacts(try FileStatus.of(path: path)))
        } catch {
            switch error {
            case .notFound:
                return .nothing
            case .accessDenied, .other:
                return .unreadable
            }
        }
    }
}
