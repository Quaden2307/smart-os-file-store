import Foundation
import os

extension InstallerPlanner {
    private static let logger = Logger(subsystem: "com.quaden2307.FileStoreCore", category: "InstallerPlanner")

    /// Plans Remove Used Installers for `records`, from one scan of `folderURL`.
    ///
    /// The installers are chosen first, from the records alone, so a Kept one is never even opened.
    /// Each is then looked at through one handle on the folder, and its facts come from the cache
    /// when the very same file was read before, or are read now: zips and packages one at a time,
    /// disk images at most two at a time (`DiskImageMounts`). An attached disk image is never read
    /// or proposed. Nothing is written: newly read facts go back on the plan, for the app to store.
    ///
    /// - Parameter onProgress: Called with the installers checked of the total: first, then at most
    ///   every 100 ms, and last. It must return quickly.
    /// - Throws: `.cancelled` when the task is cancelled, once nothing is left mounted.
    @concurrent
    public func plan(
        records: [FileRecord],
        in folderURL: URL,
        sources: InstallerSources,
        now: Date = .now,
        onProgress: (@Sendable (CleanupPlanningProgress) -> Void)? = nil
    ) async throws(CleanupPlanningError) -> CleanupPlan {
        let clock = ContinuousClock()
        let start = clock.now
        try Self.throwIfCancelled()

        let inside = DuplicatePlanner.recordsDirectlyInside(folderURL, among: records)
        let installers = candidates(in: inside, now: now).sorted { UnpackedZipPlanner.isOrderedBefore($0.displayName, $1.displayName) }
        var progress = ItemCheckProgress(total: installers.count, onProgress: onProgress)
        progress.report(checked: 0)
        guard !installers.isEmpty else {
            return Self.makePlan(folderURL: folderURL, findings: [])
        }
        let folderPath = folderURL.path(percentEncoded: false)
        guard let folder = try? DirectoryHandle.open(path: folderPath) else {
            Self.logger.error("Could not open the folder to read \(installers.count) installers")
            // A zip is an installer only once its listing shows an app, so none is listed here.
            return Self.makePlan(folderURL: folderURL, findings: installers.map { record in
                (record, Self.kind(ofName: record.displayName) == .zip ? .notProposed : .notChecked(.folderUnavailable))
            })
        }
        let volume = VolumeIdentity.of(folderPath: folderPath)

        // Each installer as it is now, and what is known about it already.
        var outcomes: [Outcome] = installers.map { Self.look(at: $0, in: folder, volume: volume) }
        let cached = await Self.cachedFacts(for: outcomes.compactMap(\.look?.key), in: sources.cache)
        var attached: AttachedImages?
        if installers.contains(where: { Self.kind(ofName: $0.displayName) == .diskImage }) {
            // A search cancelled a moment ago may still be ejecting its images.
            await sources.mounts.waitUntilIdle()
            attached = await AttachedImages.read(tool: sources.mounts.tool)
        }
        var diskImages: [Int] = []
        // A hard link of an image already to be read is the same image: it is read once.
        var sameImage: [Int: Int] = [:]
        var firstByIdentity: [FileIdentity: Int] = [:]
        var checked = 0
        for index in outcomes.indices {
            guard case .looked(let look) = outcomes[index] else {
                checked += 1
                continue
            }
            if look.kind == .diskImage, attached?.contains(look.status.identity) != false {
                outcomes[index] = .done(.notChecked(.diskImageInUse))
            } else if let facts = cached[look.key] {
                outcomes[index] = .read(look, .facts(facts), fresh: false)
            } else if look.kind == .diskImage {
                if let first = firstByIdentity[look.status.identity] {
                    sameImage[index] = first
                } else {
                    firstByIdentity[look.status.identity] = index
                    diskImages.append(index)
                }
                continue
            } else {
                try Self.throwIfCancelled()
                let reading = look.kind == .zip ? Self.readZip(named: look.name, in: folder) : Self.readPackage(named: look.name, in: folder)
                outcomes[index] = .read(look, Self.confirm(reading, of: look, in: folder), fresh: true)
            }
            checked += 1
            progress.report(checked: checked)
        }

        // Disk images, two at a time: each waits for one of the two slots.
        var wasCancelled = false
        let mounts = sources.mounts
        await withTaskGroup(of: (Int, Reading).self) { group in
            for index in diskImages {
                guard case .looked(let look) = outcomes[index] else { continue }
                group.addTask {
                    let reading = await DiskImageReader.read(named: look.name, in: folder, folderPath: folderPath, mounts: mounts)
                    return (index, Self.confirm(Self.reading(reading), of: look, in: folder))
                }
            }
            for await (index, reading) in group {
                guard case .looked(let look) = outcomes[index] else { continue }
                if case .cancelled = reading {
                    wasCancelled = true
                }
                outcomes[index] = .read(look, reading, fresh: true)
                checked += 1
                progress.report(checked: checked)
            }
        }
        if wasCancelled {
            throw .cancelled
        }
        try Self.throwIfCancelled()
        for (index, first) in sameImage {
            guard case .looked(let look) = outcomes[index], case .read(_, let reading, _) = outcomes[first] else { continue }
            outcomes[index] = .read(look, reading, fresh: true)
        }
        // The last report, whichever installer was settled last.
        progress.report(checked: installers.count)

        // Then the installed apps, and the receipts the packages name.
        let apps = await InstalledApps.read(folders: sources.applicationFolders)
        let packageIdentifiers = Set(outcomes.flatMap { outcome -> [String] in
            guard case .read(_, .facts(.packages(let packages)), _) = outcome else { return [] }
            return packages.map(\.identifier)
        })
        let receipts = await sources.receipts.receipts(for: packageIdentifiers)

        var findings: [(record: FileRecord, finding: Finding)] = []
        var factsRead: [InstallerFactsEntry] = []
        for (record, outcome) in zip(installers, outcomes) {
            switch outcome {
            case .done(let finding):
                findings.append((record, finding))
            case .looked:
                // Not reached: every looked-at installer was read above.
                findings.append((record, .notProposed))
            case .read(let look, let reading, let fresh):
                switch reading {
                case .facts(let facts):
                    if fresh, facts.isLasting {
                        factsRead.append(InstallerFactsEntry(key: look.key, facts: facts))
                    }
                    findings.append((record, Self.finding(fileName: record.displayName, facts: facts, apps: apps, receipts: receipts)))
                case .notAnInstaller:
                    findings.append((record, .notProposed))
                case .notChecked(let reason):
                    findings.append((record, .notChecked(reason)))
                case .cancelled:
                    throw .cancelled
                }
            }
        }
        let plan = Self.makePlan(folderURL: folderURL, findings: findings, factsRead: factsRead)
        Self.logger.info(
            "Checked \(installers.count) installers (\(cached.count) known, \(factsRead.count) read, \(diskImages.count) disk images): \(plan.changes.count) proposed, \(plan.skippedItems.count) not checked, in \((clock.now - start).milliseconds, format: .fixed(precision: 1)) ms"
        )
        return plan
    }

