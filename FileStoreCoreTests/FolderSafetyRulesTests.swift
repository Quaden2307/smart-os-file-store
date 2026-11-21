import FileStoreCore
import Foundation
import Testing

/// Which folders may be managed. Each test builds a stand-in home under the temporary directory;
/// the only real paths looked at are `/` and system folders, and those only with `lstat`.
@Suite("FolderSafetyRules")
struct FolderSafetyRulesTests {
    /// A stand-in home with the folders the rules name, and the rules for it.
    private struct Home {
        let root: URL
        let home: URL
        let appData: URL
        let rules: FolderSafetyRules

        init(root: URL) throws {
            self.root = root
            home = root.appending(path: "Home", directoryHint: .isDirectory)
            appData = root.appending(path: "AppData/com.example.tool", directoryHint: .isDirectory)
            for path in ["Downloads", "Desktop", "Documents/Projects", "Library/Caches", ".Trash", "Apps/Tool.app/Contents"] {
                try FileManager.default.createDirectory(at: home.appending(path: path), withIntermediateDirectories: true)
            }
            try FileManager.default.createDirectory(at: appData, withIntermediateDirectories: true)
            rules = FolderSafetyRules(home: home, appDataFolders: [appData], allowedRoots: [root])
        }

        func refusal(_ path: String, managed: [String] = []) -> FolderSafetyRules.Refusal? {
            rules.refusal(for: home.appending(path: path), managed: managed.map { home.appending(path: $0) })
        }
    }

    @Test func ordinaryFoldersInTheHomeMayBeManaged() throws {
        try withTemporaryFolder { root in
            let home = try Home(root: root)
            #expect(home.refusal("Downloads") == nil)
            #expect(home.refusal("Desktop") == nil)
            #expect(home.refusal("Documents") == nil)
            #expect(home.refusal("Documents/Projects") == nil)
        }
    }

    @Test func theHomeFolderAndWhatHoldsItAreRefused() throws {
        try withTemporaryFolder { root in
            let home = try Home(root: root)
            #expect(home.rules.refusal(for: home.home) == .homeFolder)
            #expect(home.rules.refusal(for: root) == .homeFolder)
        }
    }

    /// While a demo home stands in, the home it stands in for is still a home.
    @Test func aSecondHomeIsRefusedLikeTheFirst() throws {
        try withTemporaryFolder { root in
            let home = try Home(root: root.appending(path: "Demo"))
            let real = try Home(root: root.appending(path: "Real"))
            let rules = FolderSafetyRules(home: home.home, otherHomes: [real.home], appDataFolders: [], allowedRoots: [root])
            #expect(rules.refusal(for: real.home) == .homeFolder)
            #expect(rules.refusal(for: real.home.appending(path: "Library/Caches")) == .insideLibrary)
            #expect(rules.refusal(for: real.home.appending(path: "Documents")) == nil)
            #expect(rules.refusal(for: home.home) == .homeFolder)
            // Without it named, only the one home is.
            let onlyOne = FolderSafetyRules(home: home.home, appDataFolders: [], allowedRoots: [root])
            #expect(onlyOne.refusal(for: real.home.appending(path: "Library/Caches")) == nil)
        }
    }

    @Test func libraryTrashApplicationsAndTheAppsOwnDataAreRefused() throws {
        try withTemporaryFolder { root in
            let home = try Home(root: root)
            #expect(home.refusal("Library") == .insideLibrary)
            #expect(home.refusal("Library/Caches") == .insideLibrary)
            #expect(home.refusal(".Trash") == .trash)
            #expect(home.refusal("Apps/Tool.app") == .insideApplication)
            #expect(home.refusal("Apps/Tool.app/Contents") == .insideApplication)
            #expect(home.rules.refusal(for: home.appData) == .appData)
            // A folder that holds the app's data is refused with it.
            #expect(home.rules.refusal(for: home.appData.deletingLastPathComponent()) == .appData)
        }
    }

