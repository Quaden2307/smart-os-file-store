import FileStoreCore
import Foundation
import Testing
import UniformTypeIdentifiers

/// Remove Used Installers' rule, on values alone (decision record 0012): strong matches by bundle
/// identifier and version, possible matches by name, installed versions older than the installer's,
/// several apps in one installer, packages with receipts, and which files take part.
@Suite("Used installer rule")
struct InstallerRuleTests {
    private let now = Date(timeIntervalSince1970: 1_800_000_000)

    private func app(_ name: String, _ id: String?, _ version: String?, build: String? = nil) -> BundleFacts {
        BundleFacts(name: name, identifier: id, shortVersion: version, build: build)
    }

    private func installed(_ name: String, _ id: String?, _ version: String?, build: String? = nil, in folder: String = "/Applications") -> InstalledApp {
        InstalledApp(facts: app(name, id, version, build: build), url: URL(filePath: "\(folder)/\(name).app", directoryHint: .isDirectory))
    }

    private func evidence(
        _ fileName: String,
        _ facts: InstallerFacts?,
        _ apps: [InstalledApp],
        receipts: [InstallReceipt] = []
    ) -> InstallerPlanner.Evidence {
        InstallerPlanner.evidence(
            fileName: fileName,
            facts: facts,
            apps: apps,
            receipts: Dictionary(receipts.map { ($0.identifier, $0) }, uniquingKeysWith: { first, _ in first })
        )
    }

    private let someApp = InstalledApp(
        facts: BundleFacts(name: "SomeApp", identifier: "com.example.SomeApp", shortVersion: "2.1", build: "210"),
        url: URL(filePath: "/Applications/SomeApp.app", directoryHint: .isDirectory)
    )

    // MARK: - Strong