    /// The records among `records` that are strong matches by the facts the cache holds for them:
    /// the Installed mark. No installer is read; one not read before has no mark.
    @concurrent
    public static func strongMatches(
        among records: [FileRecord],
        in folderURL: URL,
        applicationFolders: [URL],
        cache: any InstallerFactsReading,
        receipts: InstallReceipts
    ) async -> Set<URL> {
        let folderPath = folderURL.path(percentEncoded: false)
        let installers = DuplicatePlanner.recordsDirectlyInside(folderURL, among: records).filter { $0.kind == .file && kind(ofName: $0.displayName) != nil }
        guard !installers.isEmpty, let folder = try? DirectoryHandle.open(path: folderPath) else {
            return []
        }
        let volume = VolumeIdentity.of(folderPath: folderPath)
        let keys = installers.compactMap { record in look(at: record, in: folder, volume: volume).look.map { (record.url, $0.key) } }
        let cached = await cachedFacts(for: keys.map(\.1), in: cache)
        let facts = Dictionary(keys.compactMap { url, key in cached[key].map { (url, $0) } }, uniquingKeysWith: { first, _ in first })
        guard !facts.isEmpty else {
            return []
        }
        let apps = await InstalledApps.read(folders: applicationFolders)
        let packageIdentifiers = Set(facts.values.flatMap { facts -> [String] in
            guard case .packages(let packages) = facts else { return [] }
            return packages.map(\.identifier)
        })
        let receipts = await receipts.receipts(for: packageIdentifiers)
        return strongMatches(installers, facts: facts, apps: apps, receipts: receipts)
    }

