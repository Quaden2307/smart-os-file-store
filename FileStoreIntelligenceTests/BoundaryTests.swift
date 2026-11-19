import Foundation
import Testing

/// The chat module must be unable to change files. It gets that by importing none of the app's
/// own modules: it cannot name the executor, the activity log or the database. These tests fail
/// the moment that stops being true (docs/decisions/0020).
@Suite("Boundary")
struct BoundaryTests {
    private static let allowedImports: Set = ["Foundation", "FoundationModels", "os", "Synchronization", "UniformTypeIdentifiers"]

    private enum Failure: Error {
        case projectRootNotFound
    }

    /// The folder holding `project.yml`, found from this file's own path.
    private static func projectRoot() throws -> URL {
        var folder = URL(filePath: #filePath).deletingLastPathComponent()
        for _ in 0..<5 {
            if FileManager.default.fileExists(atPath: folder.appending(path: "project.yml").path(percentEncoded: false)) {
                return folder
            }
            folder.deleteLastPathComponent()
        }
        throw Failure.projectRootNotFound
    }

    /// Every Swift file under a target's folder, at any depth, with `//` comments removed.
    private static func sources(of target: String) throws -> [(name: String, code: String)] {
        let folder = try projectRoot().appending(path: target, directoryHint: .isDirectory)
        let paths = try FileManager.default.subpathsOfDirectory(atPath: folder.path(percentEncoded: false))
        return try paths.filter { $0.hasSuffix(".swift") }.sorted().map { path in
            let text = try String(contentsOf: folder.appending(path: path), encoding: .utf8)
            let code = text.split(separator: "\n", omittingEmptySubsequences: false)
                .map { line in line.range(of: "//").map { line[..<$0.lowerBound] } ?? line }
                .joined(separator: "\n")
            return (path, code)
        }
    }

    /// The modules a source imports, in every form an import can take: attributes, an access
    /// level, or one named declaration (`import struct Module.Name`).
    private static func imports(in code: String) -> [String] {
        let statement = /(?m)(?:^|;)\s*(?:@\w+(?:\([^)]*\))?\s+)*(?:(?:public|package|internal|fileprivate|private)\s+)?import\s+(?:(?:struct|class|enum|protocol|typealias|func|var|let)\s+)?(\w+)/
        return code.matches(of: statement).map { String($0.1) }
    }

    @Test func theImportScanSeesEveryFormOfImport() {
        let code = """
            import Foundation; import Combine
            internal import GRDB
              @preconcurrency import FileStoreCore
            @_exported public import struct AppKit.NSColor
            @_spi(Internal) import SwiftUI
            let imported = "import NotAModule"
            """
        #expect(Self.imports(in: code) == ["Foundation", "Combine", "GRDB", "FileStoreCore", "AppKit", "SwiftUI"])
    }

    @Test func theChatModuleImportsNoneOfOurModules() throws {
        let sources = try Self.sources(of: "FileStoreIntelligence")
        #expect(sources.count >= 8)
        for source in sources {
            let imported = Self.imports(in: source.code)
            #expect(!imported.isEmpty, "\(source.name) imports nothing, so the scan may have missed it")
            for module in imported {
                #expect(Self.allowedImports.contains(module), "\(source.name) imports \(module)")
            }
            // A block comment could hide an import from the scan above, which strips only `//`.
            #expect(!source.code.contains("/*"), "\(source.name) has a block comment")
            // Nothing leaves the Mac: the only model is the on-device one.
            #expect(!source.code.contains("PrivateCloudCompute"), "\(source.name) names Private Cloud Compute")
            // `SafetyTests` reads this folder's top level only, so every source must be there.
            #expect(!source.name.contains("/"), "\(source.name) is in a subfolder that SafetyTests does not scan")
        }
    }

    @Test func theEngineAndTheAppStayFreeOfModelCode() throws {
        for source in try Self.sources(of: "FileStoreCore") {
            let imported = Self.imports(in: source.code)
            #expect(!imported.contains("FileStoreIntelligence"), "\(source.name) imports the chat module")
            #expect(!imported.contains("FoundationModels"), "\(source.name) imports FoundationModels")
        }
        // The app reaches the model only through the chat module.
        for source in try Self.sources(of: "SmartOSFileStore") {
            #expect(!Self.imports(in: source.code).contains("FoundationModels"), "\(source.name) imports FoundationModels")
        }
    }

    @Test func theProjectGivesTheChatModuleNoDependencies() throws {
        let project = try String(contentsOf: Self.projectRoot().appending(path: "project.yml"), encoding: .utf8)
        /// A target's own lines, comments removed: from its name to the next line indented as little as it is.
        func target(_ name: String) throws -> [Substring] {
            let lines = project.split(separator: "\n", omittingEmptySubsequences: false).map { $0.prefix { $0 != "#" } }
            let start = try #require(lines.firstIndex(of: "  \(name):"))
            return Array(lines[(start + 1)...].prefix { $0.hasPrefix("   ") || $0.allSatisfy(\.isWhitespace) })
        }
        let chat = try target("FileStoreIntelligence")
        #expect(chat.contains { $0.contains("MACH_O_TYPE: staticlib") })
        #expect(!chat.contains { $0.contains("dependencies") })
        #expect(!chat.contains { $0.contains("FileStoreCore") || $0.contains("GRDB") })
        // And the engine does not depend on the chat module either.
        #expect(try !target("FileStoreCore").contains { $0.contains("FileStoreIntelligence") })
        // The setting that makes an import with no declared dependency a build error: set once,
        // for every target, and switched off for none.
        #expect(project.contains("\n    DIAGNOSE_MISSING_TARGET_DEPENDENCIES: YES_ERROR\n"))
        #expect(project.components(separatedBy: "DIAGNOSE_MISSING_TARGET_DEPENDENCIES").count == 2)
    }

    @Test func theBuiltChatModuleReferencesNoEngineSymbol() throws {
        // The static archive sits beside this test bundle in the build products.
        let products = Bundle(for: ScriptedModel.Script.self).bundleURL.deletingLastPathComponent()
        let archive = products.appending(path: "FileStoreIntelligence.framework/FileStoreIntelligence")
        let nm = Process()
        nm.executableURL = URL(filePath: "/usr/bin/nm")
        nm.arguments = [archive.path(percentEncoded: false)]
        let output = Pipe()
        nm.standardOutput = output
        nm.standardError = Pipe()
        try nm.run()
        let symbols = String(decoding: output.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        nm.waitUntilExit()
        #expect(nm.terminationStatus == 0)
        // Swift mangles a module's name into every symbol of it, with its length in front.
        #expect(symbols.contains("21FileStoreIntelligence"), "nm did not list the chat module's own symbols")
        #expect(!symbols.contains("13FileStoreCore"), "the chat module references FileStoreCore")
        #expect(!symbols.contains("4GRDB"), "the chat module references GRDB")
    }
}
