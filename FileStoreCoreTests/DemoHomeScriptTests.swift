import Foundation
import Testing

/// scripts/make-demo-home.sh writes only into a throwaway folder (decision record 0032): its path
/// checks, run alone (`DEMO_DRY_RUN`), refuse the real home, the folders in it, system places,
/// the top of the disk and a folder holding files the script did not make. Nothing is written.
@Suite("Demo home script")
struct DemoHomeScriptTests {
    private static let script = URL(filePath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
        .appending(path: "scripts/make-demo-home.sh")

    /// The script's exit status and what it printed, for `path`, checks only.
    private func check(_ path: String) throws -> (status: Int32, output: String) {
        let process = Process()
        process.executableURL = URL(filePath: "/bin/bash")
        process.arguments = [Self.script.path(percentEncoded: false), path]
        process.environment = ProcessInfo.processInfo.environment.merging(["DEMO_DRY_RUN": "1"]) { _, new in new }
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe
        try process.run()
        process.waitUntilExit()
        let output = String(data: pipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
        return (process.terminationStatus, output)
    }

    @Test func realAndSystemPlacesAreRefused() throws {
        let home = FileManager.default.homeDirectoryForCurrentUser.path(percentEncoded: false)
        for path in [home, "\(home)/Downloads/demo", "\(home)/Desktop/demo", "\(home)/Documents", "/", "/System/demo", "/Users"] {
            let result = try check(path)
            #expect(result.status != 0, "\(path) was not refused: \(result.output)")
            #expect(result.output.contains("make-demo-home:"), "\(path)")
        }
    }

    @Test func aFolderWithOtherFilesIsRefusedAndANewOneAccepted() throws {
        try withTemporaryFolder { root in
            let busy = root.appending(path: "busy")
            try FileManager.default.createDirectory(at: busy, withIntermediateDirectories: false)
            try Data("mine".utf8).write(to: busy.appending(path: "someone-elses.txt"))
            let refused = try check(busy.path(percentEncoded: false))
            #expect(refused.status != 0)
            #expect(refused.output.contains("did not make"))

            let fresh = root.appending(path: "fresh")
            let accepted = try check(fresh.path(percentEncoded: false))
            #expect(accepted.status == 0, "\(accepted.output)")
            // The checks alone write nothing.
            #expect(!FileManager.default.fileExists(atPath: fresh.path(percentEncoded: false)))
        }
    }
}