    @Test func aFolderThatIsInsideOrHoldsAManagedOneIsRefused() throws {
        try withTemporaryFolder { root in
            let home = try Home(root: root)
            #expect(home.refusal("Documents", managed: ["Documents"]) == .overlapsManagedFolder)
            #expect(home.refusal("Documents/Projects", managed: ["Documents"]) == .overlapsManagedFolder)
            #expect(home.refusal("Documents", managed: ["Documents/Projects"]) == .overlapsManagedFolder)
            #expect(home.refusal("Desktop", managed: ["Documents", "Downloads"]) == nil)
            // Another spelling of the same folder is the same folder, on a disk that ignores letter case.
            if FileManager.default.fileExists(atPath: home.home.appending(path: "documents/PROJECTS").path(percentEncoded: false)) {
                #expect(home.refusal("documents/PROJECTS", managed: ["Documents"]) == .overlapsManagedFolder)
            }
        }
    }

    @Test func aLinkIsJudgedByWhereItLeads() throws {
        try withTemporaryFolder { root in
            let home = try Home(root: root)
            let links: [(name: String, target: URL, refusal: FolderSafetyRules.Refusal?)] = [
                ("ToHome", home.home, .homeFolder),
                ("ToLibrary", home.home.appending(path: "Library/Caches"), .insideLibrary),
                ("ToTrash", home.home.appending(path: ".Trash"), .trash),
                ("ToRoot", URL(filePath: "/"), .volumeRoot),
                ("ToSystem", URL(filePath: "/System/Library"), .systemLocation),
                ("ToManaged", home.home.appending(path: "Documents/Projects"), .overlapsManagedFolder),
                ("ToDesktop", home.home.appending(path: "Desktop"), nil),
            ]
            for link in links {
                let url = home.home.appending(path: link.name)
                try FileManager.default.createSymbolicLink(at: url, withDestinationURL: link.target)
                #expect(home.refusal(link.name, managed: ["Documents"]) == link.refusal, "\(link.name)")
            }
        }
    }

    @Test func systemLocationsAndTheTopOfADiskAreRefused() throws {
        try withTemporaryFolder { root in
            let home = try Home(root: root)
            #expect(home.rules.refusal(for: URL(filePath: "/")) == .volumeRoot)
            for path in ["/System", "/usr/bin", "/private/etc", "/Applications", "/Users", "/Volumes"] {
                #expect(home.rules.refusal(for: URL(filePath: path)) == .systemLocation, "\(path)")
            }
            #expect(home.rules.refusal(for: URL(filePath: "/Library/Fonts")) == .insideLibrary)
            // The temporary directory is under `/private`: without the exemption a test names, a
            // folder in it is a system location like any other.
            let strict = FolderSafetyRules(home: home.home, appDataFolders: [home.appData])
            #expect(strict.refusal(for: home.home.appending(path: "Downloads")) == .systemLocation)
            // The exemption covers what is in the named folder, never the folder itself.
            let onlyDownloads = FolderSafetyRules(home: home.home, appDataFolders: [], allowedRoots: [home.home.appending(path: "Downloads")])
            #expect(onlyDownloads.refusal(for: home.home.appending(path: "Downloads")) == .systemLocation)
        }
    }

    @Test func whatIsNotAFolderIsRefused() throws {
        try withTemporaryFolder { root in
            let home = try Home(root: root)
            try Data("x".utf8).write(to: home.home.appending(path: "file.txt"))
            #expect(home.refusal("file.txt") == .notAFolder)
            #expect(home.refusal("Missing") == .notAFolder)
            try FileManager.default.createSymbolicLink(
                at: home.home.appending(path: "Dangling"),
                withDestinationURL: home.home.appending(path: "Missing")
            )
            #expect(home.refusal("Dangling") == .notAFolder)
        }
    }
}