    // MARK: - One installer

    /// An installer as it was looked at, before anything was read.
    private struct Look: Sendable {
        let name: String
        let kind: Kind
        let status: FileStatus
        let key: InstallerFileKey
    }

    /// What reading an installer gave.
    private enum Reading: Sendable {
        case facts(InstallerFacts)
        /// A zip with no app at its top level, or one that could not be listed: Remove Unpacked Zips
        /// reports those.
        case notAnInstaller
        case notChecked(CleanupSkipReason)
        case cancelled
    }

    private enum Outcome {
        case done(Finding)
        case looked(Look)
        case read(Look, Reading, fresh: Bool)

        var look: Look? {
            if case .looked(let look) = self {
                return look
            }
            return nil
        }
    }

    /// The installer `record` names, as it is now: a regular file, on this Mac, the size and date the
    /// scan saw.
    private static func look(at record: FileRecord, in folder: DirectoryHandle, volume: VolumeIdentity?) -> Outcome {
        let name = record.displayName
        guard let kind = kind(ofName: name) else {
            return .done(.notProposed)
        }
        // A zip is an installer only once its listing shows an app; until then it is left out silently.
        let notChecked = { (reason: CleanupSkipReason) -> Outcome in .done(kind == .zip ? .notProposed : .notChecked(reason)) }
        let status: FileStatus
        do throws(FileStatus.Failure) {
            status = try folder.status(of: name)
        } catch {
            return notChecked(CleanupSkipReason(statusFailure: error))
        }
        guard status.isRegularFile else {
            return notChecked(.notARegularFile)
        }
        if status.isDataless {
            return notChecked(.notDownloaded)
        }
        guard let scannedDate = record.dateModified, status.sizeInBytes == record.sizeInBytes,
              abs(status.modificationDate.timeIntervalSince(scannedDate)) <= CleanupExecutor.modificationDateTolerance else {
            return notChecked(.changedSinceScan)
        }
        let key = InstallerFileKey(
            identity: volume?.identity(of: status),
            path: record.url.path(percentEncoded: false),
            sizeInBytes: status.sizeInBytes,
            dateModified: status.modificationDate,
            statusChanged: status.statusChangeDate
        )
        return .looked(Look(name: name, kind: kind, status: status, key: key))
    }

    /// `reading`, when the installer is still the very file looked at; otherwise what was read is dropped.
    private static func confirm(_ reading: Reading, of look: Look, in folder: DirectoryHandle) -> Reading {
        guard case .facts = reading else {
            return reading
        }
        guard let now = try? folder.status(of: look.name), now.identity == look.status.identity, now.isRegularFile,
              now.sizeInBytes == look.status.sizeInBytes, now.modificationDate == look.status.modificationDate,
              now.statusChangeDate == look.status.statusChangeDate else {
            return look.kind == .zip ? .notAnInstaller : .notChecked(.changedSinceScan)
        }
        return reading
    }

    private static func cachedFacts(for keys: [InstallerFileKey], in cache: (any InstallerFactsReading)?) async -> [InstallerFileKey: InstallerFacts] {
        guard let cache, !keys.isEmpty else {
            return [:]
        }
        do throws(ActivityLogError) {
            return try await cache.installerFacts(for: keys)
        } catch {
            logger.error("Could not read what was read from installers before (\(String(describing: error), privacy: .public)); reading them again")
            return [:]
        }
    }

