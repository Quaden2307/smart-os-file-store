import Foundation

/// The folder the app scans.
///
/// By default this is the user's Downloads folder. Debug builds accept an override so hand
/// testing can point the app at a throwaway folder (see the `cleanup-test-fixtures` skill):
/// the launch argument `-ScanFolder <path>`, or the environment variable `SMARTOS_SCAN_FOLDER`.
/// The launch argument wins when both are set, and the environment variable is then ignored
/// entirely. Release builds ignore both.
public struct ScanLocation: Sendable, Equatable {
    /// Where a resolved location came from.
    public enum Source: Sendable, Equatable {
        case downloadsFolder
        case launchArgument
        case environmentVariable
    }

    /// Debug-only launch argument. The next argument is the folder path.
    public static let launchArgumentName = "-ScanFolder"

    /// Debug-only environment variable holding the folder path. An empty value counts as unset.
    public static let environmentVariableName = "SMARTOS_SCAN_FOLDER"

    /// The folder to scan, as a standardized file URL.
    public let folderURL: URL

    /// How `folderURL` was chosen.
    public let source: Source

    /// Describes a folder that is already known, for example a temporary folder in a test.
    ///
    /// The app itself uses `resolve`, which finds Downloads and validates the debug override.
    public init(folderURL: URL, source: Source) {
        self.folderURL = folderURL.standardizedFileURL
        self.source = source
    }

    /// Resolves the folder to scan.
    ///
    /// - Parameters:
    ///   - arguments: The process arguments. Defaults to the current process's arguments.
    ///   - environment: The process environment. Defaults to the current process's environment.
    /// - Throws: `ScanLocationError` when an override path is unusable or Downloads cannot be found.
    public static func resolve(
        arguments: [String] = ProcessInfo.processInfo.arguments,
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) throws(ScanLocationError) -> ScanLocation {
        #if DEBUG
        if let override = try debugOverride(arguments: arguments, environment: environment) {
            return override
        }
        #endif
        return try downloadsFolder()
    }

    private static func downloadsFolder() throws(ScanLocationError) -> ScanLocation {
        let urls = FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask)
        guard let url = urls.first else {
            throw ScanLocationError.downloadsFolderUnavailable
        }
        return ScanLocation(folderURL: url, source: .downloadsFolder)
    }

    #if DEBUG
    private static func debugOverride(
        arguments: [String],
        environment: [String: String]
    ) throws(ScanLocationError) -> ScanLocation? {
        if let flagIndex = arguments.firstIndex(of: launchArgumentName) {
            let valueIndex = arguments.index(after: flagIndex)
            guard valueIndex < arguments.endIndex else {
                throw ScanLocationError.overrideValueMissing(source: .launchArgument)
            }
            return try validatedFolder(path: arguments[valueIndex], source: .launchArgument)
        }
        if let path = environment[environmentVariableName], !path.isEmpty {
            return try validatedFolder(path: path, source: .environmentVariable)
        }
        return nil
    }

    private static func validatedFolder(path: String, source: Source) throws(ScanLocationError) -> ScanLocation {
        let expandedPath = (path as NSString).expandingTildeInPath
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: expandedPath, isDirectory: &isDirectory) else {
            throw ScanLocationError.overrideDoesNotExist(path: path, source: source)
        }
        guard isDirectory.boolValue else {
            throw ScanLocationError.overrideIsNotAFolder(path: path, source: source)
        }
        let url = URL(fileURLWithPath: expandedPath, isDirectory: true)
        return ScanLocation(folderURL: url, source: source)
    }
    #endif
}

/// Why a scan location could not be resolved.
public enum ScanLocationError: Error, Sendable, Equatable {
    /// The user's Downloads folder could not be located.
    case downloadsFolderUnavailable

    /// The override was given without a path, for example `-ScanFolder` as the last argument.
    case overrideValueMissing(source: ScanLocation.Source)

    /// The override path does not exist. `path` is the value as it was given.
    case overrideDoesNotExist(path: String, source: ScanLocation.Source)

    /// The override path exists but is a file, not a folder. `path` is the value as it was given.
    case overrideIsNotAFolder(path: String, source: ScanLocation.Source)
}
