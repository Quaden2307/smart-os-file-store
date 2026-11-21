import FileStoreCore
import Foundation
import Testing

/// The rules every cleanup action shares: the grace period on both dates, hidden and archive
/// names, downloads in progress, and the debug-only way to shorten the grace period.
@Suite("CandidateEligibility")
struct CandidateEligibilityTests {
    private static let now = Date(timeIntervalSince1970: 1_800_000_000)
    private static let hour: TimeInterval = 3_600
    private let eligibility = CandidateEligibility()

    private func record(
        _ name: String,
        added: Date? = CandidateEligibilityTests.now - 2 * CandidateEligibilityTests.hour,
        modified: Date? = CandidateEligibilityTests.now - 2 * CandidateEligibilityTests.hour,
        kind: FileRecord.Kind = .file
    ) -> FileRecord {
        let url = URL(filePath: "/FakeDownloads").appending(path: name)
        return FileRecord(
            url: url,
            displayName: name,
            kind: kind,
            localizedTypeDescription: nil,
            contentType: nil,
            sizeInBytes: kind == .file ? 10 : nil,
            dateAdded: added,
            dateModified: modified,
            isDownloading: FileRecord.isInProgressDownload(url)
        )
    }

    // MARK: - Grace period

    @Test func defaultGracePeriodIsOneHour() {
        #expect(CandidateEligibility.defaultGracePeriod == Self.hour)
        #expect(eligibility.gracePeriod == Self.hour)
        #expect(CandidateEligibility(gracePeriod: -5).gracePeriod == 0)
        // Not a number never loosens the rule: the default applies.
        #expect(CandidateEligibility(gracePeriod: .nan).gracePeriod == Self.hour)
    }

    @Test func settledExactlyAtTheEndOfTheGracePeriod() {
        let now = Self.now
        #expect(eligibility.isSettled(dateAdded: now - Self.hour, dateModified: now - Self.hour, now: now))
        #expect(!eligibility.isSettled(dateAdded: now - Self.hour, dateModified: now - (Self.hour - 0.5), now: now))
        #expect(!eligibility.isSettled(dateAdded: now - (Self.hour - 0.5), dateModified: now - Self.hour, now: now))
    }

    @Test func bothDatesMustBeOutsideTheGracePeriod() {
        let now = Self.now
        let old = now - 2 * Self.hour
        let recent = now - 60
        #expect(eligibility.isSettled(dateAdded: old, dateModified: old, now: now))
        // Put in the folder moments ago, with an old modification date: a copy or a moved file.
        #expect(!eligibility.isSettled(dateAdded: recent, dateModified: old, now: now))
        // In the folder for a long time but written to moments ago.
        #expect(!eligibility.isSettled(dateAdded: old, dateModified: recent, now: now))
        // Dates in the future (a clock that moved back) are not settled either.
        #expect(!eligibility.isSettled(dateAdded: now + 60, dateModified: old, now: now))
    }

    /// Some volumes do not record Date Added; the modification date then decides alone. An unknown
    /// modification date never counts as settled.
    @Test func missingDatesFollowTheModificationDate() {
        let now = Self.now
        #expect(eligibility.isSettled(dateAdded: nil, dateModified: now - 2 * Self.hour, now: now))
        #expect(!eligibility.isSettled(dateAdded: nil, dateModified: now - 60, now: now))
        #expect(!eligibility.isSettled(dateAdded: now - 2 * Self.hour, dateModified: nil, now: now))
        #expect(!eligibility.isSettled(dateAdded: nil, dateModified: nil, now: now))
    }

    @Test func zeroGracePeriodSettlesEverythingDated() {
        let none = CandidateEligibility(gracePeriod: 0)
        #expect(none.isSettled(dateAdded: Self.now, dateModified: Self.now, now: Self.now))
        #expect(!none.isSettled(dateAdded: nil, dateModified: nil, now: Self.now))
    }

    // MARK: - Names and downloads

