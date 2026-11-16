import Darwin
import FileStoreCore
import Foundation

/// What the disk image tests need besides the engine: what is attached now, attaching an image the
/// way a user opening it would (for the cases where someone else has it open), a licence image,
/// and a look at a folder deep enough to show that nothing in it changed.
enum DiskImages {
    /// The device and the files of every image attached now, from `hdiutil info`.
    static func attached() throws -> [(device: String, inode: UInt64?, mountPoints: [String])] {
        let output = try CommandLineTool.run("/usr/bin/hdiutil", ["info", "-plist"])
        let plist = try PropertyListSerialization.propertyList(from: Data(output.utf8), options: [], format: nil)
        let images = (plist as? [String: Any])?["images"] as? [[String: Any]] ?? []
        return images.map { image in
            let entities = image["system-entities"] as? [[String: Any]] ?? []
            let devices = entities.compactMap { $0["dev-entry"] as? String }
            let path = image["image-path"] as? String ?? ""
            var status = stat()
            let inode = stat(path, &status) == 0 ? UInt64(status.st_ino) : nil
            return (devices.first { $0.wholeMatch(of: #/\/dev\/disk[0-9]+/#) != nil } ?? "", inode, entities.compactMap { $0["mount-point"] as? String })
        }
    }

    /// True when the image file at `url` is attached.
    static func isAttached(_ url: URL) throws -> Bool {
        let inode = try inode(of: url)
        return try attached().contains { $0.inode == inode }
    }

    /// True when anything is mounted inside `folder`.
    static func anythingMounted(inside folder: URL) throws -> Bool {
        let prefix = realPath(folder) + "/"
        return try attached().contains { image in image.mountPoints.contains { $0.hasPrefix(prefix) } }
    }

    /// Attaches `image` read-only and hidden, mounted at `mountPoint` or at a random folder inside
    /// `randomIn`, writing nothing into it, as a test's stand-in for a user who opened it. Returns
    /// the whole disk, to detach with `detach`.
    static func attach(_ image: URL, mountPoint: URL? = nil, randomIn folder: URL? = nil) throws -> String {
        var arguments = ["attach", "-readonly", "-nobrowse", "-noverify", "-noautofsck", "-noautoopen", "-plist"]
        if let mountPoint {
            arguments += ["-mountpoint", mountPoint.path(percentEncoded: false)]
        } else if let folder {
            arguments += ["-mountrandom", folder.path(percentEncoded: false)]
        }
        let output = try CommandLineTool.run("/usr/bin/hdiutil", arguments + [image.path(percentEncoded: false)])
        // Standard error comes first in the combined output: the deprecation warning.
        guard let start = output.range(of: "<?xml") else {
            throw CommandLineTool.Failure(tool: "hdiutil", status: 0, output: output)
        }
        let plist = try PropertyListSerialization.propertyList(from: Data(output[start.lowerBound...].utf8), options: [], format: nil)
        let entities = (plist as? [String: Any])?["system-entities"] as? [[String: Any]] ?? []
        guard let disk = entities.compactMap({ $0["dev-entry"] as? String }).first(where: { $0.wholeMatch(of: #/\/dev\/disk[0-9]+/#) != nil }) else {
            throw CommandLineTool.Failure(tool: "hdiutil", status: 0, output: output)
        }
        return disk
    }

    static func detach(_ disk: String) {
        _ = try? CommandLineTool.run("/usr/sbin/diskutil", ["eject", disk])
    }

    /// A copy of `image` that asks to accept a licence agreement before it opens, made with the
    /// deprecated `hdiutil udifrez`, as installer images carry one.
    static func licensedCopy(of image: URL, to copy: URL, staging: URL) throws {
        try FileManager.default.copyItem(at: image, to: copy)
        func resource(_ data: Data) -> [String: Any] {
            ["Attributes": "0x0000", "Data": data, "ID": "5000", "Name": ""]
        }
        let lpic = Data([0, 0, 0, 1, 0, 0, 0, 0, 0, 0])
        let strings = ["English", "Agree", "Disagree", "Print", "Save...", "Click Agree to use this test image."]
        var list = Data([0, UInt8(strings.count)])
        for string in strings {
            list.append(UInt8(string.utf8.count))
            list.append(contentsOf: string.utf8)
        }
        let resources: [String: Any] = [
            "LPic": [resource(lpic)],
            "STR#": [resource(list)],
            "TEXT": [resource(Data("TEST LICENCE. Not a real agreement.".utf8))],
        ]
        let xml = staging.appending(path: "licence.xml")
        try PropertyListSerialization.data(fromPropertyList: resources, format: .xml, options: 0).write(to: xml)
        try CommandLineTool.run("/usr/bin/hdiutil", ["udifrez", copy.path(percentEncoded: false), "-xml", xml.path(percentEncoded: false)])
    }

    /// Every entry under `folder`, its own attributes' names included: what any write, rename or
    /// attribute change would show, as the status-change time moves with an attribute.
    static func deepSnapshot(of folder: URL) -> [String: String] {
        var entries: [String: String] = [:]
        let enumerator = FileManager.default.enumerator(atPath: folder.path(percentEncoded: false))
        let names = ["."] + ((enumerator?.allObjects as? [String]) ?? [])
        for name in names {
            let path = folder.appending(path: name).path(percentEncoded: false)
            var status = stat()
            guard lstat(path, &status) == 0 else { continue }
            var buffer = [CChar](repeating: 0, count: 4_096)
            let length = listxattr(path, &buffer, buffer.count, XATTR_NOFOLLOW)
            let attributes = length > 0 ? String(decoding: buffer.prefix(length).map { UInt8(bitPattern: $0) }, as: UTF8.self) : ""
            entries[name] = "\(status.st_ino) \(status.st_size) \(status.st_mtimespec.tv_sec).\(status.st_mtimespec.tv_nsec) \(status.st_ctimespec.tv_sec).\(status.st_ctimespec.tv_nsec) \(attributes)"
        }
        return entries
    }

    /// A folder that is the tests' own and private, as the mount folder's root must be.
    static func privateFolder(_ url: URL) throws -> URL {
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        return url
    }

    static func realPath(_ url: URL) -> String {
        guard let resolved = realpath(url.path(percentEncoded: false), nil) else {
            return url.path(percentEncoded: false)
        }
        defer { free(resolved) }
        return String(cString: resolved)
    }

    private static func inode(of url: URL) throws -> UInt64 {
        var status = stat()
        guard stat(url.path(percentEncoded: false), &status) == 0 else {
            throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
        }
        return UInt64(status.st_ino)
    }
}

/// Every tool run through a `SystemTool`, for counting what was attached.
final class ToolCalls: Sendable {
    private let log = ConcurrentLog<[String]>()

    var tool: SystemTool {
        SystemTool { [log] executable, arguments in log.append([executable] + arguments) }
    }

    /// How many disk images were attached.
    var attaches: Int {
        log.values.filter { $0.count > 2 && $0[1] == "image" && $0[2] == "attach" }.count
    }
}
