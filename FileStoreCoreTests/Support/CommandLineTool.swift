import Foundation

/// Runs one of the system's command-line tools (`ditto`, `hdiutil`, `zipinfo`) for fixtures that
/// Foundation cannot make itself, such as a zip archive or a disk image.
enum CommandLineTool {
    struct Failure: Error, CustomStringConvertible {
        let tool: String
        let status: Int32
        let output: String

        var description: String { "\(tool) exited with \(status): \(output)" }
    }

    /// Runs `tool` with `arguments` and returns what it printed. Throws when it exits with a failure.
    @discardableResult
    static func run(_ tool: String, _ arguments: [String]) throws -> String {
        let process = Process()
        process.executableURL = URL(filePath: tool)
        process.arguments = arguments
        let output = Pipe()
        process.standardOutput = output
        process.standardError = output
        try process.run()
        let data = output.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        let text = String(decoding: data, as: UTF8.self)
        guard process.terminationStatus == 0 else {
            throw Failure(tool: tool, status: process.terminationStatus, output: text)
        }
        return text
    }
}
