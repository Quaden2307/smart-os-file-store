import Foundation
import os

/// The folders the app looks after, and where each one is now.
///
/// The list lives in the activity log (`folders`), which gives each folder its ID. The registry
/// finds each one on disk: a standard folder by asking the system, each launch, and a custom folder
/// through its bookmark. Whatever it finds must pass `FolderSafetyRules`, when a folder is added
/// and every time it is found again. The list starts with Downloads only.
///
/// This is the one place in the engine that asks the system where Downloads is. With a debug
/// override in use (`FolderOverride`) the system is never asked, so the real folders are never found.
public struct FolderRegistry: Sendable {
    private static let logger = Logger(subsystem: "com.quaden2307.FileStoreCore", category: "FolderRegistry")

    /// What stands in for the standard folders: nil for the user's real ones. A failure is an
    /// override that was given but cannot be used; no folder is found then, never the real ones.
    private let override: Result<FolderOverride?, FolderLocationError>

    public let rules: FolderSafetyRules

    public init(override: FolderOverride? = nil, rules: FolderSafetyRules) {
        self.override = .success(override)
        self.rules = rules
    }

    private init(overrideFailure: FolderLocationError, rules: FolderSafetyRules) {
        self.override = .failure(overrideFailure)
        self.rules = rules
    }

    /// The registry for this process: the user's real folders, or in a debug build the override it
    /// was started with. Under an override the temporary directory is exempt from the
    /// system-location rule, so a throwaway folder can stand in for Downloads.
    ///
    /// - Parameter appDataFolders: Where the app keeps its own data, which is never managed.
    public static func forProcess(
        arguments: [String] = ProcessInfo.processInfo.arguments,
        environment: [String: String] = ProcessInfo.processInfo.environment,
        appDataFolders: [URL]
    ) -> FolderRegistry {
        let home = FileManager.default.homeDirectoryForCurrentUser
        let testRoots = [FileManager.default.temporaryDirectory, URL(filePath: "/private/tmp", directoryHint: .isDirectory)]
        do throws(FolderLocationError) {
            guard let override = try FolderOverride.resolve(arguments: arguments, environment: environment) else {
                return FolderRegistry(rules: FolderSafetyRules(home: home, appDataFolders: appDataFolders))
            }
            // A demo home is judged as a home, and the real one stays one.
            let rules = FolderSafetyRules(
                home: override.kind == .demoHome ? override.folderURL : home,
                otherHomes: override.kind == .demoHome ? [home] : [],
                appDataFolders: appDataFolders,
                allowedRoots: testRoots
            )
            return FolderRegistry(override: override, rules: rules)
        } catch {
            return FolderRegistry(
                overrideFailure: error,
                rules: FolderSafetyRules(home: home, appDataFolders: appDataFolders, allowedRoots: testRoots)
            )
        }
    }

    /// The override in use, if any. For diagnostics.
    public var activeOverride: FolderOverride? {
        (try? override.get()) ?? nil
    }

    // MARK: - Finding

    /// Downloads as it is found without the log: the right place, under an ID made for this call
    /// and stored nowhere. The file list scans it at once, before the log is open and when it cannot
    /// be opened. Nothing that writes to the log may use it; that takes a folder from `folders(in:)`.
    ///
    /// For the user's real folders this asks the system where Downloads is and looks at nothing on
    /// disk, so it is safe on the main actor. The rules are `refusal(for:)`, asked before the folder
    /// is listed.
    public func provisionalDownloads() throws(FolderLocationError) -> ManagedFolder {
        ManagedFolder(kind: .downloads, url: try standardURL(for: .downloads))
    }

    /// Why `folder` may not be managed where it is now, or nil. Asked again before every listing,
    /// since where a link leads can change. A standard folder that is not there is not refused: the
    /// listing says it cannot be found, and finds it again when it is back.
    @concurrent
    public func refusal(for folder: ManagedFolder) async -> FolderSafetyRules.Refusal? {
        refusal(at: folder.url, kind: folder.kind, managed: [])
    }

    private func refusal(at url: URL, kind: ManagedFolder.Kind, managed: [URL]) -> FolderSafetyRules.Refusal? {
        let refusal = rules.refusal(for: url, managed: managed)
        return kind != .custom && refusal == .notAFolder ? nil : refusal
    }

    /// The folders on the list that were found, in the order they were added. One that cannot be
    /// found, or that the rules refuse, is left out and logged. Of two folders where one holds the
    /// other, the one added first stays.
    @concurrent
    public func folders(in log: ActivityLog) async throws(ActivityLogError) -> [ManagedFolder] {
        try await entries(in: log).compactMap(\.folder)
    }