    @Test func excludesHiddenAndArchiveNamesInAnyCase() {
        for name in [".hidden", ".DS_Store", "Old downloads", "old downloads", "OLD DOWNLOADS"] {
            #expect(CandidateEligibility.isExcludedName(name, archiveFolderName: ManagedFolder.temporary(URL(filePath: "/FakeDownloads")).archiveFolderName), "\(name) should be excluded")
        }
        for name in ["Old downloads 2", "Old download", "report.pdf", "Downloads"] {
            #expect(!CandidateEligibility.isExcludedName(name, archiveFolderName: ManagedFolder.temporary(URL(filePath: "/FakeDownloads")).archiveFolderName), "\(name) should not be excluded")
        }
        #expect(CandidateEligibility.archiveFolderName == "Old downloads")
    }

    @Test func allowsOnlySettledVisibleFinishedItems() {
        let now = Self.now
        let records = [
            record("settled.pdf"),
            record("Settled Folder", kind: .folder),
            record("added-recently.pdf", added: now - 60),
            record("modified-recently.pdf", modified: now - 60),
            record(".hidden.pdf"),
            record("Old downloads", kind: .folder),
            record("old downloads"),
            record("movie.mp4.crdownload"),
            record("partial.part"),
            record("Unconfirmed 48213.download"),
            record("presentation.key.download", kind: .package),
        ]
        let allowed = records.filter { eligibility.allows($0, in: .temporary($0.url.deletingLastPathComponent()), now: now) }.map(\.displayName)
        // Kinds are each action's own business: a settled folder passes the shared rules.
        #expect(allowed == ["settled.pdf", "Settled Folder"])
    }

    /// The executor applies the same rules to what it reads from disk, and needs to know which one
    /// refused, to report it in the user's words.
    @Test func refusalNamesTheFirstRuleThatApplies() {
        let now = Self.now
        let old = now - 2 * Self.hour
        func refusal(_ name: String, downloading: Bool = false, added: Date? = old, modified: Date? = old) -> CandidateEligibility.Refusal? {
            eligibility.refusal(name: name, isDownloading: downloading, dateAdded: added, dateModified: modified, in: .temporary(URL(filePath: "/FakeDownloads")), now: now)
        }
        #expect(refusal("report.pdf") == nil)
        #expect(refusal(".report.pdf") == .excludedName)
        #expect(refusal("Old Downloads") == .excludedName)
        #expect(refusal("movie.mp4.crdownload", downloading: true) == .downloadInProgress)
        #expect(refusal("report.pdf", added: now - 60) == .insideGracePeriod)
        #expect(refusal("report.pdf", modified: nil) == .insideGracePeriod)
        // A hidden, fresh download in progress is refused for its name first.
        #expect(refusal(".movie.crdownload", downloading: true, added: now, modified: now) == .excludedName)
    }

    // MARK: - Debug-only override

    @Test func gracePeriodArgumentInDebugOnly() {
        let flag = CandidateEligibility.gracePeriodArgumentName
        #expect(flag == "-GracePeriodSeconds")
        #if DEBUG
        #expect(CandidateEligibility.resolve(arguments: ["app", flag, "0"]).gracePeriod == 0)
        #expect(CandidateEligibility.resolve(arguments: ["app", flag, "5"]).gracePeriod == 5)
        #else
        // Release builds ignore the argument entirely.
        #expect(CandidateEligibility.resolve(arguments: ["app", flag, "0"]).gracePeriod == Self.hour)
        #expect(CandidateEligibility.resolve(arguments: ["app", flag, "5"]).gracePeriod == Self.hour)
        #endif
    }

    /// A missing or unusable value never loosens the rule: the default applies.
    @Test func unusableGracePeriodArgumentKeepsTheDefault() {
        let flag = CandidateEligibility.gracePeriodArgumentName
        for arguments in [["app"], ["app", flag], ["app", flag, "abc"], ["app", flag, "-3"], ["app", flag, "1.5"], ["app", flag, ""]] {
            #expect(CandidateEligibility.resolve(arguments: arguments).gracePeriod == Self.hour, "\(arguments)")
        }
    }
}
