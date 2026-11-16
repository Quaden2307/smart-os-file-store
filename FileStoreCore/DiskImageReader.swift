import Foundation
import os

/// What reading one disk image gave.
public enum DiskImageReading: Sendable, Hashable {
    case facts(InstallerFacts)
    /// Someone else has it attached; it was left exactly as it was.
    case attachedElsewhere
    /// The file changed while it was read, so what was read is dropped.
    case changed
    /// The file itself could not be looked at.
    case notReadable(CleanupSkipReason)
    /// The private folder images are mounted in cannot be used.
    case unavailable
    case cancelled
}

/// Reads the top-level apps of a disk image without running anything on it and without writing to
/// it (decision record 0013):
/// 1. The encryption and licence checks, from the file's own bytes (`DiskImageHeader`).
/// 2. `diskutil image attach --readOnly --noMount`, with empty input, so no password is asked for.
///    Neither the system's verification nor its file-system check runs, since both record their
///    result in the image file.
/// 3. The system's own checker, read-only (`fsck_hfs -fn` or `fsck_apfs -n`).
/// 4. `diskutil mount readOnly nobrowse` at one of this process's two private slots: hidden from
///    Finder, never opened, `nosuid` and `nodev` as for any disk image.
/// 5. The top level is listed, and each app's `Info.plist` is read through one descriptor, with no
///    link followed. Then it is always ejected, after an error or a cancel too.
///
/// A failure that says nothing about the file (a tool that could not start, a mount the system
/// refused) is `couldNotOpen`, which is never cached, so the image is tried again next time.
public enum DiskImageReader {
    private static let logger = Logger(subsystem: "com.quaden2307.FileStoreCore", category: "DiskImageReader")

    static let attachTimeout: Duration = .seconds(30)
    static let checkTimeout: Duration = .seconds(120)
    static let mountTimeout: Duration = .seconds(30)
    static let ejectTimeout: Duration = .seconds(30)

    /// The most items read at the top of an image.
    static let maximumTopLevelEntries = 1_000

    /// Reads the image at `url`, which is not followed if it is a link.
    ///
    /// - Parameter whileMounted: Called once the image is mounted, before it is read; false makes
    ///   the read fail there, as an error would. For tests.
    @concurrent
    public static func read(
        at url: URL,
        mounts: DiskImageMounts,
        whileMounted: (@Sendable () async -> Bool)? = nil
    ) async -> DiskImageReading {
        let folderPath = url.deletingLastPathComponent().path(percentEncoded: false)
        guard let folder = try? DirectoryHandle.open(path: folderPath) else {
            return .notReadable(.folderUnavailable)
        }
        return await read(named: url.lastPathComponent, in: folder, folderPath: folderPath, mounts: mounts, whileMounted: whileMounted)
    }

    /// Reads the image called `name` in `folder`, whose path is `folderPath`. The file must be the
    /// same, unchanged, before and after: its identity, size, modification date and status change.
    static func read(
        named name: String,
        in folder: DirectoryHandle,
        folderPath: String,
        mounts: DiskImageMounts,
        whileMounted: (@Sendable () async -> Bool)? = nil
    ) async -> DiskImageReading {
        let before: FileStatus
        do throws(FileStatus.Failure) {
            before = try folder.status(of: name)
        } catch {
            return .notReadable(CleanupSkipReason(statusFailure: error))
        }
        guard before.isRegularFile else {
            return .notReadable(.notARegularFile)
        }
        if before.isDataless {
            return .notReadable(.notDownloaded)
        }

        let reading: DiskImageReading
        switch header(named: name, in: folder, expecting: before) {
        case .success(.encrypted):
            reading = .facts(.unreadable(.passwordProtected))
        case .success(.licenseAgreement):
            reading = .facts(.unreadable(.licenseAgreement))
        case .success(.damaged):
            reading = .facts(.unreadable(.damaged))
        case .success(.tooLarge):
            reading = .facts(.unreadable(.tooLarge))
        case .success(.plain):
            guard let slot = await mounts.acquireSlot() else {
                return .unavailable
            }
            reading = await attachAndRead(
                path: folderPath + "/" + name,
                identity: before.identity,
                slot: slot,
                tool: mounts.tool,
                whileMounted: whileMounted
            )
            await mounts.release(slot)
        case .failure(let failure):
            return failure.reading
        }

        guard let after = try? folder.status(of: name), isUnchanged(after, since: before) else {
            return .changed
        }
        return reading
    }

