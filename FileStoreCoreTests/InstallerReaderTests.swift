import FileStoreCore
import Foundation
import Testing

/// The installer readers that run no disk image tool: the package reader on crafted and real
/// packages, a zip entry read in memory, the installed-apps index, receipts, and the tool runner
/// itself (decision record 0013).
@Suite("Installer readers")
struct InstallerReaderTests {
    // MARK: - Packages, crafted

    private let info = XarBytes.packageInfo(
        identifier: "com.example.SomeApp.pkg",
        version: "2.1",
        apps: [("./SomeApp.app", "com.example.SomeApp", "2.1"), ("./SomeApp.app/Contents/Helpers/Helper.app", "com.example.Helper", "1.0")]
    )

    @Test func aComponentPackageGivesItsIdentifierVersionAndApps() throws {
        for encoding in [XarBytes.Encoding.none, .gzip] {
            let packages = try XarArchive.packages(inBytes: XarBytes.component(info, encoding: encoding).bytes())
            #expect(packages == [PackageFacts(
                identifier: "com.example.SomeApp.pkg",
                version: "2.1",
                // The helper inside the app is not an app the package installs.
                apps: [BundleFacts(name: "SomeApp", identifier: "com.example.SomeApp", shortVersion: "2.1", build: "1")]
            )])
        }
    }

    @Test func aProductArchiveGivesEveryPart() throws {
        let other = XarBytes.packageInfo(identifier: "com.example.helper.pkg", version: "1.0")
        let archive = XarBytes([
            .file("Distribution", Array("<installer-gui-script><script>run()</script></installer-gui-script>".utf8), .gzip),
            .directory("SomeApp.pkg", [.file("PackageInfo", Array(info.utf8), .gzip), .file("Payload", Array(repeating: 7, count: 64), .none)]),
            .directory("Helper.pkg", [.file("PackageInfo", Array(other.utf8), .none)]),
        ])
        let packages = try XarArchive.packages(inBytes: archive.bytes())
        #expect(packages.map(\.identifier) == ["com.example.SomeApp.pkg", "com.example.helper.pkg"])
    }

    @Test func theBuildersArchivesAreValidToTheXarTool() throws {
        try withTemporaryFolder { folder in
            let url = folder.appending(path: "crafted.pkg")
            try Data(XarBytes([.directory("SomeApp.pkg", [.file("PackageInfo", Array(info.utf8), .gzip)])]).bytes()).write(to: url)
            let listing = try CommandLineTool.run("/usr/bin/xar", ["-t", "-f", url.path(percentEncoded: false)])
            #expect(listing.contains("SomeApp.pkg/PackageInfo"))
        }
    }

    @Test func damagedOrHostilePackagesAreRefused() {
        func problem(_ archive: XarBytes) -> InstallerFacts.Problem? {
            problem(archive.bytes())
        }
        func problem(_ bytes: [UInt8]) -> InstallerFacts.Problem? {
            do {
                _ = try XarArchive.packages(inBytes: bytes)
                return nil
            } catch {
                if case .problem(let found) = error {
                    return found
                }
                return nil
            }
        }
        var tableChecksum = XarBytes.component(info)
        tableChecksum.corruptTableChecksum = true
        #expect(problem(tableChecksum) == .damaged)

        var memberChecksum = XarBytes.component(info)
        memberChecksum.corruptMemberChecksums = true
        #expect(problem(memberChecksum) == .damaged)

        // Refused before anything that size is allocated.
        var huge = XarBytes.component(info)
        huge.declaredTableLength = 1 << 63
        #expect(problem(huge) == .tooLarge)

        var outside = XarBytes.component(info)
        outside.offsetShift = 1 << 40
        #expect(problem(outside) == .damaged)

        var doctype = XarBytes.component(info)
        doctype.tableOverride = "<?xml version=\"1.0\"?><!DOCTYPE xar [<!ENTITY a \"aaaa\">]><xar><toc></toc></xar>"
        #expect(problem(doctype) == .damaged)

        var utf16 = XarBytes.component(info)
        utf16.tableOverride = String(decoding: [0xFF, 0xFE, 0x3C, 0x00, 0x78, 0x00], as: UTF8.self)
        #expect(problem(utf16) == .damaged)

        let nested = (0..<40).reduce(XarBytes.Item.file("PackageInfo", Array(info.utf8), .none)) { inner, depth in .directory("d\(depth)", [inner]) }
        #expect(problem(XarBytes([nested])) == .tooLarge)

        #expect(problem(XarBytes.component(info, encoding: .bzip2)) == .unsupported)
        let suite = XarBytes.packageInfo(identifier: "com.example.suite.pkg", version: "1", apps: (0..<17).map { ("./App\($0).app", "com.example.App\($0)", "1") })
        #expect(problem(XarBytes.component(suite)) == .tooLarge)
        #expect(problem(XarBytes([.file("Payload", [1, 2, 3], .none)])) == .damaged)
        #expect(problem(Array("pkg".utf8)) == .damaged)
        #expect(problem(Array(XarBytes.component(info).bytes().prefix(40))) == .damaged)
    }

    // MARK: - Packages, real

    @Test func realPackagesFromPkgbuildAndProductbuildAreRead() async throws {
        try await withTemporaryFolderAsync { folder in
            let root = folder.appending(path: "root", directoryHint: .isDirectory)
            try FakeDownloadsFolder.writeApp(at: root.appending(path: "SomeApp.app"), identifier: "com.example.SomeApp", version: "2.1", build: "210")
            let component = folder.appending(path: "component.pkg")
            let product = folder.appending(path: "product.pkg")
            try CommandLineTool.run("/usr/bin/pkgbuild", [
                "--quiet", "--root", root.path(percentEncoded: false), "--identifier", "com.example.SomeApp.pkg",
                "--version", "2.1", "--install-location", "/Applications", component.path(percentEncoded: false),
            ])
            try CommandLineTool.run("/usr/bin/productbuild", ["--quiet", "--package", component.path(percentEncoded: false), product.path(percentEncoded: false)])
            let expected = [PackageFacts(
                identifier: "com.example.SomeApp.pkg",
                version: "2.1",
                apps: [BundleFacts(name: "SomeApp", identifier: "com.example.SomeApp", shortVersion: "2.1", build: "210")]
            )]
            for url in [component, product] {
                #expect(try XarArchive.packages(inBytes: Array(Data(contentsOf: url))) == expected, "\(url.lastPathComponent)")
            }
        }
    }

    // MARK: - A zip entry, in memory

    @Test func aStoredEntryIsReadAndAChangedByteIsDamage() throws {
        let plist = String(repeating: "info ", count: 40)
        let bytes = ZipBytes([.folder("SomeApp.app/"), .file("SomeApp.app/Contents/Info.plist", plist)]).bytes
        let contents = try ZipListing.contents(ofEntries: ["SomeApp.app/Contents/Info.plist"], inBytes: bytes, maximumEntrySize: 1 << 20)
        #expect(contents["SomeApp.app/Contents/Info.plist"] == Array(plist.utf8))
        // Over the limit, it is left out.
        #expect(try ZipListing.contents(ofEntries: ["SomeApp.app/Contents/Info.plist"], inBytes: bytes, maximumEntrySize: 10).isEmpty)

        // The same bytes with one changed: the directory still lists it, the CRC-32 no longer agrees.
        var changed = bytes
        let start = try #require(changed.firstRange(of: Array("info info".utf8))?.lowerBound)
        changed[start] = UInt8(ascii: "X")
        #expect(throws: ZipListing.Failure.unlistable(.damaged)) {
            _ = try ZipListing.contents(ofEntries: ["SomeApp.app/Contents/Info.plist"], inBytes: changed, maximumEntrySize: 1 << 20)
        }
    }

    @Test func aDeflatedEntryFromDittoIsInflatedInMemory() throws {
        try withTemporaryFolder { folder in
            let app = folder.appending(path: "SomeApp.app")
            try FakeDownloadsFolder.writeApp(at: app, identifier: "com.example.SomeApp", version: "2.1", build: "210")
            let zip = folder.appending(path: "SomeApp.zip")
            try ZipTools.ditto(app, to: zip, keepParent: true)
            let path = "SomeApp.app/Contents/Info.plist"
            let contents = try ZipListing.contents(ofEntries: [path], inBytes: Array(Data(contentsOf: zip)), maximumEntrySize: 1 << 20)
            #expect(contents[path] == Array(try Data(contentsOf: app.appending(path: "Contents/Info.plist"))))
        }
    }

    // MARK: - Installed apps

    @Test func theIndexHoldsTopLevelAppsOnly() async throws {
        try await withTemporaryFolderAsync { folder in
            let apps = folder.appending(path: "Applications", directoryHint: .isDirectory)
            try FakeDownloadsFolder.writeApp(at: apps.appending(path: "Xml.app"), identifier: "com.example.Xml", version: "1.0", build: "1")
            // A binary property list reads the same.
            let binary = apps.appending(path: "Binary.app/Contents", directoryHint: .isDirectory)
            try FileManager.default.createDirectory(at: binary, withIntermediateDirectories: true)
            try PropertyListSerialization.data(fromPropertyList: ["CFBundleIdentifier": "com.example.Binary", "CFBundleShortVersionString": "3"], format: .binary, options: 0)
                .write(to: binary.appending(path: "Info.plist"))
            // Values that are not strings are left out.
            let odd = apps.appending(path: "Odd.app/Contents", directoryHint: .isDirectory)
            try FileManager.default.createDirectory(at: odd, withIntermediateDirectories: true)
            try PropertyListSerialization.data(fromPropertyList: ["CFBundleIdentifier": 42, "CFBundleShortVersionString": "1"], format: .xml, options: 0)
                .write(to: odd.appending(path: "Info.plist"))
            // Not apps here: a link to one, a hidden one, one with no Info.plist, one too large, and one in a subfolder.
            try FileManager.default.createSymbolicLink(at: apps.appending(path: "Link.app"), withDestinationURL: apps.appending(path: "Xml.app"))
            try FakeDownloadsFolder.writeApp(at: apps.appending(path: ".Hidden.app"), identifier: "com.example.Hidden", version: "1.0", build: "1")
            try FileManager.default.createDirectory(at: apps.appending(path: "Empty.app/Contents", directoryHint: .isDirectory), withIntermediateDirectories: true)
            let large = apps.appending(path: "Large.app/Contents", directoryHint: .isDirectory)
            try FileManager.default.createDirectory(at: large, withIntermediateDirectories: true)
            try Data(count: (1 << 20) + 1).write(to: large.appending(path: "Info.plist"))
            try FakeDownloadsFolder.writeApp(at: apps.appending(path: "Utilities/Deep.app"), identifier: "com.example.Deep", version: "1.0", build: "1")

            let missing = folder.appending(path: "Missing", directoryHint: .isDirectory)
            let index = await InstalledApps.read(folders: [apps, missing])
            #expect(index.map(\.facts) == [
                BundleFacts(name: "Binary", identifier: "com.example.Binary", shortVersion: "3", build: nil),
                BundleFacts(name: "Odd", identifier: nil, shortVersion: "1", build: nil),
                BundleFacts(name: "Xml", identifier: "com.example.Xml", shortVersion: "1.0", build: "1"),
            ])
            #expect(index.map(\.url.lastPathComponent) == ["Binary.app", "Odd.app", "Xml.app"])
        }
    }

    @Test func theApplicationFoldersAreTheTwoStandardOnesWithoutAnOverride() {
        let home = URL(filePath: "/Users/someone", directoryHint: .isDirectory)
        #expect(ApplicationFolders.resolve(arguments: [], home: home).map { $0.path(percentEncoded: false) } == ["/Applications/", "/Users/someone/Applications/"])
        // A debug build takes the override; a value that is not a folder gives none at all.
        #expect(ApplicationFolders.resolve(arguments: ["-ApplicationsFolder", "/nonexistent/folder"], home: home).isEmpty)
        #expect(ApplicationFolders.resolve(arguments: ["-ApplicationsFolder"], home: home).isEmpty)
        let temporary = FileManager.default.temporaryDirectory
        #expect(ApplicationFolders.resolve(arguments: ["-ApplicationsFolder", temporary.path(percentEncoded: false)], home: home).count == 1)
    }

    // MARK: - Receipts

    @Test func receiptsAreParsedFromPkgutilsPropertyLists() throws {
        let list = Data("""
            <?xml version="1.0" encoding="UTF-8"?>
            <plist version="1.0"><array><string>com.apple.pkg.MobileDevice</string><string>com.example.SomeApp.pkg</string></array></plist>
            """.utf8)
        #expect(InstallReceipts.parseIdentifiers(list) == ["com.apple.pkg.MobileDevice", "com.example.SomeApp.pkg"])
        let info = Data("""
            <?xml version="1.0" encoding="UTF-8"?>
            <plist version="1.0"><dict><key>install-location</key><string>Applications</string><key>install-time</key><integer>1794519698</integer>\
            <key>pkg-version</key><string>2.1.0.1</string><key>pkgid</key><string>com.example.SomeApp.pkg</string><key>volume</key><string>/</string></dict></plist>
            """.utf8)
        #expect(InstallReceipts.parseReceipt(info) == InstallReceipt(identifier: "com.example.SomeApp.pkg", version: "2.1.0.1"))
        #expect(InstallReceipts.parseReceipt(Data("No receipt for 'x' found at '/'.".utf8)) == nil)
    }

    @Test func thisMacsReceiptListParsesAndAnUnknownIdentifierHasNone() async throws {
        let output = try CommandLineTool.run("/usr/sbin/pkgutil", ["--pkgs-plist"])
        #expect(InstallReceipts.parseIdentifiers(Data(output.utf8)) != nil)
        #expect(await InstallReceipts.system.receipts(for: ["com.example.never.installed.pkg"]).isEmpty)
        #expect(await InstallReceipts.fixed([InstallReceipt(identifier: "a", version: "1")]).receipts(for: ["a", "b"]) == ["a": InstallReceipt(identifier: "a", version: "1")])
    }

    // MARK: - Running tools

    @Test func outputLargerThanAPipeIsReadInFull() async throws {
        let output = try await SystemTool().run("/bin/dd", ["if=/dev/zero", "bs=1024", "count=512"], timeout: .seconds(10))
        #expect(output.succeeded)
        #expect(output.standardOutput.count == 512 * 1_024)
    }

    @Test func outputPastTheCapFailsTheRunWithoutStallingIt() async {
        await #expect(throws: SystemTool.Failure.outputTooLarge) {
            _ = try await SystemTool().run("/bin/dd", ["if=/dev/zero", "bs=1048576", "count=3"], timeout: .seconds(10))
        }
    }

    @Test func aToolThatOutstaysItsTimeoutIsStopped() async {
        let start = ContinuousClock.now
        await #expect(throws: SystemTool.Failure.timedOut) {
            _ = try await SystemTool().run("/bin/sleep", ["30"], timeout: .milliseconds(200))
        }
        // Well before the tool's own 30 s; generous, since a full parallel test run delays timers.
        #expect(ContinuousClock.now - start < .seconds(20))
    }

    @Test func aCancelStopsTheToolAndLeavesNoProcess() async throws {
        let marker = "41.\(Int.random(in: 100_000...999_999))"
        let run = Task { try await SystemTool().run("/bin/sleep", [marker], timeout: .seconds(60)) }
        try await Task.sleep(for: .milliseconds(300))
        run.cancel()
        await #expect(throws: SystemTool.Failure.cancelled) {
            _ = try await run.value
        }
        let left = try? CommandLineTool.run("/usr/bin/pgrep", ["-f", "sleep \(marker)"])
        #expect(left == nil, "a sleep \(marker) process is still running")
    }

    @Test func aCancelIsIgnoredByARunThatMustFinish() async throws {
        let run = Task { try await SystemTool().run("/bin/sleep", ["0.5"], timeout: .seconds(10), ignoringCancellation: true) }
        run.cancel()
        #expect(try await run.value.succeeded)
    }
}