    @Test func theSameIdentifierAndVersionIsStrongAndNamesTheInstalledApp() {
        let result = evidence("Installer.dmg", .apps([app("SomeApp", "com.example.SomeApp", "2.1", build: "210")]), [someApp])
        #expect(result == .strong(UsedInstallerEvidence(
            strength: .strong,
            name: "SomeApp",
            version: "2.1",
            installedAppPath: "/Applications/SomeApp.app",
            bundleIdentifier: "com.example.SomeApp"
        )))
    }

    @Test func aNewerInstalledVersionIsStrong() {
        #expect(isStrong(evidence("x.dmg", .apps([app("SomeApp", "com.example.SomeApp", "2.0.9")]), [someApp])))
        #expect(isStrong(evidence("x.dmg", .apps([app("SomeApp", "com.example.SomeApp", "2.1", build: "209")]), [someApp])))
    }

    /// The owner dropped the 24-hour rule: an app is installed the moment it is there, and the index
    /// keeps no install date at all.
    @Test func anAppInstalledMomentsAgoIsStrong() {
        let fresh = installed("Fresh", "com.example.Fresh", "1.0")
        #expect(isStrong(evidence("Fresh-1.0.zip", .apps([app("Fresh", "com.example.Fresh", "1.0")]), [fresh])))
    }

    @Test func anOlderInstalledVersionIsNeverProposedEvenWhenTheNamesMatch() {
        #expect(evidence("SomeApp-2.2.dmg", .apps([app("SomeApp", "com.example.SomeApp", "2.2")]), [someApp]) == .installedIsOlder)
        // The same version, but the installer's build is newer.
        #expect(evidence("SomeApp.dmg", .apps([app("SomeApp", "com.example.SomeApp", "2.1", build: "211")]), [someApp]) == .installedIsOlder)
        #expect(
            InstallerPlanner.finding(fileName: "SomeApp.dmg", facts: .apps([app("SomeApp", "com.example.SomeApp", "2.2")]), apps: [someApp], receipts: [:])
                == .notProposed
        )
    }

    @Test func anOlderCopyInOneFolderDoesNotHideANewerOneInAnother() {
        let old = installed("SomeApp", "com.example.SomeApp", "1.0", in: "/Applications")
        let current = installed("SomeApp", "com.example.SomeApp", "3.0", in: "/Users/someone/Applications")
        guard case .strong(let found) = evidence("x.dmg", .apps([app("SomeApp", "com.example.SomeApp", "2.1")]), [old, current]) else {
            Issue.record("not strong")
            return
        }
        #expect(found.installedAppPath == "/Users/someone/Applications/SomeApp.app")
    }

    @Test func versionsThatCannotBeComparedAreNoStrongMatch() {
        let beta = installed("SomeApp", "com.example.SomeApp", "2.1b3")
        #expect(evidence("SomeApp-2.1.dmg", .apps([app("SomeApp", "com.example.SomeApp", "2.1")]), [beta]).isPossible)
        #expect(evidence("Other.dmg", .apps([app("SomeApp", "com.example.SomeApp", "2.1")]), [beta]) == .none)
    }

    // MARK: - Several apps

    @Test func severalAppsAreStrongOnlyWhenEveryOneIsInstalled() {
        let other = installed("OtherApp", "com.example.OtherApp", "1.4")
        let both = InstallerFacts.apps([app("SomeApp", "com.example.SomeApp", "2.1"), app("OtherApp", "com.example.OtherApp", "1.4")])
        guard case .strong(let found) = evidence("Suite.dmg", both, [someApp, other]) else {
            Issue.record("not strong")
            return
        }
        #expect(found.name == "SomeApp")
        #expect(found.otherMatches == 1)

        // One missing: only the name rule, which matches nothing here.
        #expect(evidence("Suite.dmg", both, [someApp]) == .none)
        // One missing, but the name matches an installed app: possible.
        #expect(evidence("SomeApp-2.1.dmg", both, [someApp]).isPossible)
        // One older: not proposed.
        #expect(evidence("Suite.dmg", both, [someApp, installed("OtherApp", "com.example.OtherApp", "1.3")]) == .installedIsOlder)
    }

    // MARK: - Possible

    @Test func onlyTheNameMatchingIsAPossibleMatchLeftUnticked() {
        let result = evidence("SomeApp-2.1-arm64.dmg", .apps([app("SomeApp", "com.other.SomeApp", "2.1")]), [someApp])
        guard case .possible(let found) = result else {
            Issue.record("not possible: \(result)")
            return
        }
        #expect(found.strength == .possible)
        #expect(found.bundleIdentifier == nil)
        #expect(found.installedAppPath == "/Applications/SomeApp.app")
        #expect(ProposedChange.Reason.usedInstaller(found).isPossibleMatch)
        #expect(!ProposedChange.Reason.usedInstaller(UsedInstallerEvidence(strength: .strong, name: "a", version: nil, installedAppPath: nil, bundleIdentifier: nil)).isPossibleMatch)
        #expect(!ProposedChange.Reason.unpackedZip(unpackedTo: "x").isPossibleMatch)
    }

    @Test func anInstallerThatCouldNotBeReadFallsBackToItsName() {
        #expect(evidence("SomeApp-2.1.dmg", .unreadable(.passwordProtected), [someApp]).isPossible)
        #expect(evidence("SomeApp-2.1.dmg", nil, [someApp]).isPossible)
        // A disk image holding no app at its top level, a package inside say.
        #expect(evidence("SomeApp-2.1.dmg", .apps([]), [someApp]).isPossible)
        // Unread, and its name matches nothing: listed as not checked, with why.
        #expect(
            InstallerPlanner.finding(fileName: "Secret.dmg", facts: .unreadable(.passwordProtected), apps: [someApp], receipts: [:])
                == .notChecked(.installerUnreadable(.passwordProtected))
        )
    }

    @Test func noMatchIsNotProposed() {
        #expect(evidence("Other-1.0.dmg", .apps([app("Other", "com.example.Other", "1.0")]), [someApp]) == .none)
        #expect(InstallerPlanner.finding(fileName: "Other.dmg", facts: .apps([]), apps: [someApp], receipts: [:]) == .notProposed)
        #expect(evidence("SomeApp.dmg", .apps([app("SomeApp", "com.example.SomeApp", "2.1")]), []) == .none)
    }

    // MARK: - Packages

    private let package = PackageFacts(
        identifier: "com.example.SomeApp.pkg",
        version: "2.1",
        apps: [BundleFacts(name: "SomeApp", identifier: "com.example.SomeApp", shortVersion: "2.1", build: nil)]
    )

    @Test func aPackageIsStrongWithItsReceiptAndItsAppInstalled() {
        let result = evidence("Installer.pkg", .packages([package]), [someApp], receipts: [InstallReceipt(identifier: "com.example.SomeApp.pkg", version: "2.1.0")])
        #expect(isStrong(result))
        if case .strong(let found) = result {
            #expect(found.name == "SomeApp")
            #expect(found.installedAppPath == "/Applications/SomeApp.app")
        }
    }

    @Test func aPackageWithoutItsReceiptOrItsAppIsAtMostAPossibleMatch() {
        // No receipt: the name decides.
        #expect(evidence("SomeApp-2.1.pkg", .packages([package]), [someApp]).isPossible)
        #expect(evidence("Installer.pkg", .packages([package]), [someApp]) == .none)
        // The receipt stays after the app is dragged to the Trash; the app is gone.
        #expect(evidence("Installer.pkg", .packages([package]), [], receipts: [InstallReceipt(identifier: "com.example.SomeApp.pkg", version: "2.1")]) == .none)
        // A receipt older than the package: an update not installed yet.
        #expect(
            evidence("SomeApp.pkg", .packages([package]), [someApp], receipts: [InstallReceipt(identifier: "com.example.SomeApp.pkg", version: "2.0")])
                == .installedIsOlder
        )
    }

    @Test func aPackageOfSeveralPartsNeedsEveryReceipt() {
        let helper = PackageFacts(identifier: "com.example.helper.pkg", version: "1.0", apps: [])
        let receipts = [InstallReceipt(identifier: "com.example.SomeApp.pkg", version: "2.1")]
        #expect(evidence("Suite.pkg", .packages([package, helper]), [someApp], receipts: receipts) == .none)
        let all = receipts + [InstallReceipt(identifier: "com.example.helper.pkg", version: "1.0")]
        #expect(isStrong(evidence("Suite.pkg", .packages([package, helper]), [someApp], receipts: all)))
    }

    @Test func aPackageThatInstallsNoAppMatchesOnItsReceiptsAlone() {
        let driver = PackageFacts(identifier: "com.example.driver.pkg", version: "4.2", apps: [])
        let result = evidence("Driver.pkg", .packages([driver]), [], receipts: [InstallReceipt(identifier: "com.example.driver.pkg", version: "4.2")])
        #expect(result == .strong(UsedInstallerEvidence(
            strength: .strong,
            name: "com.example.driver.pkg",
            version: "4.2",
            installedAppPath: nil,
            bundleIdentifier: nil,
            receiptIdentifiers: ["com.example.driver.pkg"]
        )))
    }

    @Test func aPackagesAppCountsWhereverItIsInstalled() {
        // `PackageInfo` says `./SomeApp.app` under /Applications; the app was moved to ~/Applications.
        let moved = installed("SomeApp", "com.example.SomeApp", "2.1", in: "/Users/someone/Applications")
        #expect(isStrong(evidence("Installer.pkg", .packages([package]), [moved], receipts: [InstallReceipt(identifier: "com.example.SomeApp.pkg", version: "2.1")])))
    }

    // MARK: - Names and versions

    @Test func namesAreCleanedOfVersionsPlatformsAndCopySuffixes() {
        #expect(InstallerName.key(ofFileName: "SomeApp-2.1-arm64.dmg") == InstallerName.key(ofAppName: "SomeApp"))
        #expect(InstallerName.key(ofFileName: "SomeApp 2.1 (1).dmg") == "someapp")
        #expect(InstallerName.key(ofFileName: "SomeApp copy.zip") == "someapp")
        #expect(InstallerName.key(ofFileName: "SomeApp-v2.1.0b3-universal.pkg") == "someapp")
        #expect(InstallerName.key(ofFileName: "SomeApp_x86_64_macOS.zip") == "someapp")
        #expect(InstallerName.key(ofFileName: "googlechrome.dmg") == InstallerName.key(ofAppName: "Google Chrome"))
        #expect(InstallerName.key(ofFileName: "Visual-Studio-Code.zip") == InstallerName.key(ofAppName: "Visual Studio Code"))
        #expect(InstallerName.key(ofFileName: "2.1-arm64.dmg") == nil)
        // A name that starts with digits is a word, not a version.
        #expect(InstallerName.key(ofFileName: "1Password-8.10.dmg") == InstallerName.key(ofAppName: "1Password"))
        #expect(InstallerName.key(ofFileName: "4K Video Downloader 4.33.dmg") == InstallerName.key(ofAppName: "4K Video Downloader"))
        #expect(InstallerName.key(ofFileName: "VSCode-darwin-universal.zip") != InstallerName.key(ofAppName: "Visual Studio Code"))
    }

    @Test func dottedVersionsCompareByNumberWhateverTheirLength() {
        #expect(InstallerVersion.compare("2.1", "2.1.0") == .orderedSame)
        #expect(InstallerVersion.compare("2.10", "2.9") == .orderedDescending)
        #expect(InstallerVersion.compare("1.0", "1.0.1") == .orderedAscending)
        #expect(InstallerVersion.compare("02.001", "2.1") == .orderedSame)
        let long = String(repeating: "9", count: 40)
        #expect(InstallerVersion.compare(long, long + "0") == .orderedAscending)
        #expect(InstallerVersion.compare("1." + long, "1." + long) == .orderedSame)
        #expect(InstallerVersion.compare("2.1b3", "2.1") == nil)
        #expect(InstallerVersion.compare("1.0 (45)", "1.0") == nil)
        #expect(InstallerVersion.compare("", "1") == nil)
        #expect(InstallerVersion.compare("1..2", "1.2") == nil)
    }

    // MARK: - Which files take part

    private func record(
        _ name: String,
        kind: FileRecord.Kind = .file,
        type: UTType? = nil,
        age: TimeInterval = 2 * 60 * 60,
        identity: PersistentFileIdentity? = nil
    ) -> FileRecord {
        let date = now.addingTimeInterval(-age)
        let pathExtension = URL(filePath: name).pathExtension
        return FileRecord(
            url: URL(filePath: "/Users/someone/Downloads/\(name)"),
            displayName: name,
            kind: kind,
            localizedTypeDescription: nil,
            contentType: type ?? UTType(filenameExtension: pathExtension),
            sizeInBytes: 1_000,
            dateAdded: date,
            dateModified: date,
            isDownloading: FileRecord.isInProgressDownload(name: name),
            persistentIdentity: identity
        )
    }

    @Test func onlySettledInstallerFilesWhoseTypeMatchesTheirNameTakePart() {
        let identity = PersistentFileIdentity(volumeUUID: "V", fileNumber: 7)
        let records = [
            record("SomeApp.dmg"), record("Tool.pkg"), record("App.zip"),
            record("Fresh.dmg", age: 60),
            record("Kept.dmg", identity: identity),
            record(".hidden.dmg"),
            record("Partial.dmg.crdownload"),
            record("Folder.dmg", kind: .folder),
            record("Bundle.pkg", kind: .package),
            record("Link.dmg", kind: .symlink),
            record("Meta.mpkg"),
            record("Disguised.dmg", type: .zip),
            record("Image.iso"),
            record("disk-backup.img"),
            record("Old downloads"),
        ]
        let kept = KeptItems([KeptItem(identity: identity, path: "/Users/someone/Downloads/Kept.dmg", keptAt: now)])
        let candidates = InstallerPlanner(eligibility: CandidateEligibility(keptItems: kept)).candidates(in: records, now: now)
        #expect(candidates.map(\.displayName) == ["SomeApp.dmg", "Tool.pkg", "App.zip"])
        #expect(InstallerPlanner.kind(ofName: "SomeApp.DMG") == .diskImage)
        #expect(InstallerPlanner.kind(ofName: "Tool.pkg") == .package)
        #expect(InstallerPlanner.kind(ofName: "a.zip") == .zip)
        #expect(InstallerPlanner.kind(ofName: "a.mpkg") == nil)
        #expect(InstallerPlanner.kind(ofName: "a.sparseimage") == nil)
        #expect(InstallerPlanner.kind(ofName: "disk-backup.img") == nil)
    }

    @Test func thePlanListsChangesAndUncheckedFilesInNameOrder() {
        let strong = UsedInstallerEvidence(strength: .strong, name: "SomeApp", version: "2.1", installedAppPath: "/Applications/SomeApp.app", bundleIdentifier: "com.example.SomeApp")
        let possible = UsedInstallerEvidence(strength: .possible, name: "Gizmo", version: nil, installedAppPath: "/Applications/Gizmo.app", bundleIdentifier: nil)
        let folder = URL(filePath: "/Users/someone/Downloads", directoryHint: .isDirectory)
        let plan = InstallerPlanner.makePlan(folderURL: folder, findings: [
            (record("b.dmg"), .proposed(possible)),
            (record("a.zip"), .proposed(strong)),
            (record("c.pkg"), .notProposed),
            (record("e.dmg"), .notChecked(.diskImageInUse)),
            (record("d.pkg"), .notChecked(.installerUnreadable(.damaged))),
        ])
        #expect(plan.action == .removeUsedInstallers)
        #expect(plan.changes.map(\.record.displayName) == ["a.zip", "b.dmg"])
        #expect(plan.changes.map(\.reason.isPossibleMatch) == [false, true])
        #expect(plan.changes.allSatisfy { $0.operation == .moveToTrash })
        #expect(plan.skippedItems.map(\.url.lastPathComponent) == ["d.pkg", "e.dmg"])
        #expect(plan.installerFactsRead.isEmpty)
    }

    private func isStrong(_ evidence: InstallerPlanner.Evidence) -> Bool {
        if case .strong = evidence {
            return true
        }
        return false
    }
}

private extension InstallerPlanner.Evidence {
    var isPossible: Bool {
        if case .possible = self {
            return true
        }
        return false
    }
}
