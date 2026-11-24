import Foundation

/// What a cleanup request asked for, read and checked by code from the tool's arguments. The app
/// plans from it, writes "What I understood" from it, and plans it again for Refresh.
public struct CleanupRequest: Sendable, Hashable {
    /// Names from the app's list of cleanup actions, in that list's order.
    public var actions: [String]
    /// Nil for every file.
    public var query: FileQuery?
    /// In place of the app's setting for one request: how long unopened before a file is archived.
    public var archiveAfterDays: Int?
    /// In place of the app's setting for one request: the size from which a download is large.
    public var largeFileMB: Int?
    /// The folder the card is for, by the name the app shows. Nil for the folder on screen.
    public var folder: String?

    public init(actions: [String], query: FileQuery? = nil, archiveAfterDays: Int? = nil, largeFileMB: Int? = nil, folder: String? = nil) {
        self.folder = folder
        self.actions = actions
        self.query = query
        self.archiveAfterDays = archiveAfterDays
        self.largeFileMB = largeFileMB
    }

    /// The files of `snapshot` the request is narrowed to, or nil when it is not narrowed.
    public func fileIDs(in snapshot: FolderSnapshot) -> Set<URL>? {
        query.map { query in Set(snapshot.files.filter(query.matches).map(\.id)) }
    }

    /// The request once per folder of `scope`, with the files it is narrowed to there (nil for
    /// all): a card belongs to one folder, so a request for several makes one card per folder.
    func perFolder(_ scope: FolderScope, in snapshot: FolderSnapshot) -> [(request: CleanupRequest, ids: Set<URL>?)] {
        let folders: [String?] = snapshot.folders.isEmpty ? [nil] : scope.folderNames(in: snapshot)
        return folders.map { folder in
            var request = self
            request.folder = folder
            return (request, request.fileIDs(in: snapshot.narrowed(to: folder.map(FolderScope.folder) ?? .all)))
        }
    }
}

/// A cleanup the app planned for a request, as plain rows. The plan itself stays with the app,
/// under `id`: this module cannot name a plan, and the model never sees the id.
public struct CleanupProposal: Sendable, Equatable, Identifiable {
    public struct Row: Sendable, Equatable {
        public var action: String
        public var count: Int
        /// What its changes would move to the Trash.
        public var bytes: Int64
        /// How many of them the app ticks. The rest are for the user to choose.
        public var tickedCount: Int

        public init(action: String, count: Int, bytes: Int64, tickedCount: Int) {
            self.action = action
            self.count = count
            self.bytes = bytes
            self.tickedCount = tickedCount
        }
    }

    public static let sampleNamesShown = 5

    public let id: UUID
    public var request: CleanupRequest
    /// One per action that found something. Empty when nothing was found, which makes no card.
    public var rows: [Row]
    /// A few of the files' names, for the model's summary.
    public var sampleNames: [String]
    /// Actions asked for that the folder's rules turn off: no rows, and the reply says so.
    public var notOffered: [String]

    public init(id: UUID = UUID(), request: CleanupRequest, rows: [Row], sampleNames: [String], notOffered: [String] = []) {
        self.notOffered = notOffered
        self.id = id
        self.request = request
        self.rows = rows
        self.sampleNames = sampleNames
    }

    public var count: Int { rows.reduce(0) { $0 + $1.count } }
    public var bytes: Int64 { rows.reduce(0) { $0 + $1.bytes } }
}
