import FileStoreCore
import SwiftUI

/// The places the main window can show, listed in its sidebar.
enum SidebarSection: Hashable {
    /// A managed folder's files, or the way to turn it on.
    case folder(FolderPlace)

    /// Every confirmed cleanup, from the activity log.
    case activity

    static let downloads = SidebarSection.folder(.standard(.downloads))

    /// The folder this place shows, if it shows one.
    var folderPlace: FolderPlace? {
        if case .folder(let place) = self { place } else { nil }
    }
}

extension ManagedFolder.Kind {
    var systemImage: String {
        switch self {
        case .downloads:
            "arrow.down.circle"
        case .desktop:
            "menubar.dock.rectangle"
        case .documents:
            "doc"
        case .custom:
            "folder"
        }
    }
}

/// One row of the sidebar's Folders section.
struct SidebarFolderRow: Identifiable {
    enum State {
        /// Managed and found: its item count.
        case shown(count: Int)
        /// Desktop or Documents, offered but not turned on.
        case off
        /// On the list, but cannot be found now.
        case unavailable
    }

    let place: FolderPlace
    let name: String
    let kind: ManagedFolder.Kind
    let state: State

    var id: FolderPlace { place }
}

/// What the sidebar asks the window to do with a folder.
struct SidebarFolderActions {
    let turnOn: @MainActor (ManagedFolder.Kind) -> Void
    let add: @MainActor () -> Void
    let addDropped: @MainActor ([URL]) -> Void
    let startRenaming: @MainActor (FolderPlace) -> Void
    let remove: @MainActor (FolderPlace) -> Void
}

/// The main window's sidebar: each managed folder with its count on the right, Desktop and
/// Documents offered until they are turned on, Add Folder, then Activity. Arrow keys move between
/// rows once the sidebar has keyboard focus (Tab), as in Finder. A folder dragged from Finder onto
/// it is added as Add Folder adds one.
struct Sidebar: View {
    @Binding var selection: SidebarSection

    let folders: [SidebarFolderRow]

    /// Cleanups in the activity log, undone or not.
    let cleanupCount: Int

    /// False until the activity log is open: the folder list lives there.
    let canChangeFolders: Bool

    let actions: SidebarFolderActions

    var body: some View {
        List(selection: rowSelection) {
            Section("Folders") {
                ForEach(folders) { folder in
                    folderRow(folder)
                }
                Button {
                    actions.add()
                } label: {
                    Label("Add folder…", systemImage: "plus")
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
                .disabled(!canChangeFolders)
                .help("Choose a folder for Smart OS File Store to look after")
                .accessibilityLabel("Add folder")
            }
            Section("History") {
                Label("Activity", systemImage: "clock")
                    .badge(cleanupCount)
                    .accessibilityValue(Text("^[\(cleanupCount) cleanup](inflect: true)"))
                    .tag(SidebarSection.activity)
            }
        }
        .accessibilityLabel("Places")
        .dropDestination(for: URL.self) { urls, _ in
            let folders = urls.filter(\.hasDirectoryPath)
            guard canChangeFolders, !folders.isEmpty else { return false }
            actions.addDropped(folders)
            return true
        }
    }

    @ViewBuilder
    private func folderRow(_ folder: SidebarFolderRow) -> some View {
        let label = Label(folder.name, systemImage: folder.kind.systemImage)
        Group {
            switch folder.state {
            case .shown(let count):
                label
                    .badge(count)
                    .accessibilityValue(Text("^[\(count) item](inflect: true)"))
            case .off:
                label
                    .foregroundStyle(.secondary)
                    .badge(Text("Off"))
                    .accessibilityValue(Text("Off"))
            case .unavailable:
                label
                    .foregroundStyle(.secondary)
                    .badge(Text(Image(systemName: "exclamationmark.triangle")))
                    .accessibilityValue(Text("Not available"))
            }
        }
        .tag(SidebarSection.folder(folder.place))
        .contextMenu {
            if case .off = folder.state {
                Button("Turn On \(folder.name)") {
                    actions.turnOn(folder.kind)
                }
                .disabled(!canChangeFolders)
            }
            if case .custom = folder.place {
                Button("Rename…") {
                    actions.startRenaming(folder.place)
                }
                .disabled(!canChangeFolders)
            }
            if folder.kind != .downloads, !isOff(folder) {
                Button(folder.kind == .custom ? "Remove from Sidebar" : "Turn Off \(folder.name)") {
                    actions.remove(folder.place)
                }
                .disabled(!canChangeFolders)
            }
        }
    }

    private func isOff(_ folder: SidebarFolderRow) -> Bool {
        if case .off = folder.state { true } else { false }
    }

    /// A list may report no selection (Command-click on the selected row); one place is always shown.
    private var rowSelection: Binding<SidebarSection?> {
        Binding(
            get: { selection },
            set: { section in
                if let section {
                    selection = section
                }
            }
        )
    }
}

/// Shows a place of the main window and gives its list keyboard focus, so the arrow keys work at
/// once. Clicking or arrowing through the sidebar changes the place without moving focus, so the
/// sidebar keeps it.
struct PlaceSwitcher {
    let show: @MainActor (SidebarSection) -> Void
    /// File > Add Folder…, nil while the folder list cannot change.
    let addFolder: (@MainActor () -> Void)?
}

extension FocusedValues {
    /// The frontmost main window's way to change place, for the View menu. Nil while a sheet is up.
    @Entry var placeSwitcher: PlaceSwitcher?
}

/// View menu: go to Downloads or to Activity (Shift-Command-A), the same places as the sidebar,
/// below SwiftUI's own Show/Hide Sidebar.
struct PlaceCommands: Commands {
    @FocusedValue(\.placeSwitcher) private var switcher

    var body: some Commands {
        CommandGroup(after: .newItem) {
            Button("Add Folder…") {
                switcher?.addFolder?()
            }
            .keyboardShortcut("n", modifiers: [.command, .shift])
            .disabled(switcher?.addFolder == nil)
        }
        CommandGroup(after: .sidebar) {
            Button("Downloads") {
                switcher?.show(.downloads)
            }
            .disabled(switcher == nil)
            Button("Activity") {
                switcher?.show(.activity)
            }
            .keyboardShortcut("a", modifiers: [.command, .shift])
            .disabled(switcher == nil)
            Divider()
        }
    }
}
