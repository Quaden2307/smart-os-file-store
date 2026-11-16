import FileStoreCore
import Foundation
import Testing

/// Remove Unpacked Zips' matching rule on values alone, with no disk: where a zip would have been
/// unpacked, which names may hold it, and whether what is there holds every entry at its size.
@Suite("Unpacked zip matching")
struct UnpackedZipMatchingTests {
    private typealias Planner = UnpackedZipPlanner

    private func file(_ path: String, _ size: Int64) -> ZipEntry {
        ZipEntry(path: path, kind: .file, uncompressedSize: size)
    }

    private func folder(_ path: String) -> ZipEntry {
        ZipEntry(path: path, kind: .folder, uncompressedSize: 0)
    }

    private func link(_ path: String, _ size: Int64) -> ZipEntry {
        ZipEntry(path: path, kind: .symbolicLink, uncompressedSize: size)
    }

    private func expectation(_ entries: [ZipEntry], zip: String = "archive.zip") throws -> Planner.Expectation {
        try Planner.expectation(for: entries, zipName: zip).get()
    }

    private func refusal(_ entries: [ZipEntry], zip: String = "archive.zip") -> Planner.Unmatchable? {
        guard case .failure(let refusal) = Planner.expectation(for: entries, zipName: zip) else {
            return nil
        }
        return refusal
    }

    private func folderTree(_ contents: [String: UnpackedTree.Item]) -> UnpackedTree {
        UnpackedTree(root: .folder, contents: contents)
    }

    // MARK: - Where to look

    @Test func aZipOfOneFileLooksForThatFileBesideIt() throws {
        let expected = try expectation([file("contract.docx", 20)], zip: "contract.zip")

        #expect(expected.name == "contract.docx")
        #expect(expected.tree == UnpackedTree(root: .file(sizeInBytes: 20)))
        #expect(Planner.matches(expected.tree, UnpackedTree(root: .file(sizeInBytes: 20))))
        #expect(!Planner.matches(expected.tree, UnpackedTree(root: .file(sizeInBytes: 21))))
        #expect(!Planner.matches(expected.tree, UnpackedTree(root: .folder)))
        #expect(!Planner.matches(expected.tree, UnpackedTree(root: .symbolicLink(sizeInBytes: 20))))
        #expect(!Planner.matches(expected.tree, UnpackedTree(root: .other)))
    }

    @Test func aZipOfOneFolderLooksForThatFolderWithEverythingInIt() throws {
        let expected = try expectation(
            [folder("project/"), file("project/readme.md", 10), folder("project/src/"), file("project/src/main.swift", 15)],
            zip: "project.zip"
        )

        #expect(expected.name == "project")
        #expect(expected.tree == folderTree(["readme.md": .file(sizeInBytes: 10), "src": .folder, "src/main.swift": .file(sizeInBytes: 15)]))
        #expect(Planner.matches(expected.tree, expected.tree))
    }

    @Test func foldersAPathImpliesNeedNoEntriesOfTheirOwn() throws {
        let expected = try expectation([file("project/a/b/c.txt", 3)], zip: "project.zip")

        #expect(expected.name == "project")
        #expect(expected.tree == folderTree(["a": .folder, "a/b": .folder, "a/b/c.txt": .file(sizeInBytes: 3)]))
    }

    @Test func aZipOfSeveralItemsLooksForAFolderNamedAfterIt() throws {
        let expected = try expectation([file("readme.md", 10), folder("src/"), file("src/main.swift", 15)], zip: "my.project.zip")

        #expect(expected.name == "my.project")
        #expect(expected.tree == folderTree(["readme.md": .file(sizeInBytes: 10), "src": .folder, "src/main.swift": .file(sizeInBytes: 15)]))
    }

    @Test func theSystemsOwnEntriesAreLeftOut() throws {
        // Finder's Compress with extended attributes: __MACOSX at the top would otherwise be a
        // second top-level item, and look for a folder named after the zip.
        let expected = try expectation(
            [
                folder("project/"), file("project/a.txt", 4), file("project/.DS_Store", 6_148), file("project/._a.txt", 4_096),
                folder("__MACOSX/"), folder("__MACOSX/project/"), file("__MACOSX/project/._a.txt", 220),
            ],
            zip: "project.zip"
        )
        #expect(expected.name == "project")
        #expect(expected.tree == folderTree(["a.txt": .file(sizeInBytes: 4)]))

        let single = try expectation([file("solo.txt", 4), folder("__MACOSX/"), file("__MACOSX/._solo.txt", 163)], zip: "solo.zip")
        #expect(single.name == "solo.txt")
        #expect(single.tree == UnpackedTree(root: .file(sizeInBytes: 4)))
    }

