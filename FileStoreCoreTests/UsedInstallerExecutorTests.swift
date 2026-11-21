import FileStoreCore
import Foundation
import Testing

/// Remove Used Installers carried out: through the real Trash, with `TrashedFiles` removing the
/// test's own installers afterwards. Right before each moves, the installer must be the very file
/// planned, and the installed app the reason names must still be there, in the executor's own
/// application folders (decision record 0012). The app is only ever read.
@Suite("Used installer executor")
struct UsedInstallerExecutorTests {
    private typealias Names = FakeDownloadsFolder.Names

    private func plan(_ fixture: FakeDownloadsFolder, now: Date = .now, receipts: [InstallReceipt] = []) async throws -> CleanupPlan {
        let records = try await RelocationPlans.records(in: fixture.url)
        return try #require(try await CleanupPlanners.plan(
            .removeUsedInstallers,
            records: records,
            in: .temporary(fixture.url),
            eligibility: CandidateEligibility(),
            keptItems: KeptItems(),
            installers: .testing(applications: [fixture.applicationsURL], receipts: receipts),
            now: now
        ))
    }

    private func execute(
        _ plan: CleanupPlan,
        _ fixture: FakeDownloadsFolder,
        confirming names: Set<String>? = nil,
        recorder: any CleanupRecording,
        applicationFolders: [URL]? = nil
    ) async -> CleanupResult {
        let ids = plan.changes.filter { names?.contains($0.record.displayName) ?? true }.map(\.id)
        return await CleanupExecutor(recorder: testRecorder(recorder), applicationFolders: applicationFolders ?? [fixture.applicationsURL], receipts: .fixed([]))
            .execute(plan: plan, confirmedChangeIDs: Set(ids))
    }

    /// The installers as written, for `TrashedFiles` to recognise them in the Trash.
    private func contents(_ fixture: FakeDownloadsFolder) throws -> [String: Data] {
        try Dictionary(uniqueKeysWithValues: [Names.usedAppZip, Names.package].map { ($0, try Data(contentsOf: fixture.url(for: $0))) })
    }

    private func cleanUp(_ result: CleanupResult, _ contents: [String: Data]) {
        TrashedFiles.remove(result) { contents[$0.lastPathComponent] }
    }

    private func outcome(_ name: String, in result: CleanupResult) throws -> CleanupItemOutcome {
        try RelocationPlans.outcome(for: name, in: result)
    }

    // MARK: - The run

    @Test func theTickedInstallerGoesToTheTrashAndTheLogSaysEnoughToUndoIt() async throws {
        try await withFakeDownloadsFolder { fixture in
            let log = try await ActivityLog.open(.inMemory)
            let contents = try contents(fixture)
            let plan = try await plan(fixture)
            let widget = try #require(plan.changes.first { $0.record.displayName == Names.usedAppZip })
            #expect(!widget.reason.isPossibleMatch)
            #expect(plan.changes.first { $0.record.displayName == Names.package }?.reason.isPossibleMatch == true)

            // The preview ticks only the strong match.
            let result = await execute(plan, fixture, confirming: [Names.usedAppZip], recorder: log)
            defer { cleanUp(result, contents) }

            #expect(result.trashedCount == 1)
            #expect(result.action == .removeUsedInstallers)
            #expect(!DiskState.exists(fixture.url(for: Names.usedAppZip)))
            #expect(DiskState.exists(fixture.url(for: Names.package)))
            // The installed app is untouched.
            #expect(DiskState.exists(fixture.applicationsURL.appending(path: Names.usedAppZipApp)))

            let runID = try #require(result.runID)
            #expect(try await log.run(id: runID)?.action == .removeUsedInstallers)
            let rows = try await log.changes(inRun: runID)
            #expect(rows.map(\.outcome) == [.trashed])
            #expect(rows.map(\.reason) == [widget.reason])
            #expect(rows.map(\.isFolder) == [false])
            #expect(rows.allSatisfy { $0.fileNumber != nil && $0.contentHash == nil && !$0.originalPath.hasSuffix("/") })
            #expect(rows.first?.sizeInBytes == widget.sizeInBytes)
            #expect(rows.first?.dateModified == widget.dateModified)
            #expect(try await log.totals() == ActivityTotals(bytesMovedToTrash: widget.sizeInBytes, filesCleaned: 1))
        }
    }

    @Test func runningItAgainRightAfterProposesNothing() async throws {
        try await withFakeDownloadsFolder { fixture in
            let log = try await ActivityLog.open(.inMemory)
            let contents = try contents(fixture)
            let result = await execute(try await plan(fixture), fixture, recorder: log)
            defer { cleanUp(result, contents) }
            #expect(result.trashedCount == 2)

            let again = try await plan(fixture)
            #expect(again.isEmpty)
            #expect(again.skippedItems.map(\.url.lastPathComponent) == [Names.installer])
        }
    }

    @Test func aPackageWithItsReceiptIsStrongAndGoes() async throws {
        try await withFakeDownloadsFolder { fixture in
            let receipt = InstallReceipt(identifier: FakeDownloadsFolder.packageIdentifier, version: FakeDownloadsFolder.packageVersion)
            let plan = try await plan(fixture, receipts: [receipt])
            let gizmo = try #require(plan.changes.first { $0.record.displayName == Names.package })
            #expect(!gizmo.reason.isPossibleMatch)
            let log = try await ActivityLog.open(.inMemory)
            let contents = try contents(fixture)
            let result = await execute(plan, fixture, confirming: [Names.package], recorder: log)
            defer { cleanUp(result, contents) }
            #expect(try outcome(Names.package, in: result).isTrashed)
        }
    }

    /// An app that gives only a build, no short version: matched by build, and checked again by it.
    @Test func anAppWithOnlyABuildIsStrongAndGoes() async throws {
        try await withTemporaryFolderAsync { folder in
            let downloads = folder.appending(path: "Downloads", directoryHint: .isDirectory)
            let applications = folder.appending(path: "Applications", directoryHint: .isDirectory)
            let staging = folder.appending(path: "Staging", directoryHint: .isDirectory)
            for url in [downloads, applications, staging] {
                try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
            }
            func writeBuildOnlyApp(in parent: URL) throws -> URL {
                let app = parent.appending(path: "Builder.app")
                try FileManager.default.createDirectory(at: app.appending(path: "Contents"), withIntermediateDirectories: true)
                try PropertyListSerialization.data(fromPropertyList: ["CFBundleIdentifier": "com.example.Builder", "CFBundleVersion": "42"], format: .xml, options: 0)
                    .write(to: app.appending(path: "Contents/Info.plist"))
                return app
            }
            _ = try writeBuildOnlyApp(in: applications)
            let zip = downloads.appending(path: "Builder.zip")
            try ZipTools.ditto(try writeBuildOnlyApp(in: staging), to: zip, keepParent: true)
            try FileDates.settle([zip])
            let data = try Data(contentsOf: zip)

            let records = try await RelocationPlans.records(in: downloads)
            let plan = try #require(try await CleanupPlanners.plan(
                .removeUsedInstallers, records: records, in: .temporary(downloads), eligibility: CandidateEligibility(), keptItems: KeptItems(),
                installers: .testing(applications: [applications])
            ))
            let change = try #require(plan.changes.first)
            #expect(!change.reason.isPossibleMatch)
            let log = try await ActivityLog.open(.inMemory)
            let result = await CleanupExecutor(recorder: log, applicationFolders: [applications]).execute(plan: plan, confirmedChangeIDs: [change.id])
            defer { TrashedFiles.remove(result) { _ in data } }
            #expect(try outcome("Builder.zip", in: result).isTrashed)
        }
    }

    // MARK: - Changed between plan and execute

    @Test func anAppRemovedDowngradedOrReplacedKeepsItsInstaller() async throws {
        try await withFakeDownloadsFolder { fixture in
            let log = try await ActivityLog.open(.inMemory)
            let plan = try await plan(fixture)
            let apps = fixture.applicationsURL
            // The zip's app is downgraded; the package's (a possible match) is removed.
            try FakeDownloadsFolder.writeApp(at: apps.appending(path: Names.usedAppZipApp), identifier: FakeDownloadsFolder.usedAppZipAppIdentifier, version: "3.1", build: "310")
            try FileManager.default.removeItem(at: apps.appending(path: Names.packageApp))

            let result = await execute(plan, fixture, recorder: log)
            #expect(try outcome(Names.usedAppZip, in: result) == .skipped(.installedAppChanged(name: "Widget")))
            #expect(try outcome(Names.package, in: result) == .skipped(.installedAppMissing(name: "Gizmo")))
            #expect(result.trashedCount == 0)
        }
    }

    @Test func anAppReplacedByALinkOrGivenAnotherIdentifierKeepsItsInstaller() async throws {
        try await withFakeDownloadsFolder { fixture in
            let log = try await ActivityLog.open(.inMemory)
            let plan = try await plan(fixture)
            let apps = fixture.applicationsURL
            try FakeDownloadsFolder.writeApp(at: apps.appending(path: Names.usedAppZipApp), identifier: "com.example.SomethingElse", version: "3.2", build: "320")
            let gizmo = apps.appending(path: Names.packageApp)
            try FileManager.default.moveItem(at: gizmo, to: apps.appending(path: "Moved.app"))
            try FileManager.default.createSymbolicLink(at: gizmo, withDestinationURL: apps.appending(path: "Moved.app"))

            let result = await execute(plan, fixture, recorder: log)
            #expect(try outcome(Names.usedAppZip, in: result) == .skipped(.installedAppChanged(name: "Widget")))
            #expect(try outcome(Names.package, in: result) == .skipped(.installedAppChanged(name: "Gizmo")))
        }
    }

    @Test func anInstallerChangedKeptLockedOrSwappedForALinkStays() async throws {
        try await withFakeDownloadsFolder { fixture in
            let log = try await ActivityLog.open(.inMemory)
            let receipt = InstallReceipt(identifier: FakeDownloadsFolder.packageIdentifier, version: FakeDownloadsFolder.packageVersion)
            let plan = try await plan(fixture, receipts: [receipt])
            let records = try await RelocationPlans.records(in: fixture.url)

            // The zip is marked Kept after planning; the package is rewritten, then swapped for a link.
            try await log.keep([try RelocationPlans.record(named: Names.usedAppZip, in: records)])
            let first = await execute(plan, fixture, confirming: [Names.usedAppZip], recorder: log)
            #expect(try outcome(Names.usedAppZip, in: first) == .skipped(.markedKept))

            let package = fixture.url(for: Names.package)
            try Data("rewritten".utf8).write(to: package)
            let second = await execute(plan, fixture, confirming: [Names.package], recorder: log)
            #expect(try outcome(Names.package, in: second) == .skipped(.changedSinceScan))

            try FileManager.default.removeItem(at: package)
            try FileManager.default.createSymbolicLink(at: package, withDestinationURL: fixture.url(for: Names.installer))
            let third = await execute(plan, fixture, confirming: [Names.package], recorder: log)
            #expect(try outcome(Names.package, in: third) == .skipped(.notARegularFile))
        }
    }

    @Test func aLockedInstallerFailsAloneWithAClearError() async throws {
        try await withFakeDownloadsFolder { fixture in
            let log = try await ActivityLog.open(.inMemory)
            let contents = try contents(fixture)
            let plan = try await plan(fixture)
            var zip = fixture.url(for: Names.usedAppZip)
            var values = URLResourceValues()
            values.isUserImmutable = true
            try zip.setResourceValues(values)
            defer {
                values.isUserImmutable = false
                try? zip.setResourceValues(values)
            }
            let result = await execute(plan, fixture, recorder: log)
            defer { cleanUp(result, contents) }
            #expect(try outcome(Names.usedAppZip, in: result) == .failed(.fileIsLocked))
            #expect(try outcome(Names.package, in: result).isTrashed)
        }
    }

    // MARK: - Plans built elsewhere

    @Test func aPlanBuiltElsewhereMovesNothing() async throws {
        try await withFakeDownloadsFolder { fixture in
            let log = try await ActivityLog.open(.inMemory)
            let plan = try await plan(fixture)
            // The executor's own folders do not hold the reason's app.
            let elsewhere = await execute(plan, fixture, recorder: log, applicationFolders: [FileManager.default.temporaryDirectory])
            #expect(elsewhere.items.allSatisfy { $0.outcome == .skipped(.notInPlan) })

            // A file that is not an installer, given this action's reason.
            let records = try await RelocationPlans.records(in: fixture.url)
            let widget = try #require(plan.changes.first { $0.record.displayName == Names.usedAppZip })
            let report = try RelocationPlans.record(named: Names.reportPDF, in: records)
            let forged = CleanupPlan(action: .removeUsedInstallers, folder: log.downloads(at: fixture.url), changes: [
                ProposedChange(record: report, operation: .moveToTrash, reason: widget.reason),
                // An installer with another action's reason.
                ProposedChange(record: widget.record, operation: .moveToTrash, reason: .unpackedZip(unpackedTo: "Widget.app")),
            ])
            let result = await execute(forged, fixture, recorder: log)
            #expect(result.items.map(\.outcome) == [.skipped(.notInPlan), .skipped(.notInPlan)])
            #expect(DiskState.exists(fixture.url(for: Names.reportPDF)))
        }
    }

    // MARK: - Undo

    @Test func undoingTheRunPutsTheInstallersBackFromTheRealTrash() async throws {
        try await withFakeDownloadsFolder { fixture in
            let log = try await ActivityLog.open(.inMemory)
            let contents = try contents(fixture)
            let result = await execute(try await plan(fixture), fixture, recorder: log)
            defer { cleanUp(result, contents) }
            #expect(result.trashedCount == 2)
            let runID = try #require(result.runID)

            let undo = try await UndoFixtures.undo(.run(runID), in: fixture.url, trash: .system, log: log)
            #expect(Set(undo.undone.map(\.originalName)) == [Names.usedAppZip, Names.package])
            #expect(undo.notUndone.isEmpty)
            for (name, data) in contents {
                #expect((try? Data(contentsOf: fixture.url(for: name))) == data, "\(name)")
            }
            #expect(try await log.totals() == .zero)
            // Put back just now, they are inside the grace period again, and proposed once it has passed.
            #expect(try await plan(fixture).isEmpty)
            let later = try await plan(fixture, now: Date(timeIntervalSinceNow: 2 * 60 * 60))
            #expect(Set(later.changes.map(\.record.displayName)) == [Names.usedAppZip, Names.package])
        }
    }
}

private extension CleanupItemOutcome {
    var isTrashed: Bool {
        if case .trashed = self {
            return true
        }
        return false
    }
}