    /// Every folder on the list, in the order they were added, each with where it is now or why it
    /// cannot be used: a custom folder on a disk that is not connected, or one that was deleted,
    /// stays on the list under its last known name and is found again when it is back.
    @concurrent
    public func entries(in log: ActivityLog) async throws(ActivityLogError) -> [FolderEntry] {
        var found: [URL] = []
        var entries: [FolderEntry] = []
        for stored in try log.storedFolders() where !stored.isRemoved {
            let result = locate(stored, among: found, log: log)
            if case .success(let folder) = result {
                found.append(folder.url)
            } else if case .failure(let error) = result {
                Self.logger.notice("A managed folder could not be used: \(String(describing: error), privacy: .private)")
            }
            entries.append(FolderEntry(id: stored.id, kind: stored.kind, storedName: stored.displayName, state: result))
        }
        return entries
    }

    /// Gives a custom folder a new name in the app. Nothing on disk changes.
    @concurrent
    public func setDisplayName(of id: ManagedFolder.ID, to name: String, in log: ActivityLog) async throws(ActivityLogError) {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        try log.renameFolder(id: id, to: trimmed)
    }

    /// Keeps a folder's own rules; nil goes back to its kind's defaults. Nothing on disk changes, and
    /// nothing is recorded in the activity log's history.
    @concurrent
    public func setRules(_ rules: FolderRules?, of id: ManagedFolder.ID, in log: ActivityLog) async throws(ActivityLogError) {
        try log.setRules(rules, ofFolder: id)
    }

    /// The folder with `id`, whether it is on the list or was taken off it, where it is now. Undo
    /// asks this for the folder a run was made in. Nil when the log holds no such folder, it cannot
    /// be found, or the rules refuse where it is.
    @concurrent
    public func folder(id: ManagedFolder.ID, in log: ActivityLog) async throws(ActivityLogError) -> ManagedFolder? {
        guard let stored = try log.storedFolders().first(where: { $0.id == id }) else {
            return nil
        }
        return try? locate(stored, among: [], log: log).get()
    }

    // MARK: - Changing the list

    /// Puts one of the user's standard folders on the list. A kind that was on it before gets its
    /// old ID back.
    @concurrent
    public func add(_ kind: ManagedFolder.Kind, to log: ActivityLog) async throws(ActivityLogError) -> Result<ManagedFolder, FolderLocationError> {
        let url: URL
        do throws(FolderLocationError) {
            url = try standardURL(for: kind)
        } catch {
            return .failure(error)
        }
        let managed = try await folders(in: log)
        if let known = managed.first(where: { $0.kind == kind }) {
            return .success(known)
        }
        if let refusal = refusal(at: url, kind: kind, managed: managed.map(\.url)) {
            return .failure(.refused(refusal))
        }
        let stored = try log.addStandardFolder(kind)
        return .success(ManagedFolder(id: stored.id, kind: kind, url: url, rules: stored.rules))
    }

    /// Puts a folder the user chose on the list, with a bookmark to find it again.
    ///
    /// - Parameter name: What to call it. By default the folder's name on disk.
    @concurrent
    public func add(customFolderAt url: URL, named name: String? = nil, to log: ActivityLog) async throws(ActivityLogError) -> Result<ManagedFolder, FolderLocationError> {
        let managed = try await folders(in: log)
        if let refusal = rules.refusal(for: url, managed: managed.map(\.url)) {
            return .failure(.refused(refusal))
        }
        guard let bookmark = try? url.bookmarkData() else {
            return .failure(.bookmarkUnusable)
        }
        // Found through its bookmark before it goes on the list, so a folder that cannot be found
        // again is never added, and its path is spelled as every later launch spells it.
        let candidate = StoredFolder(
            id: UUID(),
            kind: .custom,
            displayName: name ?? url.standardizedFileURL.lastPathComponent,
            bookmark: bookmark,
            identity: Self.identity(ofFolderAt: url),
            isRemoved: false
        )
        let found = locate(candidate, among: managed.map(\.url), log: log)
        if case .success = found {
            try log.addCustomFolder(candidate)
        }
        return found
    }

    /// Takes `folder` off the list. The log keeps it, so the runs made in it can still be undone.
    @concurrent
    public func remove(_ folder: ManagedFolder, from log: ActivityLog, now: Date = .now) async throws(ActivityLogError) {
        try log.removeFolder(id: folder.id, at: now)
    }

    /// Takes the folder with `id` off the list, found or not.
    @concurrent
    public func remove(folderID id: ManagedFolder.ID, from log: ActivityLog, now: Date = .now) async throws(ActivityLogError) {
        try log.removeFolder(id: id, at: now)
    }

    // MARK: - Where a folder is

