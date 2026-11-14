import Darwin
import Foundation

/// The one place in the engine that changes anything on disk, and the only three ways it does:
/// move an item to the Trash, give it a new name or folder without ever replacing what is there,
/// and make a folder for a move. Nothing is ever deleted; a source-scanning test keeps every
/// file-changing call in this file. The executor decides whether a change may happen; this only
/// carries it out.
enum DiskChange {
    /// Moves the item at `url` to the Trash, from where the user can put it back.
    static func trash(_ url: URL) -> CleanupItemOutcome {
        var trashURL: NSURL?
        do {
            try autoreleasepool {
                try FileManager.default.trashItem(at: url, resultingItemURL: &trashURL)
            }
        } catch {
            return outcome(trashError: error)
        }
        return .trashed(trashURL: trashURL.map { $0 as URL })
    }

    /// Gives the item `name` in `source` the name `newName` in `destination`, which may be the same
    /// folder. The rename is exclusive: when anything already has the new name (as the volume
    /// compares names, so in any letter case on a default APFS volume) it fails with `EEXIST` and
    /// changes nothing, in one step, so no other app can slip an item in between a check and the
    /// rename. No symbolic link is followed on either side, and both names must stay in their folders.
    ///
    /// - Returns: Nil once renamed, otherwise the `errno` value.
    static func renameWithoutReplacing(_ name: String, in source: DirectoryHandle, to newName: String, in destination: DirectoryHandle) -> Int32? {
        let result = renameatx_np(
            source.descriptor,
            name,
            destination.descriptor,
            newName,
            UInt32(RENAME_EXCL | RENAME_NOFOLLOW_ANY | RENAME_RESOLVE_BENEATH)
        )
        return result == 0 ? nil : errno
    }

    /// Makes a folder called `name` directly inside `parent`, with the permissions the user's
    /// umask gives a new folder, as Finder does.
    ///
    /// - Returns: Nil once made, otherwise the `errno` value (`EEXIST` when something has the name).
    static func makeFolder(named name: String, in parent: DirectoryHandle) -> Int32? {
        mkdirat(parent.descriptor, name, 0o777) == 0 ? nil : errno
    }

    private static func outcome(trashError error: any Error) -> CleanupItemOutcome {
        if let cocoaError = error as? CocoaError {
            switch cocoaError.code {
            case .fileNoSuchFile, .fileReadNoSuchFile:
                return .skipped(.notFound)
            case .fileWriteNoPermission, .fileReadNoPermission:
                return .failed(.accessDenied)
            case .fileWriteVolumeReadOnly:
                return .failed(.volumeReadOnly)
            case .featureUnsupported:
                return .failed(.trashUnavailable)
            default:
                break
            }
            if let posixError = cocoaError.underlying as? POSIXError, let mapped = outcome(posixError: posixError) {
                return mapped
            }
        }
        if let posixError = error as? POSIXError, let mapped = outcome(posixError: posixError) {
            return mapped
        }
        let nsError = error as NSError
        return .failed(.other(domain: nsError.domain, code: nsError.code, description: error.localizedDescription))
    }

    private static func outcome(posixError error: POSIXError) -> CleanupItemOutcome? {
        switch error.code {
        case .ENOENT:
            .skipped(.notFound)
        case .EPERM, .EACCES:
            .failed(.accessDenied)
        case .EROFS:
            .failed(.volumeReadOnly)
        default:
            nil
        }
    }
}
