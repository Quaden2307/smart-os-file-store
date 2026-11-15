import SwiftUI

/// The places the main window can show, listed in its sidebar.
enum SidebarSection: Hashable, CaseIterable {
    /// The scanned folder's files.
    case downloads

    /// Every confirmed cleanup, from the activity log.
    case activity

    var title: LocalizedStringKey {
        switch self {
        case .downloads:
            "Downloads"
        case .activity:
            "Activity"
        }
    }

    var systemImage: String {
        switch self {
        case .downloads:
            "arrow.down.circle"
        case .activity:
            "clock"
        }
    }
}

/// The main window's sidebar: one row per place. Arrow keys move between them once the sidebar has
/// keyboard focus (Tab), as in Finder.
struct Sidebar: View {
    @Binding var selection: SidebarSection

    var body: some View {
        List(selection: rowSelection) {
            ForEach(SidebarSection.allCases, id: \.self) { section in
                Label(section.title, systemImage: section.systemImage)
                    .tag(section)
            }
        }
        .accessibilityLabel("Places")
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