    /// Ejects `disk` and every volume on it: three tries half a second apart, then forced. A cancel
    /// does not stop it. True once ejected.
    static func eject(_ disk: String, tool: SystemTool) async -> Bool {
        for attempt in 0..<4 {
            let arguments = attempt < 3 ? ["eject", disk] : ["eject", "force", disk]
            if let output = try? await tool.run("/usr/sbin/diskutil", arguments, timeout: ejectTimeout, ignoringCancellation: true),
               output.succeeded {
                return true
            }
            if attempt < 3 {
                await pause(.milliseconds(500))
            }
        }
        logger.error("A disk image could not be ejected; it is detached at the next launch")
        return false
    }

    // MARK: - Steps

    private static func header(named name: String, in folder: DirectoryHandle, expecting before: FileStatus) -> Result<DiskImageHeader.Finding, DiskImageReadingFailure> {
        do throws(ZipListing.Failure) {
            let file = try ZipArchiveFile.open(named: name, in: folder)
            guard try file.status().identity == before.identity else {
                return .failure(DiskImageReadingFailure(.changed))
            }
            return .success(try DiskImageHeader.inspect(file))
        } catch {
            switch error {
            case .unlistable:
                // Bytes the header names are missing: cut short.
                return .success(.damaged)
            default:
                return .failure(DiskImageReadingFailure(CleanupSkipReason(zipFailure: error).map(DiskImageReading.notReadable) ?? .cancelled))
            }
        }
    }

    private static func attachAndRead(
        path: String,
        identity: FileIdentity,
        slot: URL,
        tool: SystemTool,
        whileMounted: (@Sendable () async -> Bool)?
    ) async -> DiskImageReading {
        let attach: SystemTool.Output
        do throws(SystemTool.Failure) {
            attach = try await tool.run(
                "/usr/sbin/diskutil",
                ["image", "attach", "--plist", "--stdinpassphrase", "--readOnly", "--noMount", path],
                timeout: attachTimeout
            )
        } catch {
            // A timeout or a cancel may still have attached it, out of sight.
            await ejectUnmountedAttachments(of: identity, tool: tool)
            switch error {
            case .cancelled:
                return .cancelled
            case .timedOut:
                return .facts(.unreadable(.timedOut))
            case .launchFailed, .outputTooLarge:
                return .facts(.unreadable(.couldNotOpen))
            }
        }
        guard attach.succeeded else {
            return .facts(.unreadable(problem(fromAttachError: attach.standardError)))
        }
        let entities = Entity.parse(attach.standardOutput)
        guard let disk = entities.first(where: \.isWholeDisk)?.device else {
            await ejectUnmountedAttachments(of: identity, tool: tool)
            return .facts(.unreadable(.couldNotOpen))
        }
        if entities.contains(where: { $0.mountPoint != nil }) {
            return .attachedElsewhere
        }
        let reading = await checkMountAndRead(entities, slot: slot, tool: tool, whileMounted: whileMounted)
        _ = await eject(disk, tool: tool)
        return reading
    }

    private static func checkMountAndRead(
        _ entities: [Entity],
        slot: URL,
        tool: SystemTool,
        whileMounted: (@Sendable () async -> Bool)?
    ) async -> DiskImageReading {
        let volumes = entities.filter { $0.fileSystem != nil }
        guard volumes.count == 1, let volume = volumes.first else {
            return .facts(.unreadable(.damaged))
        }
        let checker: (tool: String, arguments: [String])
        switch volume.fileSystem {
        case "hfs":
            checker = ("/sbin/fsck_hfs", ["-f", "-n", "/dev/r" + volume.device])
        case "apfs":
            // APFS is checked by its container's physical store.
            let stores = entities.filter { $0.contentHint == "Apple_APFS" }
            guard stores.count == 1, let store = stores.first else {
                return .facts(.unreadable(.damaged))
            }
            checker = ("/sbin/fsck_apfs", ["-n", "/dev/r" + store.device])
        default:
            return .facts(.unreadable(.unsupported))
        }
        do throws(SystemTool.Failure) {
            guard try await tool.run(checker.tool, checker.arguments, timeout: checkTimeout).succeeded else {
                return .facts(.unreadable(.damaged))
            }
            let slotPath = slot.path(percentEncoded: false)
            guard try await tool.run(
                "/usr/sbin/diskutil",
                ["mount", "readOnly", "nobrowse", "-mountPoint", slotPath, volume.device],
                timeout: mountTimeout
            ).succeeded else {
                return .facts(.unreadable(.couldNotOpen))
            }
        } catch {
            switch error {
            case .cancelled:
                return .cancelled
            case .timedOut:
                return .facts(.unreadable(.timedOut))
            case .launchFailed, .outputTooLarge:
                return .facts(.unreadable(.couldNotOpen))
            }
        }
        if let whileMounted, !(await whileMounted()) {
            return .facts(.unreadable(.couldNotOpen))
        }
        if Task.isCancelled {
            return .cancelled
        }
        return .facts(readApps(at: slot))
    }

