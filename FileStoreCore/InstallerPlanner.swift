import Foundation
import UniformTypeIdentifiers

/// Plans Remove Used Installers: the disk images, packages and app zips at the top level of the folder
/// whose apps are installed, proposed for the Trash (decision record 0012).
///
/// - **Strong**, ticked: every app the installer holds is installed with the same bundle identifier
///   at the same or a newer version. For a package, every part's receipt is on this Mac at the same
///   or a newer version, and every app it installs is installed as above; a package that installs
///   no app matches on its receipts alone.
/// - **Possible**, unticked: otherwise, when the installer's cleaned file name is an installed app's
///   name (`InstallerName`).
/// - Not proposed: no match, or an installed version older than the installer's.
///
/// The rule is pure: `candidates(in:now:)`, `evidence(fileName:facts:apps:receipts:)` and
/// `makePlan(folderURL:findings:factsRead:)` work on values alone. Only
/// `plan(records:in:sources:now:onProgress:)` reads the disk, and it only reads.
public struct InstallerPlanner: Sendable {
    /// The kinds of installer.
    public enum Kind: Sendable, Hashable {
        case diskImage
        case package
        case zip
    }

    /// What the facts show.
    public enum Evidence: Sendable, Hashable {
        case strong(UsedInstallerEvidence)
        case possible(UsedInstallerEvidence)
        /// An app it holds is installed only at an older version: the installer is an update.
        case installedIsOlder
        case none
    }

    /// What one installer turned out to be.
    public enum Finding: Sendable, Hashable {
        case proposed(UsedInstallerEvidence)
        case notProposed
        case notChecked(CleanupSkipReason)
    }

    static let diskImageType = UTType("com.apple.disk-image-udif")
    static let packageType = UTType("com.apple.installer-package-archive")

    /// The rules every action shares, with the Kept list.
    public let eligibility: CandidateEligibility

    public init(eligibility: CandidateEligibility = CandidateEligibility()) {
        self.eligibility = eligibility
    }

    // MARK: - Which items take part

    /// The kind of installer `name`'s extension makes it, in any letter case, or nil. Only `.dmg`,
    /// `.pkg` and `.zip`: the system gives `.img` the disk image type and `.mpkg` the package type
    /// too, and neither is an installer here.
    public static func kind(ofName name: String) -> Kind? {
        switch URL(filePath: name, directoryHint: .notDirectory).pathExtension.lowercased() {
        case "dmg": .diskImage
        case "pkg": .package
        case "zip": .zip
        default: nil
        }
    }

    /// The type the scan must have read for an installer of `kind`.
    static func type(of kind: Kind) -> UTType? {
        switch kind {
        case .diskImage: diskImageType
        case .package: packageType
        case .zip: .zip
        }
    }

    /// The installers that may be proposed at `now`: regular files whose scanned type is exactly the
    /// one their name gives, that the shared rules allow. Folders (a bundle-style package), links
    /// and other formats never are.
    public func candidates(in records: [FileRecord], now: Date) -> [FileRecord] {
        records.filter { record in
            guard record.kind == .file, let kind = Self.kind(ofName: record.displayName) else {
                return false
            }
            return record.contentType == Self.type(of: kind) && eligibility.allows(record, now: now)
        }
    }

    // MARK: - The rule

    /// What `facts`, read from the installer called `fileName` (nil when nothing could be read),
    /// show against the installed `apps` and `receipts`.
    public static func evidence(
        fileName: String,
        facts: InstallerFacts?,
        apps installed: [InstalledApp],
        receipts: [String: InstallReceipt]
    ) -> Evidence {
        switch strongRule(facts, installed: installed, receipts: receipts) {
        case .strong(let evidence):
            return .strong(evidence)
        case .older:
            return .installedIsOlder
        case .notShown:
            break
        }
        guard let key = InstallerName.key(ofFileName: fileName),
              let app = installed.first(where: { InstallerName.key(ofAppName: $0.facts.name) == key }) else {
            return .none
        }
        return .possible(UsedInstallerEvidence(
            strength: .possible,
            name: app.facts.name,
            version: app.facts.shortVersion ?? app.facts.build,
            installedAppPath: app.url.storedPath,
            bundleIdentifier: nil
        ))
    }

    /// The finding for one installer: proposed when there is evidence, not checked when it could not
    /// be read and its name matches nothing, otherwise left out.
    public static func finding(
        fileName: String,
        facts: InstallerFacts?,
        apps: [InstalledApp],
        receipts: [String: InstallReceipt]
    ) -> Finding {
        switch evidence(fileName: fileName, facts: facts, apps: apps, receipts: receipts) {
        case .strong(let evidence), .possible(let evidence):
            return .proposed(evidence)
        case .installedIsOlder:
            return .notProposed
        case .none:
            if case .unreadable(let problem)? = facts {
                return .notChecked(.installerUnreadable(problem))
            }
            return .notProposed
        }
    }

