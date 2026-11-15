import FileStoreCore
import Foundation
import Testing

/// What the scan reads for Clear Failed Downloads: inside each `.download` folder and nowhere
/// else, links never followed, within its limits. And the plan the fake Downloads folder gives.
@Suite("Failed download scan")
struct FailedDownloadScanTests {
    private func records(in folder: URL) async throws -> [FileRecord] {
        try await RelocationPlans.records(in: folder)
    }

    private func record(_ name: String, in folder: URL) async throws -> FileRecord {
        try RelocationPlans.record(named: name, in: try await records(in: folder))
    }

    @Test func theFakeFolderProposesExactlyItsThreeStalePartials() async throws {
        try await withFakeDownloadsFolder { fixture in
            typealias Names = FakeDownloadsFolder.Names
            let plan = try #require(try await FailedDownloads.plan(fixture.url))
            #expect(plan.changes.map(\.record.displayName) == [Names.chromeDownload, Names.partialDownload, Names.safariDownload])
            #expect(plan.skippedItems.isEmpty)
            let chrome = try #require(plan.changes.first)
            guard case .failedDownload(_, let finished) = chrome.reason else {
                Issue.record("expected a failed-download reason, got \(chrome.reason)")
                return
            }
            #expect(finished == Names.finishedDownload)
            // Still in progress, so not proposed; and never anything else.
            #expect(!plan.changes.contains { $0.record.displayName == Names.freshDownload })
        }
    }

    @Test func theSafariPackageIsReadAndNothingElseIs() async throws {
        try await withFakeDownloadsFolder { fixture in
            typealias Names = FakeDownloadsFolder.Names
            let all = try await records(in: fixture.url)
            let safari = try RelocationPlans.record(named: Names.safariDownload, in: all)
            let contents = try #require(safari.readContents)
            #expect(contents.itemCount == 2)
            let info = try Data(contentsOf: fixture.url(for: "\(Names.safariDownload)/Info.plist"))
            #expect(contents.totalSizeInBytes == Int64("partial keynote".utf8.count + info.count))
            #expect(safari.contentSizeInBytes == contents.totalSizeInBytes)
            #expect(safari.lastChange != nil)
            // Every other folder and package, and every file, is left unread.
            for record in all where record.displayName != Names.safariDownload {
                #expect(record.packageContents == nil, "\(record.displayName) was read into")
            }
        }
    }

    @Test func theNewestDateInsideCountsAndALinkInsideIsNotFollowed() async throws {
        try await withTemporaryFolderAsync { folder in
            let package = folder.appending(path: "a.zip.download", directoryHint: .isDirectory)
            let nested = package.appending(path: "nested", directoryHint: .isDirectory)
            let outside = folder.appending(path: "outside", directoryHint: .isDirectory)
            try FileManager.default.createDirectory(at: nested, withIntermediateDirectories: true)
            try FileManager.default.createDirectory(at: outside, withIntermediateDirectories: true)
            try Data("12345".utf8).write(to: package.appending(path: "a.zip"))
            try Data("123".utf8).write(to: nested.appending(path: "deep.bin"))
            try Data(count: 10_000).write(to: outside.appending(path: "big.bin"))
            try FileManager.default.createSymbolicLink(at: package.appending(path: "link"), withDestinationURL: outside)
            let old = Date(timeIntervalSinceNow: -5 * 24 * 60 * 60)
            let newest = Date(timeIntervalSinceNow: -2 * 24 * 60 * 60)
            try FileDates.set(package.appending(path: "a.zip"), to: old)
            try FileDates.set(package.appending(path: "link"), to: old)
            try FileDates.set(nested, to: old)
            try FileDates.set(nested.appending(path: "deep.bin"), to: newest)
            try FileDates.set(package, to: old)
            // Whatever is behind the link is newer still, and never counted.
            try FileDates.set(outside.appending(path: "big.bin"), to: Date(timeIntervalSinceNow: -60))

            let contents = try #require(try await record("a.zip.download", in: folder).readContents)
            #expect(contents.itemCount == 4)
            #expect(contents.totalSizeInBytes == 8)
            let reportedNewest = try #require(contents.newestModificationDate)
            #expect(abs(reportedNewest.timeIntervalSince(newest)) < 0.001)
            let plan = try #require(try await FailedDownloads.plan(folder))
            #expect(plan.changes.map(\.record.displayName) == ["a.zip.download"])
        }
    }

    @Test func aFolderTooBigOrTooDeepToBeADownloadIsNotProposedOrReported() async throws {
        try await withTemporaryFolderAsync { folder in
            let wide = folder.appending(path: "wide.download", directoryHint: .isDirectory)
            try FileManager.default.createDirectory(at: wide, withIntermediateDirectories: false)
            for index in 0...PackageContents.maximumItemCount {
                try Data().write(to: wide.appending(path: "item-\(index)"))
            }
            var deep = folder.appending(path: "deep.download", directoryHint: .isDirectory)
            var levels: [URL] = []
            for level in 0...PackageContents.maximumDepth {
                levels.append(deep)
                deep = deep.appending(path: "level-\(level)", directoryHint: .isDirectory)
            }
            try FileManager.default.createDirectory(at: deep, withIntermediateDirectories: true)
            try FileDates.settle(levels.reversed() + [wide], base: Date(timeIntervalSinceNow: -3 * 24 * 60 * 60))

            #expect(try await record("wide.download", in: folder).packageContents == .failure(.tooManyItems))
            #expect(try await record("deep.download", in: folder).packageContents == .failure(.tooManyItems))
            let plan = try #require(try await FailedDownloads.plan(folder))
            #expect(plan.isEmpty)
            #expect(plan.skippedItems.isEmpty)
        }
    }

    @Test func aFolderThatMayNotBeReadIsReportedAsNotChecked() async throws {
        try await withTemporaryFolderAsync { folder in
            let package = folder.appending(path: "private.download", directoryHint: .isDirectory)
            try FileManager.default.createDirectory(at: package, withIntermediateDirectories: false)
            try Data("x".utf8).write(to: package.appending(path: "x"))
            try FileDates.set(package, to: Date(timeIntervalSinceNow: -3 * 24 * 60 * 60))
            try FileManager.default.setAttributes([.posixPermissions: 0o000], ofItemAtPath: package.path(percentEncoded: false))
            defer { try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: package.path(percentEncoded: false)) }

            #expect(try await record("private.download", in: folder).packageContents == .failure(.accessDenied))
            let plan = try #require(try await FailedDownloads.plan(folder))
            #expect(plan.changes.isEmpty)
            #expect(plan.skippedItems.map(\.reason) == [.accessDenied])
        }
    }

    @Test func aPartialHiddenByItsFlagIsNeverListed() async throws {
        try await withTemporaryFolderAsync { folder in
            try FailedDownloads.write(in: folder)
            var hidden = folder.appending(path: FailedDownloads.chrome)
            var values = URLResourceValues()
            values.isHidden = true
            try hidden.setResourceValues(values)

            let plan = try #require(try await FailedDownloads.plan(folder))
            #expect(plan.changes.map(\.record.displayName) == [FailedDownloads.firefox, FailedDownloads.safari])
        }
    }
}
