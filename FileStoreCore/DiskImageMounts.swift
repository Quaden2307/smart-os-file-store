import Darwin
import Foundation
import os

/// The proof that a change is the folder disk images are mounted in, which only this file can make.
struct MountFolderPermit {
    fileprivate init() {}
}

/// Where Remove Used Installers mounts disk images, for the whole process: two slots,
/// `<root>/<pid>/1` and `/2`, so at most two images are mounted at once, and the sweep that
/// detaches what a crashed run left mounted (decision record 0013).
///
/// The root is private: a real folder, not a link, this user's, with nothing for anyone else. Each
/// process has its own folder in it, by process ID, so two copies of the app, or the tests, never
/// touch each other's mounts. Empty folders of processes that are gone stay; nothing here removes.
public actor DiskImageMounts {
    private static let logger = Logger(subsystem: "com.quaden2307.FileStoreCore", category: "DiskImageMounts")

    /// The app's: `$TMPDIR/com.quaden2307.SmartOSFileStore.mounts`.
    public static let shared = DiskImageMounts(
        root: FileManager.default.temporaryDirectory.appending(path: "com.quaden2307.SmartOSFileStore.mounts", directoryHint: .isDirectory)
    )

    public nonisolated let root: URL
    let tool: SystemTool
    private var preparation: Task<[URL]?, Never>?
    private var freeSlots: [URL]?
    private var waiting: [CheckedContinuation<URL, Never>] = []
    private var waitingForIdle: [CheckedContinuation<Void, Never>] = []

    public init(root: URL, tool: SystemTool = SystemTool()) {
        self.root = root
        self.tool = tool
    }

    /// Makes the folders and detaches leftovers, once per process; later calls wait for the first.
    /// The app calls it at launch, so planning never makes a folder. False when the folder cannot
    /// be used, so no disk image is read.
    @discardableResult
    public func prepare() async -> Bool {
        if preparation == nil {
            let root = root
            let tool = tool
            preparation = Task { await Self.makeFolders(root: root, tool: tool) }
        }
        return await preparation?.value != nil
    }

    /// A free slot, waiting for one when both are in use. Nil when the folder was never prepared or
    /// cannot be used: planning makes no folder of its own.
    func acquireSlot() async -> URL? {
        guard let slots = await preparation?.value else {
            return nil
        }
        if freeSlots == nil {
            freeSlots = slots
        }
        if let slot = freeSlots?.popLast() {
            return slot
        }
        return await withCheckedContinuation { waiting.append($0) }
    }

    /// Gives `slot` back, once what was mounted there is detached.
    func release(_ slot: URL) {
        if waiting.isEmpty {
            freeSlots?.append(slot)
        } else {
            waiting.removeFirst().resume(returning: slot)
        }
        if freeSlots?.count == 2 {
            waitingForIdle.forEach { $0.resume() }
            waitingForIdle.removeAll()
        }
    }

    /// Returns once nothing of this process's is attached: a search cancelled a moment ago may still
    /// be ejecting, and a new search must not take its image for one someone has open.
    func waitUntilIdle() async {
        guard let free = freeSlots, free.count < 2 else {
            return
        }
        await withCheckedContinuation { waitingForIdle.append($0) }
    }

    // MARK: - The folders and the sweep

    /// Makes `root`, its folder for this process and the two slots, checks them, and detaches what
    /// earlier processes left mounted there. The slots' paths are canonical (`/private/var/…`),
    /// as `hdiutil info` reports mount points.
    private static func makeFolders(root: URL, tool: SystemTool) async -> [URL]? {
        let parentPath = root.deletingLastPathComponent().path(percentEncoded: false)
        let process = String(getpid())
        guard let parent = try? DirectoryHandle.open(path: parentPath),
              let rootFolder = privateFolder(named: root.lastPathComponent, in: parent),
              let processFolder = privateFolder(named: process, in: rootFolder),
              let canonicalRoot = FileStatus.realPath(of: root) else {
            logger.error("The folder for reading disk images could not be made or is not private; no disk image is read")
            return nil
        }
        // Before the slots are looked at: a run with this same process ID may have left a volume
        // mounted in one, whose root is not this folder.
        await sweep(root: canonicalRoot, tool: tool)
        guard privateFolder(named: "1", in: processFolder) != nil, privateFolder(named: "2", in: processFolder) != nil else {
            logger.error("The folder for reading disk images could not be made or is not private; no disk image is read")
            return nil
        }
        let folder = URL(filePath: canonicalRoot, directoryHint: .isDirectory).appending(path: process, directoryHint: .isDirectory)
        return [folder.appending(path: "2", directoryHint: .isDirectory), folder.appending(path: "1", directoryHint: .isDirectory)]
    }

    /// The folder `name` in `parent`, made if missing, when it is a real folder of this user's
    /// that nobody else may use. One that is not is refused, never repaired.
    private static func privateFolder(named name: String, in parent: DirectoryHandle) -> DirectoryHandle? {
        if let failure = DiskChange.makePrivateFolder(named: name, in: parent, permit: MountFolderPermit()), failure != EEXIST {
            return nil
        }
        guard let folder = try? parent.openFolder(named: name) else {
            return nil
        }
        var status = stat()
        guard fstat(folder.descriptor, &status) == 0, status.st_uid == getuid(), status.st_mode & 0o077 == 0 else {
            return nil
        }
        return folder
    }

    /// Detaches every image mounted in the folder of a process that is gone, or of this process
    /// before it has mounted anything (a process ID used again). Nothing else is touched.
    private static func sweep(root: String, tool: SystemTool) async {
        guard let attached = await AttachedImages.read(tool: tool, ignoringCancellation: true) else {
            logger.notice("Could not list attached disk images, so leftovers were not looked for")
            return
        }
        var detached = 0
        for image in attached.images {
            let owners = image.mountPoints.compactMap { owner(of: $0, root: root) }
            guard !owners.isEmpty, owners.allSatisfy(isGoneOrThisProcess), let disk = image.wholeDisk else {
                continue
            }
            if await DiskImageReader.eject(disk, tool: tool) {
                detached += 1
            }
        }
        if detached > 0 {
            logger.info("Detached \(detached) disk images left mounted by an earlier run")
        }
    }

    /// The process ID whose folder `mountPoint` is in, when it is inside `root`.
    private static func owner(of mountPoint: String, root: String) -> pid_t? {
        guard mountPoint.hasPrefix(root + "/") else {
            return nil
        }
        return mountPoint.dropFirst(root.count + 1).split(separator: "/").first.flatMap { pid_t($0) }
    }

    private static func isGoneOrThisProcess(_ process: pid_t) -> Bool {
        process == getpid() || (kill(process, 0) == -1 && errno == ESRCH)
    }
}

