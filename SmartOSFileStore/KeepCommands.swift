import SwiftUI

/// What the File menu's Kept items act on in the frontmost main window.
struct KeepCommandTarget {
    /// What Keep This File would do for the selection; nil when nothing is selected.
    let toggle: KeepToggle?

    /// False when nothing is selected, or the Kept list cannot be changed now.
    let canToggle: Bool

    let toggleSelection: @MainActor () -> Void

    /// False when nothing is Kept, or the Kept list cannot be changed now.
    let canStopKeepingAll: Bool

    /// Asks first, then empties the Kept list.
    let stopKeepingAll: @MainActor () -> Void
}

extension FocusedValues {
    /// The frontmost main window's Kept commands. Nil while a sheet is up.
    @Entry var keepCommands: KeepCommandTarget?
}

/// File menu: Keep This File (Shift-Command-K; Command-K is the chat bar's), which reads Stop
/// Keeping when every selected item is Kept, and Stop Keeping All, which asks first.
struct KeepCommands: Commands {
    @FocusedValue(\.keepCommands) private var target

    var body: some Commands {
        CommandGroup(after: .newItem) {
            Divider()
            Button((target?.toggle ?? .keep).title) {
                target?.toggleSelection()
            }
            .keyboardShortcut("k", modifiers: [.command, .shift])
            .disabled(target?.canToggle != true)
            Button("Stop Keeping All…") {
                target?.stopKeepingAll()
            }
            .disabled(target?.canStopKeepingAll != true)
        }
    }
}
