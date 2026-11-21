import FileStoreCore
import Foundation
import Testing

/// Remove Used Installers with real disk images: read without prompts or writes, always detached,
/// never one someone else has open, and attached only once thanks to the cache (decision record
/// 0013). Serialized: each test mounts images, and the counts must be its own. Each test has its
/// own private mount folder, so none can touch another's mounts.
@Suite("Disk images", .serialized)
struct DiskImageTests {
    private typealias Names = FakeDownloadsFolder.Names

    private func withImages(_ body: (FakeDownloadsFolder, URL) async throws -> Void) async throws {
        let mountFolder = try TemporaryFolder.make(prefix: "Mounts")
        defer { mountFolder.remove() }
        try await withFakeDownloadsFolder(includingDiskImage: true) { fixture in
            try await body(fixture, mountFolder.url.appending(path: "root", directoryHint: .isDirectory))
            #expect(try DiskImages.anythingMounted(inside: mountFolder.url) == false, "something is still mounted")
        }
    }

    /// Mounts for one test, prepared as the app prepares its own at launch: planning makes no folder.
    private func prepared(_ root: URL, tool: SystemTool = SystemTool()) async -> DiskImageMounts {
        let mounts = DiskImageMounts(root: root, tool: tool)
        await mounts.prepare()
        return mounts
    }

