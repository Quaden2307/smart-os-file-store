import Darwin
import Foundation

/// Proof that a change is to the activity log's own storage. Only `ActivityLogStorage` can make
/// one, and the `DiskChange` calls for the log's folder and files ask for one, so no other code can
/// use them on a user's files.
struct StoragePermit {
    fileprivate init() {}
}

/// The activity log's own files: which folders and which file it needs, in what order they are
/// made, and how a damaged database is set aside. This decides names and order only; `DiskChange`
/// makes every change, and none of them can remove or replace anything.
enum ActivityLogStorage {
    /// The files SQLite keeps beside a database, by what it adds to the database's name.
    static let sideFileSuffixes = ["-wal", "-shm", "-journal"]

    /// How many names are tried for a database set aside within the same second.
    private static let asideNameAttempts = 100

    /// Makes sure the log's folder and its database file exist, open to their owner only. A new
    /// database file is made empty, before SQLite opens it, so the file is never there with wider
    /// permissions, and SQLite gives its side files the permissions of the database.
    ///
    /// - Returns: The database's path, or nil for a log in memory.
    static func prepare(_ location: ActivityLogLocation) throws(ActivityLogError) -> String? {
        guard let databaseURL = location.databaseURL else {
            return nil
        }
        guard let folder = try openFolder(of: location, makingMissingFolders: true) else {
            throw .unreadable(code: ENOENT)
        }
        let name = ActivityLogLocation.fileName
        if let failure = DiskChange.makeEmptyPrivateFile(named: name, in: folder, permit: StoragePermit()), failure != EEXIST {
            throw .unreadable(code: failure)
        }
        // Whether it was made a moment ago or long ago, what sits at the name must be a file of its
        // own: never a link to a database somewhere else, and never a folder.
        guard let status = try? folder.status(of: name), status.isRegularFile, !status.isSymbolicLink else {
            throw .unreadable(code: EFTYPE)
        }
        return databaseURL.path(percentEncoded: false)
    }

    /// Gives the database and its side files new names in the same folder, so a fresh log can be
    /// made in their place. The files are kept exactly as they are.
    ///
    /// - Returns: Where the database is now, or nil when there was no database to set aside.
    static func setAside(_ location: ActivityLogLocation, now: Date) throws(ActivityLogError) -> URL? {
        guard let folderURL = location.folderURL,
              let folder = try openFolder(of: location, makingMissingFolders: false) else {
            return nil
        }
        let permit = StoragePermit()
        let name = ActivityLogLocation.fileName
        let stamp = timestamp(now)
        for attempt in 0..<asideNameAttempts {
            let asideName = attempt == 0 ? "FileStore.damaged-\(stamp).sqlite" : "FileStore.damaged-\(stamp)-\(attempt).sqlite"
            // A name is free only when neither it nor any side file of it is taken. The renames are
            // exclusive whatever this finds, so a name taken meanwhile is an error, not a loss.
            let isTaken = ([""] + sideFileSuffixes).contains { (try? folder.status(of: asideName + $0)) != nil }
            if isTaken {
                continue
            }
            // Side files first. A write-ahead file left beside a new database of the same name
            // would be taken for that database's own.
            var moved: [String] = []
            do throws(ActivityLogError) {
                for suffix in sideFileSuffixes {
                    if let failure = DiskChange.renameLogFile(name + suffix, to: asideName + suffix, in: folder, permit: permit) {
                        guard failure == ENOENT else {
                            throw .unreadable(code: failure)
                        }
                    } else {
                        moved.append(suffix)
                    }
                }
                if let failure = DiskChange.renameLogFile(name, to: asideName, in: folder, permit: permit) {
                    guard failure == ENOENT else {
                        throw .unreadable(code: failure)
                    }
                    // Side files without their database: they stay set aside, where no new
                    // database can take them for its own.
                    return nil
                }
            } catch {
                // The database stays where it was, so its side files go back beside it: without its
                // write-ahead file it would open without its latest rows. One that cannot be put
                // back stays under the new name, kept.
                for suffix in moved {
                    _ = DiskChange.renameLogFile(asideName + suffix, to: name + suffix, in: folder, permit: permit)
                }
                throw error
            }
            return folderURL.appending(path: asideName, directoryHint: .notDirectory)
        }
        throw .unreadable(code: EEXIST)
    }

    /// Opens the log's folder: the root as it is (Application Support or the temporary directory,
    /// either of which may be a link the user set up), then each of the log's own folders inside
    /// the one before, never through a link.
    ///
    /// - Returns: The folder, or nil when it does not exist and missing folders are not to be made.
    private static func openFolder(of location: ActivityLogLocation, makingMissingFolders: Bool) throws(ActivityLogError) -> DirectoryHandle? {
        guard let rootURL = location.rootURL else {
            return nil
        }
        var handle: DirectoryHandle
        do throws(DirectoryHandle.OpenFailure) {
            handle = try DirectoryHandle.open(path: rootURL.path(percentEncoded: false))
        } catch {
            throw unreadable(error)
        }
        for name in location.folderNames {
            do throws(DirectoryHandle.OpenFailure) {
                handle = try handle.openFolder(named: name)
            } catch {
                guard error == .notFound else {
                    throw unreadable(error)
                }
                guard makingMissingFolders else {
                    return nil
                }
                if let failure = DiskChange.makePrivateFolder(named: name, in: handle, permit: StoragePermit()), failure != EEXIST {
                    throw .unreadable(code: failure)
                }
                do throws(DirectoryHandle.OpenFailure) {
                    handle = try handle.openFolder(named: name)
                } catch {
                    throw unreadable(error)
                }
            }
        }
        return handle
    }

    private static func unreadable(_ failure: DirectoryHandle.OpenFailure) -> ActivityLogError {
        switch failure {
        case .notFound:
            .unreadable(code: ENOENT)
        case .symbolicLink:
            .unreadable(code: ELOOP)
        case .notAFolder:
            .unreadable(code: ENOTDIR)
        case .accessDenied:
            .unreadable(code: EACCES)
        case .other(let code):
            .unreadable(code: code)
        }
    }

    /// `20261114-190530`, in the Mac's own time zone, so the name shows the time its user saw. It
    /// sorts by time and holds no character a file name cannot.
    private static func timestamp(_ date: Date) -> String {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = .current
        let parts = calendar.dateComponents([.year, .month, .day, .hour, .minute, .second], from: date)
        return String(
            format: "%04d%02d%02d-%02d%02d%02d",
            parts.year ?? 0, parts.month ?? 0, parts.day ?? 0, parts.hour ?? 0, parts.minute ?? 0, parts.second ?? 0
        )
    }
}
