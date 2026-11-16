import Foundation
import os

extension UnpackedZipPlanner {
    private static let logger = Logger(subsystem: "com.quaden2307.FileStoreCore", category: "UnpackedZipPlanner")

    /// Plans Remove Unpacked Zips for `records`, from one scan of `folderURL`.
    ///
    /// The zips are chosen first, from the records alone, so a Kept zip is never even opened and no
    /// plan can name one. Then, one zip at a time through one handle on the folder, it reads the
    /// zip's listing, works out where it would have been unpacked, and reads each place that could
    /// hold it until one holds everything. A zip that cannot be read or listed is reported as not
    /// checked. Nothing is ever written.
    ///
    /// - Parameter onProgress: Called with the zips checked of the total: first, then at most every
    ///   100 ms, and last. It must return quickly.
    /// - Throws: `.cancelled` when the task is cancelled.
    @concurrent
    public func plan(
        records: [FileRecord],
        in folderURL: URL,
        now: Date = .now,
        onProgress: (@Sendable (CleanupPlanningProgress) -> Void)? = nil
    ) async throws(CleanupPlanningError) -> CleanupPlan {
        let clock = ContinuousClock()
        let start = clock.now
        try Self.throwIfCancelled()

        let inside = DuplicatePlanner.recordsDirectlyInside(folderURL, among: records)
        let zips = candidates(in: inside, now: now).sorted { Self.isOrderedBefore($0.displayName, $1.displayName) }
        let copyNames = Self.unpackedCopies(in: inside).map(\.displayName)
        var progress = ItemCheckProgress(total: zips.count, onProgress: onProgress)
        progress.report(checked: 0)
        guard !zips.isEmpty else {
            return Self.makePlan(folderURL: folderURL, findings: [])
        }

        let folder: DirectoryHandle
        do throws(DirectoryHandle.OpenFailure) {
            folder = try DirectoryHandle.open(path: folderURL.path(percentEncoded: false))
        } catch {
            Self.logger.error("Could not open the folder to read \(zips.count) zips")
            return Self.makePlan(folderURL: folderURL, findings: zips.map { ($0, .notChecked(.folderUnavailable)) })
        }

        var findings: [(record: FileRecord, finding: Finding)] = []
        findings.reserveCapacity(zips.count)
        for (index, zip) in zips.enumerated() {
            try Self.throwIfCancelled()
            findings.append((zip, try check(zip, in: folder, copyNames: copyNames, now: now)))
            progress.report(checked: index + 1)
        }
        try Self.throwIfCancelled()

        let plan = Self.makePlan(folderURL: folderURL, findings: findings)
        Self.logger.info(
            "Checked \(zips.count) of \(records.count) records as zips: \(plan.changes.count) unpacked, \(plan.skippedItems.count) not checked, in \((clock.now - start).milliseconds, format: .fixed(precision: 1)) ms"
        )
        return plan
    }

    /// One zip: its listing, read through `folder`, where it would have been unpacked, and each place
    /// among `copyNames` that could hold it, in the order `candidateNames` gives.
    private func check(_ zip: FileRecord, in folder: DirectoryHandle, copyNames: [String], now: Date) throws(CleanupPlanningError) -> Finding {
        let listing: ZipListing
        do throws(ZipListing.Failure) {
            // The zip the scan saw: its size and modification date.
            listing = try ZipListing.read(named: zip.displayName, in: folder, limits: .standard) { status in
                guard let scannedDate = zip.dateModified else {
                    return false
                }
                return status.sizeInBytes == zip.sizeInBytes
                    && abs(status.modificationDate.timeIntervalSince(scannedDate)) <= CleanupExecutor.modificationDateTolerance
            }
        } catch {
            guard let reason = CleanupSkipReason(zipFailure: error) else {
                throw .cancelled
            }
            return .notChecked(reason)
        }
        let expectation: Expectation
        switch Self.expectation(for: listing.entries, zipName: zip.displayName) {
        case .success(let expected):
            expectation = expected
        case .failure(.tooLarge):
            // Within the reader's limits, but implying more folders than the rule reads.
            return .notChecked(.zipUnlistable(.tooManyEntries))
        case .failure(.empty), .failure(.holdsAnApp), .failure(.unsafePath), .failure(.conflictingEntries):
            return .notUnpacked
        }
        for name in Self.candidateNames(for: expectation.name, among: copyNames) {
            switch checkCopy(named: name, of: expectation, in: folder, now: now) {
            case .matches:
                return .unpacked(to: name)
            case .missing, .notVerified, .recentlyChanged:
                // This place proves nothing; the next one may.
                continue
            case .cancelled:
                throw .cancelled
            }
        }
        return .notUnpacked
    }

