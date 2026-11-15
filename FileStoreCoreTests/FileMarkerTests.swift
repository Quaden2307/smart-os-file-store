import FileStoreCore
import Foundation
import Testing
import UniformTypeIdentifiers

/// The age marks: each one at, just under and just over its threshold, the combinations, missing
/// dates, and the kinds of item that never carry one.
@Suite("FileMarker")
struct FileMarkerTests {
    private static let now = Date(timeIntervalSince1970: 1_800_000_000)
    private static let day: TimeInterval = 24 * 60 * 60
    private static let unusedAfter = 30 * day
    private static let oldAfter = 90 * day
    private let settings = CleanupSettings()

    /// A file added two hours ago and never opened, unless the test says otherwise.
    private func record(
        _ name: String = "file.pdf",
        kind: FileRecord.Kind = .file,
        contentType: UTType? = .pdf,
        added: Date? = FileMarkerTests.now - 2 * 60 * 60,
        lastOpened: Date? = nil,
        canReadLastOpened: Bool = true
    ) -> FileRecord {
        let url = URL(filePath: "/FakeDownloads").appending(path: name)
        return FileRecord(
            url: url,
            displayName: name,
            kind: kind,
            localizedTypeDescription: nil,
            contentType: contentType,
            sizeInBytes: kind == .file ? 10 : nil,
            dateAdded: added,
            dateModified: added,
            isDownloading: FileRecord.isInProgressDownload(url),
            lastOpened: lastOpened,
            canReadLastOpened: canReadLastOpened
        )
    }

    private func marks(_ record: FileRecord, settings: CleanupSettings? = nil) -> [FileMark] {
        FileMarker.marks(for: record, now: Self.now, settings: settings ?? self.settings)
    }

    // MARK: - Thresholds

    @Test func neverOpenedAfterMoreThanThirtyDays() {
        let now = Self.now
        #expect(marks(record(added: now - Self.unusedAfter)) == [])
        #expect(marks(record(added: now - (Self.unusedAfter - 1))) == [])
        #expect(marks(record(added: now - (Self.unusedAfter + 1))) == [.neverOpened])
    }

    @Test func unusedWhenLastOpenedMoreThanThirtyDaysAgo() {
        let now = Self.now
        let added = now - 40 * Self.day
        #expect(marks(record(added: added, lastOpened: now - Self.unusedAfter)) == [])
        #expect(marks(record(added: added, lastOpened: now - (Self.unusedAfter - 1))) == [])
        #expect(marks(record(added: added, lastOpened: now - (Self.unusedAfter + 1))) == [.unused])
    }

    @Test func oldAfterMoreThanNinetyDays() {
        let now = Self.now
        let openedYesterday = now - Self.day
        #expect(marks(record(added: now - Self.oldAfter, lastOpened: openedYesterday)) == [])
        #expect(marks(record(added: now - (Self.oldAfter - 1), lastOpened: openedYesterday)) == [])
        #expect(marks(record(added: now - (Self.oldAfter + 1), lastOpened: openedYesterday)) == [.old])
    }

    // MARK: - Combinations

    @Test func oldJoinsNeverOpenedOrUnused() {
        let now = Self.now
        let longAgo = now - 200 * Self.day
        #expect(marks(record(added: longAgo)) == [.neverOpened, .old])
        #expect(marks(record(added: longAgo, lastOpened: now - 100 * Self.day)) == [.unused, .old])
    }

    /// A last-opened date decides between the two: an item is never both.
    @Test func neverOpenedAndUnusedExcludeEachOther() {
        let now = Self.now
        for opened in [nil, now - Self.day, now - 60 * Self.day] as [Date?] {
            let result = marks(record(added: now - 200 * Self.day, lastOpened: opened))
            #expect(!(result.contains(.neverOpened) && result.contains(.unused)))
        }
    }

    @Test func marksFollowDeclarationOrder() {
        let result = marks(record(added: Self.now - 200 * Self.day))
        #expect(result == FileMark.allCases.filter(result.contains))
    }

    // MARK: - Missing and odd dates