    private func plan(
        _ fixture: FakeDownloadsFolder,
        mounts: DiskImageMounts,
        cache: (any InstallerFactsReading)? = nil,
        receipts: [InstallReceipt] = [],
        keeping keptItems: KeptItems = KeptItems(),
        onProgress: (@Sendable (CleanupPlanningProgress) -> Void)? = nil
    ) async throws -> CleanupPlan {
        let records = try await RelocationPlans.records(in: fixture.url)
        return try #require(try await CleanupPlanners.plan(
            .removeUsedInstallers,
            records: records,
            in: .temporary(fixture.url),
            eligibility: CandidateEligibility(),
            keptItems: keptItems,
            installers: .testing(applications: [fixture.applicationsURL], cache: cache, receipts: receipts, mounts: mounts),
            onProgress: onProgress
        ))
    }

    /// "name: strong" or "name: possible", in plan order.
    private func proposals(_ plan: CleanupPlan) -> [String] {
        plan.changes.map { change in
            guard case .usedInstaller(let evidence) = change.reason else { return "\(change.record.displayName): ?" }
            return "\(change.record.displayName): \(evidence.strength == .strong ? "strong" : "possible")"
        }
    }

    // MARK: - The plan

    @Test func theFixturesInstallersArePlannedAsTheRuleSays() async throws {
        try await withImages { fixture, root in
            let calls = ToolCalls()
            let plan = try await plan(fixture, mounts: await prepared(root, tool: calls.tool))
            #expect(proposals(plan) == [
                "\(Names.package): possible",
                "\(Names.encryptedImage): possible",
                "\(Names.diskImage): strong",
                "\(Names.usedAppZip): strong",
            ])
            let someApp = try #require(plan.changes.first { $0.record.displayName == Names.diskImage })
            #expect(someApp.reason == .usedInstaller(UsedInstallerEvidence(
                strength: .strong,
                name: "SomeApp",
                version: FakeDownloadsFolder.diskImageAppVersion,
                installedAppPath: fixture.applicationsURL.appending(path: Names.diskImageApp).path(percentEncoded: false),
                bundleIdentifier: FakeDownloadsFolder.diskImageAppIdentifier
            )))
            #expect(plan.skippedItems.map(\.url.lastPathComponent) == [Names.installer])
            #expect(plan.skippedItems.map(\.reason) == [.installerUnreadable(.damaged)])
            // The encrypted image was never attached, so nothing could ask for its password.
            #expect(calls.attaches == 1)
        }
    }

    @Test func aSecondSearchAttachesNothing() async throws {
        try await withImages { fixture, root in
            let calls = ToolCalls()
            let mounts = await prepared(root, tool: calls.tool)
            let log = try await ActivityLog.open(.inMemory)
            let first = try await plan(fixture, mounts: mounts, cache: log)
            #expect(calls.attaches == 1)
            #expect(Set(first.installerFactsRead.map { URL(filePath: $0.key.path).lastPathComponent }) == [
                Names.diskImage, Names.encryptedImage, Names.usedAppZip, Names.package, Names.installer, Names.appZip,
            ])
            try await log.storeInstallerFacts(first.installerFactsRead)

            let second = try await plan(fixture, mounts: mounts, cache: log)
            #expect(calls.attaches == 1)
            #expect(second.installerFactsRead.isEmpty)
            #expect(second.changes == first.changes)
        }
    }

    @Test func aKeptImageIsNeverRead() async throws {
        try await withImages { fixture, root in
            let calls = ToolCalls()
            let records = try await RelocationPlans.records(in: fixture.url)
            let log = try await ActivityLog.open(.inMemory)
            try await log.keep([try RelocationPlans.record(named: Names.diskImage, in: records)])
            let plan = try await plan(fixture, mounts: await prepared(root, tool: calls.tool), keeping: try await log.keptItems(for: log.downloads(at: fixture.url)))
            #expect(calls.attaches == 0)
            #expect(!plan.changes.contains { $0.record.displayName == Names.diskImage })
            #expect(!plan.skippedItems.contains { $0.url.lastPathComponent == Names.diskImage })
        }
    }

    @Test func aCancelledSearchThrowsAndLeavesNothingMounted() async throws {
        try await withImages { fixture, root in
            let mounts = await prepared(root)
            let records = try await RelocationPlans.records(in: fixture.url)
            let search = Task {
                try await CleanupPlanners.plan(
                    .removeUsedInstallers,
                    records: records,
                    in: .temporary(fixture.url),
                    eligibility: CandidateEligibility(),
                    keptItems: KeptItems(),
                    installers: .testing(applications: [fixture.applicationsURL], mounts: mounts)
                ) { _ in withUnsafeCurrentTask { $0?.cancel() } }
            }
            await #expect(throws: CleanupPlanningError.cancelled) {
                _ = try await search.value
            }
            for name in [Names.diskImage, Names.encryptedImage] {
                let stillAttached = try DiskImages.isAttached(fixture.url(for: name))
                #expect(!stillAttached, "\(name)")
            }
        }
    }

    /// A cancel that lands while the image is being attached: the tool is stopped, and attached
    /// images are listed all the same, so one the attach finished out of sight is ejected.
    @Test func aCancelDuringAttachStillLooksForAnAttachmentToEject() async throws {
        try await withImages { fixture, root in
            let image = fixture.url(for: Names.diskImage)
            let calls = ConcurrentLog<[String]>()
            let tool = SystemTool { executable, arguments in
                calls.append([executable] + arguments)
                if arguments.starts(with: ["image", "attach"]) {
                    withUnsafeCurrentTask { $0?.cancel() }
                }
            }
            let mounts = await prepared(root, tool: tool)
            let reading = Task { await DiskImageReader.read(at: image, mounts: mounts) }
            #expect(await reading.value == .cancelled)
            let after = calls.values.drop { !($0.count > 2 && $0[1] == "image" && $0[2] == "attach") }
            #expect(after.contains { $0.last == "-plist" && $0.contains("info") }, "attached images were not listed after the cancel")
            let stillAttached = try DiskImages.isAttached(image)
            #expect(!stillAttached)
        }
    }

    @Test func aSearchRightAfterACancelledOneWaitsForItsEjects() async throws {
        try await withImages { fixture, root in
            let mounts = await prepared(root)
            let records = try await RelocationPlans.records(in: fixture.url)
            let first = Task {
                try await CleanupPlanners.plan(
                    .removeUsedInstallers, records: records, in: .temporary(fixture.url), eligibility: CandidateEligibility(), keptItems: KeptItems(),
                    installers: .testing(applications: [fixture.applicationsURL], mounts: mounts)
                )
            }
            try await Task.sleep(for: .milliseconds(300))
            first.cancel()
            let again = try await plan(fixture, mounts: mounts)
            #expect(!again.skippedItems.contains { $0.reason == .diskImageInUse })
            #expect(again.changes.contains { $0.record.displayName == Names.diskImage })
            _ = try? await first.value
        }
    }

    @Test func planningWritesNothingToTheInstallersOrTheApps() async throws {
        try await withImages { fixture, root in
            for name in [Names.diskImage, Names.encryptedImage] {
                try ExtendedAttributes.setQuarantine(
                    ExtendedAttributes.quarantineValue(app: "Safari", downloadedAt: Date(timeIntervalSinceNow: -3_600)),
                    on: fixture.url(for: name)
                )
            }
            let before = (DiskImages.deepSnapshot(of: fixture.url), DiskImages.deepSnapshot(of: fixture.applicationsURL))
            _ = try await plan(fixture, mounts: await prepared(root))
            let after = (DiskImages.deepSnapshot(of: fixture.url), DiskImages.deepSnapshot(of: fixture.applicationsURL))
            #expect(after.0 == before.0)
            #expect(after.1 == before.1)
        }
    }

    @Test func anImageSomeoneHasOpenIsNotProposedAndStaysOpen() async throws {
        try await withImages { fixture, root in
            let image = fixture.url(for: Names.diskImage)
            let elsewhere = try DiskImages.privateFolder(root.deletingLastPathComponent().appending(path: "user", directoryHint: .isDirectory))
            let disk = try DiskImages.attach(image, randomIn: elsewhere)
            defer { DiskImages.detach(disk) }

            let plan = try await plan(fixture, mounts: await prepared(root))
            #expect(!plan.changes.contains { $0.record.displayName == Names.diskImage })
            #expect(plan.skippedItems.first { $0.url.lastPathComponent == Names.diskImage }?.reason == .diskImageInUse)
            #expect(try DiskImages.isAttached(image))
        }
    }

    @Test func anImageOpenedBetweenPlanAndExecuteStays() async throws {
        try await withImages { fixture, root in
            let plan = try await plan(fixture, mounts: await prepared(root))
            let image = fixture.url(for: Names.diskImage)
            let change = try #require(plan.changes.first { $0.record.displayName == Names.diskImage })
            let elsewhere = try DiskImages.privateFolder(root.deletingLastPathComponent().appending(path: "user", directoryHint: .isDirectory))
            let disk = try DiskImages.attach(image, randomIn: elsewhere)
            defer { DiskImages.detach(disk) }

            let log = try await ActivityLog.open(.inMemory)
            let result = await CleanupExecutor(recorder: log, applicationFolders: [fixture.applicationsURL])
                .execute(plan: plan, confirmedChangeIDs: [change.id])
            #expect(try RelocationPlans.outcome(for: Names.diskImage, in: result) == .skipped(.diskImageInUse))
            #expect(DiskState.exists(image))
        }
    }

    @Test func progressCountsEveryInstallerFromTheFirstReportToTheLast() async throws {
        try await withImages { fixture, root in
            let reports = ConcurrentLog<CleanupPlanningProgress>()
            _ = try await plan(fixture, mounts: await prepared(root)) { reports.append($0) }
            let values = reports.values
            let total = try #require(values.first?.itemsToCheck)
            // Every zip, package and disk image at the top: none is known to be an installer yet.
            #expect(total == 10)
            #expect(values.first?.itemsChecked == 0)
            #expect(values.last?.itemsChecked == total)
            #expect(zip(values, values.dropFirst()).allSatisfy { $0.itemsChecked <= $1.itemsChecked })
        }
    }

    // MARK: - One image

    @Test func theFixtureImageGivesItsAppAndIsDetached() async throws {
        try await withImages { fixture, root in
            let reading = await DiskImageReader.read(at: fixture.url(for: Names.diskImage), mounts: await prepared(root))
            #expect(reading == .facts(.apps([BundleFacts(
                name: "SomeApp",
                identifier: FakeDownloadsFolder.diskImageAppIdentifier,
                shortVersion: FakeDownloadsFolder.diskImageAppVersion,
                build: FakeDownloadsFolder.diskImageAppBuild
            )])))
            let stillAttached = try DiskImages.isAttached(fixture.url(for: Names.diskImage))
            #expect(!stillAttached)
        }
    }

    @Test func passwordAndLicenceImagesAreNeverAttached() async throws {
        try await withImages { fixture, root in
            let calls = ToolCalls()
            let mounts = await prepared(root, tool: calls.tool)
            let start = ContinuousClock.now
            #expect(await DiskImageReader.read(at: fixture.url(for: Names.encryptedImage), mounts: mounts) == .facts(.unreadable(.passwordProtected)))
            #expect(ContinuousClock.now - start < .seconds(5))

            let staging = try TemporaryFolder.make(prefix: "Licence")
            defer { staging.remove() }
            let licensed = staging.url.appending(path: "Licensed-1.0.dmg")
            try DiskImages.licensedCopy(of: fixture.url(for: Names.diskImage), to: licensed, staging: staging.url)
            #expect(await DiskImageReader.read(at: licensed, mounts: mounts) == .facts(.unreadable(.licenseAgreement)))
            #expect(calls.attaches == 0)
        }
    }

    @Test func aCancelWhileMountedStillDetaches() async throws {
        try await withImages { fixture, root in
            let image = fixture.url(for: Names.diskImage)
            let mounts = await prepared(root)
            let reading = Task {
                await DiskImageReader.read(at: image, mounts: mounts) {
                    withUnsafeCurrentTask { $0?.cancel() }
                    return true
                }
            }
            #expect(await reading.value == .cancelled)
            let stillAttached = try DiskImages.isAttached(image)
            #expect(!stillAttached)
        }
    }

    @Test func anErrorOnceMountedStillDetaches() async throws {
        try await withImages { fixture, root in
            let image = fixture.url(for: Names.diskImage)
            let reading = await DiskImageReader.read(at: image, mounts: await prepared(root)) {
                #expect((try? DiskImages.isAttached(image)) == true)
                return false
            }
            // A failure that says nothing about the file, so it is tried again next time.
            #expect(reading == .facts(.unreadable(.couldNotOpen)))
            let stillAttached = try DiskImages.isAttached(image)
            #expect(!stillAttached)
        }
    }

    @Test func theSweepDetachesOnlyWhatAGoneProcessLeft() async throws {
        try await withImages { fixture, root in
            _ = try DiskImages.privateFolder(root)
            // A process ID nothing has now, and launchd's, which is always there.
            let gone = try #require((90_000...99_999).reversed().first { kill(pid_t($0), 0) == -1 && errno == ESRCH })
            let left = try DiskImages.privateFolder(root.appending(path: "\(gone)/1", directoryHint: .isDirectory))
            let alive = try DiskImages.privateFolder(root.appending(path: "1/1", directoryHint: .isDirectory))
            let elsewhere = try DiskImages.privateFolder(root.deletingLastPathComponent().appending(path: "user", directoryHint: .isDirectory))
            let copies = try TemporaryFolder.make(prefix: "Copies")
            defer { copies.remove() }
            var images: [URL] = []
            for index in 0..<3 {
                let copy = copies.url.appending(path: "copy-\(index).dmg")
                try FileManager.default.copyItem(at: fixture.url(for: Names.diskImage), to: copy)
                images.append(copy)
            }
            let leftDisk = try DiskImages.attach(images[0], mountPoint: left)
            let aliveDisk = try DiskImages.attach(images[1], mountPoint: alive)
            let elsewhereDisk = try DiskImages.attach(images[2], randomIn: elsewhere)
            defer {
                for disk in [leftDisk, aliveDisk, elsewhereDisk] { DiskImages.detach(disk) }
            }

            #expect(await DiskImageMounts(root: root).prepare())
            let stillAttached = try DiskImages.isAttached(images[0])
            #expect(!stillAttached)
            #expect(try DiskImages.isAttached(images[1]))
            #expect(try DiskImages.isAttached(images[2]))
        }
    }

    @Test func aMountFolderThatIsNotPrivateIsRefused() async throws {
        let folder = try TemporaryFolder.make(prefix: "Mounts")
        defer { folder.remove() }
        let root = folder.url.appending(path: "root", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o755])
        #expect(await !DiskImageMounts(root: root).prepare())
        let link = folder.url.appending(path: "link", directoryHint: .isDirectory)
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: try DiskImages.privateFolder(folder.url.appending(path: "real")))
        #expect(await !DiskImageMounts(root: link).prepare())
    }
}