    /// What one place beside a zip holds, compared with what the zip expects there.
    enum CopyCheck {
        /// Everything is there, and has settled. `rootStatus` is the item at the place, as it was
        /// looked at.
        case matches(rootStatus: FileStatus)
        /// Nothing is at the place.
        case missing
        /// Something is there, but not all of the zip, or it could not be read in full, or it is hidden.
        case notVerified
        /// Everything is there, but it arrived, or something in it was written, within the grace period.
        case recentlyChanged
        case cancelled
    }

    /// Reads the item called `name` in `folder` as far as `expectation` asks, matches it, and checks
    /// it has settled, all by what the disk says now, at the planner and the executor alike.
    ///
    /// Settled means the shared rules on the copy: not hidden, not the archive, not a download in
    /// progress; it arrived (its Date Added) more than the grace period ago; and nothing in it that
    /// the zip names as a file or a link was written since then. A folder's own date is left out,
    /// so opening the copy in Finder, which writes a `.DS_Store` into it, does not hold the zip back.
    func checkCopy(named name: String, of expectation: Expectation, in folder: DirectoryHandle, now: Date) -> CopyCheck {
        let found: UnpackedTree.Reading
        do throws(UnpackedTree.ReadFailure) {
            found = try UnpackedTree.read(named: name, in: folder, expecting: expectation.tree)
        } catch {
            switch error {
            case .missing:
                return .missing
            case .cancelled:
                return .cancelled
            case .notDownloaded, .accessDenied, .unreadable, .tooLarge:
                return .notVerified
            }
        }
        guard Self.matches(expectation.tree, found.tree), !found.rootStatus.isHidden else {
            return .notVerified
        }
        // Nil on a volume that does not record it; the modification dates then decide alone.
        let dateAdded: Date?
        do throws(FileStatus.Failure) {
            dateAdded = try FileStatus.dateAdded(path: name, relativeTo: folder.descriptor)
        } catch {
            return .notVerified
        }
        let settled = eligibility.refusal(
            name: name,
            isDownloading: FileRecord.isInProgressDownload(name: name),
            dateAdded: dateAdded,
            dateModified: found.newestChange ?? found.rootStatus.modificationDate,
            now: now
        ) == nil
        return settled ? .matches(rootStatus: found.rootStatus) : .recentlyChanged
    }

    /// Typed-throws stand-in for `Task.checkCancellation()`, which throws `CancellationError`.
    private static func throwIfCancelled() throws(CleanupPlanningError) {
        if Task.isCancelled {
            throw .cancelled
        }
    }
}

extension CleanupSkipReason {
    /// The reason matching a zip that could not be read or listed. Nil for `.cancelled`, which is
    /// a reason to stop, not to skip.
    init?(zipFailure: ZipListing.Failure) {
        switch zipFailure {
        case .notFound:
            self = .notFound
        case .accessDenied:
            self = .accessDenied
        case .notDownloaded:
            self = .notDownloaded
        case .notARegularFile:
            self = .notARegularFile
        case .changedSinceScan:
            self = .changedSinceScan
        case .unreadable(let reason):
            self = .unreadable(reason: reason)
        case .unlistable(let problem):
            self = .zipUnlistable(problem)
        case .cancelled:
            return nil
        }
    }
}
