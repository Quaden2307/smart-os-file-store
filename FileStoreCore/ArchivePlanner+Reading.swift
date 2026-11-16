import Foundation

extension ArchivePlanner {
    /// Plans the archive for `records`, from one scan of `folderURL`, at `now`. Reads only: the
    /// volume's letter-case rule, the names in the archive folder, through a handle on the scanned
    /// folder that never follows a link, and the content of a candidate and of the archived file
    /// with its name when the two are the same size, to tell an identical copy from a different file.
    ///
    /// - Throws: `.cancelled` when the task is cancelled.
    @concurrent
    public func plan(
        records: [FileRecord],
        in folderURL: URL,
        now: Date = .now,
        timeZone: TimeZone = .current
    ) async throws(CleanupPlanningError) -> CleanupPlan {
        let candidates = candidates(in: records, folderURL: folderURL, now: now)
        // Unknown counts as not case-sensitive: more names clash, never fewer.
        let values = try? folderURL.resourceValues(forKeys: [.volumeSupportsCaseSensitiveNamesKey])
        let caseSensitive = values?.volumeSupportsCaseSensitiveNames ?? false

        let read = Self.readArchive(in: folderURL)
        var entries: [ArchiveListing.Entry] = []
        var hashes: [FileRecord.ID: ContentHash] = [:]
        var skippedItems: [CleanupPlan.SkippedItem] = []
        if case .folder(let archive, let names) = read {
            let candidatesByKey = Dictionary(
                candidates.map { (MessyNamePlanner.comparisonKey($0.displayName, caseSensitive: caseSensitive), $0) },
                uniquingKeysWith: { first, _ in first }
            )
            for name in names {
                if Task.isCancelled {
                    throw .cancelled
                }
                // Only a regular file with a candidate's name and size can be an identical copy.
                guard let candidate = candidatesByKey[MessyNamePlanner.comparisonKey(name, caseSensitive: caseSensitive)],
                      let size = candidate.sizeInBytes, size > 0,
                      let status = try? archive.status(of: name),
                      status.isRegularFile, !status.isSymbolicLink, !status.isDataless, status.sizeInBytes == size else {
                    entries.append(ArchiveListing.Entry(name: name))
                    continue
                }
                let theirs: ContentHash?
                do throws(ContentHashError) {
                    theirs = try await hasher.hash(contentsOf: Self.archiveURL(in: folderURL).appending(path: name), expectedSizeInBytes: size)
                } catch {
                    guard error != .cancelled else { throw .cancelled }
                    // Unreadable there: a different file, so this one is filed under a dated name.
                    theirs = nil
                }
                entries.append(ArchiveListing.Entry(name: name, contentHash: theirs))
                guard theirs != nil else { continue }
                do throws(ContentHashError) {
                    if let known = hashCache?.hash(for: candidate) {
                        hashes[candidate.id] = known
                    } else {
                        let hash = try await hasher.hash(contentsOf: candidate.url, expectedSizeInBytes: size)
                        hashes[candidate.id] = hash
                        hashCache?.store(hash, for: candidate)
                    }
                } catch {
                    guard let reason = CleanupSkipReason(hashError: error) else {
                        throw .cancelled
                    }
                    skippedItems.append(CleanupPlan.SkippedItem(url: candidate.url, reason: reason))
                }
            }
        }
        if Task.isCancelled {
            throw .cancelled
        }

        let listing: ArchiveListing
        switch read {
        case .folder:
            listing = ArchiveListing(entries: entries)
        case .missing:
            listing = .missing
        case .problem(let problem):
            listing = ArchiveListing(problem: problem)
        }
        let plan = Self.makePlan(
            folderURL: folderURL,
            candidates: candidates,
            archive: listing,
            hashes: hashes,
            skippedItems: skippedItems,
            caseSensitive: caseSensitive,
            timeZone: timeZone
        )
        Self.logger.info(
            "\(candidates.count) old downloads; archive problem: \(String(describing: listing.problem), privacy: .public); \(plan.changes.count) changes, \(plan.skippedItems.count) skipped"
        )
        return plan
    }

    /// What reading the archive folder found.
    private enum ArchiveRead {
        case missing
        case problem(ArchiveProblem)
        /// The folder, opened without following a link, and the names in it.
        case folder(DirectoryHandle, [String])
    }

    private static func readArchive(in folderURL: URL) -> ArchiveRead {
        let name = CandidateEligibility.archiveFolderName
        guard let folder = try? DirectoryHandle.open(path: folderURL.path(percentEncoded: false)) else {
            return .problem(.unreadable)
        }
        let status: FileStatus
        do throws(FileStatus.Failure) {
            status = try folder.status(of: name)
        } catch .notFound {
            return .missing
        } catch {
            return .problem(.unreadable)
        }
        if status.isSymbolicLink {
            return .problem(.symbolicLink)
        }
        guard status.isDirectory else {
            return .problem(.notAFolder)
        }
        let archive: DirectoryHandle
        do throws(DirectoryHandle.OpenFailure) {
            archive = try folder.openFolder(named: name)
        } catch .symbolicLink {
            return .problem(.symbolicLink)
        } catch .notAFolder {
            return .problem(.notAFolder)
        } catch {
            return .problem(.unreadable)
        }
        guard let names = try? archive.entryNames(limit: .max) else {
            return .problem(.unreadable)
        }
        return .folder(archive, names)
    }
}
