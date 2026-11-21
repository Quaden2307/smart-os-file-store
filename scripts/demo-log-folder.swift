// Prints the folder of the activity log a debug build keeps for a demo home, worked out as
// ActivityLogLocation does (a hash of the demo home's path, under the temporary directory), so
// scripts/run-demo.sh --reset can remove that log and nothing else.
//
// Usage: xcrun swift scripts/demo-log-folder.swift <demo home path>
import CryptoKit
import Foundation

guard CommandLine.arguments.count == 2 else {
    FileHandle.standardError.write(Data("usage: demo-log-folder.swift <demo home path>\n".utf8))
    exit(2)
}
let expanded = (CommandLine.arguments[1] as NSString).expandingTildeInPath
let path = URL(fileURLWithPath: expanded, isDirectory: true).standardizedFileURL.path(percentEncoded: false)
let digest = SHA256.hash(data: Data(("demo-home:" + path).utf8))
let name = digest.prefix(8).map { String(format: "%02x", $0) }.joined()
print(FileManager.default.temporaryDirectory.appending(path: "com.quaden2307.SmartOSFileStore.debug/\(name)").path(percentEncoded: false))
