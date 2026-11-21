import Foundation

/// A debug build's stand-in for the user's standard folders, so hand testing uses throwaway folders
/// (see the `cleanup-test-fixtures` skill) and never the real ones.
///
/// - `-DemoHome <path>` or `SMARTOS_DEMO_HOME`: `<path>/Downloads`, `<path>/Desktop` and
///   `<path>/Documents` are the three standard folders.
/// - `-ScanFolder <path>` or `SMARTOS_SCAN_FOLDER`: the folder is Downloads, and there is no
///   Desktop and no Documents.
///
/// One override applies: the first that is set, in the order of `Source.allCases` (launch
/// arguments before environment variables, the demo home before the scan folder). The others are
/// then ignored entirely. Release builds ignore all four.
public struct FolderOverride: Sendable, Equatable {
    public enum Kind: Sendable, Equatable {
        case scanFolder
        case demoHome
    }

    /// The ways an override is given, in the order they are looked for.
    public enum Source: Sendable, Equatable, CaseIterable {
        case demoHomeArgument
        case scanFolderArgument
        case demoHomeVariable
        case scanFolderVariable

        /// The launch argument, whose next argument is the path, or the environment variable, whose
        /// value is. An empty variable counts as unset.
        public var name: String {
            switch self {
            case .demoHomeArgument:
                "-DemoHome"
            case .scanFolderArgument:
                "-ScanFolder"
            case .demoHomeVariable:
                "SMARTOS_DEMO_HOME"
            case .scanFolderVariable:
                "SMARTOS_SCAN_FOLDER"
            }
        }

        public var kind: Kind {
            switch self {
            case .demoHomeArgument, .demoHomeVariable:
                .demoHome
            case .scanFolderArgument, .scanFolderVariable:
                .scanFolder
            }
        }

        var isLaunchArgument: Bool {
            self == .demoHomeArgument || self == .scanFolderArgument
        }
    }

    public var kind: Kind { source.kind }

    public let source: Source

    /// The demo home or the scan folder, as a standardized file URL.
    public let folderURL: URL

    /// Describes an override that is already known, for example a temporary folder in a test.
    /// The app itself uses `resolve`, which validates the path.
    public init(source: Source, folderURL: URL) {
        self.source = source
        self.folderURL = folderURL.standardizedFileURL
    }

    /// The override this process was started with, or nil when there is none: always, in a Release build.
    ///
    /// - Throws: `FolderLocationError` when the override that applies is unusable. It is never
    ///   skipped for the next one, or for the real folders.
    public static func resolve(
        arguments: [String] = ProcessInfo.processInfo.arguments,
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) throws(FolderLocationError) -> FolderOverride? {
        #if DEBUG
        for source in Source.allCases {
            let path: String
            if source.isLaunchArgument {
                guard let flagIndex = arguments.firstIndex(of: source.name) else { continue }
                let valueIndex = arguments.index(after: flagIndex)
                guard valueIndex < arguments.endIndex else {
                    throw FolderLocationError.overrideValueMissing(source: source)
                }
                path = arguments[valueIndex]
            } else {
                guard let value = environment[source.name], !value.isEmpty else { continue }
                path = value
            }
            return FolderOverride(source: source, folderURL: try validatedFolder(path: path, source: source))
        }
        #endif
        return nil
    }

    /// The folder at `path`, which must exist and be a folder. `~` stands for the home folder.
    static func validatedFolder(path: String, source: Source) throws(FolderLocationError) -> URL {
        let expandedPath = (path as NSString).expandingTildeInPath
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: expandedPath, isDirectory: &isDirectory) else {
            throw FolderLocationError.overrideDoesNotExist(path: path, source: source)
        }
        guard isDirectory.boolValue else {
            throw FolderLocationError.overrideIsNotAFolder(path: path, source: source)
        }
        return URL(fileURLWithPath: expandedPath, isDirectory: true)
    }
}

/// Why a managed folder could not be found.
public enum FolderLocationError: Error, Sendable, Equatable {
    /// The system reports no such standard folder, or the override in use has none of that kind.
    case standardFolderUnavailable(ManagedFolder.Kind)

    /// The override was given without a path, for example `-ScanFolder` as the last argument.
    case overrideValueMissing(source: FolderOverride.Source)

    /// The override's folder does not exist. `path` is the value as it was given, or for a demo
    /// home the standard folder that is missing from it.
    case overrideDoesNotExist(path: String, source: FolderOverride.Source)

    /// The path exists but is a file, not a folder.
    case overrideIsNotAFolder(path: String, source: FolderOverride.Source)

    /// The folder is one the app does not look after (`FolderSafetyRules`).
    case refused(FolderSafetyRules.Refusal)

    /// A custom folder's bookmark no longer leads to a folder.
    case bookmarkUnusable
}