    // MARK: - What must be there

    @Test func extraItemsInTheUnpackedFolderAreFine() throws {
        let expected = try expectation([file("project/readme.md", 10)], zip: "project.zip")
        let found = folderTree([
            "readme.md": .file(sizeInBytes: 10),
            "build": .folder,
            "build/app": .file(sizeInBytes: 9_000),
            "notes.txt": .file(sizeInBytes: 3),
        ])

        #expect(Planner.matches(expected.tree, found))
    }

    @Test func oneMissingEntryMeansNoMatch() throws {
        let expected = try expectation([file("photos/a.jpg", 14), file("photos/b.jpg", 14), file("photos/c.jpg", 14)], zip: "photos.zip")
        let found = folderTree(["a.jpg": .file(sizeInBytes: 14), "b.jpg": .file(sizeInBytes: 14)])

        #expect(!Planner.matches(expected.tree, found))
    }

    @Test func oneSizeMismatchMeansNoMatch() throws {
        let expected = try expectation([file("project/readme.md", 10), file("project/main.swift", 15)], zip: "project.zip")
        let found = folderTree(["readme.md": .file(sizeInBytes: 10), "main.swift": .file(sizeInBytes: 16)])

        #expect(!Planner.matches(expected.tree, found))
    }

    @Test func anItemOfAnotherKindMeansNoMatch() throws {
        let expected = try expectation(
            [file("project/readme.md", 10), folder("project/src/"), file("project/src/main.swift", 15), link("project/latest", 6)],
            zip: "project.zip"
        )
        let whole: [String: UnpackedTree.Item] = [
            "readme.md": .file(sizeInBytes: 10), "src": .folder, "src/main.swift": .file(sizeInBytes: 15), "latest": .symbolicLink(sizeInBytes: 6),
        ]
        #expect(Planner.matches(expected.tree, folderTree(whole)))

        var folderForFile = whole
        folderForFile["readme.md"] = .folder
        #expect(!Planner.matches(expected.tree, folderTree(folderForFile)))
        // A link to a folder, never followed: whatever it points to is not inside this folder.
        var linkForFolder = whole
        linkForFolder["src"] = .symbolicLink(sizeInBytes: 9)
        #expect(!Planner.matches(expected.tree, folderTree(linkForFolder)))
        var fileForLink = whole
        fileForLink["latest"] = .file(sizeInBytes: 6)
        #expect(!Planner.matches(expected.tree, folderTree(fileForLink)))
        var longerLink = whole
        longerLink["latest"] = .symbolicLink(sizeInBytes: 7)
        #expect(!Planner.matches(expected.tree, folderTree(longerLink)))
        var device = whole
        device["readme.md"] = .other
        #expect(!Planner.matches(expected.tree, folderTree(device)))
        // The root itself must be a folder.
        #expect(!Planner.matches(expected.tree, UnpackedTree(root: .symbolicLink(sizeInBytes: 7), contents: whole)))
    }

    @Test func aDeviceOrPipeInAZipNeverMatches() throws {
        let pipe = ZipEntry(path: "project/fifo", kind: .other, uncompressedSize: 0)
        let expected = try expectation([file("project/readme.md", 10), pipe], zip: "project.zip")

        #expect(!Planner.matches(expected.tree, folderTree(["readme.md": .file(sizeInBytes: 10), "fifo": .other])))
    }

    // MARK: - Numbered names

    @Test func numberedNamesAreTriedAfterTheExactNameInOrder() {
        let names = ["project 3", "notes.txt", "project", "project 10", "project 2"]
        #expect(Planner.candidateNames(for: "project", among: names) == ["project", "project 2", "project 3", "project 10"])

        let files = ["contract.docx", "contract 2.docx", "contract.docx 3", "contract 4.pdf"]
        #expect(Planner.candidateNames(for: "contract.docx", among: files) == ["contract.docx", "contract 2.docx", "contract.docx 3"])

        // Without the exact name, the numbered ones still count.
        #expect(Planner.candidateNames(for: "project", among: ["project 2"]) == ["project 2"])
    }

    @Test(arguments: ["project 02", "project 1", "project 0", "project2", "project copy", "project 2 ", "project -2", "project ²", "Project 2", "project 2.zip"])
    func namesThatAreNotArchiveUtilitysCopiesDoNotCount(name: String) {
        #expect(Planner.candidateNames(for: "project", among: [name]).isEmpty, "\(name)")
    }

