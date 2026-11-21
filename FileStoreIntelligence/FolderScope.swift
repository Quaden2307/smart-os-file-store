import Foundation

/// Which folders a tool call is about: one managed folder, or all of them. The model writes a
/// folder's name (untrusted: it may be a custom folder's name, or anything); code matches it
/// against the folders the app manages and never trusts it further.
public enum FolderScope: Sendable, Hashable {
    /// The folder with this name, as the app names it.
    case folder(String)
    case all

    /// What the model may write for every folder.
    static let allWords: Set<String> = ["all", "all folders", "everywhere", "every folder", "everything"]

    /// The scope a call asks for.
    ///
    /// - Parameters:
    ///   - name: What the model wrote. Nil means the folder on screen, or every folder for a
    ///     search inside the last result, whose files may be in several.
    ///   - insideLastResult: True for a search inside the last result.
    /// - Throws: A `FilterError` naming the folders the app manages, for a folder it does not
    ///   manage, or saying why a managed folder cannot be read.
    static func resolve(_ name: String?, in snapshot: FolderSnapshot, insideLastResult: Bool = false) throws(FilterError) -> FolderScope {
        // A snapshot without folders comes from a single folder: nothing to choose.
        guard !snapshot.folders.isEmpty else { return .all }
        let words = name?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            .replacing(/^(my|the|in|on)\s+/, with: "").replacing(/\s+folder$/, with: "") ?? ""
        if words.isEmpty {
            if insideLastResult { return .all }
            return snapshot.folders.first(where: \.isCurrent).map { .folder($0.name) } ?? .all
        }
        if allWords.contains(words) { return .all }
        let match = snapshot.folders.first { $0.name.lowercased() == words }
            // "docs", "desk": the start of one folder's name, and of no other.
            ?? { () -> FolderSnapshot.Folder? in
                guard words.count >= 3 else { return nil }
                let starts = snapshot.folders.filter { $0.name.lowercased().hasPrefix(words) }
                return starts.count == 1 ? starts.first : nil
            }()
        guard let folder = match else {
            let names = snapshot.folders.map(\.name).map(ToolOutput.quoted).joined(separator: ", ")
            throw FilterError(message: "\(ToolOutput.quoted(name ?? "")) is not a folder the app manages. It manages \(names). Say so to the user.")
        }
        switch folder.state {
        case .available:
            return .folder(folder.name)
        case .permissionNeeded:
            throw FilterError(message: "\(ToolOutput.quoted(folder.name)) is managed, but macOS has not allowed the app to read it. Say so; it is not empty.")
        case .unavailable:
            throw FilterError(message: "\(ToolOutput.quoted(folder.name)) is managed, but cannot be found now (its disk may be disconnected). Say so; it is not empty.")
        }
    }

    /// The folder names this scope covers in `snapshot`: the readable ones for every folder.
    func folderNames(in snapshot: FolderSnapshot) -> [String] {
        switch self {
        case .folder(let name):
            [name]
        case .all:
            snapshot.folders.filter { $0.state == .available }.map(\.name)
        }
    }
}

extension FolderSnapshot {
    /// The snapshot narrowed to the files of `scope`.
    func narrowed(to scope: FolderScope) -> FolderSnapshot {
        guard case .folder(let name) = scope else { return self }
        var narrowed = self
        narrowed.files = files.filter { $0.folder == name }
        return narrowed
    }

    /// The folders that a call about every folder could not read, for the reply to mention.
    var unreadableFolders: [Folder] {
        folders.filter { $0.state != .available }
    }
}
