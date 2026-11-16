import Darwin
import Foundation

/// The one place in the engine that changes anything on disk. For a user's files there are five
/// ways, and each needs a `ChangePermit`, the proof that the activity log already says the change is
/// about to happen: move an item to the Trash, give it a new name or folder without ever replacing
/// what is there, make a folder for a move, set a moved item's Date Added back, and, for undo
/// only, put an item back from the Trash without ever replacing what is there. For the activity log's own storage there are three
/// more, each needing a `StoragePermit`, which only the log's storage can make: make its folder,
/// make its empty database file, and give one of its files a new name. And one for the folder disk
/// images are read in, needing a `MountFolderPermit`: make it. Nothing is ever deleted and
/// nothing is ever replaced; a source-scanning test keeps every file-changing call in this file.
/// The executor decides whether a change may happen; this only carries it out.
enum DiskChange {
    // MARK: - A user's files

    /// Moves the item at `url` to the Trash, from where the user can put it back.
    static func trash(_ url: URL, permit: ChangePermit) -> CleanupItemOutcome {
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
    static func renameWithoutReplacing(
        _ name: String,
        in source: DirectoryHandle,
        to newName: String,
        in destination: DirectoryHandle,
        permit: ChangePermit
    ) -> Int32? {
        exclusiveRename(name, in: source, to: newName, in: destination)
    }

    /// Moves the item at `trashPath`, directly inside the Trash, back into `folder` under `name`:
    /// undo of a move to the Trash. The same exclusive rename, so when anything already has the name
    /// it fails with `EEXIST` and changes nothing. Without Full Disk Access the Trash folder itself
    /// cannot be opened, only the items in it, so the item is named by its path, on which no
    /// symbolic link is followed; the destination is one name inside the scanned folder's handle.
    ///
    /// - Returns: Nil once moved back, otherwise the `errno` value.
    static func putBackFromTrash(_ trashPath: String, to name: String, in folder: DirectoryHandle, permit: ChangePermit) -> Int32? {
        exclusiveRename(from: AT_FDCWD, trashPath, to: folder.descriptor, name, resolvingBeneath: false)
    }

    /// Makes a folder called `name` directly inside `parent`, with the permissions the user's
    /// umask gives a new folder, as Finder does.
    ///
    /// - Returns: Nil once made, otherwise the `errno` value (`EEXIST` when something has the name).
    static func makeFolder(named name: String, in parent: DirectoryHandle, permit: ChangePermit) -> Int32? {
        makeFolder(named: name, in: parent, permissions: 0o777)
    }

    /// Sets the Date Added of the item `name` in `folder` back to `time`, as it was before a move:
    /// the volume sets it to the moment an item arrives in another folder, which would make a file
    /// moved out and back look new. No link is followed. Changes no content and no other date.
    ///
    /// - Returns: Nil once set, otherwise the `errno` value.
    static func setDateAdded(of name: String, in folder: DirectoryHandle, to time: timespec, permit: ChangePermit) -> Int32? {
        var request = attrlist()
        request.bitmapcount = u_short(ATTR_BIT_MAP_COUNT)
        request.commonattr = attrgroup_t(ATTR_CMN_ADDEDTIME)
        var time = time
        let result = setattrlistat(folder.descriptor, name, &request, &time, MemoryLayout<timespec>.size, UInt32(FSOPT_NOFOLLOW))
        return result == 0 ? nil : errno
    }

    // MARK: - The activity log's own storage

    /// Makes a folder for the activity log, open to its owner only.
    ///
    /// - Returns: Nil once made, otherwise the `errno` value (`EEXIST` when something has the name).
    static func makePrivateFolder(named name: String, in parent: DirectoryHandle, permit: StoragePermit) -> Int32? {
        makeFolder(named: name, in: parent, permissions: 0o700)
    }

    // MARK: - The folder disk images are read in

    /// Makes a folder that Remove Used Installers mounts disk images in, read-only, open to its
    /// owner only. The app's own folder, never a user's.
    ///
    /// - Returns: Nil once made, otherwise the `errno` value (`EEXIST` when something has the name).
    static func makePrivateFolder(named name: String, in parent: DirectoryHandle, permit: MountFolderPermit) -> Int32? {
        makeFolder(named: name, in: parent, permissions: 0o700)
    }

    /// Makes an empty file called `name` in `folder`, readable and writable by its owner only, for
    /// SQLite to open as a new database. Exclusive: when anything already has the name, a symbolic
    /// link included, it fails with `EEXIST` and changes nothing. It can never empty or replace a file.
    ///
    /// - Returns: Nil once made, otherwise the `errno` value.
    static func makeEmptyPrivateFile(named name: String, in folder: DirectoryHandle, permit: StoragePermit) -> Int32? {
        let descriptor = openat(folder.descriptor, name, O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC | O_RDONLY, 0o600)
        guard descriptor >= 0 else {
            return errno
        }
        close(descriptor)
        return nil
    }

    /// Gives the log's file `name` in `folder` the name `newName` there: to set a database aside,
    /// or to put a side file back. The same exclusive rename a user's file gets: it never replaces
    /// anything.
    ///
    /// - Returns: Nil once renamed, otherwise the `errno` value.
    static func renameLogFile(_ name: String, to newName: String, in folder: DirectoryHandle, permit: StoragePermit) -> Int32? {
        exclusiveRename(name, in: folder, to: newName, in: folder)
    }

    // MARK: - The calls

    private static func exclusiveRename(_ name: String, in source: DirectoryHandle, to newName: String, in destination: DirectoryHandle) -> Int32? {
        exclusiveRename(from: source.descriptor, name, to: destination.descriptor, newName, resolvingBeneath: true)
    }

    /// The one rename call. Always exclusive and never through a link. `resolvingBeneath` keeps each
    /// name inside its folder's handle; a source named by an absolute path has no handle to stay in.
    private static func exclusiveRename(
        from sourceDescriptor: Int32,
        _ source: String,
        to destinationDescriptor: Int32,
        _ destination: String,
        resolvingBeneath: Bool
    ) -> Int32? {
        let beneath: Int32 = resolvingBeneath ? RENAME_RESOLVE_BENEATH : 0
        let result = renameatx_np(
            sourceDescriptor,
            source,
            destinationDescriptor,
            destination,
            UInt32(RENAME_EXCL | RENAME_NOFOLLOW_ANY | beneath)
        )
        return result == 0 ? nil : errno
    }

    private static func makeFolder(named name: String, in parent: DirectoryHandle, permissions: mode_t) -> Int32? {
        mkdirat(parent.descriptor, name, permissions) == 0 ? nil : errno
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
