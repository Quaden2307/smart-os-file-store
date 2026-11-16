import Foundation

/// The checks for moving a used installer to the Trash. Right before it moves, through the handle on
/// the scanned folder, the installer must still be the very file the plan saw, a disk image must not
/// be attached, and the installed app the reason names must still be there, in one of the executor's
/// own application folders (decision record 0012). The app is only ever read.
extension CleanupExecutor {
    /// One used installer, checked from the cheapest test to the dearest. The first failing check decides.
    func trashUsedInstaller(
        _ change: ProposedChange,
        folder: DirectoryHandle,
        context: PlanContext,
        folderIdentity: FileIdentity,
        now: Date,
        journal: inout RunJournal,
        beforeChange: (@Sendable (ProposedChange) -> Void)?
    ) async -> CleanupItemOutcome {
        // Membership: the plan must propose it as a used installer.
        guard case .usedInstaller(let evidence) = change.reason else {
            return .skipped(.notInPlan)
        }

        // Containment: act on `<folder>/<name>`, and only through the folder's handle from here on.
        guard let itemURL = Self.urlInsideFolder(
            change.record.url.standardizedFileURL,
            folderURL: context.folderURL,
            folderIdentity: folderIdentity
        ) else {
            return .skipped(.outsideFolder)
        }
        let name = itemURL.lastPathComponent
        // The plan's own claim: an installer, by the rule the planner applied too.
        guard !change.isFolder, let kind = InstallerPlanner.kind(ofName: name) else {
            return .skipped(.notInPlan)
        }

        // The installer as it is now.
        let status: FileStatus
        do throws(FileStatus.Failure) {
            status = try folder.status(of: name)
        } catch {
            return .skipped(CleanupSkipReason(statusFailure: error))
        }
        guard Self.isExpectedKind(status, isFolder: false) else {
            return .skipped(.notARegularFile)
        }
        if status.isDataless {
            return .skipped(.notDownloaded)
        }

        // The rules every action shares, on what the disk says now, a hidden installer included.
        let readDateAdded = { () throws(FileStatus.Failure) -> Date? in
            try FileStatus.dateAdded(path: name, relativeTo: folder.descriptor)
        }
        if let refused = sharedRefusal(status, itemURL: itemURL, change: change, now: now, readDateAdded: readDateAdded) {
            return refused
        }

        // A disk image someone has open is never moved, nor one whose state could not be told.
        if kind == .diskImage {
            guard let attached = await AttachedImages.read(tool: SystemTool()), attached.contains(status.identity) == false else {
                // A cancel stops the listing too; that is a cancel, not an image in use.
                return .skipped(Task.isCancelled ? .cancelled : .diskImageInUse)
            }
        }

        // The evidence, read again from the disk as it is now.
        if let refused = await installedAppRefusal(evidence) {
            return refused
        }

        // The activity log first: whether the installer is Kept by the list as it is now, then a row
        // that says this change was started, with its disk ID, which undo checks.
        let permit: ChangePermit
        switch journal.intend(
            change,
            contentHash: nil,
            fileNumber: UInt64(status.identity.inode),
            itemURL: itemURL,
            identity: context.volume?.identity(of: status)
        ) {
        case .permitted(let granted):
            permit = granted
        case .markedKept:
            return .skipped(.markedKept)
        case .stopped:
            return .skipped(.activityLogUnavailable)
        }

        // Last look, after the log's row and right before the move: the very installer checked above.
        if let refused = Self.lastLookRefusal(try? folder.status(of: name), checked: status) {
            return refused
        }
        if Task.isCancelled {
            return .skipped(.cancelled)
        }
        beforeChange?(change)
        return DiskChange.trash(itemURL, permit: permit)
    }

    /// Nil when what `evidence` names is still installed:
    /// - an app: still a real app folder at its path, directly inside one of the executor's
    ///   application folders; for a strong match, with the same identifier and a version the same
    ///   or newer than when the plan was made (the short version, or the build when the app gives
    ///   none, as the evidence recorded it);
    /// - a package matched by its receipts alone: every receipt still on this Mac.
    private func installedAppRefusal(_ evidence: UsedInstallerEvidence) async -> CleanupItemOutcome? {
        guard let path = evidence.installedAppPath else {
            guard evidence.strength == .strong, !evidence.receiptIdentifiers.isEmpty else {
                return .skipped(.notInPlan)
            }
            let identifiers = Set(evidence.receiptIdentifiers)
            let found = await receipts.receipts(for: identifiers)
            guard found.count == identifiers.count else {
                return .skipped(Task.isCancelled ? .cancelled : .installedAppMissing(name: evidence.name))
            }
            return nil
        }
        let appURL = URL(filePath: path, directoryHint: .isDirectory)
        let bundleName = appURL.lastPathComponent
        let folderPath = appURL.deletingLastPathComponent().storedPath
        guard BundleInfo.isAppName(bundleName), applicationFolders.contains(where: { $0.storedPath == folderPath }) else {
            return .skipped(.notInPlan)
        }
        guard let appFolder = try? DirectoryHandle.open(path: folderPath) else {
            return .skipped(.installedAppMissing(name: evidence.name))
        }
        let app: FileStatus
        do throws(FileStatus.Failure) {
            app = try appFolder.status(of: bundleName)
        } catch {
            return .skipped(error == .notFound ? .installedAppMissing(name: evidence.name) : .installedAppChanged(name: evidence.name))
        }
        guard app.isDirectory, !app.isSymbolicLink else {
            return .skipped(.installedAppChanged(name: evidence.name))
        }
        guard evidence.strength == .strong else {
            return nil
        }
        guard let facts = BundleInfo.read(bundleNamed: bundleName, in: appFolder),
              facts.identifier != nil, facts.identifier == evidence.bundleIdentifier,
              let planned = evidence.version, let installed = facts.shortVersion ?? facts.build,
              let order = InstallerVersion.compare(installed, planned),
              order != .orderedAscending else {
            return .skipped(.installedAppChanged(name: evidence.name))
        }
        return nil
    }
}