    /// The system's directory for a standard kind, and its name in a demo home.
    private static func standardDirectory(for kind: ManagedFolder.Kind) -> (directory: FileManager.SearchPathDirectory, name: String)? {
        switch kind {
        case .downloads:
            (.downloadsDirectory, "Downloads")
        case .desktop:
            (.desktopDirectory, "Desktop")
        case .documents:
            (.documentDirectory, "Documents")
        case .custom:
            nil
        }
    }

    private func standardURL(for kind: ManagedFolder.Kind) throws(FolderLocationError) -> URL {
        guard let standard = Self.standardDirectory(for: kind) else {
            throw FolderLocationError.standardFolderUnavailable(kind)
        }
        guard let override = try override.get() else {
            guard let url = FileManager.default.urls(for: standard.directory, in: .userDomainMask).first else {
                throw FolderLocationError.standardFolderUnavailable(kind)
            }
            return url
        }
        switch override.kind {
        case .scanFolder:
            guard kind == .downloads else {
                throw FolderLocationError.standardFolderUnavailable(kind)
            }
            return override.folderURL
        case .demoHome:
            // A demo home that is the real home would hand out the real folders.
            let realHome = FileStatus.realPath(of: FileManager.default.homeDirectoryForCurrentUser)
            guard let demoHome = FileStatus.realPath(of: override.folderURL), demoHome != realHome else {
                throw FolderLocationError.refused(.homeFolder)
            }
            let url = override.folderURL.appending(path: standard.name, directoryHint: .isDirectory)
            return try FolderOverride.validatedFolder(path: url.path(percentEncoded: false), source: override.source)
        }
    }

    /// Which folder is at `url` on its volume. Nil where the volume gives its items no lasting
    /// identity, or nothing can be read there.
    private static func identity(ofFolderAt url: URL) -> PersistentFileIdentity? {
        let path = url.path(percentEncoded: false)
        guard let status = try? FileStatus.of(path: path, followingLinks: true), status.isDirectory else {
            return nil
        }
        return VolumeIdentity.of(folderPath: path)?.identity(of: status)
    }

    /// Finds `stored` and applies the rules to where it is.
    ///
    /// - Parameter managed: The managed folders it must not be inside of, or hold.
    private func locate(_ stored: StoredFolder, among managed: [URL], log: ActivityLog) -> Result<ManagedFolder, FolderLocationError> {
        let url: URL
        var locator = ManagedFolder.Locator.standard
        if stored.kind == .custom {
            var isStale = false
            guard let bookmark = stored.bookmark,
                  var resolved = try? URL(resolvingBookmarkData: bookmark, options: [.withoutUI, .withoutMounting], bookmarkDataIsStale: &isStale) else {
                return .failure(.bookmarkUnusable)
            }
            // A bookmark tries the old path first, and takes whatever folder is there now. Only the
            // folder that was added is the managed one: when another has its place, it is looked
            // for by what it is on its volume.
            if let identity = stored.identity, Self.identity(ofFolderAt: resolved) != identity {
                guard let volume = VolumeIdentity.of(folderPath: resolved.path(percentEncoded: false)),
                      volume.uuid == identity.volumeUUID,
                      let path = volume.path(ofNumber: identity.fileNumber) else {
                    return .failure(.bookmarkUnusable)
                }
                resolved = URL(filePath: path, directoryHint: .isDirectory)
                isStale = true
            }
            url = resolved
            locator = .bookmark(bookmark)
            // The folder was renamed or moved: it was still found, and its bookmark is made again.
            if isStale, let fresh = try? resolved.bookmarkData() {
                locator = .bookmark(fresh)
                do throws(ActivityLogError) {
                    try log.updateBookmark(fresh, ofFolder: stored.id)
                } catch {
                    Self.logger.notice("A folder's bookmark could not be renewed: \(String(describing: error), privacy: .public)")
                }
            }
        } else {
            do throws(FolderLocationError) {
                url = try standardURL(for: stored.kind)
            } catch {
                return .failure(error)
            }
        }
        if let refusal = refusal(at: url, kind: stored.kind, managed: managed) {
            return .failure(.refused(refusal))
        }
        return .success(ManagedFolder(id: stored.id, kind: stored.kind, displayName: stored.displayName, locator: locator, url: url, rules: stored.rules))
    }
}

/// A folder on the list, found or not.
public struct FolderEntry: Sendable, Identifiable {
    public let id: ManagedFolder.ID

    public let kind: ManagedFolder.Kind

    /// The name the user gave a custom folder. Nil for a standard folder.
    public let storedName: String?

    /// Where the folder is now, or why it cannot be used.
    public let state: Result<ManagedFolder, FolderLocationError>

    /// The folder, when it was found and may be managed.
    public var folder: ManagedFolder? { try? state.get() }
}
