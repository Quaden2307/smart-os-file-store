import FileStoreCore
import SwiftUI

/// What the Clean Up menu acts on in the frontmost main window.
struct CleanUpCommandTarget {
    /// False while no cleanup may start: the list is loading, a search or undo is running, or the
    /// activity log does not work.
    let canStart: Bool

    let start: @MainActor (CleanupAction) -> Void

    /// Starts Tidy Now: every action at once, in one overview.
    let startTidyNow: @MainActor () -> Void
}

extension FocusedValues {
    /// The frontmost main window's Clean Up commands. Nil while a sheet is up.
    @Entry var cleanUpCommands: CleanUpCommandTarget?
}

/// The Clean Up menu: Tidy Now (Command-T), then every action the app offers, each with its own
/// shortcut (Shift-Command and a letter). The toolbar's Clean Up menu lists the same actions without shortcuts, so no key is
/// claimed twice.
struct CleanUpCommands: Commands {
    @FocusedValue(\.cleanUpCommands) private var target

    var body: some Commands {
        CommandMenu("Clean Up") {
            Button {
                target?.startTidyNow()
            } label: {
                Label("Tidy Now", systemImage: "sparkles")
            }
            .keyboardShortcut("t", modifiers: .command)
            .disabled(target?.canStart != true)
            Divider()
            ForEach(CleanupAction.menuActions, id: \.self) { action in
                let display = action.display
                Button {
                    target?.start(action)
                } label: {
                    Label(display.commandTitle, systemImage: display.symbol)
                }
                .keyboardShortcut(display.shortcut)
                .disabled(target?.canStart != true)
            }
        }
    }
}