    /// The apps at the top of the volume mounted at `slot`. The handles close before it is ejected.
    private static func readApps(at slot: URL) -> InstallerFacts {
        guard let volume = try? DirectoryHandle.openWithoutFollowing(path: slot.path(percentEncoded: false)),
              let root = try? volume.status(),
              let parent = try? FileStatus.of(path: slot.deletingLastPathComponent().path(percentEncoded: false)),
              // A mount point on the slot's own volume would mean nothing was mounted there.
              root.identity.device != parent.identity.device,
              let names = try? volume.entryNames(limit: maximumTopLevelEntries + 1) else {
            return .unreadable(.couldNotOpen)
        }
        guard names.count <= maximumTopLevelEntries else {
            return .unreadable(.tooLarge)
        }
        let appNames = names.filter(BundleInfo.isAppName).filter { name in
            guard let status = try? volume.status(of: name) else { return false }
            return status.isDirectory && !status.isSymbolicLink
        }
        guard appNames.count <= InstallerFacts.maximumApps else {
            return .unreadable(.tooLarge)
        }
        return .apps(appNames.sorted { $0.localizedStandardCompare($1) == .orderedAscending }.map { name in
            BundleInfo.read(bundleNamed: name, in: volume)
                ?? BundleFacts(name: BundleInfo.appName(ofBundleNamed: name), identifier: nil, shortVersion: nil, build: nil)
        })
    }

    /// Ejects attachments of the file `identity` names that have no volume mounted: what an attach
    /// cut short by a timeout or a cancel may have left. Images skipped as attached never get here.
    private static func ejectUnmountedAttachments(of identity: FileIdentity, tool: SystemTool) async {
        guard let attached = await AttachedImages.read(tool: tool, ignoringCancellation: true) else { return }
        for image in attached.images where image.mountPoints.isEmpty {
            guard let status = try? FileStatus.of(path: image.imagePath, followingLinks: true), status.identity == identity,
                  let disk = image.wholeDisk else {
                continue
            }
            _ = await eject(disk, tool: tool)
        }
    }

    private static func problem(fromAttachError errors: Data) -> InstallerFacts.Problem {
        let text = String(decoding: errors, as: UTF8.self).lowercased()
        if text.contains("passphrase") || text.contains("authentication") {
            return .passwordProtected
        }
        if text.contains("cancel") {
            return .licenseAgreement
        }
        return .damaged
    }

    private static func isUnchanged(_ now: FileStatus, since before: FileStatus) -> Bool {
        now.identity == before.identity && now.isRegularFile && now.sizeInBytes == before.sizeInBytes
            && now.modificationDate == before.modificationDate && now.statusChangeDate == before.statusChangeDate
    }

    /// Waits `duration`, cancelled or not: the pauses between eject attempts must happen.
    private static func pause(_ duration: Duration) async {
        await Task.detached { try? await Task.sleep(for: duration) }.value
    }
}

/// A reading that ends before anything is attached.
private struct DiskImageReadingFailure: Error {
    let reading: DiskImageReading

    init(_ reading: DiskImageReading) {
        self.reading = reading
    }
}

/// One device `diskutil image attach --plist` reports.
private struct Entity {
    let device: String
    let contentHint: String?
    let fileSystem: String?
    let mountPoint: String?

    /// `disk4`, not `disk4s1`.
    var isWholeDisk: Bool {
        device.wholeMatch(of: #/disk[0-9]+/#) != nil
    }

    static func parse(_ data: Data) -> [Entity] {
        guard let plist = try? PropertyListSerialization.propertyList(from: data, options: [], format: nil),
              let dictionary = plist as? [String: Any],
              let entities = dictionary["system-entities"] as? [[String: Any]] else {
            return []
        }
        return entities.compactMap { entity in
            guard let device = entity["dev-entry"] as? String,
                  // Only a plain device name reaches a command line.
                  device.wholeMatch(of: #/disk[0-9]+(s[0-9]+)?/#) != nil else {
                return nil
            }
            return Entity(
                device: device,
                contentHint: entity["content-hint"] as? String,
                fileSystem: entity["filesystem-type"] as? String,
                mountPoint: entity["mount-point"] as? String
            )
        }
    }
}