    // MARK: - Zips and packages

    /// A zip's top-level apps, each from its `Info.plist`, read in memory through the strict zip
    /// reader (decision record 0011). An app whose `Info.plist` cannot be read counts by its name only.
    private static func readZip(named name: String, in folder: DirectoryHandle) -> Reading {
        let read: (listing: ZipListing, contents: [String: [UInt8]], status: FileStatus)
        do throws(ZipListing.Failure) {
            read = try ZipListing.read(
                named: name,
                in: folder,
                limits: .standard,
                contentsOf: { entries in Set(topLevelApps(in: entries).prefix(InstallerFacts.maximumApps).map(infoPlistPath)) },
                maximumEntrySize: BundleInfo.maximumPlistSize
            )
        } catch {
            return error == .cancelled ? .cancelled : .notAnInstaller
        }
        let apps = topLevelApps(in: read.listing.entries)
        guard !apps.isEmpty else {
            return .notAnInstaller
        }
        guard apps.count <= InstallerFacts.maximumApps else {
            return .facts(.unreadable(.tooLarge))
        }
        return .facts(.apps(apps.map { bundle in
            read.contents[infoPlistPath(bundle)].flatMap { BundleInfo.parse($0, bundleName: bundle) }
                ?? BundleFacts(name: BundleInfo.appName(ofBundleNamed: bundle), identifier: nil, shortVersion: nil, build: nil)
        }))
    }

    /// The apps at a zip's top level, by name: a top-level folder named like an app, outside
    /// `__MACOSX`, with no link where the app or its `Contents` would be.
    static func topLevelApps(in entries: [ZipEntry]) -> [String] {
        var apps: Set<String> = []
        var linked: Set<String> = []
        for entry in entries {
            let path = entry.path.hasSuffix("/") ? String(entry.path.dropLast()) : entry.path
            let parts = path.split(separator: "/", omittingEmptySubsequences: false)
            guard let first = parts.first.map(String.init), first != "__MACOSX", BundleInfo.isAppName(first) else {
                continue
            }
            if entry.kind == .symbolicLink, parts.count <= 2 {
                linked.insert(first)
            } else if parts.count > 1 || entry.kind == .folder {
                apps.insert(first)
            }
        }
        return apps.subtracting(linked).sorted { UnpackedZipPlanner.isOrderedBefore($0, $1) }
    }

    private static func infoPlistPath(_ bundle: String) -> String {
        bundle + "/Contents/Info.plist"
    }

    /// A package's parts, from its own metadata (`XarArchive`).
    private static func readPackage(named name: String, in folder: DirectoryHandle) -> Reading {
        let file: ZipArchiveFile
        do throws(ZipListing.Failure) {
            file = try ZipArchiveFile.open(named: name, in: folder)
        } catch {
            return reading(error)
        }
        do throws(XarArchive.Failure) {
            return .facts(.packages(try XarArchive.packages(in: file)))
        } catch {
            switch error {
            case .problem(let problem):
                return .facts(.unreadable(problem))
            case .file(let failure):
                return reading(failure)
            }
        }
    }

    private static func reading(_ failure: ZipListing.Failure) -> Reading {
        CleanupSkipReason(zipFailure: failure).map(Reading.notChecked) ?? .cancelled
    }

    private static func reading(_ reading: DiskImageReading) -> Reading {
        switch reading {
        case .facts(let facts):
            .facts(facts)
        case .attachedElsewhere:
            .notChecked(.diskImageInUse)
        case .changed:
            .notChecked(.changedSinceScan)
        case .notReadable(let reason):
            .notChecked(reason)
        case .unavailable:
            .notChecked(.unreadable(reason: "The private folder for opening disk images cannot be used"))
        case .cancelled:
            .cancelled
        }
    }

    /// Typed-throws stand-in for `Task.checkCancellation()`.
    private static func throwIfCancelled() throws(CleanupPlanningError) {
        if Task.isCancelled {
            throw .cancelled
        }
    }
}