    /// Without a Date Added there is no telling how long an item has been there, so neither Never
    /// opened nor Old; Unused needs only the last-opened date.
    @Test func missingDateAddedGivesOnlyUnused() {
        let now = Self.now
        #expect(marks(record(added: nil)) == [])
        #expect(marks(record(added: nil, lastOpened: now - Self.day)) == [])
        #expect(marks(record(added: nil, lastOpened: now - 60 * Self.day)) == [.unused])
    }

    @Test func futureDatesGiveNoMarks() {
        let now = Self.now
        #expect(marks(record(added: now + Self.day)) == [])
        #expect(marks(record(added: now + Self.day, lastOpened: now + Self.day)) == [])
    }

    // MARK: - Items that never carry age marks

    @Test func foldersAppsLinksHiddenAndInProgressGetNoMarks() {
        let ancient = Self.now - 400 * Self.day
        let cases: [FileRecord] = [
            record("Subfolder", kind: .folder, contentType: .folder, added: ancient),
            record("SomeApp.app", kind: .package, contentType: .applicationBundle, added: ancient),
            record("report-link.pdf", kind: .symlink, contentType: .symbolicLink, added: ancient),
            record("report alias", contentType: .aliasFile, added: ancient),
            record(".hidden-file", added: ancient),
            record("Old downloads", kind: .folder, contentType: .folder, added: ancient),
        ]
        for item in cases {
            #expect(marks(item) == [], "\(item.displayName) should carry no age marks")
        }
        // A download in progress carries no age marks either. These two stopped long ago, so Clear
        // Failed Downloads would propose them, and that is the one mark they carry.
        let partials: [FileRecord] = [
            record("movie.mp4.crdownload", contentType: nil, added: ancient),
            record("partial.part", contentType: nil, added: ancient, lastOpened: ancient),
        ]
        for item in partials {
            #expect(marks(item) == [.failedDownload], "\(item.displayName) should carry no age marks, only Failed download")
        }
    }

    /// A document package (a Keynote file, say) is opened like a document, so it is marked like one.
    @Test func documentPackageIsMarkedLikeAFile() {
        let ancient = Self.now - 400 * Self.day
        let package = record("slides.key", kind: .package, contentType: .package, added: ancient)
        #expect(package.recordsLastOpened)
        #expect(marks(package) == [.neverOpened, .old])
    }

    /// When the date could not be read at all (a volume without extended attributes, say), a
    /// missing date is unknown, so the item is not called Never opened, and not Old either.
    @Test func unreadableLastOpenedGivesNoMarks() {
        let ancient = Self.now - 400 * Self.day
        let unreadable = record(added: ancient, canReadLastOpened: false)
        #expect(!unreadable.recordsLastOpened)
        #expect(marks(unreadable) == [])
    }

    @Test func recordsLastOpenedByKind() {
        #expect(record(kind: .file).recordsLastOpened)
        #expect(record(kind: .file, contentType: nil).recordsLastOpened)
        #expect(record(kind: .package, contentType: .package).recordsLastOpened)
        #expect(record(kind: .package, contentType: nil).recordsLastOpened)
        #expect(!record(kind: .package, contentType: .applicationBundle).recordsLastOpened)
        #expect(!record(kind: .folder, contentType: .folder).recordsLastOpened)
        #expect(!record(kind: .symlink, contentType: .symbolicLink).recordsLastOpened)
        #expect(!record(kind: .file, contentType: .aliasFile).recordsLastOpened)
        #expect(!record(kind: .file, canReadLastOpened: false).recordsLastOpened)
    }

    // MARK: - Settings

    @Test func customThresholdsApply() {
        let now = Self.now
        let settings = CleanupSettings(unusedAfterDays: 7, oldAfterDays: 14)
        #expect(marks(record(added: now - 7 * Self.day), settings: settings) == [])
        #expect(marks(record(added: now - (7 * Self.day + 1)), settings: settings) == [.neverOpened])
        #expect(marks(record(added: now - (14 * Self.day + 1)), settings: settings) == [.neverOpened, .old])
        #expect(marks(record(added: now - 20 * Self.day, lastOpened: now - 8 * Self.day), settings: settings) == [.unused, .old])
    }
}