    /// The records among `records` whose facts make them strong matches: the Installed mark.
    public static func strongMatches(
        _ records: [FileRecord],
        facts: [URL: InstallerFacts],
        apps: [InstalledApp],
        receipts: [String: InstallReceipt]
    ) -> Set<URL> {
        Set(records.compactMap { record in
            guard let recordFacts = facts[record.url],
                  case .strong = evidence(fileName: record.displayName, facts: recordFacts, apps: apps, receipts: receipts) else {
                return nil
            }
            return record.url
        })
    }

    // MARK: - The plan

    /// The plan from each installer's finding, for `folderURL`. Changes and items not checked are in
    /// name order. Pure: nothing here touches the disk.
    public static func makePlan(
        folderURL: URL,
        findings: [(record: FileRecord, finding: Finding)],
        factsRead: [InstallerFactsEntry] = []
    ) -> CleanupPlan {
        var changes: [ProposedChange] = []
        var skippedItems: [CleanupPlan.SkippedItem] = []
        for (record, finding) in findings {
            switch finding {
            case .proposed(let evidence):
                changes.append(ProposedChange(record: record, operation: .moveToTrash, reason: .usedInstaller(evidence)))
            case .notProposed:
                break
            case .notChecked(let reason):
                skippedItems.append(CleanupPlan.SkippedItem(url: record.url, reason: reason))
            }
        }
        changes.sort { UnpackedZipPlanner.isOrderedBefore($0.record.displayName, $1.record.displayName) }
        skippedItems.sort { UnpackedZipPlanner.isOrderedBefore($0.url.lastPathComponent, $1.url.lastPathComponent) }
        return CleanupPlan(
            action: .removeUsedInstallers,
            folderURL: folderURL,
            changes: changes,
            skippedItems: skippedItems,
            installerFactsRead: factsRead
        )
    }

    // MARK: - Helpers

    private enum StrongRule {
        case strong(UsedInstallerEvidence)
        case older
        case notShown
    }

    private static func strongRule(_ facts: InstallerFacts?, installed: [InstalledApp], receipts: [String: InstallReceipt]) -> StrongRule {
        switch facts {
        case .apps(let apps)?:
            guard !apps.isEmpty else {
                return .notShown
            }
            let match = match(apps, installed: installed)
            if match.older {
                return .older
            }
            guard match.all, let first = match.copies.first else {
                return .notShown
            }
            return .strong(evidence(naming: first, otherMatches: match.copies.count - 1))
        case .packages(let packages)?:
            guard !packages.isEmpty else {
                return .notShown
            }
            var allReceipts = true
            var older = false
            for package in packages {
                guard let receipt = receipts[package.identifier], let installedVersion = receipt.version, let version = package.version,
                      let order = InstallerVersion.compare(installedVersion, version) else {
                    allReceipts = false
                    continue
                }
                if order == .orderedAscending {
                    older = true
                }
            }
            let match = match(packages.flatMap(\.apps), installed: installed)
            if older || match.older {
                return .older
            }
            guard allReceipts, match.all else {
                return .notShown
            }
            if let first = match.copies.first {
                return .strong(evidence(naming: first, otherMatches: match.copies.count - 1 + packages.count - 1))
            }
            let named = packages[0]
            return .strong(UsedInstallerEvidence(
                strength: .strong,
                name: named.identifier,
                version: receipts[named.identifier]?.version,
                installedAppPath: nil,
                bundleIdentifier: nil,
                receiptIdentifiers: packages.map(\.identifier),
                otherMatches: packages.count - 1
            ))
        case .unreadable?, nil:
            return .notShown
        }
    }

    /// For each app, its first installed copy with the same identifier and the same or a newer
    /// version. `all` when every app has one; `older` when an app's only copies are older.
    private static func match(_ apps: [BundleFacts], installed: [InstalledApp]) -> (copies: [InstalledApp], all: Bool, older: Bool) {
        var copies: [InstalledApp] = []
        var all = true
        var older = false
        for app in apps {
            let sameApp = installed.filter { app.identifier != nil && $0.facts.identifier == app.identifier }
            if let copy = sameApp.first(where: { (InstallerVersion.compare(installed: $0.facts, installer: app) ?? .orderedAscending) != .orderedAscending }) {
                copies.append(copy)
                continue
            }
            all = false
            if sameApp.contains(where: { InstallerVersion.compare(installed: $0.facts, installer: app) == .orderedAscending }) {
                older = true
            }
        }
        return (copies, all, older)
    }

    private static func evidence(naming copy: InstalledApp, otherMatches: Int) -> UsedInstallerEvidence {
        UsedInstallerEvidence(
            strength: .strong,
            name: copy.facts.name,
            // The build stands in when the app gives no short version, as it did in the comparison.
            version: copy.facts.shortVersion ?? copy.facts.build,
            installedAppPath: copy.url.storedPath,
            bundleIdentifier: copy.facts.identifier,
            otherMatches: otherMatches
        )
    }
}