/// The disk images attached now, as `hdiutil info -plist` lists them. `hdiutil` is deprecated in
/// macOS 27, but `diskutil image` has no listing.
struct AttachedImages: Sendable {
    struct Image: Sendable, Hashable {
        let imagePath: String
        let devices: [String]
        let mountPoints: [String]

        /// The image's whole disk (`/dev/disk4`), which ejecting detaches with its volumes.
        var wholeDisk: String? {
            devices.first { $0.wholeMatch(of: #/\/dev\/disk[0-9]+/#) != nil }
        }
    }

    let images: [Image]

    /// - Parameter ignoringCancellation: For cleanup that must happen after a cancel.
    static func read(tool: SystemTool, ignoringCancellation: Bool = false) async -> AttachedImages? {
        guard let output = try? await tool.run("/usr/bin/hdiutil", ["info", "-plist"], timeout: .seconds(10), ignoringCancellation: ignoringCancellation),
              output.succeeded else {
            return nil
        }
        return parse(output.standardOutput)
    }

    static func parse(_ data: Data) -> AttachedImages? {
        guard let plist = try? PropertyListSerialization.propertyList(from: data, options: [], format: nil),
              let dictionary = plist as? [String: Any],
              let images = dictionary["images"] as? [[String: Any]] else {
            return nil
        }
        return AttachedImages(images: images.map { image in
            let entities = image["system-entities"] as? [[String: Any]] ?? []
            return Image(
                imagePath: image["image-path"] as? String ?? "",
                devices: entities.compactMap { $0["dev-entry"] as? String },
                mountPoints: entities.compactMap { $0["mount-point"] as? String }
            )
        })
    }

    /// Whether the file `identity` names is attached: true or false, or nil when an attached image's
    /// path leads nowhere (the image was renamed or moved while attached, and `hdiutil` still gives
    /// the old path), so it could be this file.
    func contains(_ identity: FileIdentity) -> Bool? {
        var unknown = false
        // Only an image attached from a file path can be a file here.
        for image in images where image.imagePath.hasPrefix("/") {
            guard let status = try? FileStatus.of(path: image.imagePath, followingLinks: true) else {
                unknown = true
                continue
            }
            if status.identity == identity {
                return true
            }
        }
        return unknown ? nil : false
    }
}