    // MARK: - Zips that never match

    @Test func anEmptyZipNeverMatches() {
        #expect(refusal([]) == .empty)
        #expect(refusal([folder("__MACOSX/"), file("__MACOSX/._x", 82), file(".DS_Store", 6_148)]) == .empty)
        // Folders only: nothing to compare.
        #expect(refusal([folder("project/"), folder("project/empty/")]) == .empty)
    }

    @Test(arguments: ["/etc/passwd", "../x", "a/../../b", "a//b", "./a", "a/./b", "", "/", "a/\u{0}b", "a/\u{301}b"])
    func aHostilePathMeansNoMatch(path: String) {
        #expect(refusal([file("project/readme.md", 10), file(path, 4)]) == .unsafePath, "\(path)")
    }

    @Test func anEmptyPartOfAFoldersNameIsHostileToo() {
        #expect(refusal([file("project/readme.md", 10), folder("project//")]) == .unsafePath)
        // Its own trailing `/` is its mark, not an empty part.
        #expect(refusal([file("project/readme.md", 10), folder("project/docs/")]) == nil)
    }

    @Test func aBackslashIsAnOrdinaryCharacter() throws {
        let expected = try expectation([file("..\\..\\evil.txt", 4)], zip: "evil.zip")

        #expect(expected.name == "..\\..\\evil.txt")
    }

    @Test func aZipHoldingAnAppAnywhereIsLeftToTheInstallersAction() {
        #expect(refusal([folder("OtherApp.app/"), file("OtherApp.app/Contents/Info.plist", 400)]) == .holdsAnApp)
        #expect(refusal([file("Tools/Build/My.APP/Contents/MacOS/My", 9)]) == .holdsAnApp)
        // A file merely named like one is not an app.
        #expect(refusal([file("readme.txt", 3), file("notes.app", 4)]) == nil)
    }

    @Test func conflictingEntriesNeverMatch() {
        #expect(refusal([file("a", 1), file("a/b", 2)]) == .conflictingEntries)
        #expect(refusal([file("a/b", 2), file("a", 1)]) == .conflictingEntries)
        #expect(refusal([folder("a/"), file("a", 3)]) == .conflictingEntries)
        #expect(refusal([file("x/a.txt", 1), file("x/a.txt", 2)]) == .conflictingEntries)
        // A file listed twice is unpacked once, so one of the two is beside nothing, even at the
        // same size, and even when the two names differ only in their Unicode form.
        #expect(refusal([file("x/a.txt", 4), file("x/a.txt", 4)]) == .conflictingEntries)
        #expect(refusal([file("x/R\u{E9}sum\u{E9}", 3), file("x/Re\u{301}sume\u{301}", 3)]) == .conflictingEntries)
        // A folder listed twice, or listed and implied, is one folder.
        #expect(refusal([folder("x/"), folder("x/"), folder("x/sub/"), file("x/sub/a.txt", 1)]) == nil)
    }

    @Test func pathsImplyingMoreFoldersThanTheRuleReadsAreTooLarge() {
        // Names of 1,024 bytes, 512 folders deep, each under a top-level folder of its own: within
        // every limit of the listing, but each implies 512 folders.
        let deep = String(repeating: "a/", count: 509)
        let entries = (0..<400).map { index in file(String(format: "d%03d/", index) + deep + "f", 1) }
        #expect(entries.allSatisfy { $0.path.utf8.count <= 1_024 })

        #expect(refusal(entries) == .tooLarge)
    }

    // MARK: - Names

    @Test func namesMatchInExactLetterCaseInAnyUnicodeForm() throws {
        let composed = "R\u{E9}sum\u{E9}.txt"
        let decomposed = "Re\u{301}sume\u{301}.txt"
        let expected = try expectation([file("README.md", 5), file(composed, 3)], zip: "docs.zip")

        #expect(Planner.matches(expected.tree, folderTree(["README.md": .file(sizeInBytes: 5), decomposed: .file(sizeInBytes: 3)])))
        #expect(!Planner.matches(expected.tree, folderTree(["readme.md": .file(sizeInBytes: 5), composed: .file(sizeInBytes: 3)])))
        // The disk's spelling is the one returned.
        #expect(Planner.candidateNames(for: "r\u{E9}sum\u{E9}", among: ["re\u{301}sume\u{301}"]) == ["re\u{301}sume\u{301}"])
        #expect(Planner.candidateNames(for: "project", among: ["Project"]).isEmpty)
    }
}
