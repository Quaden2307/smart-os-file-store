import Foundation

/// A file's identity that outlasts the app: the UUID of its volume and its number there (the
/// inode). It stays the same when the file is renamed or moved on its volume, and no other file
/// ever takes it over: APFS never hands a number out twice. An app that saves by writing a new file
/// and swapping it in (a safe save, or an atomic write) gives the file a new number.
///
/// The device number `lstat` reports is not part of it, since it can change when a disk is mounted
/// again (decision record 0009).
public struct PersistentFileIdentity: Sendable, Hashable {
    public let volumeUUID: String
    public let fileNumber: UInt64

    public init(volumeUUID: String, fileNumber: UInt64) {
        self.volumeUUID = volumeUUID
        self.fileNumber = fileNumber
    }
}

/// The volume a folder is on, as far as identities need it. Read once per scan, run or load of the
/// Kept list, never per item.
struct VolumeIdentity: Sendable {
    /// The device number the volume has while it stays mounted.
    let device: dev_t

    /// Nil when the volume has no UUID or does not keep file numbers across mounts: its items then
    /// have no identity, and their paths stand in.
    let uuid: String?

    /// The kernel's ID for the mounted volume (`statfs`'s `f_fsid`), to look a number up by.
    private let fileSystemID: (Int32, Int32)

    /// The volume `folderPath` is on, following the folder itself if it is a link (Downloads can
    /// be). Nil when it could not be read.
    static func of(folderPath: String) -> VolumeIdentity? {
        guard let status = try? FileStatus.of(path: folderPath, followingLinks: true), status.isDirectory else {
            return nil
        }
        var volume = statfs()
        guard statfs(folderPath, &volume) == 0 else {
            return nil
        }
        // `stat` and `statfs` follow a link; resource values could describe the link itself, so they
        // are read for where it leads. A URL made here holds no values cached earlier.
        let url = URL(filePath: folderPath, directoryHint: .isDirectory).resolvingSymlinksInPath()
        guard let values = try? url.resourceValues(forKeys: [.volumeUUIDStringKey, .volumeSupportsPersistentIDsKey]) else {
            return nil
        }
        return VolumeIdentity(
            device: status.identity.device,
            uuid: values.volumeSupportsPersistentIDs == true ? values.volumeUUIDString : nil,
            fileSystemID: (volume.f_fsid.val.0, volume.f_fsid.val.1)
        )
    }

    /// The identity of the item `status` describes: nil when it is on another volume (a disk mounted
    /// inside the folder), or when this volume gives its items none.
    func identity(of status: FileStatus) -> PersistentFileIdentity? {
        guard let uuid, status.identity.device == device else {
            return nil
        }
        return PersistentFileIdentity(volumeUUID: uuid, fileNumber: UInt64(status.identity.inode))
    }

    /// Whether anything on this volume still has `number`: false only when the system says nothing
    /// does, nil when it could not tell. Where the item is now is read and thrown away; it is never
    /// logged.
    func fileExists(number: UInt64) -> Bool? {
        var fsid = fsid_t(val: fileSystemID)
        var path = [CChar](repeating: 0, count: Int(MAXPATHLEN))
        if fsgetpath(&path, path.count, &fsid, number) >= 0 {
            return true
        }
        return errno == ENOENT ? false : nil
    }

    /// Where the item with `number` is on this volume now. Nil when nothing has the number, or the
    /// system could not tell.
    func path(ofNumber number: UInt64) -> String? {
        var fsid = fsid_t(val: fileSystemID)
        var path = [CChar](repeating: 0, count: Int(MAXPATHLEN))
        guard fsgetpath(&path, path.count, &fsid, number) >= 0 else {
            return nil
        }
        return String(decoding: path.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }, as: UTF8.self)
    }
}
